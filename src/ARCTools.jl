module ARCTools

using Glob
using Parameters
using ReadableRegex

export QSub, qsub
export JuliaCmd, JuliaJob

#### QSub

@with_kw struct QSub
    modules::Vector{String}
    account::String
    jobname::String
    walltime::String
    select::Int
    ncpus::Int
    ompthreads::Int
    mem::Int
    stdout::String
    stderr::String
end

function pbs_header(q::QSub)
    """
    #!/bin/bash
    #PBS -l walltime=$(q.walltime),select=$(q.select):ncpus=$(q.ncpus):ompthreads=$(q.ompthreads):mem=$(q.mem)gb
    #PBS -A $(q.account)
    #PBS -N $(q.jobname)
    #PBS -o $(q.stdout)
    #PBS -e $(q.stderr)
    #PBS -j oe

    # Load modules
    $(join(["module load $mod" for mod in q.modules], "\n"))

    # Potentially useful environment variables exported by PBS
    #   PBS_JOBDIR      Pathname of job's staging and execution directory on the primary execution host
    #   PBS_JOBID       Job identifier given by PBS when the job is submitted
    #   PBS_JOBNAME     Job name specified by submitter
    #   PBS_NODEFILE    Name of file containing the list of nodes assigned to the job
    #   PBS_O_HOME      User's home directory. Value of HOME taken from user's submission environment
    #   PBS_O_PATH      User's PATH. Value of PATH taken from user's submission environment
    #   PBS_O_WORKDIR   Absolute path to directory where qsub is run. Value taken from user's submission environment
    #   TMPDIR          Pathname of job's scratch directory. Set when PBS assigns it
    """
end

#### JuliaCmd

@with_kw struct JuliaCmd
    dir::String = "."
    env::Vector{Pair{String,String}} = []
    bin::String = ""
    flags::Vector{String} = []
    script::String
    args::Vector{String} = []
end

function bash_commands(jl::JuliaCmd)
    """
    # Ensure working directory path exists
    mkdir -p $(jl.dir)
    cd $(jl.dir)

    # Set environment variables
    $(join(["export $k=$v" for (k,v) in jl.env], "\n"))

    # Run julia script
    $(join([joinpath(jl.bin, "julia"); jl.flags; jl.script; jl.args], " "))
    """
end

#### JuliaCmd + QSub

struct JuliaJob end

function qsub(
        ::JuliaJob;
        # qsub kwargs
        modules::Vector{String} = [
            "gcc/9.1.0",  # for git/2.21.0
            "git/2.21.0", # for julia 1.6+
            "python/3.7.3",
        ],
        account::String,
        jobname::String,
        walltime::String,
        select::Int,
        memory::Int,
        # julia kwargs
        env::Vector{Pair{String,String}} = Pair{String,String}[],
        bin::String,
        project::String,
        threads::Int,
        optimize::Int,
        script::String,
        args::Vector{String} = [],
    )
    @assert endswith(script, ".jl")

    pbs_file(suffix) = joinpath(
        mkpath(joinpath(project, "pbs")),
        basename(script)[1:end-3] * suffix,
    )

    q = QSub(;
        modules = modules,
        account = account,
        jobname = jobname,
        walltime = walltime,
        select = select,
        ncpus = threads,
        ompthreads = threads,
        mem = memory,
        stdout = pbs_file("_stdout.txt"),
        stderr = pbs_file("_stderr.txt"),
    )

    jl = JuliaCmd(;
        dir = project,
        env = [
            env;
            "JULIA_BINDIR" => bin;
            "JULIA_PROJECT" => project;
            "JULIA_NUM_THREADS" => string(threads);
        ],
        bin = bin,
        flags = [
            "--startup-file=no",
            "--history-file=no",
            "--optimize=$(optimize)",
        ],
        script,
        args,
    )

    # Write pbs script to file
    open(pbs_file("_job.pbs"), "w+") do io
        print(io,
            """
            $(pbs_header(q))
            $(bash_commands(jl))
            """
        )
    end

    `qsub $(pbs_file("_job.pbs"))`
end

end
