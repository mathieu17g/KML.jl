module FieldAssignment

export assign_field!, assign_complex_object!, handle_polygon_boundary!

using Dates, TimeZones
using StaticArrays
import ..Core: KMLElement, typemap
import ..Enums
import ..Geometries
import ..Coordinates
import ..FieldConversion: convert_field_value, convert_field_value_vector, FieldConversionError
import ..TimeElements
import XML

"""
    assign_field!(parent, field_name::Symbol, value::AbstractString, original_tag::String; parse_iso8601_fn=nothing)

Assign a converted string value to a field in the parent object.
Handles both scalar and vector fields.
"""
function assign_field!(parent::KMLElement, field_name::Symbol, value::AbstractString, original_tag::String; parse_iso8601_fn=nothing)
    # Handle special field name mappings
    true_field_name = map_field_name(parent, field_name)
    
    if !hasfield(typeof(parent), true_field_name)
        @warn "No field named '$field_name' (or mapped '$true_field_name') in $(typeof(parent)) for tag <$original_tag>"
        return
    end
    
    # Get field type information
    field_type = fieldtype(typeof(parent), true_field_name)
    non_nothing_type = typemap(typeof(parent))[true_field_name]
    
    # Convert to String if needed (for SubString support)
    value_str = String(value)
    
    # Special handling for coordinate fields - they should ALWAYS use convert_field_value
    # and never go through the vector element parsing path
    if true_field_name === :coordinates || true_field_name === :gx_coord
        try
            converted_value = convert_field_value(value_str, field_type, true_field_name; parse_iso8601_fn=parse_iso8601_fn)
            setfield!(parent, true_field_name, converted_value)
        catch e
            if e isa FieldConversionError
                @warn "Failed to convert coordinate field $true_field_name: $(e.message)" value=value_str
                if Nothing <: field_type
                    setfield!(parent, true_field_name, nothing)
                end
            else
                rethrow(e)
            end
        end
        return
    end
    
    # Check if it's a vector field (but not coordinates)
    if non_nothing_type <: AbstractVector && is_simple_vector_type(non_nothing_type)
        assign_vector_element!(parent, true_field_name, field_type, non_nothing_type, value_str, original_tag; parse_iso8601_fn=parse_iso8601_fn)
    else
        # Scalar field
        try
            converted_value = convert_field_value(value_str, field_type, true_field_name; parse_iso8601_fn=parse_iso8601_fn)
            setfield!(parent, true_field_name, converted_value)
        catch e
            if e isa FieldConversionError
                @warn "Failed to convert value for field $true_field_name: $(e.message)" value=value_str
                # Set to nothing if optional, otherwise use fallback
                if Nothing <: field_type
                    setfield!(parent, true_field_name, nothing)
                elseif non_nothing_type === String
                    setfield!(parent, true_field_name, value_str)  # Fallback to string
                end
            else
                rethrow(e)
            end
        end
    end
end

"""
    assign_complex_object!(parent, child_object::KMLElement, original_tag::String)

Assign a complex KML object to the appropriate field in the parent.
"""
function assign_complex_object!(parent::KMLElement, child_object::KMLElement, original_tag::String)
    child_type = typeof(child_object)
    assigned = false
    parent_type = typeof(parent)
    
    # Try to find a compatible field
    for field_name in fieldnames(parent_type)
        field_type = fieldtype(parent_type, field_name)
        non_nothing_type = typemap(parent_type)[field_name]
        
        # Direct type match
        if child_type <: non_nothing_type
            setfield!(parent, field_name, child_object)
            assigned = true
            break
        # Vector field match
        elseif non_nothing_type <: AbstractVector && child_type <: eltype(non_nothing_type)
            vec = getfield(parent, field_name)
            if vec === nothing
                setfield!(parent, field_name, eltype(non_nothing_type)[])
                vec = getfield(parent, field_name)
            end
            push!(vec, child_object)
            assigned = true
            break
        end
    end
    
    if !assigned
        @warn "Could not assign $(child_type) (from <$original_tag>) to any field in $(parent_type)"
    end
end

