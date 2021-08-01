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
@with_kw mutable struct Resources
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

@with_kw mutable struct QSub
    resources::Resources
    modules::Vector{String}
    account::String
    jobname::String
    stdout::String = ""
    stderr::String = ""
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

@with_kw mutable struct JuliaCmd
    bindir::String
    threads::Int
    project::String
    script::String
    flags::Dict{String, Any} = Dict{String, Any}()
    args::Vector{String} = String[]
    env::Dict{String, Any} = Dict{String, Any}()
    secrets::Vector{String} = String[]
end

function try_find_julia_bindir()
    jldir = chomp(read(`which julia`, String)) # path of default julia
    jldir = chomp(read(`readlink -e $(jldir)`, String)) # follow symlinks
    bindir = dirname(jldir)
    @assert isdir(bindir)
    return bindir
end

function bash_commands(jl::JuliaCmd)
    envfile = logfile(JuliaJob(), jl.project, jl.script, "env.toml")
    flags = [isnothing(v) ? k : "$k=$v" for (k, v) in jl.flags]
    julia = join([joinpath(jl.bindir, "julia"); flags], " ")

    """
    # Ensure project directory path exists
    mkdir -p $(jl.project)
    cd $(jl.project)

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
        q::QSub,
        jl::JuliaCmd,
    )
    logfile_(suffix) = logfile(JuliaJob(), jl.project, jl.script, suffix)

    # Set standard output/standard error log files
    isempty(q.stdout) && (q.stdout = logfile_("stdout.txt"))
    isempty(q.stderr) && (q.stderr = logfile_("stderr.txt"))

    # Default environment
    get!(jl.env, "JULIA_BINDIR", jl.bindir)
    get!(jl.env, "JULIA_PROJECT", jl.project)
    get!(jl.env, "JULIA_NUM_THREADS", jl.threads)

    # Default flags
    get!(jl.flags, "--startup-file", "no")
    get!(jl.flags, "--history-file", "no")
    get!(jl.flags, "--optimize", nothing)
    get!(jl.flags, "--quiet", nothing)

    if q.interactive
        get!(jl.flags, "-i", nothing)
    end

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
