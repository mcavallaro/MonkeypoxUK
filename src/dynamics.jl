"""
    function setup_initial_state(N_pop, N_msm, α_choose, p_detect, α_incubation_eff, ps, init_scale; n_states=8, n_cliques=50)

Setup an initial state for the MPX model given overall population size `N_pop`, overall MSM population size `N_msm`, pseudo-clique size dispersion parameter `α_choose`,
    mean weekly probability of detection `p_detect`, incubation rate `α_incubation_eff`, proportion MSM in each sexual activity group `ps`, and initial scale of number of infected `init_scale`. Output 
    initial MSM population array `u0_msm`, initial non-MSM array `u0_other`, pseudo-clique sizes, total population in each pseudo-clique/sexual activity group.
"""
function setup_initial_state(N_pop, N_msm, α_choose, p_detect, α_incubation_eff, ps, init_scale; n_states=9, n_cliques=50)
    u0_msm = zeros(Int64, n_states, length(ps), n_cliques)
    u0_other = zeros(Int64, n_states)
    N_clique = rand(DirichletMultinomial(N_msm, α_choose * ones(n_cliques)))
    for k = 1:n_cliques
        u0_msm[1, :, k] .= rand(Multinomial(N_clique[k], ps))
    end
    #Add infecteds so that expected detections on week 1 are 1
    choose_clique = rand(Categorical(normalize(N_clique, 1)))
    av_infs = 5 * init_scale / (p_detect * (1 - exp(-α_incubation_eff))) #Set av number of infecteds in each of 5 categories of incubation and infectious rescaled by daily probability of detection if infectious
    u0_msm[2:6, :, choose_clique] .= map(μ -> rand(Poisson(μ)), fill(av_infs / (5 * length(ps)), 5, length(ps)))
    u0_msm = u0_msm[:, :, N_clique.>0] #Reduce group size
    #Set up non MSM population
    u0_other[1] = N_pop - N_msm
    N_grp_msm = u0_msm[1, :, :]
    return u0_msm, u0_other, N_clique[N_clique.>0], N_grp_msm
end

"""
    function setup_transmission_matrix(ms, ps, N_clique; ingroup=0.99)

Setup the two matrices used in calculating daily force of infection due to infectious MSM individuals.        
"""
function setup_transmission_matrix(ms, ps, N_clique; ingroup=0.99)
    n_cliques = length(N_clique)
    n_grps = length(ps)
    B = Matrix{Float64}(undef, n_cliques, n_cliques) #Between group contacting
    for i = 1:n_cliques, j = 1:n_cliques
        if i == j
            B[i, i] = ingroup
        else
            B[i, j] = (1 - ingroup) * (N_clique[j] / (sum(N_clique) - N_clique[i]))
        end
    end
    Λ = Matrix{Float64}(undef, n_grps, n_grps)
    attraction_vect = ms .* ps ./ sum(ms .* ps)
    for i = 1:n_grps, j = 1:n_grps
        Λ[i, j] = attraction_vect[i] * ms[j]
    end
    return Λ, B
end


