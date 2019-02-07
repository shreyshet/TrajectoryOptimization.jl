struct NewtonResults
    z::Vector
    λ::Vector
    ν::Vector
    W::SparseMatrixCSC
    w::Vector
    G::SparseMatrixCSC
    g::Vector
    D::SparseMatrixCSC
    d::Vector
    A::SparseMatrixCSC
    b::Vector
    active_set::Vector
    x_eval::Vector
end

function NewtonResults(Nz::Int,Np::Int,Nx::Int)
    z = zeros(Nz)
    λ = zeros(Np)
    ν = zeros(Nx)

    W = spzeros(Nz,Nz)
    w = zeros(Nz)

    G = spzeros(Np,Nz)
    g = zeros(Np)

    D = spzeros(Nx,Nz)
    d = zeros(Nx)

    A = spzeros(Nz+Np+Nx,Nz+Np+Nx)
    b = spzeros(Nz+Np+Nx)

    active_set = zeros(Bool,Np)
    x_eval = zeros(Nx)

    NewtonResults(z,λ,ν,W,w,G,g,D,d,A,b,active_set,x_eval)
end

function NewtonResults(solver::Solver)
    n,m,N = get_sizes(solver)
    n̄,nn = get_num_states(solver)
    m̄,mm = get_num_controls(solver)
    p,pI,pE = get_num_constraints(solver)
    p_N,pI_N,pE_N = get_num_terminal_constraints(solver)

    # batch problem dimensions
    nm = nn + mm
    Nz = nn*N + mm*(N-1)
    Np = p*(N-1) + p_N
    Nx = N*nn

    NewtonResults(Nz,Np,Nx)
end

function get_batch_sizes(solver::Solver)
    n,m,N = get_sizes(solver)
    n̄,nn = get_num_states(solver)
    m̄,mm = get_num_controls(solver)
    p,pI,pE = get_num_constraints(solver)
    p_N,pI_N,pE_N = get_num_terminal_constraints(solver)

    # batch problem dimensions
    nm = nn + mm
    Nz = nn*N + mm*(N-1)
    Np = p*(N-1) + p_N
    Nx = N*n
    Nu = mm*(N-1) # number of control decision variables u

    return Nz,Np,Nx,Nu,nm
end

## Newton solve
function update_newton_results!(newton_results::NewtonResults,results::SolverIterResults,solver::Solver)
    # get problem dimensions
    n,m,N = get_sizes(solver)
    n̄,nn = get_num_states(solver)
    m̄,mm = get_num_controls(solver)
    p,pI,pE = get_num_constraints(solver)
    p_N,pI_N,pE_N = get_num_terminal_constraints(solver)
    Nz,Np,Nx,Nu,nm = get_batch_sizes(solver)

    # pull out results for convenience
    X = results.X
    U = results.U
    Iμ = results.Iμ
    C = results.C
    Cx = results.Cx
    Cu = results.Cu
    fdx = results.fdx
    fdu = results.fdu
    x0 = solver.obj.x0

    # pull out newton results for convenience
    z = newton_results.z
    λ = newton_results.λ
    ν = newton_results.ν

    W = newton_results.W
    w = newton_results.w

    G = newton_results.G
    g = newton_results.g

    D = newton_results.D
    d = newton_results.d

    active_set = newton_results.active_set
    x_eval = newton_results.x_eval

    Inn = sparse(Matrix(I,nn,nn))

    # update batch matrices
    for k = 1:N
        x = results.X[k]

        if k != N
            u = results.U[k]
            Q,R,H,q,r = taylor_expansion(solver.obj.cost,x,u) .* solver.dt
        else
            Qf,qf = taylor_expansion(solver.obj.cost,x)
        end

        # Indices
        k != N ? idx = (((k-1)*nm + 1):k*nm) : idx = (((k-1)*nm + 1):Nz) # index over x and u
        k != N ? idx2 = (((k-1)*p + 1):k*p) : idx2 = (((k-1)*p + 1):Np) # index over p
        idx3 = ((k-1)*nm + 1):((k-1)*nm + nn) # index over x only
        idx4 = ((k-1)*nm + nn + 1):k*nm # index over u only
        idx5 = ((k-1)*mm + 1):k*mm # index through stacked u vector
        idx6 = ((k-1)*p + 1):((k-1)*p + pI) # index over p only inequality indices
        idx7 = ((k-1)*nn + 1):(k*nn)
        idx8 = ((k-2)*nm + 1):((k-1)*nm + nn)
        idx9 = ((k-2)*nm + 1):((k-2)*nm + nn)
        idx10 = ((k-2)*nm + nn + 1):((k-1)*nm)

        # Assemble W, w, G, g
        if k != N
            # W[idx,idx] = [Q H';H R] + [Cx[k]'*Iμ[k]*Cx[k] Cx[k]'*Iμ[k]*Cu[k]; Cu[k]'*Iμ[k]*Cx[k] Cu[k]'*Iμ[k]*Cu[k]]
            W[idx3,idx3] = Q + Cx[k]'*Iμ[k]*Cx[k]
            W[idx3,idx4] = H' + Cx[k]'*Iμ[k]*Cu[k]
            W[idx4,idx3] = H + Cu[k]'*Iμ[k]*Cx[k]
            W[idx4,idx4] = R + Cu[k]'*Iμ[k]*Cu[k]

            # w[idx] = [q;r] + [Cx[k]'*Iμ[k]*C[k]; Cu[k]'*Iμ[k]*C[k]]
            w[idx3] = q + Cx[k]'*Iμ[k]*C[k]
            w[idx4] = r + Cu[k]'*Iμ[k]*C[k]

            # G[idx2,idx] = [Cx[k] Cu[k]]
            G[idx2,idx3] = Cx[k]
            G[idx2,idx4] = Cu[k]

            g[idx2] = C[k]

            z[idx] = [x;u]
        else
            W[idx,idx] = Qf + Cx[N]'*Iμ[N]*Cx[N]
            w[idx] = qf + Cx[N]'*Iμ[N]*C[N]

            G[idx2,idx] = results.Cx[N]
            g[idx2] = results.C[N]

            z[idx] = x
        end

        # assemble D, d
        if k == 1
            D[1:nn,1:nn] = Inn
            d[1:nn] = X[1] - solver.obj.x0
        else
            # D[idx7,idx8] = [-fdx[k-1] -fdu[k-1] Inn]
            D[idx7,idx9] = -fdx[k-1]
            D[idx7,idx10] = -fdu[k-1]
            D[idx7,idx3] = Inn

            solver.fd(view(x_eval,idx7),X[k-1][1:n],U[k-1][1:m])
            d[idx7] = X[k] - x_eval[idx7]
        end

        # assemble λ, ν, active_set
        λ[idx2] = results.λ[k]
        ν[idx7] = results.s[k]
        active_set[idx2] = results.active_set[k]

    end

    return nothing
