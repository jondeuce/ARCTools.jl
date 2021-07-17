module ARCTools

using Glob
using Parameters
using ReadableRegex

export Resources
export QSub, qsub
export JuliaCmd, JuliaJob

#### QSub

const Maybe{T} = Union{T, Nothing}

"""
https://confluence.it.ubc.ca/display/UARC/Running+Jobs
"""
@with_kw struct Resources
    walltime::Maybe{String} = nothing
    select::Maybe{Int} = nothing
    ncpus::Maybe{Int} = nothing
    ngpus::Maybe{Int} = nothing
    mpiprocs::Maybe{Int} = nothing
    ompthreads::Maybe{Int} = ncpus
    mem::Maybe{Int} = nothing
    gpu_mem::Maybe{Int} = nothing
end

function resource_string(r::Resources, prop::Symbol)
    val = getfield(r, prop)
    units = (prop === :mem || prop === :gpu_mem) ? "gb" : ""
    sep = (prop === :walltime) ? "," : ":"
    val === nothing ? "" : "$(prop)=$(val)$(units)$(sep)"
end

function resource_list(r::Resources)
    r_list = ""
    for prop in [
            # Note: order matters here for :walltime and :select
            :walltime,
            :select,
            :ncpus,
            :ngpus,
            :mpiprocs,
            :ompthreads,
            :mem,
            :gpu_mem,
        ]
        r_list *= resource_string(r, prop)
    end

    # Return resource list, removing trailing separator
    @assert !isempty(r_list)
    r_list[begin:end-1]
end

#### QSub

@with_kw struct QSub
    resources::Resources
    modules::Vector{String}
    account::String
    jobname::String
    stdout::String
    stderr::String
    interactive::Bool = false
    X11forwarding::Bool = interactive
    @assert !(X11forwarding && !interactive) "X11 forwarding requires interactive=true"
end

function pbs_header(q::QSub)
    pbs_directives = Any[
        "#PBS -l $(resource_list(q.resources))",
        "#PBS -A $(q.account)",
        "#PBS -N $(q.jobname)",
        "#PBS -o $(q.stdout)",
        "#PBS -e $(q.stderr)",
        "#PBS -j oe",
    ]
    if q.interactive
        push!(pbs_directives, "#PBS -I")
        push!(pbs_directives, "#PBS -q interactive_$(q.resources.ngpus !== nothing ? "gpu" : "cpu")")
    end
    if q.X11forwarding
        push!(pbs_directives, "#PBS -X")
    end

    """
    #!/bin/bash
    $(join(pbs_directives, "\n"))

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
    secrets::Vector{String} = []
    bin::String = ""
    flags::Vector{String} = []
    script::String
    args::Vector{String} = []
end

function bash_commands(jl::JuliaCmd)
    envfile = logfile(JuliaJob(), jl.dir, jl.script, "env.toml")
    julia = join([joinpath(jl.bin, "julia"); jl.flags], " ")

    """
    # Ensure working directory path exists
    mkdir -p $(jl.dir)
    cd $(jl.dir)

    # Set environment variables
    $(join(["export $k=$v" for (k,v) in jl.env], "\n"))

    # Log environment variables
    $(julia) -e 'using TOML; TOML.print(ENV)' | sort -h $(
        isempty(jl.secrets) ?
            "> $(envfile)" :
            "| grep -Ev '^($(join(collect(jl.secrets), "|")))' > $(envfile)"
    )

    # Run julia script
    $(join([julia; jl.script; "--"; jl.args], " "))
    """
end

#### JuliaCmd + QSub

struct JuliaJob end

function Base.basename(::JuliaJob, script)
    @assert endswith(script, ".jl")
    basename(script)[begin:end-3]
end

function logfile(::JuliaJob, project, script, suffix)
    joinpath(
        mkpath(joinpath(project, "pbs")),
        basename(JuliaJob(), script) * "_" * suffix,
    )
end

function qsub(
        ::JuliaJob;
        # qsub kwargs
        resources::Resources,
        modules::Vector{String} = [
            "gcc/9.1.0",  # for git/2.21.0
            "git/2.21.0", # for julia 1.6+
            "python/3.7.3",
            "cuda/10.0.130",
        ],
        account::String,
        jobname::String,
        interactive::Bool = false,
        X11forwarding::Bool = interactive,
        # julia kwargs
        env::Vector{Pair{String,String}} = Pair{String,String}[],
        secrets::Vector{String} = String[],
        bin::String,
        project::String,
        threads::Int = resources.ncpus,
        script::String,
        args::Vector{String} = [],
    )
    @assert endswith(script, ".jl")
    logfile_(suffix) = logfile(JuliaJob(), project, script, suffix)

    q = QSub(;
        resources,
        modules,
        account,
        jobname,
        stdout = logfile_("stdout.txt"),
        stderr = logfile_("stderr.txt"),
        interactive,
        X11forwarding,
    )

    flags = [
        "--startup-file=no",
        "--history-file=no",
        "--optimize",
        "--quiet",
    ]
    if interactive
        push!(flags, "-i")
    end

    jl = JuliaCmd(;
        dir = project,
        env = [
            env;
            "JULIA_BINDIR" => bin;
            "JULIA_PROJECT" => project;
            "JULIA_NUM_THREADS" => string(threads);
        ],
        secrets,
        bin,
        flags,
        script,
        args,
    )

    # Write pbs script to file
    open(logfile_("job.pbs"), "w+") do io
        print(io,
            """
            $(pbs_header(q))
            $(bash_commands(jl))
            """
        )
    end

    `qsub $(logfile_("job.pbs"))`
end

#### Copy project

function copy_project(;
        project,
        folders = [
            "src",
            "scripts",
        ],
        dest = mktempdir(),
    )
    files = joinpath.(project, [
        "Project.toml",
        "Manifest.toml",
        folders...,
    ])
    files = filter(ispath, files)

    for file in files
        cp(file, joinpath(dest, basename(file)); force=false, follow_symlinks=true)
    end

    return dest
end

end # module ARCTools
