"""
    fm = parse_source(filename::AbstractString, mod::Module)

Parse the source `filename`, returning a [`FileModules`](@ref) `fm`.
`mod` is the "parent" module for the file (i.e., the one that `include`d the file);
if `filename` defines more module(s) then these will all have separate entries in `fm`.

If parsing `filename` fails, `nothing` is returned.
"""
parse_source(filename::AbstractString, mod::Module) =
    parse_source!(FileModules(mod), filename, mod)

"""
    parse_source!(fm::FileModules, filename, mod::Module)

Top-level parsing of `filename` as included into module
`mod`. Successfully-parsed expressions will be added to `fm`. Returns
`fm` if parsing finished successfully, otherwise `nothing` is returned.

See also [`parse_source`](@ref).
"""
function parse_source!(fm::FileModules, filename::AbstractString, mod::Module)
    if !isfile(filename)
        @warn "$filename is not a file, omitting from revision tracking"
        return nothing
    end
    parse_source!(fm, read(filename, String), Symbol(filename), 1, mod)
end

"""
    success = parse_source!(fm::FileModules, src::AbstractString, file::Symbol, pos::Integer, mod::Module)

Parse a string `src` obtained by reading `file` as a single
string. `pos` is the 1-based byte offset from which to begin parsing `src`.

See also [`parse_source`](@ref).
"""
function parse_source!(fm::FileModules, src::AbstractString, file::Symbol, pos::Integer, mod::Module)
    local ex, oldpos
    # Since `parse` doesn't keep track of line numbers (it works
    # expression-by-expression), to ensure good backtraces we have to
    # keep track of them here. For each expression we parse, we count
    # the number of linefeed characters that occurred between the
    # beginning and end of the portion of the string consumed to parse
    # the expression.
    line_offset = 0
    while pos < lastindex(src)
        try
            oldpos = pos
            ex, pos = Meta.parse(src, pos; greedy=true)
        catch err
            ex, posfail = Meta.parse(src, pos; greedy=true, raise=false)
            warnline = line_offset + count(c->c=='\n', SubString(src, oldpos, posfail)) + 1
            with_logger(SimpleLogger(stderr)) do
                @error "omitting file $file due to parsing error near line $warnline"
            end
            showerror(stderr, err)
            println(stderr)
            return nothing
        end
        if isa(ex, Expr)
            ex = ex::Expr
            fix_line_statements!(ex, file, line_offset)  # fixes the backtraces
            parse_expr!(fm, ex, file, mod)
        end
        # Update the number of lines
        line_offset += count(c->c=='\n', SubString(src, oldpos, pos-1))
    end
    fm
end

"""
    success = parse_source!(fm::FileModules, ex::Expr, file, mod::Module)

For a `file` that defines a sub-module, parse the body `ex` of the
sub-module.  `mod` will be the module into which this sub-module is
evaluated (i.e., included). Successfully-parsed expressions will be
added to `fm`. Returns `true` if parsing finished successfully.

See also [`parse_source`](@ref).
"""
function parse_source!(fm::FileModules, ex::Expr, file::Symbol, mod::Module)
    @assert ex.head == :block
    for a in ex.args
        if isa(a, Expr)
            parse_expr!(fm, a::Expr, file, mod)
        end
    end
    fm
end

