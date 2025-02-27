
calcMidpoints(edges::AbstractVector) = Float64[0.5 * (edges[i] + edges[i+1]) for i in 1:length(edges)-1]

"Make histogram-like bins of data"
function binData(data, nbins)
  lo, hi = ignorenan_extrema(data)
  edges = collect(linspace(lo, hi, nbins+1))
  midpoints = calcMidpoints(edges)
  buckets = Int[max(2, min(searchsortedfirst(edges, x), length(edges)))-1 for x in data]
  counts = zeros(Int, length(midpoints))
  for b in buckets
    counts[b] += 1
  end
  edges, midpoints, buckets, counts
end

"""
A hacky replacement for a histogram when the backend doesn't support histograms directly.
Convert it into a bar chart with the appropriate x/y values.
"""
function histogramHack(; kw...)
  d = KW(kw)

  # we assume that the y kwarg is set with the data to be binned, and nbins is also defined
  edges, midpoints, buckets, counts = binData(d[:y], d[:bins])
  d[:x] = midpoints
  d[:y] = float(counts)
  d[:seriestype] = :bar
  d[:fillrange] = d[:fillrange] == nothing ? 0.0 : d[:fillrange]
  d
end

"""
A hacky replacement for a bar graph when the backend doesn't support bars directly.
Convert it into a line chart with fillrange set.
"""
function barHack(; kw...)
  d = KW(kw)
  midpoints = d[:x]
  heights = d[:y]
  fillrange = d[:fillrange] == nothing ? 0.0 : d[:fillrange]

  # estimate the edges
  dists = diff(midpoints) * 0.5
  edges = zeros(length(midpoints)+1)
  for i in 1:length(edges)
    if i == 1
      edge = midpoints[1] - dists[1]
    elseif i == length(edges)
      edge = midpoints[i-1] + dists[i-2]
    else
      edge = midpoints[i-1] + dists[i-1]
    end
    edges[i] = edge
  end

  x = Float64[]
  y = Float64[]
  for i in 1:length(heights)
    e1, e2 = edges[i:i+1]
    append!(x, [e1, e1, e2, e2])
    append!(y, [fillrange, heights[i], heights[i], fillrange])
  end

  d[:x] = x
  d[:y] = y
  d[:seriestype] = :path
  d[:fillrange] = fillrange
  d
end


"""
A hacky replacement for a sticks graph when the backend doesn't support sticks directly.
Convert it into a line chart that traces the sticks, and a scatter that sets markers at the points.
"""
function sticksHack(; kw...)
  dLine = KW(kw)
  dScatter = copy(dLine)

  # these are the line vertices
  x = Float64[]
  y = Float64[]
  fillrange = dLine[:fillrange] == nothing ? 0.0 : dLine[:fillrange]

  # calculate the vertices
  yScatter = dScatter[:y]
  for (i,xi) in enumerate(dScatter[:x])
    yi = yScatter[i]
    for j in 1:3 push!(x, xi) end
    append!(y, [fillrange, yScatter[i], fillrange])
  end

  # change the line args
  dLine[:x] = x
  dLine[:y] = y
  dLine[:seriestype] = :path
  dLine[:markershape] = :none
  dLine[:fillrange] = nothing

  # change the scatter args
  dScatter[:seriestype] = :none

  dLine, dScatter
end

function regressionXY(x, y)
  # regress
  β, α = convert(Matrix{Float64}, [x ones(length(x))]) \ convert(Vector{Float64}, y)

  # make a line segment
  regx = [ignorenan_minimum(x), ignorenan_maximum(x)]
  regy = β * regx + α
  regx, regy
end

function replace_image_with_heatmap(z::Array{T}) where T<:Colorant
    @show T, size(z)
    n, m = size(z)
    # idx = 0
    colors = ColorGradient(vec(z))
    newz = reshape(linspace(0, 1, n*m), n, m)
    newz, colors
    # newz = zeros(n, m)
    # for i=1:n, j=1:m
    #     push!(colors, T(z[i,j]...))
    #     newz[i,j] = idx / (n*m-1)
    #     idx += 1
    # end
    # newz, ColorGradient(colors)
end

function imageHack(d::KW)
    is_seriestype_supported(:heatmap) || error("Neither :image or :heatmap are supported!")
    d[:seriestype] = :heatmap
    d[:z], d[:fillcolor] = replace_image_with_heatmap(d[:z].surf)
end
# ---------------------------------------------------------------

"Build line segments for plotting"
mutable struct Segments{T}
    pts::Vector{T}
end

# Segments() = Segments{Float64}(zeros(0))

Segments() = Segments(Float64)
Segments(::Type{T}) where {T} = Segments(T[])
Segments(p::Int) = Segments(NTuple{2,Float64}[])


# Segments() = Segments(zeros(0))

to_nan(::Type{Float64}) = NaN
to_nan(::Type{NTuple{2,Float64}}) = (NaN, NaN)

coords(segs::Segments{Float64}) = segs.pts
coords(segs::Segments{NTuple{2,Float64}}) = Float64[p[1] for p in segs.pts], Float64[p[2] for p in segs.pts]

function Base.push!(segments::Segments{T}, vs...) where T
    if !isempty(segments.pts)
        push!(segments.pts, to_nan(T))
    end
    for v in vs
        push!(segments.pts, convert(T,v))
    end
    segments
end

