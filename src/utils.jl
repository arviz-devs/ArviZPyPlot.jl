"""
    convert_arguments(f, args...; kwargs...) -> NTuple{2}

Convert arguments to the function `f` before calling.

This function is used primarily for pre-processing arguments within macros before sending
to arviz.
"""
convert_arguments(::Any, args...; kwargs...) = args, kwargs

"""
    convert_result(f, result, args...)

Convert result of the function `f` before returning.

This function is used primarily for post-processing outputs of arviz before returning.
The `args` are primarily used for dispatch.
"""
convert_result(f, result, args...) = result

"""
    @forwardplotfun f

Wrap a plotting function `arviz.f` in `f`, forwarding its docstrings.

Use [`convert_arguments`](@ref) and [`convert_result`](@ref) to customize what is passed to
and returned from `f`.
"""
macro forwardplotfun(f)
    fesc = esc(f)
    sf = string(f)
    ex = quote
        @doc LazyHelp(arviz, $sf) function $(fesc)(args...; kwargs...)
            args, kwargs = convert_arguments($(fesc), args...; kwargs...)
            pyargs = Iterators.map(topytype, args)
            pykwargs = (k => topytype(v) for (k, v) in pairs(kwargs))
            result = arviz.$(f)(pyargs...; pykwargs..., backend="matplotlib")
            return convert_result($(fesc), result)
        end
    end
    # make sure line number of methods are place where macro is called, not here
    _replace_line_number!(ex, __source__)
    return ex
end

function _replace_line_number!(ex, source)
    for i in eachindex(ex.args)
        if ex.args[i] isa LineNumberNode
            ex.args[i] = source
        elseif ex.args[i] isa Expr
            _replace_line_number!(ex.args[i], source)
        end
    end
end

# Convert python types to Julia types if possible
@inline frompytype(x) = x
frompytype(x::AbstractArray{Py}) = map(frompytype, x)
frompytype(x::AbstractArray{Any}) = map(frompytype, x)
frompytype(x::AbstractArray{<:AbstractArray}) = map(frompytype, x)

# Convert Julia types to suitable Python types
topytype(x::AbstractVector) = pylist(map(topytype, x))
topytype(x::AbstractVector{<:Real}) = Py(x).to_numpy()
topytype(x::AbstractArray{<:Real}) = Py(x).to_numpy()
topytype(x::Tuple) = pytuple(map(topytype, x))
topytype(x::AbstractDict) = pydict(topytype(k) => topytype(v) for (k, v) in pairs(x))
topytype(x::NamedTuple) = topytype(pairs(x))
topytype(x::Symbol) = pystr(x)
topytype(::Missing) = Py(NaN)
topytype(x) = Py(x)

"""
    todataframes(df; index_name = nothing) -> DataFrames.DataFrame

Convert a Python `pandas.DataFrame` or `pandas.Series` into a `DataFrames.DataFrame`.

If `index_name` is not `nothing`, the index is converted into a column with `index_name`.
Otherwise, it is discarded.
"""
function todataframes(::Val{:DataFrame}, df::Py; index_name=nothing)
    col_vals = map(df.columns) do name
        series = pygetitem(df, name)
        vals = series.values
        return Symbol(name) => frompytype(vals)
    end
    if index_name !== nothing
        index_vals = frompytype(df.index.values)
        col_vals = [Symbol(index_name) => index_vals; col_vals]
    end
    return DataFrames.DataFrame(col_vals)
end
function todataframes(::Val{:Series}, series::Py; kwargs...)
    colnames = map(i -> Symbol(frompytype(i)), series.index)
    colvals = map(x -> [frompytype(x)], series.values)
    return DataFrames.DataFrame(colvals, colnames)
end
function todataframes(df::Py; kwargs...)
    if pyisinstance(df, pandas.Series)
        return todataframes(Val(:Series), df; kwargs...)
    end
    return todataframes(Val(:DataFrame), df; kwargs...)
end

"""
    topandas(::Type{:DataFrame}, df; index_name = nothing) -> Py
    topandas(::Type{:Series}, df) -> Py
    topandas(::Val{:ELPDData}, df) -> Py

Convert a `DataFrames.DataFrame` to the specified pandas type.

If `index_name` is not `nothing`, the corresponding column is made the index of the
returned dataframe.
"""
function topandas(::Val{:DataFrame}, df; index_name=nothing)
    # initialize_pandas()
    df = DataFrames.DataFrame(df)
    colnames = names(df)
    rowvals = map(x -> Py(collect(x)).to_numpy(), eachrow(df))
    pdf = pandas.DataFrame(rowvals; columns=colnames)
    index_name !== nothing && pdf.set_index(index_name; inplace=true)
    return pdf
end
function topandas(::Val{:Series}, df)
    # initialize_pandas()
    df = DataFrames.DataFrame(df)
    rownames = pylist(names(df))
    colvals = Py(only(eachrow(df))).to_numpy()
    return pandas.Series(colvals, rownames)
end
