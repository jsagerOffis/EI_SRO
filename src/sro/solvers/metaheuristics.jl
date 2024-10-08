using Random

"""
Helper function for truncated fit evaluations.
"""
function evaluation(
    subset::Vector{Int64},
    target::SROTarget,
    value_sample_data::Matrix{Float64},
    cost_sample_data::Matrix{Float64},
    lowers::Vector{Float64},
    uppers::Vector{Float64},
    cost_lowers::Vector{Float64},
    cost_uppers::Vector{Float64},
)::Float64

    value_fit_dist, cost_fit_dist = fit_subset(subset, value_sample_data, cost_sample_data)
    value_min = sum(lowers[subset])
    value_max = sum(uppers[subset])
    value_truncated_dist = truncated(value_fit_dist; lower = value_min, upper = value_max)

    cost_min = sum(cost_lowers[subset])
    cost_max = sum(cost_uppers[subset])
    cost_truncated_dist = truncated(cost_fit_dist; lower = cost_min, upper = cost_max)
    return expected_cost(value_truncated_dist, cost_truncated_dist, target)
end


"""
Binary PSO algorithm as originally described by Kennedy and Eberhart (1997).
This implementation uses two acceleration constants, a global best topology, and
an intertia constant.

Uses truncated normal dist for evaluation. Makese the same assumptions on resources as:
    - fk_truncated_normal_fit 

Parameters:
n_samples - sample count for truncated normal fit of candidate solutions.

PSO parameters are fixed to:
n_particles - 10
n_steps - 10
c1 - 1.43
c2 - 1.43
w - 0.69
v_max - 4.0
"""
function bpso_truncated_normal_fit(
    rng,
    problem::SROProblem,
    n_samples::Int64,
    n_particles::Int64,
    n_steps::Int64;
    buy_all::Bool,
)::SROSolution
    sigmoid(z::Real) = one(z) / (one(z) + exp(-z))

    resources = problem.resources
    target = problem.target
    value_sklar_dist = get_gaussian_sklar_value_dist(problem)
    cost_sklar_dist = get_gaussian_sklar_cost_dist(problem)
    indices = collect(1:length(resources))
    value_sample_data = rand(rng, value_sklar_dist, n_samples)
    cost_sample_data = rand(rng, cost_sklar_dist, n_samples)

    uppers = [r.possible_values.upper for r in resources]
    lowers = [r.possible_values.lower for r in resources]
    cost_lowers = [r.c_selection for r in resources]
    cost_uppers = [r.possible_values.upper * r.c_per_w + r.c_selection for r in resources]

    # n_particles = 10
    # n_steps = 10
    c1 = 1.43
    c2 = 1.43
    w = 0.69
    v_max = 4.0

    assert_msg1 = "truncated normal solver requires all resources to be truncated with upper and lower bound"
    @assert all([r.possible_values isa Truncated for r in resources]) assert_msg1

    if sum([r.possible_values.upper for r in resources]) < target.v_target
        # no feasible solution exists
        return SROSolution(Vector{SROResource}(), Inf, target.v_target)
    end

    # init particles and global best
    particle_positions = Vector{Vector{Bool}}()
    for _ = 1:n_particles
        push!(particle_positions, bitrand(rng, length(resources)))
    end
    particle_velocities = Vector{Vector{Float64}}()
    for _ = 1:n_particles
        push!(particle_velocities, zeros(Float64, length(resources)))
    end
    particle_bests = deepcopy(particle_positions)
    particle_best_evals = [
        evaluation(
            indices[x],
            target,
            value_sample_data,
            cost_sample_data,
            lowers,
            uppers,
            cost_lowers,
            cost_uppers,
        ) for x in particle_bests
    ]

    # initialize global best to full selection
    global_best = ones(Bool, length(resources))
    global_best_eval = evaluation(
        indices,
        target,
        value_sample_data,
        cost_sample_data,
        lowers,
        uppers,
        cost_lowers,
        cost_uppers,
    )

    # velocity update: v(t+1) = w * v(t) + c1 R1 (local_best - position) + c2 R2 (g_best - position)
    # have to apply this bitwise of course
    #
    # x(t+1) = 0 if rand() >= S(v(t+1))
    #          1 else
    #
    # local and global best are set as one may expect
    for _ = 1:n_steps
        intermediate_g_best = global_best
        intermediate_best_eval = global_best_eval

        for i = 1:n_particles
            # update velocity
            r1 = rand(rng)
            r2 = rand(rng)

            v = particle_velocities[i]
            local_best = particle_bests[i]
            local_eval = particle_best_evals[i]
            pos = particle_positions[i]

            v_new = w * v + c1 * r1 * (local_best - pos) + c2 * r2 * (global_best - pos)
            particle_velocities[i] = v_new


            # update position
            bitflip = rand(rng, length(resources))
            pos_new =
                Bool[bitflip[i] >= sigmoid(v_new[i]) ? 0 : 1 for i in eachindex(bitflip)]
            particle_positions[i] = pos_new

            # evaluate
            eval_new = evaluation(
                indices[pos_new],
                target,
                value_sample_data,
                cost_sample_data,
                lowers,
                uppers,
                cost_lowers,
                cost_uppers,
            )

            if eval_new < local_eval
                particle_best_evals[i] = eval_new
                particle_bests[i] = pos_new
            end

            if eval_new < intermediate_best_eval
                intermediate_best_eval = eval_new
                intermediate_g_best = pos_new
            end
        end

        global_best = intermediate_g_best
        global_best_eval = intermediate_best_eval
    end

    output_set = resources[global_best]

    if buy_all
        return SROSolution(
            output_set,
            total_cost(output_set),
            remaining_target(output_set, target.v_target),
        )
    else
        return SROSolution(
            output_set,
            target_cost(output_set, target.v_target),
            remaining_target(output_set, target.v_target),
        )
    end