"""
    handle_polygon_boundary!(polygon, boundary_node::XML.AbstractXMLNode, boundary_type::Symbol, object_fn)

Special handler for Polygon boundary elements.
The object_fn parameter should be the object parsing function from the parsing module.
"""
function handle_polygon_boundary!(polygon, boundary_node::XML.AbstractXMLNode, boundary_type::Symbol, object_fn=nothing)
    # If object_fn not provided, we can't parse LinearRing nodes
    if object_fn === nothing
        @warn "object function not provided to handle_polygon_boundary!"
        return
    end
    
    boundary_children = XML.children(boundary_node)
    element_children = [c for c in boundary_children if XML.nodetype(c) === XML.Element]
    
    if boundary_type === :outerBoundaryIs
        if length(element_children) == 1
            lr_node = element_children[1]
            if tagsym(XML.tag(lr_node)) === :LinearRing
                lr_obj = object_fn(lr_node)
                if lr_obj isa Geometries.LinearRing
                    setfield!(polygon, :outerBoundaryIs, lr_obj)
                else
                    @warn "<outerBoundaryIs> LinearRing didn't parse correctly"
                end
            else
                @warn "<outerBoundaryIs> expected <LinearRing>, got <$(XML.tag(lr_node))>"
            end
        else
            @warn "<outerBoundaryIs> expected 1 element, found $(length(element_children))"
        end
        
    elseif boundary_type === :innerBoundaryIs
        if isempty(element_children)
            @warn "<innerBoundaryIs> contained no elements"
        else
            if getfield(polygon, :innerBoundaryIs) === nothing
                setfield!(polygon, :innerBoundaryIs, Geometries.LinearRing[])
            end
            
            rings_processed = 0
            for lr_node in element_children
                if tagsym(XML.tag(lr_node)) === :LinearRing
                    lr_obj = object_fn(lr_node)
                    if lr_obj isa Geometries.LinearRing
                        push!(getfield(polygon, :innerBoundaryIs), lr_obj)
                        rings_processed += 1
                    else
                        @warn "LinearRing in <innerBoundaryIs> didn't parse correctly"
                    end
                else
                    @warn "<innerBoundaryIs> contained non-LinearRing element: <$(XML.tag(lr_node))>"
                end
            end
            
            if length(element_children) > 1 && rings_processed > 0
                @info "Processed $rings_processed LinearRing(s) from <innerBoundaryIs>" maxlog=1
            end
        end
    end
end

# Helper functions

function map_field_name(parent, field_name::Symbol)::Symbol
    # Special mappings for specific types
    if parent isa TimeElements.TimeSpan
        if field_name === :begin
            return :begin_
        elseif field_name === :end
            return :end_
        end
    end
    return field_name
end

function is_simple_vector_type(vec_type::Type)
    if !(vec_type <: AbstractVector)
        return false
    end
    
    el_type = eltype(vec_type)
    actual_el_type = Base.nonnothingtype(el_type)
    
    # Exclude coordinate types - they need special parsing
    if actual_el_type <: Union{Coordinates.Coord2, Coordinates.Coord3}
        return false
    end
    
    # Exclude StaticArrays (which are often used for coordinates)
    if actual_el_type <: StaticArrays.StaticArray
        return false
    end
    
    return actual_el_type === String ||
           actual_el_type <: Integer ||
           actual_el_type <: AbstractFloat ||
           actual_el_type <: Bool ||
           actual_el_type <: Enums.AbstractKMLEnum ||
           is_time_primitive_element_type(el_type)
end

function is_time_primitive_element_type(T::Type)
    T == Union{TimeZones.ZonedDateTime, Dates.Date, String} ||
    T == Union{Dates.Date, TimeZones.ZonedDateTime, String} ||
    T == Union{TimeZones.ZonedDateTime, String, Dates.Date} ||
    T == Union{String, TimeZones.ZonedDateTime, Dates.Date} ||
    T == Union{Dates.Date, String, TimeZones.ZonedDateTime} ||
    T == Union{String, Dates.Date, TimeZones.ZonedDateTime}
end

function assign_vector_element!(parent, field_name::Symbol, field_type::Type, vec_type::Type,
                               value::String, original_tag::String; parse_iso8601_fn=nothing)
    el_type = eltype(vec_type)
    
    try
        converted_value = convert_field_value_vector(value, el_type, field_name; parse_iso8601_fn=parse_iso8601_fn)
        
        # Get or initialize the vector
        current_vector = getfield(parent, field_name)
        if current_vector === nothing
            new_vector = el_type[]
            setfield!(parent, field_name, new_vector)
            current_vector = new_vector
        end
        
        # Push the converted element
        if converted_value !== nothing || Nothing <: el_type
            push!(current_vector, converted_value)
        elseif !isempty(value)
            @warn "Could not push non-empty value '$value' to vector field $field_name"
        end
        
    catch e
        if e isa FieldConversionError
            @warn "Failed to convert vector element for field $field_name: $(e.message)" value=value
        else
            rethrow(e)
        end
    end
end

# Helper to convert tag strings to symbols (same as in parsing.jl)
const _TAGSYM_CACHE = Dict{String,Symbol}()
const _COLON_TO_UNDERSCORE = r":" => "_"

function tagsym(x::String)
    get!(_TAGSYM_CACHE, x) do
        Symbol(replace(x, _COLON_TO_UNDERSCORE))
    end
end

end # module FieldAssignment