function Base.push!(segments::Segments{T}, vs::AVec) where T
    if !isempty(segments.pts)
        push!(segments.pts, to_nan(T))
    end
    for v in vs
        push!(segments.pts, convert(T,v))
    end
    segments
end


# -----------------------------------------------------
# helper to manage NaN-separated segments

mutable struct SegmentsIterator
    args::Tuple
    n::Int
end

function iter_segments(args...)
    tup = Plots.wraptuple(args)
    n = maximum(map(length, tup))
    SegmentsIterator(tup, n)
end

function iter_segments(series::Series)
    x, y, z = series[:x], series[:y], series[:z]
    if has_attribute_segments(series)
        if series[:seriestype] in (:scatter, :scatter3d)
            return [[i] for i in 1:length(y)]
        else
            return [i:(i + 1) for i in 1:(length(y) - 1)]
        end
    else
        segs = UnitRange{Int}[]
        args = is3d(series) ? (x, y, z) : (x, y)
        for seg in iter_segments(args...)
            push!(segs, seg)
        end
        return segs
    end
end

# helpers to figure out if there are NaN values in a list of array types
anynan(i::Int, args::Tuple) = any(a -> try isnan(_cycle(a,i)) catch MethodError false end, args)
anynan(istart::Int, iend::Int, args::Tuple) = any(i -> anynan(i, args), istart:iend)
allnan(istart::Int, iend::Int, args::Tuple) = all(i -> anynan(i, args), istart:iend)

function Base.start(itr::SegmentsIterator)
    nextidx = 1
    if !any(isempty,itr.args) && anynan(1, itr.args)
        _, nextidx = next(itr, 1)
    end
    nextidx
end
Base.done(itr::SegmentsIterator, nextidx::Int) = nextidx > itr.n
function Base.next(itr::SegmentsIterator, nextidx::Int)
    i = istart = iend = nextidx

    # find the next NaN, and iend is the one before
    while i <= itr.n + 1
        if i > itr.n || anynan(i, itr.args)
            # done... array end or found NaN
            iend = i-1
            break
        end
        i += 1
    end

    # find the next non-NaN, and set nextidx
    while i <= itr.n
        if !anynan(i, itr.args)
            break
        end
        i += 1
    end

    istart:iend, i
end

# Find minimal type that can contain NaN and x
# To allow use of NaN separated segments with categorical x axis

float_extended_type(x::AbstractArray{T}) where {T} = Union{T,Float64}
float_extended_type(x::AbstractArray{T}) where {T<:Real} = Float64

# ------------------------------------------------------------------------------------


nop() = nothing
notimpl() = error("This has not been implemented yet")

isnothing(x::Void) = true
isnothing(x) = false

_cycle(wrapper::InputWrapper, idx::Int) = wrapper.obj
_cycle(wrapper::InputWrapper, idx::AVec{Int}) = wrapper.obj

_cycle(v::AVec, idx::Int) = v[mod1(idx, length(v))]
_cycle(v::AMat, idx::Int) = size(v,1) == 1 ? v[1, mod1(idx, size(v,2))] : v[:, mod1(idx, size(v,2))]
_cycle(v, idx::Int)       = v

_cycle(v::AVec, indices::AVec{Int}) = map(i -> _cycle(v,i), indices)
_cycle(v::AMat, indices::AVec{Int}) = map(i -> _cycle(v,i), indices)
_cycle(v, indices::AVec{Int})       = fill(v, length(indices))

_cycle(grad::ColorGradient, idx::Int) = _cycle(grad.colors, idx)
_cycle(grad::ColorGradient, indices::AVec{Int}) = _cycle(grad.colors, indices)

makevec(v::AVec) = v
makevec(v::T) where {T} = T[v]

"duplicate a single value, or pass the 2-tuple through"
maketuple(x::Real)                     = (x,x)
maketuple(x::Tuple{T,S}) where {T,S} = x

mapFuncOrFuncs(f::Function, u::AVec)        = map(f, u)
mapFuncOrFuncs(fs::AVec{F}, u::AVec) where {F<:Function} = [map(f, u) for f in fs]

unzip(xy::AVec{Tuple{X,Y}}) where {X,Y}              = [t[1] for t in xy], [t[2] for t in xy]
unzip(xyz::AVec{Tuple{X,Y,Z}}) where {X,Y,Z}         = [t[1] for t in xyz], [t[2] for t in xyz], [t[3] for t in xyz]
unzip(xyuv::AVec{Tuple{X,Y,U,V}}) where {X,Y,U,V}    = [t[1] for t in xyuv], [t[2] for t in xyuv], [t[3] for t in xyuv], [t[4] for t in xyuv]

unzip(xy::AVec{FixedSizeArrays.Vec{2,T}}) where {T}  = T[t[1] for t in xy], T[t[2] for t in xy]
unzip(xy::FixedSizeArrays.Vec{2,T}) where {T}        = T[xy[1]], T[xy[2]]

unzip(xyz::AVec{FixedSizeArrays.Vec{3,T}}) where {T} = T[t[1] for t in xyz], T[t[2] for t in xyz], T[t[3] for t in xyz]
unzip(xyz::FixedSizeArrays.Vec{3,T}) where {T}       = T[xyz[1]], T[xyz[2]], T[xyz[3]]

