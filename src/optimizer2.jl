@kwdef mutable struct Timers
    start_time::Float64 = 0.
    initialize_time::Float64 = 0.
    eval_objective_time::Float64 = 0.
    eval_primal_feasibility_time::Float64 = 0.
    eval_dual_feasibility_time::Float64 = 0.
    update_subproblem_time::Float64 = 0.
    solve_subproblem_time::Float64 = 0.
    total_time::Float64 = 0.
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    graph::OptiGraph                              #Subgraphs should not have any overlap and should cover all the nodes
    subproblem_graphs::Vector{OptiGraph}          #These are expanded subgraphs (i.e. subgraphs with overlap)

    sub_optimizer::Any
    tolerance::Float64
    max_iterations::Int64

    # x_neighbor_indices::Dict{OptiGraph,Vector{Int64}}   #primals into subproblem
    # l_neighbor_indices::Dict{OptiGraph,Vector{Int64}}   #duals into subproblem

    node_subgraph_map::Dict                       #map optinodes to "owning" subgraph
    expanded_subgraph_map::Dict
    incident_variable_map::Dict                   #map variable indices in optigraphs to ghost (copy) variables
    subproblem_links::Vector                            #link constraints that do dual updates

    x_vals::Vector{Float64}                       #current primal values that get communicated to subproblems
    l_vals::Vector{Float64}                       #current dual values that get communicated to subproblems

    status::MOI.TerminationStatusCode
    err_pr::Float64
    err_du::Float64
    objective_value::Float64

    iteration::Int64
    primal_error_iters::Vector{Float64}
    dual_error_iters::Vector{Float64}
    objective_iters::Vector{Float64}
    solve_time::Float64

    #plasmo_optimizer_hook::Function
    timers::Timers
    loaded::Bool

    function Optimizer()
        optimizer = new()

        optimizer.subproblem_graphs = Vector{OptiGraph}()
        # optimizer.x_neighbor_indices = Dict{OptiGraph,Vector{Int64}}()
        # optimizer.l_neighbor_indices = Dict{OptiGraph,Vector{Int64}}()

        optimizer.node_subgraph_map = Dict()
        optimizer.expanded_subgraph_map = Dict()
        optimizer.subproblem_links = Vector{Vector{LinkConstraintRef}}()
        optimizer.incident_variable_map = Dict()

        optimizer.x_vals = Vector{Float64}()  #Primal values for communication
        optimizer.l_vals = Vector{Float64}()  #Dual values for communication

        optimizer.err_pr = Inf
        optimizer.err_du = Inf
        optimizer.objective_value = 0
        optimizer.status = MOI.OPTIMIZE_NOT_CALLED
        optimizer.iteration = 0
        optimizer.primal_error_iters = Float64[]
        optimizer.dual_error_iters = Float64[]
        optimizer.objective_iters = Float64[]

        optimizer.timers = Timers()
        optimizer.loaded = false

        return optimizer
    end
end

function Optimizer(graph::OptiGraph,subgraphs::Vector{OptiGraph};
    sub_optimizer = nothing,
    primal_links::Vector{LinkConstraintRef} = LinkConstraintRef[],
    dual_links::Vector{LinkConstraintRef} = LinkConstraintRef[],
    tolerance = 1e-6,
    max_iterations = 100)

    optimizer = Optimizer()
    for subgraph in subgraphs
        sub = Plasmo.optigraph_reference(subgraph)
        push!(optimizer.subproblem_graphs,sub)
        optimizer.x_neighbor_indices[sub] = Int64[]
        optimizer.l_neighbor_indices[sub] = Int64[]
    end

    optimizer.graph = graph
    optimizer.sub_optimizer = sub_optimizer
    optimizer.tolerance = tolerance
    optimizer.max_iterations = max_iterations

    return optimizer
end

