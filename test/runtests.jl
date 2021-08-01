using ARCTools
using Test

@testset "ARCTools.jl" begin
    q = QSub(;
        resources = Resources(
            walltime = "00:05:00",
            select = 2,
            ncpus = 3,
            mem = 5,
        ),
        modules = [
            "gcc/9.1.0",  # for git/2.21.0
            "git/2.21.0", # for julia 1.6+
            "python/3.7.3",
            "cuda/10.0.130",
        ],
        account = "st-arausch-1",
        jobname = "test-job",
    )

    jl = JuliaCmd(;
        bindir = Sys.BINDIR,
        threads = q.resources.ompthreads,
        project = ARCTools.copy_project(;
            project = joinpath(@__DIR__, "TestProj"),
            dest = mktempdir(
                "/scratch/st-arausch-1/jcd1994";
                prefix = "TestProj_",
            ),
        ),
        script = "./scripts/test_script.jl",
        args = ["Alice", "Bob", "Carol"],
        env = Dict{String, Any}(
            "JL_SECRET_VAL1" => "SECRET1",
            "JL_SECRET_VAL2" => "SECRET2",
            "JL_PUBLIC_VAL" => "PUBLIC",
        ),
        secrets = String[
            "JL_SECRET_VAL1",
            "JL_SECRET_VAL2",
        ],
    )

    run(qsub(q, jl))
end
