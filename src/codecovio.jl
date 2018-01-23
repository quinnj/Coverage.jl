export Codecov

"""
Coverage.Codecov Module

This module provides functionality to push coverage information to the CodeCov.io
web service. It exports the `submit` and `submit_token` methods.
"""

module Codecov
    using HTTP
    using Coverage
    using JSON
    using Compat

    export submit, submit_token, submit_local, submit_generic

    #=
    JSON structure for Codecov.io
    https://codecov.io/api#post-report

    {
      "coverage": {
        "path/to/file.py": [null, 1, 0, null, true, 0, 0, 1, 1],
        "path/to/other.py": [null, 0, 1, 1, "1/3", null]
      },
      "messages": {
        "path/to/other.py": {
          "1": "custom message for line 1"
        }
      }
    }
    =#

    # Turn vector of filename : coverage pairs into a dictionary
    function to_json(fcs::Vector{FileCoverage})
        cov = Dict()
        for fc in fcs
            cov[fc.filename] = vcat(nothing, fc.coverage)
        end
        return Dict("coverage" => cov)
    end


    if VERSION >= v"0.7.0-DEV.3481"
        """
        kwargs provides default values to insert into args_array, only if they are
        not already specified in args_array.
        """
        function set_defaults(args_array; kwargs...)
            defined_names = keys(pairs(args_array))
            is_args_array = Pair{Symbol, Any}[]
            if args_array isa Base.Iterators.IndexValue
                is_args_array = vcat(is_args_array, collect(Pair(k, v) for (k,v) in args_array))
            else
                is_args_array = vcat(is_args_array, vec(args_array))
            end
            for kwarg in kwargs
                if !(kwarg[1] in defined_names)
                    push!(is_args_array, Pair(kwarg[1], kwarg[2]))
                end
            end
            return is_args_array
        end
    else
        """
        kwargs provides default values to insert into args_array, only if they are
        not already specified in args_array.
        """
        function set_defaults(args_array; kwargs...)
            defined_names = [k for (k, v) in args_array]
            for kwarg in kwargs
                if !(kwarg[1] in defined_names)
                    push!(args_array, kwarg)
                end
            end
            return args_array
        end
    end

    """
        submit(fcs::Vector{FileCoverage})

    Takes a vector of file coverage results (produced by `process_folder`),
    and submits them to Codecov.io. Assumes that this code is being run
    on TravisCI or AppVeyor. If running locally, use `submit_local`.
    """
    function submit(fcs::Vector{FileCoverage}; kwargs...)
        if lowercase(get(ENV, "APPVEYOR", "false")) == "true"
            appveyor_pr = get(ENV, "APPVEYOR_PULL_REQUEST_NUMBER", "")
            appveyor_job = join(
                [
                    ENV["APPVEYOR_ACCOUNT_NAME"],
                    ENV["APPVEYOR_PROJECT_SLUG"],
                    ENV["APPVEYOR_BUILD_VERSION"],
                ],
                "%2F",
            )
            kwargs = set_defaults(kwargs,
                service      = "appveyor",
                branch       = ENV["APPVEYOR_REPO_BRANCH"],
                commit       = ENV["APPVEYOR_REPO_COMMIT"],
                pull_request = appveyor_pr,
                job          = appveyor_job,
                slug         = ENV["APPVEYOR_REPO_NAME"],
                build        = ENV["APPVEYOR_JOB_ID"],
            )
        elseif lowercase(get(ENV, "TRAVIS", "false")) == "true"
            kwargs = set_defaults(kwargs,
                service      = "travis-org",
                branch       = ENV["TRAVIS_BRANCH"],
                commit       = ENV["TRAVIS_COMMIT"],
                pull_request = ENV["TRAVIS_PULL_REQUEST"],
                job          = ENV["TRAVIS_JOB_ID"],
                slug         = ENV["TRAVIS_REPO_SLUG"],
                build        = ENV["TRAVIS_JOB_NUMBER"],
            )
        elseif lowercase(get(ENV, "CIRCLECI", "false")) == "true"
            circle_slug = join(
                [
                    ENV["CIRCLE_PROJECT_USERNAME"],
                    ENV["CIRCLE_PROJECT_REPONAME"],
                ],
                "%2F",
            )
            kwargs = set_defaults(kwargs,
                service      = "circleci",
                branch       = ENV["CIRCLE_BRANCH"],
                commit       = ENV["CIRCLE_SHA1"],
                pull_request = get(ENV, "CIRCLE_PR_NUMBER", "false"),  # like Travis
                build_url    = ENV["CIRCLE_BUILD_URL"],
                slug         = circle_slug,
                build        = ENV["CIRCLE_BUILD_NUM"],
            )
        else
            error("No compatible CI platform detected")
        end

        submit_generic(fcs; kwargs...)
    end


    import Base.LibGit2

    """
        submit_local(fcs::Vector{FileCoverage}, dir::AbstractString=pwd())

    Take a `Vector` of file coverage results (produced by `process_folder`),
    and submit them to Codecov.io. Assumes the submission is being made from
    a local git installation, rooted at `dir`. A repository token should be specified by a
    `token` keyword argument or the `CODECOV_TOKEN` environment variable.
    """
    function submit_local(fcs::Vector{FileCoverage}, dir::AbstractString=joinpath(pwd(),".."); kwargs...)
        LibGit2.with(LibGit2.GitRepo(dir)) do repo
            LibGit2.with(LibGit2.head(repo)) do headref
                branch_name = LibGit2.shortname(headref)
                commit_oid  = LibGit2.GitHash(LibGit2.peel(headref))
                kwargs = set_defaults(kwargs,
                    commit = string(commit_oid),
                    branch = LibGit2.branch(headref) # this function returns a String
                    )
            end
        end

        if haskey(ENV, "REPO_TOKEN")
            println("the environment variable REPO_TOKEN is deprecated, use CODECOV_TOKEN instead")
            kwargs = set_defaults(kwargs, token = ENV["REPO_TOKEN"])
        end

        submit_generic(fcs; kwargs...)
    end

    @deprecate submit_token submit_local


    """
        submit_generic(fcs::Vector{FileCoverage})

    Takes a vector of file coverage results (produced by `process_folder`),
    and submits them to a Codecov.io instance. Keyword arguments are converted
    into a generic Codecov.io API uri.  It is essential that the keywords and
    values match the Codecov upload/v2 API specification.
    The `codecov_url` keyword argument or the CODECOV_URL environment variable
    can be used to specify the base path of the uri.
    The `dry_run` keyword can be used to prevent the http request from
    being generated
    """
    function submit_generic(fcs::Vector{FileCoverage}; kwargs...)
        @assert length(kwargs) > 0

        if haskey(ENV, "CODECOV_URL")
            kwargs = set_defaults(kwargs, codecov_url = ENV["CODECOV_URL"])
        end

        if haskey(ENV, "CODECOV_TOKEN")
            kwargs = set_defaults(kwargs, token = ENV["CODECOV_TOKEN"])
        end

        codecov_url = "https://codecov.io"
        dry_run = false
        for (k,v) in kwargs
            if k == :codecov_url
                codecov_url = v
            end
            if k == :dry_run
                dry_run = true
            end
        end
        @assert codecov_url[end] != "/" "the codecov_url should not end with a /, given url $(codecov_url)"

        uri_str = "$(codecov_url)/upload/v2?"
        for (k,v) in kwargs
            if k != :codecov_url && k != :dry_run
                uri_str = "$(uri_str)&$(k)=$(v)"
            end
        end

        println("Codecov.io API URL:")
        println(uri_str)

        if !dry_run
            heads   = Dict("Content-Type" => "application/json")
            data    = to_json(fcs)
            req     = HTTP.post(uri_str; body = JSON.json(data), headers = heads)
            println("Result of submission:")
            println(String(req.data))
        end
    end

end  # module Codecov
