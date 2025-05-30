module FieldConversion

export convert_field_value, convert_field_value_vector, FieldConversionError

using Parsers
using TimeZones
using Dates
import ..Core
import ..Enums
import ..Coordinates: parse_coordinates_automa, Coord2, Coord3

struct FieldConversionError <: Exception
    field_name::Symbol
    target_type::Type
    value::String
    message::String
end

"""
    convert_field_value(value::String, target_type::Type, field_name::Symbol; parse_iso8601_fn=nothing) -> Any

Convert a string value to the target type for a specific field.
Handles all KML field type conversions including coordinates, dates, enums, etc.
The parse_iso8601_fn keyword should be the parse_iso8601 function when available.
"""
function convert_field_value(value::String, target_type::Type, field_name::Symbol; parse_iso8601_fn=nothing)
    # Handle empty strings for optional fields
    if isempty(value) && Nothing <: target_type
        return nothing
    end
    
    # Get the non-nothing type for conversion
    actual_type = Base.nonnothingtype(target_type)
    
    try
        # String types
        if actual_type === String
            return value
            
        # Numeric types
        elseif actual_type <: Integer
            return isempty(value) ? zero(actual_type) : Parsers.parse(actual_type, value)
            
        elseif actual_type <: AbstractFloat
            return isempty(value) ? zero(actual_type) : Parsers.parse(actual_type, value)
            
        # Boolean types
        elseif actual_type <: Bool
            return parse_boolean(value)
            
        # Enum types
        elseif actual_type <: Enums.AbstractKMLEnum
            return isempty(value) && Nothing <: target_type ? nothing : actual_type(value)
            
        # Coordinate types
        elseif field_name === :coordinates || field_name === :gx_coord
            return convert_coordinates(value, actual_type, target_type)
            
        # Time primitive types
        elseif is_time_primitive_type(actual_type)
            if parse_iso8601_fn !== nothing
                return parse_iso8601_fn(value)
            else
                # Fallback to string if parse function not available
                return value
            end
            
        else
            throw(FieldConversionError(field_name, target_type, value, 
                "Unhandled field type: $actual_type"))
        end
        
    catch e
        if e isa FieldConversionError
            rethrow(e)
        else
            throw(FieldConversionError(field_name, target_type, value, 
                "Conversion failed: $(e)"))
        end
    end
end

"""
    convert_field_value_vector(value::String, element_type::Type, field_name::Symbol; parse_iso8601_fn=nothing) -> Any

Convert a string value for a vector field element.
"""
function convert_field_value_vector(value::String, element_type::Type, field_name::Symbol; parse_iso8601_fn=nothing)
    # Handle empty strings for optional elements
    if isempty(value) && Nothing <: element_type
        return nothing
    end
    
    actual_type = Base.nonnothingtype(element_type)
    
    # For vector elements, use the same conversion logic
    return convert_field_value(value, actual_type, field_name; parse_iso8601_fn=parse_iso8601_fn)
end

# Helper functions

function parse_boolean(value::String)::Bool
    len = length(value)
    if len == 1
        return value[1] == '1'
    elseif len == 4 && uppercase(value) == "TRUE"
        return true
    elseif len == 5 && uppercase(value) == "FALSE"
        return false
    else
        return false  # Default for invalid values
    end
end

function convert_coordinates(value::String, actual_type::Type, original_type::Type)
    parsed_coords = parse_coordinates_automa(value)
    
    if isempty(parsed_coords)
        if Nothing <: original_type
            return nothing
        elseif actual_type <: AbstractVector
            return actual_type()
        else
            return nothing
        end
    end
    
    # Single coordinate types (Point)
    if actual_type <: Union{Coord2, Coord3}
        if length(parsed_coords) == 1
            return convert(actual_type, parsed_coords[1])
        else
            # Take first coordinate with warning
            @warn "Expected 1 coordinate, got $(length(parsed_coords)). Using first."
            return convert(actual_type, parsed_coords[1])
        end
    # Vector coordinate types (LineString, LinearRing)
    elseif actual_type <: AbstractVector
        return convert(actual_type, parsed_coords)
    else
        throw(FieldConversionError(:coordinates, actual_type, value,
            "Unhandled coordinate type: $actual_type"))
    end
end

function is_time_primitive_type(T::Type)
    T == Union{TimeZones.ZonedDateTime, Dates.Date, String} ||
    T == Union{Dates.Date, TimeZones.ZonedDateTime, String} ||
    T == Union{TimeZones.ZonedDateTime, String, Dates.Date} ||
    T == Union{String, TimeZones.ZonedDateTime, Dates.Date} ||
    T == Union{Dates.Date, String, TimeZones.ZonedDateTime} ||
    T == Union{String, Dates.Date, TimeZones.ZonedDateTime}
end

end # module FieldConversion