using ARCTools
using Test

@testset "ARCTools.jl" begin
    q = qsub(
        JuliaJob();
        # qsub kwargs
        resources = Resources(
            walltime = "00:05:00",
            select = 2,
            ncpus = 3,
            mem = 5,
        ),
        account = "st-arausch-1",
        jobname = "test-job",
        # julia kwargs
        env = [
            "JL_SECRET_VAL1" => "SECRET1",
            "JL_SECRET_VAL2" => "SECRET2",
            "JL_PUBLIC_VAL" => "PUBLIC",
        ],
        secrets = [
            "JL_SECRET_VAL1",
            "JL_SECRET_VAL2",
        ],
        bin = Sys.BINDIR,
        project = expanduser("~/TestProj"),
        script = "./scripts/test_script.jl",
        args = ["Alice", "Bob", "Carol"]
    )
    run(q)
end
