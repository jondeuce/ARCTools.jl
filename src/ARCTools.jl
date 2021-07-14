module ARCTools

using Glob
using Parameters
using ReadableRegex

#### JuliaCmd

@with_kw struct JuliaCmd
    path::String = "julia"
    env::Vector{Pair{String,String}} = []
    dir::String = "."
    flags::Vector{String} = []
    script::String
    args::Vector{String} = []
end

function command(jl::JuliaCmd)
    Cmd(`$[jl.path; jl.flags; jl.script; jl.args]`; env = jl.env, dir = jl.dir)
end

function bash_script(jl::JuliaCmd)
    """
    #!/bin/bash
    cd $(jl.dir)
    $(join(["export $k=$v" for (k,v) in jl.env], "\n"))
    $(join([jl.path; jl.flags; jl.script; jl.args], " "))
    """
end

#### QSubCmd

@with_kw struct QSubCmd
    path::String = "qsub"
    env::Vector{Pair{String,String}} = []
    dir::String = "."
    flags::Vector{String} = []
    pbs::String
end

function command(qsub::QSubCmd)
    Cmd(`$[qsub.path; qsub.flags; qsub.pbs]`; env = qsub.env, dir = qsub.dir)
end

#### QSubCmd + JuliaCmd

function command(
        qsub::QSubCmd,
        jl::JuliaCmd,
    )
    mkpath(jl.dir)
    jl_pbs_file = tempname() * ".pbs"
    jl_pbs_script = bash_script(jl)
    open(jl_pbs_file, "w+") do io
        println(io, jl_pbs_script)
    end
    command(QSubCmd(qsub; pbs = jl_pbs_file))
end

end
