####################################
### METHODS FOR INFEASIBLE START ###
####################################

"""
$(SIGNATURES)
    Calculate infeasible controls to produce an infeasible state trajectory
"""
function infeasible_controls(solver::Solver,X0::Array{Float64,2},u::Array{Float64,2})
    ui = zeros(solver.model.n,solver.N) # initialize
    m = solver.model.m
    m̄,mm = get_num_controls(solver)
    dt = solver.dt

    x = zeros(solver.model.n,solver.N)
    x[:,1] = solver.obj.x0
    for k = 1:solver.N-1
        solver.state.minimum_time ? dt = u[m̄,k]^2 : nothing

        solver.fd(view(x,:,k+1),x[:,k],u[1:m,k], dt)

        ui[:,k] = X0[:,k+1] - x[:,k+1]
        x[:,k+1] += ui[:,k]
    end
    ui
end

function infeasible_controls(solver::Solver,X0::Array{Float64,2})
    u = zeros(solver.model.m,solver.N)
    if solver.state.minimum_time
        dt = get_initial_dt(solver)
        u_dt = ones(1,solver.N)
        u = [u; u_dt]
    end
    infeasible_controls(solver,X0,u)
end

"""
$(SIGNATURES)
Linear interpolation trajectory between initial and final state(s)
"""
function line_trajectory(solver::Solver, method=:trapezoid)::Array{Float64,2}
    N, = get_N(solver,method)
    line_trajectory(solver.obj.x0,solver.obj.xf,N)
end

function line_trajectory(x0::Array{Float64,1},xf::Array{Float64,1},N::Int64)::Array{Float64,2}
    x_traj = zeros(size(x0,1),N)
    t = range(0,stop=N,length=N)
    slope = (xf-x0)./N
    for i = 1:size(x0,1)
        x_traj[i,:] = slope[i].*t
    end
    x_traj
end