unzip(xyuv::AVec{FixedSizeArrays.Vec{4,T}}) where {T} = T[t[1] for t in xyuv], T[t[2] for t in xyuv], T[t[3] for t in xyuv], T[t[4] for t in xyuv]
unzip(xyuv::FixedSizeArrays.Vec{4,T}) where {T}       = T[xyuv[1]], T[xyuv[2]], T[xyuv[3]], T[xyuv[4]]

# given 2-element lims and a vector of data x, widen lims to account for the extrema of x
function _expand_limits(lims, x)
  try
    e1, e2 = ignorenan_extrema(x)
    lims[1] = NaNMath.min(lims[1], e1)
    lims[2] = NaNMath.max(lims[2], e2)
  # catch err
  #   warn(err)
  end
  nothing
end

expand_data(v, n::Integer) = [_cycle(v, i) for i=1:n]

# if the type exists in a list, replace the first occurence.  otherwise add it to the end
function addOrReplace(v::AbstractVector, t::DataType, args...; kw...)
    for (i,vi) in enumerate(v)
        if isa(vi, t)
            v[i] = t(args...; kw...)
            return
        end
    end
    push!(v, t(args...; kw...))
    return
end

function replaceType(vec, val)
  filter!(x -> !isa(x, typeof(val)), vec)
  push!(vec, val)
end

function replaceAlias!(d::KW, k::Symbol, aliases::Dict{Symbol,Symbol})
  if haskey(aliases, k)
    d[aliases[k]] = pop!(d, k)
  end
end

function replaceAliases!(d::KW, aliases::Dict{Symbol,Symbol})
  ks = collect(keys(d))
  for k in ks
      replaceAlias!(d, k, aliases)
  end
end

createSegments(z) = collect(repmat(reshape(z,1,:),2,1))[2:end]

Base.first(c::Colorant) = c
Base.first(x::Symbol) = x


sortedkeys(d::Dict) = sort(collect(keys(d)))


const _scale_base = Dict{Symbol, Real}(
    :log10 => 10,
    :log2 => 2,
    :ln => e,
)

"create an (n+1) list of the outsides of heatmap rectangles"
function heatmap_edges(v::AVec, scale::Symbol = :identity)
  vmin, vmax = ignorenan_extrema(v)
  extra_min = extra_max = 0.5 * (vmax-vmin) / (length(v)-1)
  if scale in _logScales
      vmin > 0 || error("The axis values must be positive for a $scale scale")
      while vmin - extra_min <= 0
          extra_min /= _scale_base[scale]
      end
  end
  vcat(vmin-extra_min, 0.5 * (v[1:end-1] + v[2:end]), vmax+extra_max)
end


function calc_r_extrema(x, y)
    xmin, xmax = ignorenan_extrema(x)
    ymin, ymax = ignorenan_extrema(y)
    r = 0.5 * NaNMath.min(xmax - xmin, ymax - ymin)
    ignorenan_extrema(r)
end

function convert_to_polar(x, y, r_extrema = calc_r_extrema(x, y))
    rmin, rmax = r_extrema
    theta, r = filter_radial_data(x, y, r_extrema)
    r = (r - rmin) / (rmax - rmin)
    x = r.*cos.(theta)
    y = r.*sin.(theta)
    x, y
end

# Filters radial data for points within the axis limits
function filter_radial_data(theta, r, r_extrema::Tuple{Real, Real})
    n = max(length(theta), length(r))
    rmin, rmax = r_extrema
    x, y = zeros(n), zeros(n)
    for i in 1:n
        x[i] = _cycle(theta, i)
        y[i] = _cycle(r, i)
    end
    points = map((a, b) -> (a, b), x, y)
    filter!(a -> a[2] >= rmin && a[2] <= rmax, points)
    x = map(a -> a[1], points)
    y = map(a -> a[2], points)
    x, y
end

function fakedata(sz...)
  y = zeros(sz...)
  for r in 2:size(y,1)
    y[r,:] = 0.95 * vec(y[r-1,:]) + randn(size(y,2))
  end
  y
end

isijulia() = isdefined(Main, :IJulia) && Main.IJulia.inited
isatom() = isdefined(Main, :Atom) && Main.Atom.isconnected()

function is_installed(pkgstr::AbstractString)
    try
        Pkg.installed(pkgstr) === nothing ? false : true
    catch
        false
    end
end

istuple(::Tuple) = true
istuple(::Any)   = false
isvector(::AVec) = true
isvector(::Any)  = false
ismatrix(::AMat) = true
ismatrix(::Any)  = false
isscalar(::Real) = true
isscalar(::Any)  = false

is_2tuple(v) = typeof(v) <: Tuple && length(v) == 2


isvertical(d::KW) = get(d, :orientation, :vertical) in (:vertical, :v, :vert)
isvertical(series::Series) = isvertical(series.d)


ticksType(ticks::AVec{T}) where {T<:Real}                      = :ticks
ticksType(ticks::AVec{T}) where {T<:AbstractString}            = :labels
ticksType(ticks::Tuple{T,S}) where {T<:AVec,S<:AVec}  = :ticks_and_labels
ticksType(ticks)                                        = :invalid

limsType(lims::Tuple{T,S}) where {T<:Real,S<:Real}    = :limits
limsType(lims::Symbol)                                  = lims == :auto ? :auto : :invalid
limsType(lims)                                          = :invalid

# axis_Symbol(letter, postfix) = Symbol(letter * postfix)
# axis_symbols(letter, postfix...) = map(s -> axis_Symbol(letter, s), postfix)