"""
    function f_mpx_vac(du, u, p, t, Λ, B, N_msm, N_grp_msm, N_total)

Daily stochastic dynamics of the MPX model. NB: the state object `u` is an `ArrayPartition` object with 
        `u.x[1]` being the state of the MSM population and `u.x[2]` being the state of the non-MSM population.

"""
function f_mpx_vac(du, u, p, t, Λ, B, N_msm, N_grp_msm, N_total)
    p_trans, R0_other, γ_eff, α_incubation, vac_eff = p

    #states
    S = @view u.x[1][1, :, :]
    E = @view u.x[1][2:5, :, :]
    I = @view u.x[1][6, :, :]
    R = @view u.x[1][7, :, :]
    V = @view u.x[1][8, :, :]
    C = @view u.x[1][9, :, :]

    S_other = u.x[2][1]
    E_other = @view u.x[2][2:5]
    I_other = u.x[2][6]
    R_other = u.x[2][7]

    #force of infection
    total_I = I_other + sum(I)
    λ = (p_trans .* (Λ * I * B)) ./ (N_grp_msm .+ 1e-5)
    λ_other = γ_eff * R0_other * total_I / N_total
    #number of events

    num_infs = map((n, p) -> rand(Binomial(n, p)), S, 1 .- exp.(-(λ .+ λ_other)))#infections among MSM
    num_infs_vac = map((n, p) -> rand(Binomial(n, p)), V, 1 .- exp.(-(1 - vac_eff) * (λ .+ λ_other)))#infections among MSM with vaccine
    num_incs = map(n -> rand(Binomial(n, 1 - exp(-α_incubation))), E)#incubation among MSM
    num_recs = map(n -> rand(Binomial(n, 1 - exp(-γ_eff))), I)#recovery among MSM
    num_infs_other = rand(Binomial(S_other, 1 - exp(-λ_other)))#infections among non MSM
    num_incs_other = map(n -> rand(Binomial(n, 1 - exp(-α_incubation))), E_other)#incubation among non MSM
    num_recs_other = rand(Binomial(I_other, 1 - exp(-γ_eff)))#recovery among non MSM

    #create change
    du.x[1] .= u.x[1]
    du.x[2] .= u.x[2]
    #infections
    du.x[1][1, :, :] .-= num_infs
    du.x[1][8, :, :] .-= num_infs_vac
    du.x[1][2, :, :] .+= num_infs .+ num_infs_vac
    du.x[2][1] -= num_infs_other
    du.x[2][2] += num_infs_other
    #incubations
    du.x[1][2:5, :, :] .-= num_incs
    du.x[1][3:6, :, :] .+= num_incs
    du.x[2][2:5] .-= num_incs_other
    du.x[2][3:6] .+= num_incs_other
    du.x[1][9, :, :] .+= num_incs[end, :, :] #cumulative onsets - MSM
    du.x[2][9] += num_incs_other[end] #cumulative onsets - non-MSM
    #recoveries
    du.x[1][6, :, :] .-= num_recs
    du.x[1][7, :, :] .+= num_recs
    du.x[2][6] -= num_recs_other
    du.x[2][7] += num_recs_other

    return nothing
end