end

function update_results_from_newton_results!(results::SolverIterResults,newton_results::NewtonResults,solver::Solver)
    n,m,N = get_sizes(solver)
    n̄,nn = get_num_states(solver)
    m̄,mm = get_num_controls(solver)
    p,pI,pE = get_num_constraints(solver)
    p_N,pI_N,pE_N = get_num_terminal_constraints(solver)

    # batch problem dimensions
    nm = nn + mm
    Nz = nn*N + mm*(N-1)
    Np = p*(N-1) + p_N
    Nu = mm*(N-1) # number of control decision variables u

    z = newton_results.z
    λ = newton_results.λ
    active_set = newton_results.active_set

    # update results with stack vector
    for k = 1:N
        idx = ((k-1)*nm + 1):k*nm # index over x and u
        k != N ? idx2 = (((k-1)*p + 1):k*p) : idx2 = (((k-1)*p + 1):Np) # index over p
        k != N ? idx3 = (((k-1)*nm + 1):((k-1)*nm + nn)) : idx3 = (((k-1)*nm + 1):Nz)# index over x only
        idx4 = ((k-1)*nm + nn + 1):k*nm # index over u only
        idx5 = ((k-1)*mm + 1):k*mm # index through stacked u vector
        idx6 = ((k-1)*p + 1):((k-1)*p + pI) # index over p only inequality indices

        results.X[k] = z[idx3]
        k != N ? results.U[k] = z[idx4] : nothing
        results.λ[k] = λ[idx2]
        results.active_set[k] = active_set[idx2]
    end

    update_constraints!(results,solver)
    update_jacobians!(results,solver)

    return nothing
end

function solve_KKT!(newton_results::NewtonResults,alpha::Float64=1.0)
    W = newton_results.W
    w = newton_results.w

    G = newton_results.G
    g = newton_results.g

    D = newton_results.D
    d = newton_results.d

    A = newton_results.A
    b = newton_results.b

    z = newton_results.z
    λ = newton_results.λ
    ν = newton_results.ν

    # get batch problem sizes
    Nz = size(W,1)
    Np = size(G,1)
    Nx = size(D,1)

    active_set = newton_results.active_set

    Np_as = sum(active_set)

    # assemble KKT matrix/vector
    idx1 = 1:Nz
    idx2 = Nz+1:Nz+Np_as
    idx3 = Nz+Np_as+1:Nz+Np_as+Nx
    idx4 = 1:Nz+Np_as+Nx

    A[idx1,idx1] = W
    A[idx1,idx2] = G[active_set,:]'
    A[idx1,idx3] = D'
    A[idx2,idx1] = G[active_set,:]
    A[idx3,idx1] = D

    b[idx1] = -w
    b[idx2] = -g[active_set]
    b[idx3] = -d

    δ = A[idx4,idx4]\b[idx4]

    z .+= alpha*δ[idx1]
    λ[active_set] += δ[idx2]
    ν .+= δ[idx3]

    return nothing
end

function cost_newton(results::SolverIterResults,newton_results::NewtonResults,solver::Solver)
    results = copy(results)

    # get problem dimensions
    n,m,N = get_sizes(solver)

    J = cost(solver,results)

    # add dynamics constraint costs
    X = results.X
    U = results.U
    ν = newton_results.ν
    x_eval = newton_results.x_eval

    for k = 1:N
        if k == 1
            J += ν[1:n]'*(X[1] - solver.obj.x0)
        else
            idx = ((k-1)*n+1):k*n
            solver.fd(view(x_eval,idx),X[k-1][1:n],U[k-1][1:m])
            J += ν[idx]'*(X[k] - x_eval[idx])
        end
    end
    return J
end

function newton_solve(results::SolverIterResults,newton_results::NewtonResults,solver::Solver,alpha::Float64=1.0)
    results_new = copy(results)
    update_newton_results!(newton_results,results_new,solver)
    solve_KKT!(newton_results,alpha)
    update_results_from_newton_results!(results_new,newton_results,solver)

    J = cost_newton(results_new,newton_results,solver)
    c_max = max_violation(results_new)
    
    return results_new, J, c_max
end
