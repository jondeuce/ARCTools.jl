using Distributed

addprocs(
    readlines(ENV["PBS_NODEFILE"]);
    enable_threaded_blas = true,
    topology = :master_worker,
    exeflags = [
        "--project=$(Base.active_project())",
        "--threads=$(Threads.nthreads())",
        "--optimize",
    ],
)

# Load packages
@everywhere using TestProj
@everywhere MASTER_ARGS = ARGS

pmap(1:10) do id
    println(hello(join(MASTER_ARGS, ", ", ", and ")))
    println("PID:          $(getpid())")
    println("Host name:    $(gethostname())")
    println("Num. threads: $(Threads.nthreads())")
    sleep(0.5 + rand())
end

nothing