"""
    function mpx_sim_function_chp(params, constants, wkly_cases)

Simulation function for the MPX transmission model with change points. Outputs the relative L1 error for ABC inference, 
    and detected cases (for saving).        
"""
function mpx_sim_function_chp(params, constants, wkly_cases)
    #Get constant data
    N_total, N_msm, ps, ms, ingroup, ts, α_incubation, n_cliques, wkly_vaccinations, vac_effectiveness, chp_t2 = constants

    #Get parameters and make transformations
    α_choose, p_detect, mean_inf_period, p_trans, R0_other, M, init_scale, chp_t, trans_red, trans_red_other, scale_trans_red2, scale_red_other2 = params
    p_γ = 1 / (1 + mean_inf_period)
    γ_eff = -log(1 - p_γ) #get recovery rate
    trans_red2 = trans_red * scale_trans_red2
    trans_red_other2 = scale_trans_red2 * scale_red_other2

    #Generate random population structure
    u0_msm, u0_other, N_clique, N_grp_msm = setup_initial_state(N_total, N_msm, α_choose, p_detect, α_incubation, ps, init_scale; n_states=9, n_cliques=n_cliques)
    Λ, B = setup_transmission_matrix(ms, ps, N_clique; ingroup=ingroup)

    #Simulate and track error
    L1_rel_err = 0.0
    total_cases = sum(wkly_cases[1:(end-1), :])
    u_mpx = ArrayPartition(u0_msm, u0_other)
    prob = DiscreteProblem((du, u, p, t) -> f_mpx_vac(du, u, p, t, Λ, B, N_msm, N_grp_msm, N_total),
        u_mpx, (ts[1] - 7, ts[1] - 7 + 7 * size(wkly_cases, 1)),#lag for week before detection
        [p_trans, R0_other, γ_eff, α_incubation, vac_effectiveness])
    mpx_init = init(prob, FunctionMap(), save_everystep=false) #Begins week 1
    old_onsets = [0, 0]
    new_onsets = [0, 0]
    wk_num = 1
    detected_cases = zeros(size(wkly_cases))
    not_changed = true
    not_changed2 = true

    while wk_num <= size(wkly_cases, 1)
        if not_changed && mpx_init.t > chp_t ##Change point for transmission
            not_changed = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red) #Reduce transmission per sexual contact after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other) #Reduce transmission per non-sexual contact after the change point
        end
        if not_changed2 && mpx_init.t > chp_t2 ##2nd change point for transmission 
            not_changed2 = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red2) #Reduce sexual MSM transmission after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other2) #Reduce  other transmission after the change point
        end
        step!(mpx_init, 7)#Step forward a week

        #Do vaccine uptake
        nv = wkly_vaccinations[wk_num]#Mean number of vaccines deployed
        du_vac = deepcopy(mpx_init.u)
        vac_rate = nv .* du_vac.x[1][1, 3:end, :] / (sum(du_vac.x[1][1, 3:end, :]) .+ 1e-5)
        num_vaccines = map((μ, maxval) -> min(rand(Poisson(μ)), maxval), vac_rate, du_vac.x[1][1, 3:end, :])
        du_vac.x[1][1, 3:end, :] .-= num_vaccines
        du_vac.x[1][8, 3:end, :] .+= num_vaccines
        set_u!(mpx_init, du_vac) #Change the state of the model

        #Calculate actual onsets, generate observed cases and score errors        
        new_onsets = [sum(mpx_init.u.x[1][end, :, :]), mpx_init.u.x[2][end]]
        actual_obs = [rand(BetaBinomial(new_onsets[1] - old_onsets[1], p_detect * M, (1 - p_detect) * M)), rand(BetaBinomial(new_onsets[2] - old_onsets[2], p_detect * M, (1 - p_detect) * M))]
        detected_cases[wk_num, :] .= actual_obs #lag 1 week
        if wk_num < size(wkly_cases, 1) && wk_num >= 3  # Leave last week out for cross-validation and possible right censoring issues and leave out first two weeks
            L1_rel_err += sum(abs, actual_obs .- wkly_cases[wk_num, :]) / total_cases #lag 1 week
        end
        wk_num += 1
        old_onsets = new_onsets
    end

    return L1_rel_err, detected_cases
end