"""
    parse_expr!(fm::FileModules, ex::Expr, file::Symbol, mod::Module)

Recursively parse the expressions in `ex`, iterating over blocks and
sub-module definitions. Successfully parsed
expressions are added to `fm` with key `mod`, and any sub-modules will
be stored in `fm` using appropriate new keys. This accomplishes two main
tasks:

* add parsed expressions to the source-code cache (so that later we can detect changes)
* determine the module into which each parsed expression is `eval`uated into
"""
function parse_expr!(fm::FileModules, ex::Expr, file::Symbol, mod::Module)
    if ex.head == :block
        for a in ex.args
            a isa Expr || continue
            parse_expr!(fm, a, file, mod)
        end
        return fm
    end
    macroreplace!(ex, String(file))
    if ex.head == :line
        # skip line statements
    elseif ex.head == :module
        parse_module!(fm, ex, file, mod)
    elseif isdocexpr(ex)
        mac, source, meta, dex = ex.args
        dex isa Expr && parse_expr!(fm, dex, file, mod)
        # Store a non-defining doc expression (update the docstring if it gets modified,
        # but we don't want to evaluate the object when we do so)
        drex = convert(RelocatableExpr, Expr(:macrocall, mac, source, meta, dex, false))
        fm[mod].defmap[drex] = nothing
    elseif ex.head == :struct
        # Extract methods from inner constructors
        body = ex.args[end]
        for a in body.args
            if isa(a, Expr) && (a.head == :function || a.head == :(=))
                ra = convert(RelocatableExpr, a)
                fm[mod].defmap[ra] = get_signature(ra)
            end
        end
        fm[mod].defmap[convert(RelocatableExpr, ex)] = nothing
    elseif ex.head == :call && ex.args[1] == :include
        # skip include statements
    elseif ex.head == :for
        # handle simple loops that eval generated code
        loopvars, body = ex.args
        while is_trivial_block_wrapper(body)
            body = body.args[end]
        end
        # Extract the @eval body
        if isexpr(body, :macrocall) && body.args[1] == Symbol("@eval")
            try
                ebody = Expr(:block)
                ebody.args = body.args[2:end]
                if isexpr(loopvars, :(=)) && isexpr(loopvars.args[1], :tuple)
                    # handle destructuring, i.e., :(for (k, v) in iter body end)
                    varnames = map(Symbol, loopvars.args[1].args)
                    iter = Core.eval(mod, loopvars.args[2])
                    for vals in iter
                        tex = interpolate(mod, ebody, varnames, vals)
                        parse_expr!(fm, tex, file, mod)
                    end
                else
                    # :(for T in iter body end) or :(for T1 in iter1, T2 in iter2 body end)
                    loopvars = loopvars.head == :(=) ? [loopvars] : loopvars.args
                    varnames = [lex.args[1] for lex in loopvars]
                    varvals  = Any[Core.eval(mod, lex.args[2]) for lex in loopvars]
                    for vals in Iterators.product(varvals...)
                        tex = interpolate(mod, ebody, varnames, vals)
                        parse_expr!(fm, tex, file, mod)
                    end
                end
            catch
                # @warn "parsing failure on $ex, punting on these expressions"
                fm[mod].defmap[convert(RelocatableExpr, ex)] = nothing
            end
        else
            # This is a loop we don't understand, so store it wholesale without extracting signatures
            fm[mod].defmap[convert(RelocatableExpr, ex)] = nothing
        end
    else
        # Any expression that *doesn't* define line numbers, new
        # modules, or include new files must be "real code."
        # Handle macros
        exorig = ex0 = ex
        if isexpr(ex, :macrocall)
            if ex.args[1] ∉ (Symbol("@warn"), Symbol("@info"), Symbol("@debug"), Symbol("@error"), Symbol("@logmsg"))  # issue #208
                # To get the signature, we have to expand any unrecognized macro because
                # the macro may change the signature
                try
                    ex0, ex = macexpand(mod, ex)
                catch
                end
            end
        end
        ex isa Expr || return fm
        ex.head == :tuple && isempty(ex.args) && return fm
        if ex.head == :block
            return parse_expr!(fm, ex, file, mod)
        end
        # Add any method definitions to the cache
        sig = ex.head == :macrocall ? nothing : get_signature(convert(RelocatableExpr, ex))
        # However, we have to store the original unexpanded expression if
        # `revise(mod)` can be expected to work (issue #174).
        rex = convert(RelocatableExpr, exorig)
        if isa(sig, ExLike)
            fm[mod].defmap[rex] = sig  # we can't safely `eval` the types because they may not yet exist
        else
            fm[mod].defmap[rex] = nothing
        end
    end
    fm
end

function macexpand(mod::Module, ex::Expr)
    ex0 = ex
    if is_poppable_macro(ex.args[1])
        ex = ex.args[end]
        if isexpr(ex, :macrocall)
            ex0.args[end], ex = macexpand(mod, ex)
        end
    else
        ex0 = ex = macroexpand(mod, ex)
    end
    return ex0, ex
end

const nargs_docexpr = 4
isdocexpr(ex) = ex.head == :macrocall && ex.args[1] == GlobalRef(Core, Symbol("@doc")) &&
           length(ex.args) >= nargs_docexpr


"""
    newmod = parse_module!(fm::FileModules, ex::Expr, file, mod::Module)

Parse an expression `ex` that defines a new module `newmod`. This
module is "parented" by `mod`. Source-code expressions are added to
`fm` under the appropriate module name.
"""
function parse_module!(fm::FileModules, ex::Expr, file::Symbol, mod::Module)
    newname = _module_name(ex)
    if isdefined(mod, newname)
        newmod = getfield(mod, newname)
    else
        id = Base.identify_package(mod, String(newname))
        if id === nothing
            newmod = eval_module_expr(mod, ex, newname)
        else
            newmod = Base.root_module(id)
            if !isa(newmod, Module)
                newmod = eval_module_expr(mod, ex, newname)
            end
        end
    end
    fm[newmod] = FMMaps()
    parse_source!(fm, ex.args[3], file, newmod)  # recurse into the body of the module
    newmod
end

function eval_module_expr(mod, ex, newname)
    with_logger(_debug_logger) do
        @debug "parse_module" _group="Parsing" activemodule=fullname(mod) newname
    end
    try
        Core.eval(mod, ex) # support creating new submodules
    catch
        @warn "Error evaluating expression in $mod:\n$ex"
        rethrow()
    end
    return getfield(mod, newname)
end

_module_name(ex::Expr) = ex.args[2]