Base.convert(::Type{Vector{T}}, rng::Range{T}) where {T<:Real}         = T[x for x in rng]
Base.convert(::Type{Vector{T}}, rng::Range{S}) where {T<:Real,S<:Real} = T[x for x in rng]

Base.merge(a::AbstractVector, b::AbstractVector) = sort(unique(vcat(a,b)))

nanpush!(a::AbstractVector, b) = (push!(a, NaN); push!(a, b))
nanappend!(a::AbstractVector, b) = (push!(a, NaN); append!(a, b))

function nansplit(v::AVec)
    vs = Vector{eltype(v)}[]
    while true
        idx = findfirst(isnan, v)
        if idx <= 0
            # no nans
            push!(vs, v)
            break
        elseif idx > 1
            push!(vs, v[1:idx-1])
        end
        v = v[idx+1:end]
    end
    vs
end

function nanvcat(vs::AVec)
    v_out = zeros(0)
    for v in vs
        nanappend!(v_out, v)
    end
    v_out
end

# given an array of discrete values, turn it into an array of indices of the unique values
# returns the array of indices (znew) and a vector of unique values (vals)
function indices_and_unique_values(z::AbstractArray)
    vals = sort(unique(z))
    vmap = Dict([(v,i) for (i,v) in enumerate(vals)])
    newz = map(zi -> vmap[zi], z)
    newz, vals
end

# this is a helper function to determine whether we need to transpose a surface matrix.
# it depends on whether the backend matches rows to x (transpose_on_match == true) or vice versa
# for example: PyPlot sends rows to y, so transpose_on_match should be true
function transpose_z(d, z, transpose_on_match::Bool = true)
    if d[:match_dimensions] == transpose_on_match
        # z'
        permutedims(z, [2,1])
    else
        z
    end
end

function ok(x::Number, y::Number, z::Number = 0)
    isfinite(x) && isfinite(y) && isfinite(z)
end
ok(tup::Tuple) = ok(tup...)

# compute one side of a fill range from a ribbon
function make_fillrange_side(y, rib)
    frs = zeros(length(y))
    for (i, (yi, ri)) in enumerate(zip(y, Base.Iterators.cycle(rib)))
        frs[i] = yi + ri
    end
    frs
end

# turn a ribbon into a fillrange
function make_fillrange_from_ribbon(kw::KW)
    y, rib = kw[:y], kw[:ribbon]
    rib = wraptuple(rib)
    rib1, rib2 = -first(rib), last(rib)
    # kw[:ribbon] = nothing
    kw[:fillrange] = make_fillrange_side(y, rib1), make_fillrange_side(y, rib2)
    (get(kw, :fillalpha, nothing) == nothing) && (kw[:fillalpha] = 0.5)
end

#turn tuple of fillranges to one path
function concatenate_fillrange(x,y::Tuple)
    rib1, rib2 = first(y), last(y)
    yline = vcat(rib1,(rib2)[end:-1:1])
    xline = vcat(x,x[end:-1:1])
    return xline, yline
end

function get_sp_lims(sp::Subplot, letter::Symbol)
    axis_limits(sp[Symbol(letter, :axis)])
end

"""
    xlims([plt])

Returns the x axis limits of the current plot or subplot
"""
xlims(sp::Subplot) = get_sp_lims(sp, :x)

"""
    ylims([plt])

Returns the y axis limits of the current plot or subplot
"""
ylims(sp::Subplot) = get_sp_lims(sp, :y)

"""
    zlims([plt])

Returns the z axis limits of the current plot or subplot
"""
zlims(sp::Subplot) = get_sp_lims(sp, :z)

xlims(plt::Plot, sp_idx::Int = 1) = xlims(plt[sp_idx])
ylims(plt::Plot, sp_idx::Int = 1) = ylims(plt[sp_idx])
zlims(plt::Plot, sp_idx::Int = 1) = zlims(plt[sp_idx])
xlims(sp_idx::Int = 1) = xlims(current(), sp_idx)
ylims(sp_idx::Int = 1) = ylims(current(), sp_idx)
zlims(sp_idx::Int = 1) = zlims(current(), sp_idx)


function get_clims(sp::Subplot)
    zmin, zmax = Inf, -Inf
    z_colored_series = (:contour, :contour3d, :heatmap, :histogram2d, :surface)
    for series in series_list(sp)
        for vals in (series[:seriestype] in z_colored_series ? series[:z] : nothing, series[:line_z], series[:marker_z], series[:fill_z])
            if (typeof(vals) <: AbstractSurface) && (eltype(vals.surf) <: Real)
                zmin, zmax = _update_clims(zmin, zmax, ignorenan_extrema(vals.surf)...)
            elseif (vals != nothing) && (eltype(vals) <: Real)
                zmin, zmax = _update_clims(zmin, zmax, ignorenan_extrema(vals)...)
            end
        end
    end
    clims = sp[:clims]
    if is_2tuple(clims)
        isfinite(clims[1]) && (zmin = clims[1])
        isfinite(clims[2]) && (zmax = clims[2])
    end
    return zmin < zmax ? (zmin, zmax) : (-0.1, 0.1)
end

_update_clims(zmin, zmax, emin, emax) = min(zmin, emin), max(zmax, emax)

