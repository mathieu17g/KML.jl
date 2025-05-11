module TablesBridge
using Tables
import ..KML: KMLFile, read, Feature, Document, Folder, Placemark, Geometry, object
import XML: parse, Node
using Base.Iterators: flatten

#────────────────────────────── helpers lifted from your old code ──────────────────────────────#
function _top_level_features(file::KMLFile)::Vector{Feature}
    feats = Feature[c for c in file.children if c isa Feature]
    if isempty(feats)
        for c in file.children
            if (c isa Document || c isa Folder) && c.Features !== nothing
                append!(feats, c.Features)
            end
        end
    end
    feats
end

function _determine_layers(features::Vector{Feature})
    if length(features) == 1
        f = features[1]
        if f isa Document || f isa Folder
            sub = (f.Features !== nothing ? f.Features : Feature[])
            return [x for x in sub if x isa Document || x isa Folder], Placemark[x for x in sub if x isa Placemark], f
        else
            return Feature[], (f isa Placemark ? [f] : Placemark[]), nothing
        end
    else
        return [x for x in features if x isa Document || x isa Folder],
        Placemark[x for x in features if x isa Placemark],
        nothing
    end
end

function _select_layer(cont::Vector{Feature}, direct::Vector{Placemark}, parent, layer::Union{Nothing,String})
    if layer !== nothing
        for c in cont
            if c.name === layer
                return c
            end
        end
        if isempty(cont) && parent !== nothing && parent.name === layer
            return parent
        end
        error("Layer \"$layer\" not found")
    end

    opts, cand = String[], Any[]
    for c in cont
        push!(opts, c.name !== nothing ? c.name : "<Unnamed>")
        push!(cand, c)
    end
    if !isempty(direct)
        push!(opts, "<Ungrouped Placemarks>")
        push!(cand, direct)
    end

    if length(cand) ≤ 1
        return isempty(cand) ? nothing : cand[1]
    end

    interactive = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()
    if interactive
        idx = request("Select a layer:", RadioMenu(opts; pagesize = min(10, length(opts))))
        idx == -1 && error("Selection cancelled")
        cand[idx]
    else
        @warn "Multiple layers - picking first ($(opts[1])) automatically"
        cand[1]
    end
end

#────────────────────────── streaming iterator over placemarks ──────────────────────────#
function _placemark_iterator(file::KMLFile, layer)
    feats = _top_level_features(file)
    cont, direct, parent = _determine_layers(feats)
    sel = _select_layer(cont, direct, parent, layer)
    return _iter_feat(sel) # Remove flatten()
end

function _iter_feat(x)
    if x isa Placemark
        return (x for _ = 1:1)
    elseif (x isa Document || x isa Folder) && x.Features !== nothing
        return flatten(_iter_feat.(x.Features))
    elseif x isa AbstractVector{<:Feature} # Or more specifically AbstractVector{<:Placemark}
        # If x is a vector of features (e.g., Placemarks),
        # iterate over each feature and recursively call _iter_feat.
        # This ensures that if it's a vector of Placemarks, each Placemark
        # is properly processed by the 'x isa Placemark' case.
        return flatten(_iter_feat.(x))
    else
        return () # Fallback for any other type or empty collections
    end
end

#──────────────────────────── streaming PlacemarkTable type ────────────────────────────#
"""
    PlacemarkTable(source; layer=nothing)

A lazy, streaming Tables.jl table of the placemarks in a KML file.
You can call it either with a path or with an already‐loaded `KMLFile`.
"""
struct PlacemarkTable
    file::KMLFile
    layer::Union{Nothing,String}
end

# two constructors:
PlacemarkTable(path::AbstractString; layer = nothing) = PlacemarkTable(read(path, KMLFile), layer)
PlacemarkTable(file::KMLFile; layer = nothing) = PlacemarkTable(file, layer)

#──────────────────────────────── Tables.jl API ──────────────────────────────────#
Tables.istable(::Type{PlacemarkTable}) = true
Tables.rowaccess(::Type{PlacemarkTable}) = true

Tables.schema(::PlacemarkTable) = Tables.Schema((:name, :description, :geometry), (String, String, Geometry))

function Tables.rows(tbl::PlacemarkTable)
    it = _placemark_iterator(tbl.file, tbl.layer)
    return (
        let pl = pl
            (
                name = pl.name === nothing ? "" : pl.name,
                description = pl.description === nothing ? "" : pl.description,
                geometry = pl.Geometry,
            )
        end for pl in it
    )
end

Tables.istable(::Type{KMLFile}) = true
Tables.rowaccess(::Type{KMLFile}) = true

function Tables.schema(k::KMLFile)
    # use the same 3-column schema as for PlacemarkTable
    return Tables.schema(PlacemarkTable(k))
end

function Tables.rows(k::KMLFile)
    # delegate row iteration to the PlacemarkTable constructor
    return Tables.rows(PlacemarkTable(k))
end

end # module TablesBridge
