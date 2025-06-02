module KML

# Base dependencies
using OrderedCollections: OrderedDict
using StaticArrays
using Automa, Parsers
using TimeZones, Dates
using InteractiveUtils: subtypes

# Include all modules in dependency order
include("enums.jl")
include("types.jl")
include("coordinates.jl")
include("time_parsing.jl")
include("html_entities.jl")
include("field_conversion.jl")
include("xml_parsing.jl")
include("xml_serialization.jl")
include("io.jl")
include("layers.jl")
include("utils.jl")
include("tables.jl")
include("validation.jl")

# Import for easier access
using .Types
using .Enums
using .Coordinates: coordinate_string, Coord2, Coord3
using .Layers: list_layers, get_layer_names, get_num_layers
using .TablesBridge: PlacemarkTable

# Re-export public API
export KMLFile, LazyKMLFile, object
export unwrap_single_part_multigeometry
export PlacemarkTable, list_layers, get_layer_names, get_num_layers
export coordinate_string, Coord2, Coord3

# Export all type names from Types module
for name in names(Types; all=false)
    if name != :Types && name != :eval && name != :include
        @eval export $name
    end
end

# Export all enum types
for name in names(Enums; all=false)
    if name != :Enums && name != :AbstractKMLEnum
        @eval export $name
    end
end

function __init__()
    # Register error hints for KMZ support
    Base.Experimental.register_error_hint(IO._read_kmz_file_from_path_error_hinter, ErrorException)
end

end # module KML