"""
    function mpx_sim_function_interventions(params, constants, wkly_cases, interventions)

Forecasting/scenario projection simulation function. Compared to main simulation function `mpx_sim_function_chp`, this takes in a richer 
    set of interventions, encoded in an `interventions` object. Outputs a richer set of observables.       
"""
function mpx_sim_function_interventions(params, constants, wkly_cases, interventions)
    #Get constant data
    N_total, N_msm, ps, ms, ingroup, ts, α_incubation, n_cliques = constants

    #Get intervention data
    chp_t2 = interventions.chp_t2
    wkly_vaccinations = interventions.wkly_vaccinations
    trans_red2 = interventions.trans_red2
    inf_duration_red = interventions.inf_duration_red
    vac_effectiveness = interventions.vac_effectiveness
    trans_red_other2 = interventions.trans_red_other2

    #Get parameters and make transformations
    α_choose, p_detect, mean_inf_period, p_trans, R0_other, M, init_scale, chp_t, trans_red, trans_red_other = params
    p_γ = 1 / (1 + mean_inf_period)
    γ_eff = -log(1 - p_γ) #get recovery rate

    #Generate random population structure
    u0_msm, u0_other, N_clique, N_grp_msm = setup_initial_state(N_total, N_msm, α_choose, p_detect, α_incubation, ps, init_scale; n_states=9, n_cliques=n_cliques)
    Λ, B = setup_transmission_matrix(ms, ps, N_clique; ingroup=ingroup)

    #Simulate and track error
    L1_rel_err = 0.0
    total_cases = sum(wkly_cases[1:end-1, :])
    u_mpx = ArrayPartition(u0_msm, u0_other)
    prob = DiscreteProblem((du, u, p, t) -> f_mpx_vac(du, u, p, t, Λ, B, N_msm, N_grp_msm, N_total),
        u_mpx, (ts[1] - 7, ts[1] - 7 + 7 * size(wkly_cases, 1)),#lag for week before detection
        [p_trans, R0_other, γ_eff, α_incubation, vac_effectiveness])
    mpx_init = init(prob, FunctionMap(), save_everystep=false) #Begins week 1
    old_onsets = [0, 0]
    new_onsets = [0, 0]
    old_sus = [sum(u0_msm[1, :, :][:,:],dims = 2)[:]; u0_other[1]]
    new_sus = [sum(u0_msm[1, :, :][:,:],dims = 2)[:]; u0_other[1]]
    wk_num = 1
    detected_cases = zeros(size(wkly_cases))
    incidence = zeros(Int64, size(wkly_cases, 1), 11)
    prevalence = zeros(Int64, size(wkly_cases, 1), 11)
    not_changed = true
    not_changed2 = true


    while wk_num <= size(wkly_cases, 1) #Step forward a week
        #Change points
        if not_changed && mpx_init.t > chp_t ##1st change point for transmission prob
            not_changed = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red) #Reduce transmission after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other) #Reduce non-sexual transmission after the change point
        end
        if not_changed2 && mpx_init.t > chp_t2 ##2nd change point for transmission 
            not_changed2 = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red2) #Reduce sexual MSM transmission after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other2) #Reduce  other transmission after the change point
            p_γ = 1 / (1 + (mean_inf_period * (1 - inf_duration_red)))
            mpx_init.p[3] = -log(1 - p_γ) #Reduce duration of transmission after the change point
        end
        #Step forward a week in time
        step!(mpx_init, 7)

        #Do vaccine uptake
        nv = wkly_vaccinations[wk_num]#Mean number of vaccines deployed
        du_vac = deepcopy(mpx_init.u)
        vac_rate = nv .* du_vac.x[1][1, 3:end, :] / (sum(du_vac.x[1][1, 3:end, :]) .+ 1e-5)
        num_vaccines = map((μ, maxval) -> min(rand(Poisson(μ)), maxval), vac_rate, du_vac.x[1][1, 3:end, :])
        du_vac.x[1][1, 3:end, :] .-= num_vaccines
        du_vac.x[1][8, 3:end, :] .+= num_vaccines
        set_u!(mpx_init, du_vac) #Change the state of the model

        #Calculate actual onsets, actual infections, actual prevelance, generate observed cases and score errors
        new_onsets = [sum(mpx_init.u.x[1][end, :, :]), mpx_init.u.x[2][end]]
        new_sus = [sum(mpx_init.u.x[1][1, :, :][:,:],dims = 2)[:]; mpx_init.u.x[2][1]]
        actual_obs = [rand(BetaBinomial(new_onsets[1] - old_onsets[1], p_detect * M, (1 - p_detect) * M)), rand(BetaBinomial(new_onsets[2] - old_onsets[2], p_detect * M, (1 - p_detect) * M))]
        detected_cases[wk_num, :] .= Float64.(actual_obs)
        incidence[wk_num, :] .= old_sus .- new_sus .- [0;0;sum(num_vaccines,dims = 2)[:];0] #Total infections = reduction in susceptibles - number vaccinated
        if wk_num < size(wkly_cases, 1) # Only compare on weeks 1 --- (end-1)
            L1_rel_err += sum(abs, actual_obs .- wkly_cases[wk_num, :]) / total_cases
        end
        prevalence[wk_num, :] .= [[sum(mpx_init.u.x[1][2:6, n, :]) for n = 1:10]; sum(mpx_init.u.x[2][2:6])]

        #Move time forwards one week
        wk_num += 1
        old_onsets = new_onsets
        old_sus = new_sus
    end

    return L1_rel_err, detected_cases, incidence, prevalence