end


function one_plus_one_evo_truncated_normal_fit(
    rng,
    problem::SROProblem,
    n_samples::Int64,
    n_steps::Int64;
    buy_all::Bool,
    p_bit_flip::Float64
)::SROSolution

    resources = problem.resources
    target = problem.target
    value_sklar_dist = get_gaussian_sklar_value_dist(problem)
    cost_sklar_dist = get_gaussian_sklar_cost_dist(problem)
    indices = collect(1:length(resources))
    value_sample_data = rand(rng, value_sklar_dist, n_samples)
    cost_sample_data = rand(rng, cost_sklar_dist, n_samples)

    uppers = [r.possible_values.upper for r in resources]
    lowers = [r.possible_values.lower for r in resources]
    cost_lowers = [r.c_selection for r in resources]
    cost_uppers = [r.possible_values.upper * r.c_per_w + r.c_selection for r in resources]

    if sum([r.possible_values.upper for r in resources]) < target.v_target
        # no feasible solution exists
        return SROSolution(Vector{SROResource}(), Inf, target.v_target)
    end

    global_best = ones(Bool, length(resources))
    global_best_eval = evaluation(
        indices,
        target,
        value_sample_data,
        cost_sample_data,
        lowers,
        uppers,
        cost_lowers,
        cost_uppers,
    )

    known_combinations = Vector{Vector{Bool}}()
    push!(known_combinations, ones(Bool, length(resources)))

    select_vector = ones(Bool, length(resources))

    for _ in 1:n_steps
        new_select_vector = zeros(Bool, length(resources))
        for i in eachindex(new_select_vector)
            if rand(rng) <= p_bit_flip
                new_select_vector[i] = !select_vector[i]
            else
                new_select_vector[i] = select_vector[i]
            end
        end

        if new_select_vector in known_combinations
            # no way to improve, skip
            continue
        else
            push!(known_combinations, new_select_vector)
        end

        new_eval = evaluation(
            indices[new_select_vector],
            target,
            value_sample_data,
            cost_sample_data,
            lowers,
            uppers,
            cost_lowers,
            cost_uppers,
        )

        if new_eval < global_best_eval
            global_best_eval = new_eval
            global_best = new_select_vector
        end
    end

    output_set = resources[global_best]
    if buy_all
        return SROSolution(
            output_set,
            total_cost(output_set),
            remaining_target(output_set, target.v_target),
        )
    else
        return SROSolution(
            output_set,
            target_cost(output_set, target.v_target),
            remaining_target(output_set, target.v_target),
        )
    end
end

function subset_size_truncated_normal_fit(
    rng,
    problem::SROProblem,
    n_samples::Int64,
    n_subset_samples::Int64;
    buy_all::Bool,
)::SROSolution
resources = problem.resources
    target = problem.target
    value_sklar_dist = get_gaussian_sklar_value_dist(problem)
    cost_sklar_dist = get_gaussian_sklar_cost_dist(problem)
    indices = collect(1:length(resources))
    value_sample_data = rand(rng, value_sklar_dist, n_samples)
    cost_sample_data = rand(rng, cost_sklar_dist, n_samples)

    uppers = [r.possible_values.upper for r in resources]
    lowers = [r.possible_values.lower for r in resources]
    cost_lowers = [r.c_selection for r in resources]
    cost_uppers = [r.possible_values.upper * r.c_per_w + r.c_selection for r in resources]

    global_best = ones(Bool, length(resources))
    global_best_eval = evaluation(
        indices,
        target,
        value_sample_data,
        cost_sample_data,
        lowers,
        uppers,
        cost_lowers,
        cost_uppers,
    )

    for size in 1:length(resources)-1
        base = vcat(ones(Bool, size), zeros(Bool, length(resources)-size))
        for _ in 1:n_subset_samples
            sample = shuffle(rng, base)
            new_eval = evaluation(
                indices[sample],
                target,
                value_sample_data,
                cost_sample_data,
                lowers,
                uppers,
                cost_lowers,
                cost_uppers,
            )

            if new_eval < global_best_eval
                global_best_eval = new_eval
                global_best = sample
            end
        end
    end

    output_set = resources[global_best]
    if buy_all
        return SROSolution(
            output_set,
            total_cost(output_set),
            remaining_target(output_set, target.v_target),
        )
    else
        return SROSolution(
            output_set,
            target_cost(output_set, target.v_target),
            remaining_target(output_set, target.v_target),
        )
    end
end