function hascolorbar(series::Series)
    st = series[:seriestype]
    hascbar = st == :heatmap
    if st == :contour
        hascbar = (isscalar(series[:levels]) ? (series[:levels] > 1) : (length(series[:levels]) > 1)) && (length(unique(Array(series[:z]))) > 1)
    end
    if series[:marker_z] != nothing || series[:line_z] != nothing || series[:fill_z] != nothing
        hascbar = true
    end
    # no colorbar if we are creating a surface LightSource
    if xor(st == :surface, series[:fill_z] != nothing)
        hascbar = true
    end
    return hascbar
end

function hascolorbar(sp::Subplot)
    cbar = sp[:colorbar]
    hascbar = false
    if cbar != :none
        for series in series_list(sp)
            if hascolorbar(series)
                hascbar = true
            end
        end
    end
    hascbar
end

function get_linecolor(series, i::Int = 1)
    lc = series[:linecolor]
    lz = series[:line_z]
    if lz == nothing
        isa(lc, ColorGradient) ? lc : plot_color(_cycle(lc, i))
    else
        cmin, cmax = get_clims(series[:subplot])
        grad = isa(lc, ColorGradient) ? lc : cgrad()
        grad[clamp((_cycle(lz, i) - cmin) / (cmax - cmin), 0, 1)]
    end
end

function get_linealpha(series, i::Int = 1)
    _cycle(series[:linealpha], i)
end

function get_linewidth(series, i::Int = 1)
    _cycle(series[:linewidth], i)
end

function get_linestyle(series, i::Int = 1)
    _cycle(series[:linestyle], i)
end

function get_fillcolor(series, i::Int = 1)
    fc = series[:fillcolor]
    fz = series[:fill_z]
    if fz == nothing
        isa(fc, ColorGradient) ? fc : plot_color(_cycle(fc, i))
    else
        cmin, cmax = get_clims(series[:subplot])
        grad = isa(fc, ColorGradient) ? fc : cgrad()
        grad[clamp((_cycle(fz, i) - cmin) / (cmax - cmin), 0, 1)]
    end
end

function get_fillalpha(series, i::Int = 1)
    _cycle(series[:fillalpha], i)
end

function get_markercolor(series, i::Int = 1)
    mc = series[:markercolor]
    mz = series[:marker_z]
    if mz == nothing
        isa(mc, ColorGradient) ? mc : plot_color(_cycle(mc, i))
    else
        cmin, cmax = get_clims(series[:subplot])
        grad = isa(mc, ColorGradient) ? mc : cgrad()
        grad[clamp((_cycle(mz, i) - cmin) / (cmax - cmin), 0, 1)]
    end
end

function get_markeralpha(series, i::Int = 1)
    _cycle(series[:markeralpha], i)
end

function get_markerstrokecolor(series, i::Int = 1)
    msc = series[:markerstrokecolor]
    isa(msc, ColorGradient) ? msc : _cycle(msc, i)
end

function get_markerstrokealpha(series, i::Int = 1)
    _cycle(series[:markerstrokealpha], i)
end

function has_attribute_segments(series::Series)
    # we want to check if a series needs to be split into segments just because
    # of its attributes
    for letter in (:x, :y, :z)
        # If we have NaNs in the data they define the segments and
        # SegmentsIterator is used
        series[letter] != nothing && NaN in collect(series[letter]) && return false
    end
    series[:seriestype] == :shape && return false
    # ... else we check relevant attributes if they have multiple inputs
    return any((typeof(series[attr]) <: AbstractVector && length(series[attr]) > 1) for attr in [:seriescolor, :seriesalpha, :linecolor, :linealpha, :linewidth, :fillcolor, :fillalpha, :markercolor, :markeralpha, :markerstrokecolor, :markerstrokealpha]) || any(typeof(series[attr]) <: AbstractArray{<:Real} for attr in (:line_z, :fill_z, :marker_z))
end

# ---------------------------------------------------------------

makekw(; kw...) = KW(kw)

wraptuple(x::Tuple) = x
wraptuple(x) = (x,)

trueOrAllTrue(f::Function, x::AbstractArray) = all(f, x)
trueOrAllTrue(f::Function, x) = f(x)

allLineTypes(arg)   = trueOrAllTrue(a -> get(_typeAliases, a, a) in _allTypes, arg)
allStyles(arg)      = trueOrAllTrue(a -> get(_styleAliases, a, a) in _allStyles, arg)
allShapes(arg)      = trueOrAllTrue(a -> is_marker_supported(get(_markerAliases, a, a)), arg) ||
                        trueOrAllTrue(a -> isa(a, Shape), arg)
allAlphas(arg)      = trueOrAllTrue(a -> (typeof(a) <: Real && a > 0 && a < 1) ||
                        (typeof(a) <: AbstractFloat && (a == zero(typeof(a)) || a == one(typeof(a)))), arg)
allReals(arg)       = trueOrAllTrue(a -> typeof(a) <: Real, arg)
allFunctions(arg)   = trueOrAllTrue(a -> isa(a, Function), arg)

# ---------------------------------------------------------------
# ---------------------------------------------------------------


