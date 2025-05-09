module TablesInterface

import Tables
import REPL.TerminalMenus: RadioMenu, request
using ..KML: KMLFile, Feature, Document, Folder, Placemark
using ..KML: Geometry, Point, LineString, LinearRing, Polygon, MultiGeometry

# Table type representing a collection of Placemark rows
struct PlacemarkTable
    placemarks::Vector{Placemark}
end

# Constructor: build a PlacemarkTable from a KML file, optionally filtering by layer name
function PlacemarkTable(file::KMLFile; layer::Union{Nothing,String} = nothing)
    features = _top_level_features(file)
    containers, direct_pls, parent = _determine_layers(features)
    selected = _select_layer(containers, direct_pls, parent, layer)

    # -- build the candidate list ------------------------------------------
    local placemarks::Vector{Placemark}
    if selected === nothing
        placemarks = Placemark[]                   # no layers selected
    elseif selected isa Vector{Placemark}
        placemarks = selected                      # already plain placemarks
    else
        placemarks = collect_placemarks(selected)  # recurse into chosen container
    end

    # -- drop entries that have no geometry --------------------------------
    placemarks = filter(pl -> pl.Geometry !== nothing, placemarks)

    return PlacemarkTable(placemarks)
end

# Helper: get all top‑level Feature elements from a KML file
function _top_level_features(file::KMLFile)::Vector{Feature}
    # 1. direct children that *are* Feature objects
    feats = Feature[c for c in file.children if c isa Feature]

    # 2. if none found, recurse one level into the first container
    if isempty(feats)
        for c in file.children
            if (c isa Document || c isa Folder) && c.Features !== nothing
                append!(feats, c.Features)
            end
        end
    end
    return feats
end

# Helper: Determine layer groupings from top-level features.
# Returns a tuple (containers, direct_pls, parent_container):
#  - containers: Vector of Document/Folder that can act as sub-layers
#  - direct_pls: Vector of Placemark at this level not inside a container
#  - parent_container: if there's exactly one top-level Document/Folder, this is it (for naming context)
function _determine_layers(features::Vector{Feature})
    if length(features) == 1
        f = features[1]
        if f isa Document || f isa Folder
            # Single top-level container; check its children for sub-containers
            subfeatures = (hasproperty(f, :Features) && f.Features !== nothing) ? f.Features : Feature[]
            containers = [x for x in subfeatures if x isa Document || x isa Folder]
            direct_pls = Placemark[x for x in subfeatures if x isa Placemark]
            return containers, direct_pls, f
        else
            # Single top-level Placemark or other feature (no containers)
            return Feature[], (f isa Placemark ? [f] : Placemark[]), nothing
        end
    else
        # Multiple top-level features; some may be containers, some placemarks
        containers = [x for x in features if x isa Document || x isa Folder]
        direct_pls = Placemark[x for x in features if x isa Placemark]
        return containers, direct_pls, nothing
    end
end

# Helper: Select a specific layer (Document/Folder or group of placemarks) given potential containers and direct placemarks.
# If `layer` is provided (by name), selects that; otherwise uses TerminalMenus for disambiguation if multiple options exist.
function _select_layer(
    containers::Vector{Feature},
    direct_pls::Vector{Placemark},
    parent::Union{Document,Folder,Nothing},
    layer::Union{Nothing,String},
)
    # If a layer name is explicitly given, try to find a matching container by name
    if layer !== nothing
        for c in containers
            if c.name !== nothing && c.name == layer
                return c
            end
        end
        # If there are no sub-containers and the single parent has the matching name, select the parent (for its direct placemarks)
        if isempty(containers) && parent !== nothing && parent.name !== nothing && parent.name == layer
            return parent
        end
        error("Layer \"$layer\" not found in KML file")
    end

    # No layer specified: if multiple possible layers, prompt user to choose
    options = String[]
    candidates = Any[]
    for c in containers
        # Use container's name if available, otherwise a placeholder
        name = c.name !== nothing ? c.name : (c isa Document ? "<Unnamed Document>" : "<Unnamed Folder>")
        push!(options, name)
        push!(candidates, c)
    end
    if !isempty(direct_pls)
        # Add an option for placemarks not inside any container (un-grouped placemarks)
        if parent !== nothing && parent.name !== nothing
            push!(options, parent.name * " (unfoldered placemarks)")
        else
            push!(options, "<Ungrouped Placemarks>")
        end
        push!(candidates, direct_pls)
    end

    # ────────────────── choose the layer ────────────────────────────
    # If there is zero or exactly one candidate, we can return immediately.
    if length(options) <= 1
        return isempty(candidates) ? nothing : candidates[1]
    end

    # More than one layer → decide whether we can ask the user interactively.
    #
    # We treat the session as “interactive” if *both* stdin and stdout are
    # real terminals (TTYs).  That excludes VS Code notebooks, Jupyter, 
    # batch scripts, etc., where TerminalMenus would just hang.
    _is_interactive() = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()

    if _is_interactive()
        menu = RadioMenu(options; pagesize = min(length(options), 10))
        idx = request("Select a layer to use:", menu)
        idx == -1 && error("Layer selection cancelled by user.")
        return candidates[idx]
    else
        # Non‑interactive context (e.g. DataFrame(...) in a script or notebook):
        # pick the first container automatically and warn the user so they know
        # how to override.
        @warn "Multiple layers detected in KML; selecting layer \"$(options[1])\" automatically. " *
              "Pass keyword `layer=\"$(options[1])\"` (or another layer name) to choose a different one."
        return candidates[1]
    end
