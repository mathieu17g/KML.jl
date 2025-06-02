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
using .Utils: unwrap_single_part_multigeometry

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
    
    # Only check for conflicts when not precompiling
    if !Base.generating_output()
        check_geometry_conflicts()
    end
end

function check_geometry_conflicts()
    geometry_types = [:Point, :LineString, :LinearRing, :Polygon, :MultiGeometry]
    blocked_exports = Symbol[]
    conflicts_with = Set{Symbol}()
    
    for geom_type in geometry_types
        if isdefined(Main, geom_type)
            main_type = getfield(Main, geom_type)
            kml_type = getfield(KML, geom_type)
            
            # Check if Main's type is NOT KML's type
            if main_type !== kml_type && !isa(main_type, Module)
                push!(blocked_exports, geom_type)
                
                # Try to identify source package
                try
                    # For types, use parentmodule directly
                    source_module = parentmodule(main_type)
                    if source_module !== Main && source_module !== Base && source_module !== Core
                        push!(conflicts_with, nameof(source_module))
                    end
                catch
                    # If that fails, try checking methods
                    meths = methods(main_type)
                    if !isempty(meths)
                        for m in meths
                            mod = parentmodule(m.module)
                            if mod !== Main && mod !== Base && mod !== Core
                                push!(conflicts_with, nameof(mod))
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    
    if !isempty(blocked_exports)
        conflict_source = isempty(conflicts_with) ? "" : " (from $(join(collect(conflicts_with), ", ")))"
        
        @warn """
        KML.jl exports were blocked by existing definitions$conflict_source: $(join(blocked_exports, ", "))
        
        To use KML's geometry types:
        • Import KML first:
          using KML
          using GeometryBasics  # or other geometry packages
        • Or use qualified names:
          KML.Point(coordinates=(1.0, 2.0))
          df = DataFrame(kml_file)  # Other KML functions work normally
        """
    end
end

end # module KML