"""
Allows temporary setting of backend and defaults for Plots. Settings apply only for the `do` block.  Example:
```
with(:gr, size=(400,400), type=:histogram) do
  plot(rand(10))
  plot(rand(10))
end
```
"""
function with(f::Function, args...; kw...)
    newdefs = KW(kw)

    if :canvas in args
        newdefs[:xticks] = nothing
        newdefs[:yticks] = nothing
        newdefs[:grid] = false
        newdefs[:legend] = false
    end

  # dict to store old and new keyword args for anything that changes
  olddefs = KW()
  for k in keys(newdefs)
    olddefs[k] = default(k)
  end

  # save the backend
  if CURRENT_BACKEND.sym == :none
    pickDefaultBackend()
  end
  oldbackend = CURRENT_BACKEND.sym

  for arg in args

    # change backend?
    if arg in backends()
      backend(arg)
    end

    # # TODO: generalize this strategy to allow args as much as possible
    # #       as in:  with(:gadfly, :scatter, :legend, :grid) do; ...; end
    # # TODO: can we generalize this enough to also do something similar in the plot commands??

    # k = :seriestype
    # if arg in _allTypes
    #   olddefs[k] = default(k)
    #   newdefs[k] = arg
    # elseif haskey(_typeAliases, arg)
    #   olddefs[k] = default(k)
    #   newdefs[k] = _typeAliases[arg]
    # end

    k = :legend
    if arg in (k, :leg)
      olddefs[k] = default(k)
      newdefs[k] = true
    end

    k = :grid
    if arg == k
      olddefs[k] = default(k)
      newdefs[k] = true
    end
  end

  # display(olddefs)
  # display(newdefs)

  # now set all those defaults
  default(; newdefs...)

  # call the function
  ret = f()

  # put the defaults back
  default(; olddefs...)

  # revert the backend
  if CURRENT_BACKEND.sym != oldbackend
    backend(oldbackend)
  end

  # return the result of the function
  ret
end

# ---------------------------------------------------------------
# ---------------------------------------------------------------

mutable struct DebugMode
  on::Bool
end
const _debugMode = DebugMode(false)

function debugplots(on = true)
  _debugMode.on = on
end

debugshow(x) = show(x)
debugshow(x::AbstractArray) = print(summary(x))

function dumpdict(d::KW, prefix = "", alwaysshow = false)
  _debugMode.on || alwaysshow || return
  println()
  if prefix != ""
    println(prefix, ":")
  end
  for k in sort(collect(keys(d)))
    @printf("%14s: ", k)
    debugshow(d[k])
    println()
  end
  println()
end
DD(d::KW, prefix = "") = dumpdict(d, prefix, true)


function dumpcallstack()
  error()  # well... you wanted the stacktrace, didn't you?!?
end

# ---------------------------------------------------------------
# ---------------------------------------------------------------
# used in updating an existing series

extendSeriesByOne(v::UnitRange{Int}, n::Int = 1) = isempty(v) ? (1:n) : (minimum(v):maximum(v)+n)
extendSeriesByOne(v::AVec, n::Integer = 1)       = isempty(v) ? (1:n) : vcat(v, (1:n) + ignorenan_maximum(v))
extendSeriesData(v::Range{T}, z::Real) where {T}        = extendSeriesData(float(collect(v)), z)
extendSeriesData(v::Range{T}, z::AVec) where {T}        = extendSeriesData(float(collect(v)), z)
extendSeriesData(v::AVec{T}, z::Real) where {T}         = (push!(v, convert(T, z)); v)
extendSeriesData(v::AVec{T}, z::AVec) where {T}         = (append!(v, convert(Vector{T}, z)); v)


# -------------------------------------------------------
# NOTE: backends should implement the following methods to get/set the x/y/z data objects

tovec(v::AbstractVector) = v
tovec(v::Void) = zeros(0)

function getxy(plt::Plot, i::Integer)
    d = plt.series_list[i].d
    tovec(d[:x]), tovec(d[:y])
end
function getxyz(plt::Plot, i::Integer)
    d = plt.series_list[i].d
    tovec(d[:x]), tovec(d[:y]), tovec(d[:z])
end

function setxy!(plt::Plot, xy::Tuple{X,Y}, i::Integer) where {X,Y}
    series = plt.series_list[i]
    series.d[:x], series.d[:y] = xy
    sp = series.d[:subplot]
    reset_extrema!(sp)
    _series_updated(plt, series)
end
function setxyz!(plt::Plot, xyz::Tuple{X,Y,Z}, i::Integer) where {X,Y,Z}
    series = plt.series_list[i]
    series.d[:x], series.d[:y], series.d[:z] = xyz
    sp = series.d[:subplot]
    reset_extrema!(sp)
    _series_updated(plt, series)
end

function setxyz!(plt::Plot, xyz::Tuple{X,Y,Z}, i::Integer) where {X,Y,Z<:AbstractMatrix}
    setxyz!(plt, (xyz[1], xyz[2], Surface(xyz[3])), i)
end


# -------------------------------------------------------
# indexing notation

# Base.getindex(plt::Plot, i::Integer) = getxy(plt, i)
Base.setindex!(plt::Plot, xy::Tuple{X,Y}, i::Integer) where {X,Y} = (setxy!(plt, xy, i); plt)
Base.setindex!(plt::Plot, xyz::Tuple{X,Y,Z}, i::Integer) where {X,Y,Z} = (setxyz!(plt, xyz, i); plt)

# -------------------------------------------------------

# operate on individual series

function push_x!(series::Series, xi)
    push!(series[:x], xi)
    expand_extrema!(series[:subplot][:xaxis], xi)
    return
end
function push_y!(series::Series, yi)
    push!(series[:y], yi)
    expand_extrema!(series[:subplot][:yaxis], yi)
    return
end
function push_z!(series::Series, zi)
    push!(series[:z], zi)
    expand_extrema!(series[:subplot][:zaxis], zi)
    return
end