end

"""
    function mpx_sim_function_interventions(params, constants, wkly_cases, interventions, weeks_to_reversion)

Forecasting/scenario projection simulation function. Compared to main simulation function `mpx_sim_function_chp`, this takes in a richer 
    set of interventions, encoded in an `interventions` object. Outputs a richer set of observables. The number of weeks to revert probability of transmission
    to its initial estimate is given by `weeks_to_reversion`.     
"""
function mpx_sim_function_interventions(params, constants, wkly_cases, interventions, weeks_to_reversion)
    #Get constant data
    N_total, N_msm, ps, ms, ingroup, ts, α_incubation, n_cliques = constants

    #Get intervention data
    chp_t2 = interventions.chp_t2
    wkly_vaccinations = interventions.wkly_vaccinations
    trans_red2 = interventions.trans_red2
    inf_duration_red = interventions.inf_duration_red
    vac_effectiveness = interventions.vac_effectiveness
    trans_red_other2 = interventions.trans_red_other2

    #Get parameters and make transformations
    α_choose, p_detect, mean_inf_period, p_trans, R0_other, M, init_scale, chp_t, trans_red, trans_red_other = params

    p_γ = 1 / (1 + mean_inf_period)
    γ_eff = -log(1 - p_γ) #get recovery rate
    
    #Calculate logistic reversion to pre-change
    p_min = p_trans*(1 - trans_red)*(1 - trans_red2)
    R_oth_min = R0_other*(1 - trans_red_other)*(1 - trans_red_other2)
    T₅₀ = (Date(2022,9,1) - Date(2021,12,31)).value + (weeks_to_reversion * 7 / 2) # 50% return to normal point
    κ = (weeks_to_reversion * 7 / 2) / 4.6 # logistic scale for return to normal: 4.6 is κ = 1 time to go from 0.01 to 0.5 and 0.5 to 0.99

    # wkly_reversion = exp(-(log(1 - trans_red) + log(1 - trans_red2))/weeks_to_reversion)
    # wkly_reversion_othr = exp(-(log(1 - trans_red_other) + log(1 - trans_red_other2))/weeks_to_reversion)
    #Generate random population structure
    u0_msm, u0_other, N_clique, N_grp_msm = setup_initial_state(N_total, N_msm, α_choose, p_detect, α_incubation, ps, init_scale; n_states=9, n_cliques=n_cliques)
    Λ, B = setup_transmission_matrix(ms, ps, N_clique; ingroup=ingroup)

    #Simulate and track error
    L1_rel_err = 0.0
    total_cases = sum(wkly_cases[1:end-1, :])
    u_mpx = ArrayPartition(u0_msm, u0_other)
    _p = copy([p_trans, R0_other, γ_eff, α_incubation, vac_effectiveness])
    prob = DiscreteProblem((du, u, p, t) -> f_mpx_vac(du, u, p, t, Λ, B, N_msm, N_grp_msm, N_total),
        u_mpx, (ts[1] - 7, ts[1] - 7 + 7 * size(wkly_cases, 1)),#lag for week before detection
        _p)
    mpx_init = init(prob, FunctionMap(), save_everystep=false) #Begins week 1

    #Set up arrays for tracking epidemiological observables
    old_onsets = [0, 0]
    new_onsets = [0, 0]
    old_sus = [sum(u0_msm[1, :, :][:,:],dims = 2)[:]; u0_other[1]]
    new_sus = [sum(u0_msm[1, :, :][:,:],dims = 2)[:]; u0_other[1]]
    wk_num = 1
    detected_cases = zeros(size(wkly_cases))
    incidence = zeros(Int64, size(wkly_cases, 1), 11)
    prevalence = zeros(Int64, size(wkly_cases, 1), 11)
    not_changed = true
    not_changed2 = true

    #Step through the dynamics
    while wk_num <= size(wkly_cases, 1) #Step forward a week
        #Change points
        if not_changed && mpx_init.t > chp_t ##1st change point for transmission prob
            not_changed = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red) #Reduce transmission after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other) #Reduce non-sexual transmission after the change point
        end
        if not_changed2 && mpx_init.t > chp_t2 ##2nd change point for transmission 
            not_changed2 = false
            mpx_init.p[1] = mpx_init.p[1] * (1 - trans_red2) #Reduce sexual MSM transmission after the change point
            mpx_init.p[2] = mpx_init.p[2] * (1 - trans_red_other2) #Reduce  other transmission after the change point
            p_γ = 1 / (1 + (mean_inf_period * (1 - inf_duration_red)))
            mpx_init.p[3] = -log(1 - p_γ) #Reduce duration of transmission after the change point
        end
        #Step forward a week in time and implement reversion to normal transmission
        # step!(mpx_init, 7)
        # if wk_num >= 19 && mpx_init.p[1] < p_trans  #Reversion starts first week in September
        #     mpx_init.p[1] *= wkly_reversion
        #     mpx_init.p[2] *= wkly_reversion_othr
        # end
        for stp = 1:7
            step!(mpx_init, 1)
            mpx_init.p[1] += (p_trans - p_min)*(sigmoid((mpx_init.t - T₅₀)/κ) - sigmoid((mpx_init.t - 1.0 - T₅₀)/κ))
            mpx_init.p[2] += (R0_other - R_oth_min)*(sigmoid((mpx_init.t - T₅₀)/κ) - sigmoid((mpx_init.t - 1.0 - T₅₀)/κ))
        end

        #Do vaccine uptake
        nv = wkly_vaccinations[wk_num]#Mean number of vaccines deployed
        du_vac = deepcopy(mpx_init.u)
        vac_rate = nv .* du_vac.x[1][1, 3:end, :] / (sum(du_vac.x[1][1, 3:end, :]) .+ 1e-5)
        num_vaccines = map((μ, maxval) -> min(rand(Poisson(μ)), maxval), vac_rate, du_vac.x[1][1, 3:end, :])
        du_vac.x[1][1, 3:end, :] .-= num_vaccines
        du_vac.x[1][8, 3:end, :] .+= num_vaccines
        set_u!(mpx_init, du_vac) #Change the state of the model

        #Calculate actual onsets, actual infections, actual prevelance, generate observed cases and score errors
        new_onsets = [sum(mpx_init.u.x[1][end, :, :]), mpx_init.u.x[2][end]]
        new_sus = [sum(mpx_init.u.x[1][1, :, :][:,:],dims = 2)[:]; mpx_init.u.x[2][1]]
        actual_obs = [rand(BetaBinomial(new_onsets[1] - old_onsets[1], p_detect * M, (1 - p_detect) * M)), rand(BetaBinomial(new_onsets[2] - old_onsets[2], p_detect * M, (1 - p_detect) * M))]
        detected_cases[wk_num, :] .= Float64.(actual_obs)
        incidence[wk_num, :] .= old_sus .- new_sus .- [0;0;sum(num_vaccines,dims = 2)[:];0] #Total infections = reduction in susceptibles - number vaccinated
        if wk_num < size(wkly_cases, 1) # Only compare on weeks 1 --- (end-1)
            L1_rel_err += sum(abs, actual_obs .- wkly_cases[wk_num, :]) / total_cases
        end
        prevalence[wk_num, :] .= [[sum(mpx_init.u.x[1][2:6, n, :]) for n = 1:10]; sum(mpx_init.u.x[2][2:6])]

        #Move time forwards one week
        wk_num += 1
        old_onsets = new_onsets
        old_sus = new_sus
    end

    return L1_rel_err, detected_cases, incidence, prevalence
end