end

# Helper: Recursively collect all Placemark objects under a given Feature (Document/Folder).
function collect_placemarks(feat::Feature)::Vector{Placemark}
    if feat isa Placemark
        return [feat]
    elseif feat isa Document || feat isa Folder
        # Traverse into containers
        local result = Placemark[]
        local subfeatures = (hasproperty(feat, :Features) && feat.Features !== nothing) ? feat.Features : Feature[]
        for sub in subfeatures
            append!(result, collect_placemarks(sub))
        end
        return result
    else
        # Other feature types (GroundOverlay, NetworkLink, etc.) contain no placemarks
        return Placemark[]
    end
end

# TODO: could be deleted if we don't need to flatten geometries
# Flatten a Geometry into a vector of coordinate tuples (each tuple is (lon, lat) or (lon, lat, alt))
function flatten_geometry(geom::Geometry)::Vector{Tuple}
    if geom isa Point
        # Point: single coordinate tuple
        return [geom.coordinates]
    elseif geom isa LineString || geom isa LinearRing
        # LineString/LinearRing: sequence of coordinate tuples
        return collect(geom.coordinates)
    elseif geom isa Polygon
        # Polygon: flatten outer ring + all inner rings
        coords = Tuple[]                       # collect tuples here

        # --- outer ring ----------------------------------------------------
        if geom.outerBoundaryIs !== nothing
            append!(coords, flatten_geometry(geom.outerBoundaryIs))
        end

        # --- inner rings ---------------------------------------------------
        if geom.innerBoundaryIs !== nothing
            for ring in geom.innerBoundaryIs
                append!(coords, flatten_geometry(ring))
            end
        end
        return coords
    elseif geom isa MultiGeometry
        # MultiGeometry: concatenate coordinates from all sub-geometries
        local coords = Tuple[]
        # Retrieve the vector of sub-geometries (field name might be `Geometries`)
        local subgeoms =
            hasproperty(geom, :Geometries) ? geom.Geometries : (hasproperty(geom, :geometries) ? geom.geometries : nothing)
        if subgeoms !== nothing
            for g in subgeoms
                append!(coords, flatten_geometry(g))
            end
        end
        return coords
    else
        # Other geometry types (Model, etc.): return empty vector (no coordinates to flatten)
        return Tuple[]
    end
end

# --- Tables.jl interface ----------------------------------------------------
Tables.istable(::Type{PlacemarkTable})      = true
Tables.columnaccess(::Type{PlacemarkTable}) = true

Tables.schema(::PlacemarkTable) = Tables.Schema(
    (:name, :description, :geometry),
    (String, String, Geometry)       # raw geometry objects
)

function Tables.columns(t::PlacemarkTable)
    return (
        name        = [ pl.name        === nothing ? "" : pl.name        for pl in t.placemarks ],
        description = [ pl.description === nothing ? "" : pl.description for pl in t.placemarks ],
        geometry    = [ pl.Geometry                                      for pl in t.placemarks ],
    )
end

end  # module TablesInterface