function Base.push!(series::Series, yi)
    x = extendSeriesByOne(series[:x])
    expand_extrema!(series[:subplot][:xaxis], x[end])
    series[:x] = x
    push_y!(series, yi)
end
Base.push!(series::Series, xi, yi) = (push_x!(series,xi); push_y!(series,yi))
Base.push!(series::Series, xi, yi, zi) = (push_x!(series,xi); push_y!(series,yi); push_z!(series,zi))

# -------------------------------------------------------

function attr!(series::Series; kw...)
    d = KW(kw)
    preprocessArgs!(d)
    for (k,v) in d
        if haskey(_series_defaults, k)
            series[k] = v
        else
            warn("unused key $k in series attr")
        end
    end
    _series_updated(series[:subplot].plt, series)
    series
end

function attr!(sp::Subplot; kw...)
    d = KW(kw)
    preprocessArgs!(d)
    for (k,v) in d
        if haskey(_subplot_defaults, k)
            sp[k] = v
        else
            warn("unused key $k in subplot attr")
        end
    end
    sp
end

# -------------------------------------------------------
# push/append for one series

# push value to first series
Base.push!(plt::Plot, y::Real) = push!(plt, 1, y)
Base.push!(plt::Plot, x::Real, y::Real) = push!(plt, 1, x, y)
Base.push!(plt::Plot, x::Real, y::Real, z::Real) = push!(plt, 1, x, y, z)

# y only
function Base.push!(plt::Plot, i::Integer, y::Real)
    xdata, ydata = getxy(plt, i)
    setxy!(plt, (extendSeriesByOne(xdata), extendSeriesData(ydata, y)), i)
    plt
end
function Base.append!(plt::Plot, i::Integer, y::AVec)
    xdata, ydata = plt[i]
    if !isa(xdata, UnitRange{Int})
        error("Expected x is a UnitRange since you're trying to push a y value only")
    end
    plt[i] = (extendSeriesByOne(xdata, length(y)), extendSeriesData(ydata, y))
    plt
end

# x and y
function Base.push!(plt::Plot, i::Integer, x::Real, y::Real)
    xdata, ydata = getxy(plt, i)
    setxy!(plt, (extendSeriesData(xdata, x), extendSeriesData(ydata, y)), i)
    plt
end
function Base.append!(plt::Plot, i::Integer, x::AVec, y::AVec)
    @assert length(x) == length(y)
    xdata, ydata = getxy(plt, i)
    setxy!(plt, (extendSeriesData(xdata, x), extendSeriesData(ydata, y)), i)
    plt
end

# x, y, and z
function Base.push!(plt::Plot, i::Integer, x::Real, y::Real, z::Real)
    # @show i, x, y, z
    xdata, ydata, zdata = getxyz(plt, i)
    # @show xdata, ydata, zdata
    setxyz!(plt, (extendSeriesData(xdata, x), extendSeriesData(ydata, y), extendSeriesData(zdata, z)), i)
    plt
end
function Base.append!(plt::Plot, i::Integer, x::AVec, y::AVec, z::AVec)
    @assert length(x) == length(y) == length(z)
    xdata, ydata, zdata = getxyz(plt, i)
    setxyz!(plt, (extendSeriesData(xdata, x), extendSeriesData(ydata, y), extendSeriesData(zdata, z)), i)
    plt
end

# tuples
Base.push!(plt::Plot, xy::Tuple{X,Y}) where {X,Y}                  = push!(plt, 1, xy...)
Base.push!(plt::Plot, xyz::Tuple{X,Y,Z}) where {X,Y,Z}             = push!(plt, 1, xyz...)
Base.push!(plt::Plot, i::Integer, xy::Tuple{X,Y}) where {X,Y}      = push!(plt, i, xy...)
Base.push!(plt::Plot, i::Integer, xyz::Tuple{X,Y,Z}) where {X,Y,Z} = push!(plt, i, xyz...)

# -------------------------------------------------------
# push/append for all series

# push y[i] to the ith series
function Base.push!(plt::Plot, y::AVec)
    ny = length(y)
    for i in 1:plt.n
        push!(plt, i, y[mod1(i,ny)])
    end
    plt
end

# push y[i] to the ith series
# same x for each series
function Base.push!(plt::Plot, x::Real, y::AVec)
    push!(plt, [x], y)
end

# push (x[i], y[i]) to the ith series
function Base.push!(plt::Plot, x::AVec, y::AVec)
    nx = length(x)
    ny = length(y)
    for i in 1:plt.n
        push!(plt, i, x[mod1(i,nx)], y[mod1(i,ny)])
    end
    plt
end

# push (x[i], y[i], z[i]) to the ith series
function Base.push!(plt::Plot, x::AVec, y::AVec, z::AVec)
    nx = length(x)
    ny = length(y)
    nz = length(z)
    for i in 1:plt.n
        push!(plt, i, x[mod1(i,nx)], y[mod1(i,ny)], z[mod1(i,nz)])
    end
    plt
end




# ---------------------------------------------------------------


# Some conversion functions
# note: I borrowed these conversion constants from Compose.jl's Measure

const PX_PER_INCH   = 100
const DPI           = PX_PER_INCH
const MM_PER_INCH   = 25.4
const MM_PER_PX     = MM_PER_INCH / PX_PER_INCH

