module KML

# ─── base deps ────────────────────────────────────────────────────────────────
using OrderedCollections: OrderedDict
import XML: XML, read as xmlread, parse as xmlparse, write as xmlwrite, Node, LazyNode, nodetype
using InteractiveUtils: subtypes
using StaticArrays
using Automa, Parsers

# ─── split implementation files ──────────────────────────────────────────────
include("Coordinates.jl")       # coordinate parsing and string generation
include("Enums.jl")             # KML enum types
include("types.jl")             # all KML data types (now modularized)
include("utils.jl")             # utility functions
include("Layers.jl")            # layer management functionality
include("geointerface.jl")      # GeoInterface extensions
include("parsing.jl")           # XML → struct & struct → XML
include("types_integration.jl") # Integration between types and parsing
include("tables.jl")            # Tables.jl wrapper for Placemarks
using .TablesBridge
using .Coordinates: coordinate_string, Coord2, Coord3
using .Layers: list_layers, get_layer_names, get_num_layers

# Remove the manual _parse_kmlfile assignment since it's now in types_integration.jl

# ─── re‑export public names ──────────────────────────────────────────────────
export KMLFile, LazyKMLFile, Enums, object
export unwrap_single_part_multigeometry
export PlacemarkTable, list_layers, get_layer_names, get_num_layers
export coordinate_string, Coord2, Coord3

# Export all types from types.jl (which re-exports from submodules)
for name in names(Core; all=false)
    if name != :Core && name != :eval && name != :include
        @eval export $name
    end
end

# Also export from all the submodules loaded by types.jl
for mod in [TimeElements, Components, Styles, Views, Geometries, Features]
    for name in names(mod; all=false)
        if name != nameof(mod)
            @eval export $name
        end
    end
end

function __init__()
    # Handle all available errors!
    Base.Experimental.register_error_hint(_read_kmz_file_from_path_error_hinter, MethodError)
end

end # module