function _check_valid_subgraphs(graph::OptiGraph,subgraphs::Vector{OptiGraph})
    subgraph_nodes = union(all_nodes.(subgraphs)...)
    length(subgraph_nodes) == num_all_nodes(graph) || error("Invalid subgraphs given to optimizer.  The number of nodes in subgraphs does not match the number of nodes
    in the optigraph.")
    all((node) -> node in all_nodes(graph),subgraph_nodes) || error("Invalid subgraphs given to optimizer.  At least one provided subgraph
    constrains an optinode that is not in the optigraph.")

    #TODO: check for overlap of at least 1.

    #TODO: check for non-contiguous partitions and raise warning if they are not
    return true
end

function _initialize_optimizer!(optimizer::Optimizer)
    if optimizer.sub_optimizer == nothing
        error("No optimizer set for the subproblems.  Please provide an optimizer constructor to use to solve subproblem optigraphs")
    end

    optimizer.timers.initialize_time = @elapsed begin
        graph = optimizer.graph
        overlap_subgraphs = optimizer.subproblem_graphs
        primal_links = optimizer.primal_links
        dual_links = optimizer.dual_links

        _check_valid_subgraphs(graph,overlap_subgraphs)
        n_subproblems = length(optimizer.subproblem_graphs)
        
        #MAP OPTINODES TO ORIGNAL SUBGRAPHS
        original_subgraphs = getsubgraphs(graph)
        for sub in original_subgraphs
            for node in all_nodes(sub)
                optimizer.node_subgraph_map[node] = sub
            end
        end

        #Map subgraphs to their expanded versions
        for i = 1:length(optimizer.subproblem_graphs)
            original_subgraph = original_subgraphs[i]
            expanded_subgraph = optimizer.subproblem_graphs[i]
            @assert intersect(all_nodes(original_subgraph),all_nodes(expanded_subgraph)) == all_nodes(original_subgraph)
            optimizer.expanded_subgraph_map[original_subgraph] = expanded_subgraph #TODO: make sure these match up
            expanded_subgraph.ext[:restricted_subgraph] = original_subgraph
            expanded_subgraph.ext[:restricted_objective] = sum(objective_function(node) for node in all_nodes(original_subgraph))
        end

        #FIND SUBGRAPH BOUNDARIES AND ASSIGN LINKS AS EITHER PRIMAL OR DUAL
        subgraph_boundary_edges = _find_boundaries(graph,optimizer.subproblem_graphs)
        
        subproblem_links = _gather_links(optimizer.subproblem_graphs, subgraph_boundary_edges)

        optimizer.subproblem_links = subproblem_links
        @assert length(subproblem_links) == n_subproblems
        ########################################################
        #INITIALIZE SUBPROBLEM DATA
        ########################################################
        for subgraph in optimizer.subproblem_graphs
            #Primal data
            subgraph.ext[:x_map] = Dict{Int64,VariableRef}()                                 #variables into subproblem (these are local copies)
            subgraph.ext[:l_map] = Dict{Int64,LinkConstraintRef}()                           #duals from linkconstraint

            #Original objective function
            JuMP.set_objective(subgraph, MOI.MIN_SENSE, sum(objective_function(node) for node in all_nodes(subgraph)))
            obj = objective_function(subgraph)
            subgraph.ext[:original_objective] = obj
        end

        #######################################################
        #INITIALIZE SUBPROBLEMS
        #######################################################
        for i = 1:length(optimizer.subproblem_graphs)
            subproblem_graph = optimizer.subproblem_graphs[i]
            sub_links = subproblem_links[i]

            #map all of the boundary variables for each subproblem
            for link_reference in sub_links
                # primal information map
                incident_variables = setdiff(vars, all_variables(subproblem_graph))
                for incident_variable in incident_variables
                    if !(incident_variable in keys(optimizer.incident_variable_map))        # if incident variable hasn't been counted yet, create a new one
                        JuMP.start_value(incident_variable) == nothing ? start = 0 : start = JuMP.start_value(incident_variable)
                        push!(optimizer.x_vals, start)                                                #increment x_vals
                        idx = length(optimizer.x_vals) 
                        optimizer.incident_variable_map[incident_variable] = idx                      #map index for external variable

                        incident_node = getnode(incident_variable)                                    #get the node for this external variable
                        original_subgraph = optimizer.node_subgraph_map[incident_node]                #get the restricted subgraph
                        exp_subgraph = optimizer.expanded_subgraph_map[original_subgraph]             #get the subproblem that owns this external variable
                        exp_subgraph.ext[:x_idx_map][incident_variable] = idx
                        exp_subgraph.ext[:x_map][idx] = incident_variable                                  # this graph is used to calculate this variable
                    end
                end
            end

            # setup penalty terms for each subproblem
            for link_reference in sub_links
   
                dual_start = 0
                push!(optimizer.l_vals, dual_start)
                idx = length(optimizer.l_vals)
                
                link = constraint_object(link_reference)
                vars = collect(keys(link.func.terms))                                     

                incident_node = Plasmo.attached_node(link)                                         #this is the owning node for the link
                @assert !(incident_node in all_nodes(subproblem_graph))
                
                original_subgraph = optimizer.node_subgraph_map[incident_node]                     #get the restricted subgraph
                exp_subgraph = optimizer.expanded_subgraph_map[original_subgraph]               #the subproblem that "owns" this link_constraint
                
                # push!(optimizer.l_out_indices[target_subgraph], idx)                               #add index to target subproblem outputs
                exp_subgraph.ext[:l_idx_map][link_reference] = idx
                exp_subgraph.ext[:l_map][idx] = link_reference                              # this graph is used to calculate this dual
            end

        end
        optimizer.loaded = true
    end
end

#Add penalty to subproblem objective
function _formulate_penalty!(optimizer, subproblem_graph::OptiGraph, link_reference::LinkConstraintRef)
    link = constraint_object(link_reference)
    link_variables = collect(keys(link.func.terms))
    
    local_link_variables = intersect(link_variables, all_variables(subproblem_graph))
    
    external_variables = setdiff(link_variables, local_link_variables)
    external_var_inds = [subproblem_graph.ext[:x_idx_map][var] for var in external_variables]
    external_values = [optimizer.x_vals[x_idx] for x_idx in external_var_inds]

    local_link_coeffs = [link.func.terms[var] for var in link_variables]
    external_coeffs = [link.func.terms[var] for var in external_variables]

    l_idx = subproblem_graph.ext[:l_idx_map][link_reference]
    l_link = optimizer.l_vals[l_idx]

    rhs = link.func.set.value
    penalty = local_link_coeffs'*local_link_variables + external_coeffs'*external_values - rhs
    augmented_penalty = penalty^2

    set_objective_function(subproblem_graph, objective_function(subproblem_graph) - l_link*penalty + 0.5*optimizer.mu*augmented_penalty)
    return nothing
end

function _do_iteration(subproblem_graph::OptiGraph)
    Plasmo.optimize!(subproblem_graph)
    term_status = termination_status(subproblem_graph)
    !(term_status in [MOI.TerminationStatusCode(4),MOI.TerminationStatusCode(1),MOI.TerminationStatusCode(10)]) && @warn("Suboptimal solution detected for subproblem with status $term_status")

    x_out = subproblem_graph.ext[:x_map]           # primal variables to update
    l_out = subproblem_graph.ext[:l_map]           # dual variables to update

    xk = Dict(key => value(subproblem_graph, val) for (key,val) in x_out)
    lk = Dict(key => dual(subproblem_graph, val) for (key,val) in l_out)

    return xk, lk
end

function _update_subproblem!(optimizer, subproblem_graph::OptiGraph)
    for link in subproblem_graph.ext[:incident_links]
        _formulate_penalty!(optimizer, subproblem_graph, link)
    end
    return nothing
end

function _calculate_objective_value(optimizer)
    return sum(value(optimizer.subproblem_graphs[i].ext[:restricted_objective]) for i = 1:length(optimizer.subproblem_graphs))
end

#TODO: figure out these mappings ahead of time.  This is bottlenecking
function _calculate_primal_feasibility(optimizer)
    linkrefs = getlinkconstraints(optimizer.graph)
    prf = []
    for linkref in linkrefs
        val = 0
        linkcon = constraint_object(linkref)
        terms = linkcon.func.terms
        for (term,coeff) in terms
            node = getnode(term)
            graph = optimizer.node_subgraph_map[node]
            subproblem_graph = optimizer.expanded_subgraph_map[graph]
            val += coeff*value(subproblem_graph, term)
        end
        push!(prf, val - linkcon.set.value)
    end
    return prf
end

#NOTE: Need at least an overlap of one
function _calculate_dual_feasibility(optimizer)
    linkrefs = getlinkconstraints(optimizer.graph)
    duf = []
    for linkref in linkrefs
        lambdas = []
        linkcon = constraint_object(linkref)
        graphs = []
        for node in getnodes(linkcon)
            graph = optimizer.node_subgraph_map[node]
            subproblem_graph = optimizer.expanded_subgraph_map[graph]
            push!(graphs,subproblem_graph)
        end
        graphs = unique(graphs)
        for subproblem_graph in graphs
            l_val = dual(subproblem_graph,linkref)   #check each subproblem's dual value for this linkconstraint
            push!(lambdas,l_val)
        end
        dual_res = maximum(diff(lambdas))#lambdas[1] - lambdas[2]
        push!(duf,dual_res)
    end
    return duf
end

function optimize!(optimizer::Optimizer)
    if !optimizer.loaded
        println("Initializing SchwarzOpt...")
        _initialize_optimizer!(optimizer)
    end

    println("###########################################################")
    println("Optimizing with SchwarzOpt v0.1.0 using $(Threads.nthreads()) threads")
    println("###########################################################")
    println()
    println("Number of variables: $(num_all_variables(optimizer.graph))")
    println("Number of constraints: $(num_all_constraints(optimizer.graph) + num_all_linkconstraints(optimizer.graph))")
    println("Number of subproblems: $(length(optimizer.subproblem_graphs))")
    println("Overlap: ")
    println("Subproblem variables:   $(num_all_variables.(optimizer.subproblem_graphs))")
    println("Subproblem constraints: $(num_all_constraints.(optimizer.subproblem_graphs))")
    println()

    optimizer.timers = Timers()
    optimizer.timers.start_time = time()

    for subgraph in optimizer.subproblem_graphs
        JuMP.set_optimizer(subgraph,optimizer.sub_optimizer)
    end

    optimizer.err_pr = Inf
    optimizer.err_du = Inf
    optimizer.iteration = 0
    while optimizer.err_pr > optimizer.tolerance || optimizer.err_du > optimizer.tolerance
        optimizer.iteration += 1
        if optimizer.iteration > optimizer.max_iterations
            optimizer.status = MOI.ITERATION_LIMIT
            break
        end

        #Do iteration for each subproblem
        optimizer.timers.update_subproblem_time += @elapsed begin
            if optimizer.iteration > 1 #don't fix variables in first iteration
                for subproblem_graph in optimizer.subproblem_graphs
                    x_in_inds = optimizer.x_in_indices[subproblem_graph]
                    l_in_inds = optimizer.l_in_indices[subproblem_graph]
                    x_in_vals = optimizer.x_vals[x_in_inds]
                    l_in_vals = optimizer.l_vals[l_in_inds]
                    _update_subproblem!(subproblem_graph,x_in_vals,l_in_vals,x_in_inds,l_in_inds)
                end
            end
        end

        optimizer.timers.solve_subproblem_time += @elapsed begin
            Threads.@threads for subproblem_graph in optimizer.subproblem_graphs
                #Returns primal and dual information we need to communicate to other subproblems
                xk,lk = _do_iteration(subproblem_graph)

                #Updates primal and dual information for other subproblems.
                for (idx,val) in xk
                    optimizer.x_vals[idx] = val
                end
                for (idx,val) in lk
                    optimizer.l_vals[idx] = val
                end
            end
        end

        #Evaluate residuals
        optimizer.timers.eval_primal_feasibility_time += @elapsed prf = _calculate_primal_feasibility(optimizer)
        optimizer.timers.eval_dual_feasibility_time += @elapsed duf = _calculate_dual_feasibility(optimizer)
        optimizer.err_pr = norm(prf[:],Inf)
        optimizer.err_du = norm(duf[:],Inf)


        #NOTE: This is the wrong way to calculate this
        #TODO: Calculate objective value correctly

        optimizer.timers.eval_objective_time += @elapsed optimizer.objective_value = _calculate_objective_value(optimizer)
        push!(optimizer.primal_error_iters,optimizer.err_pr)
        push!(optimizer.dual_error_iters,optimizer.err_du)
        push!(optimizer.objective_iters,optimizer.objective_value)

        #Print iteration
        if optimizer.iteration % 20 == 0 || optimizer.iteration == 1
            @printf "%4s | %8s | %8s | %8s" "Iter" "Obj" "Prf" "Duf\n"
        end
        @printf("%4i | %7.2e | %7.2e | %7.2e\n",optimizer.iteration,optimizer.objective_value,optimizer.err_pr,optimizer.err_du)

        optimizer.timers.update_subproblem_time += @elapsed begin
            for subproblem in optimizer.subproblem_graphs
                JuMP.set_start_value.(Ref(subproblem),all_variables(subproblem),value.(Ref(subproblem),all_variables(subproblem)))
            end
        end
    end

    #Point variables to restricted solutions
    for (node,subgraph) in optimizer.node_subgraph_map
        subproblem_graph = optimizer.expanded_subgraph_map[subgraph]
        backend(node).last_solution_id = subproblem_graph.id
    end

    optimizer.timers.total_time =  time() - optimizer.timers.start_time
    if optimizer.status != MOI.ITERATION_LIMIT
        optimizer.status = termination_status(optimizer.subproblem_graphs[1])
    end
    # optimizer.graph.optimizer = optimizer
    println()
    println("Number of Iterations: ",length(optimizer.iteration))

    println("Time spent in subproblems: ",optimizer.timers.solve_subproblem_time)
    println("Solution Time: ",optimizer.timers.total_time)
    println("EXIT: SchwarzOpt Finished with status: ",optimizer.status)
end

#call with SchwarzOpt.optimize!(graph)
"""
    SchwarzOpt.optimize!(graph::OptiGraph;kwargs...)

Optimize an optigraph with overlapping schwarz decomposition.
"""
function optimize!(
    graph::OptiGraph;
    subgraphs = Plasmo.OptiGraph[],
    sub_optimizer = Ipopt.Optimizer,
    overlap = 1,
    max_iterations = 50,
    primal_links = LinkConstraintRef[],
    dual_links = LinkConstraintRef[]
)

    #TODO: heuristic to calculate overlap
    # Plasmo.graph_structure(graph) == Plasmo.RECURSIVE_GRAPH || error("Invalid optigraph.  SchwarzOpt requires a RECURSIVE_GRAPH_STRUCTURE.  Consider using partition_to_subgraphs to obtain
    # a valid optigraph.")
    #check for subgraphs, or apply overlap if no subgraphs defined
    if length(subgraphs) == 0
        println("Optimizing with overlap of $overlap")
        subgraphs = expand(graph,subgraphs,overlap)
    else
        println("Optimizing with user provided overlap")
    end

    optimizer = Optimizer(
        graph,
        subgraphs; 
        primal_links = primal_links, 
        dual_links = dual_links,
        sub_optimizer = sub_optimizer, 
        max_iterations = max_iterations
    )

    #set the optimizer for querying results on the optigraph
    # graph.optimizer = optimizer
    optimize!(optimizer)
end


# function _add_subproblem_variable!(subproblem_graph::OptiGraph,incident_variable::VariableRef,idx::Int64)
#     JuMP.start_value(incident_variable) == nothing ? start = 0 : start = JuMP.start_value(incident_variable)
#     copy_node = @optinode(subproblem_graph)
#     copy_variable = @variable(copy_node,start = start)
#     JuMP.set_name(copy_variable,name(incident_variable)*"_copy")
#     if JuMP.has_lower_bound(incident_variable)
#         JuMP.set_lower_bound(copy_variable,lower_bound(incident_variable))
#     end
#     if JuMP.has_upper_bound(incident_variable)
#         JuMP.set_upper_bound(copy_variable,upper_bound(incident_variable))
#     end

#     #JuMP.fix(copy_variable,start)
#     subproblem_graph.ext[:incident_variable_map][incident_variable] = copy_variable
#     subproblem_graph.ext[:x_in_map][idx] = copy_variable
#     return nothing
# end

#Add link constraint to optigraph connecting to copy variable
# function _add_subproblem_constraint!(subproblem_graph::OptiGraph,link_reference::LinkConstraintRef)
#     varmap = subproblem_graph.ext[:incident_variable_map]

#     agg_map = Plasmo.AggregateMap(varmap, Dict{Plasmo.ConstraintRef,Plasmo.ConstraintRef}(), Dict{Plasmo.LinkConstraint, Plasmo.ConstraintRef}())

#     link = constraint_object(link_reference)
#     copy_link = Plasmo._copy_constraint(link, agg_map)
#     copy_linkref = JuMP.add_constraint(subproblem_graph, copy_link) #this is a linkconstraint
#     #push!(graph.ext[:incident_constraints], copy_linkref) #this isn't used anywhere?
#     return nothing
# end