inch2px(inches::Real)   = float(inches * PX_PER_INCH)
px2inch(px::Real)       = float(px / PX_PER_INCH)
inch2mm(inches::Real)   = float(inches * MM_PER_INCH)
mm2inch(mm::Real)       = float(mm / MM_PER_INCH)
px2mm(px::Real)         = float(px * MM_PER_PX)
mm2px(mm::Real)         = float(px / MM_PER_PX)


"Smallest x in plot"
xmin(plt::Plot) = ignorenan_minimum([ignorenan_minimum(series.d[:x]) for series in plt.series_list])
"Largest x in plot"
xmax(plt::Plot) = ignorenan_maximum([ignorenan_maximum(series.d[:x]) for series in plt.series_list])

"Extrema of x-values in plot"
ignorenan_extrema(plt::Plot) = (xmin(plt), xmax(plt))


# ---------------------------------------------------------------
# get fonts from objects:

titlefont(sp::Subplot) = font(
    sp[:titlefontfamily],
    sp[:titlefontsize],
    sp[:titlefontvalign],
    sp[:titlefonthalign],
    sp[:titlefontrotation],
    sp[:titlefontcolor],
)

legendfont(sp::Subplot) = font(
    sp[:legendfontfamily],
    sp[:legendfontsize],
    sp[:legendfontvalign],
    sp[:legendfonthalign],
    sp[:legendfontrotation],
    sp[:legendfontcolor],
)

tickfont(ax::Axis) = font(
    ax[:tickfontfamily],
    ax[:tickfontsize],
    ax[:tickfontvalign],
    ax[:tickfonthalign],
    ax[:tickfontrotation],
    ax[:tickfontcolor],
)

guidefont(ax::Axis) = font(
    ax[:guidefontfamily],
    ax[:guidefontsize],
    ax[:guidefontvalign],
    ax[:guidefonthalign],
    ax[:guidefontrotation],
    ax[:guidefontcolor],
)

# ---------------------------------------------------------------
# converts unicode scientific notation unsupported by pgfplots and gr
# into a format that works

function convert_sci_unicode(label::AbstractString)
    unicode_dict = Dict(
    '⁰' => "0",
    '¹' => "1",
    '²' => "2",
    '³' => "3",
    '⁴' => "4",
    '⁵' => "5",
    '⁶' => "6",
    '⁷' => "7",
    '⁸' => "8",
    '⁹' => "9",
    '⁻' => "-",
    "×10" => "×10^{",
    )
    for key in keys(unicode_dict)
        label = replace(label, key, unicode_dict[key])
    end
    if contains(label, "10^{")
        label = string(label, "}")
    end
    label
end

function straightline_data(series)
    sp = series[:subplot]
    xl, yl = isvertical(series) ? (xlims(sp), ylims(sp)) : (ylims(sp), xlims(sp))
    x, y = series[:x], series[:y]
    n = length(x)
    if n == 2
        return straightline_data(xl, yl, x, y)
    else
        k, r = divrem(n, 3)
        if r == 0
            xdata, ydata = fill(NaN, n), fill(NaN, n)
            for i in 1:k
                inds = (3 * i - 2):(3 * i - 1)
                xdata[inds], ydata[inds] = straightline_data(xl, yl, x[inds], y[inds])
            end
            return xdata, ydata
        else
            error("Misformed data. `straightline_data` either accepts vectors of length 2 or 3k. The provided series has length $n")
        end
    end
end

function straightline_data(xl, yl, x, y)
    x_vals, y_vals = if y[1] == y[2]
        if x[1] == x[2]
            error("Two identical points cannot be used to describe a straight line.")
        else
            [xl[1], xl[2]], [y[1], y[2]]
        end
    elseif x[1] == x[2]
        [x[1], x[2]], [yl[1], yl[2]]
    else
        # get a and b from the line y = a * x + b through the points given by
        # the coordinates x and x
        b = y[1] - (y[1] - y[2]) * x[1] / (x[1] - x[2])
        a = (y[1] - y[2]) / (x[1] - x[2])
        # get the data values
        xdata = [clamp(x[1] + (x[1] - x[2]) * (ylim - y[1]) / (y[1] - y[2]), xl...) for ylim in yl]

        xdata, a .* xdata .+ b
    end
    # expand the data outside the axis limits, by a certain factor too improve
    # plotly(js) and interactive behaviour
    factor = 100
    x_vals = x_vals .+ (x_vals[2] - x_vals[1]) .* factor .* [-1, 1]
    y_vals = y_vals .+ (y_vals[2] - y_vals[1]) .* factor .* [-1, 1]
    return x_vals, y_vals
end

function shape_data(series)
    sp = series[:subplot]
    xl, yl = isvertical(series) ? (xlims(sp), ylims(sp)) : (ylims(sp), xlims(sp))
    x, y = series[:x], series[:y]
    factor = 100
    for i in eachindex(x)
        if x[i] == -Inf
            x[i] = xl[1] - factor * (xl[2] - xl[1])
        elseif x[i] == Inf
            x[i] = xl[2] + factor * (xl[2] - xl[1])
        end
    end
    for i in eachindex(y)
        if y[i] == -Inf
            y[i] = yl[1] - factor * (yl[2] - yl[1])
        elseif y[i] == Inf
            y[i] = yl[2] + factor * (yl[2] - yl[1])
        end
    end
    return x, y
end

function construct_categorical_data(x::AbstractArray, axis::Axis)
    map(xi -> axis[:discrete_values][searchsortedfirst(axis[:continuous_values], xi)], x)
end
