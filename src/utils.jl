"""
    unwrap_single_part_multigeometry(geom::Geometry) -> Geometry

If `geom` is a `MultiGeometry` containing exactly one sub-geometry, 
returns that single sub-geometry (recursively simplified). 
Otherwise, returns the original geometry.
"""
function unwrap_single_part_multigeometry(geom::MultiGeometry)
    if geom.Geometries !== nothing && length(geom.Geometries) == 1
        # Recursively simplify in case the single element is also a MultiGeometry
        return unwrap_single_part_multigeometry(geom.Geometries[1])
    end
    return geom # Return as is if multiple elements, empty, or already simple
end

# Fallback for non-MultiGeometry types (just returns the geometry itself)
unwrap_single_part_multigeometry(geom::Geometry) = geom

# Handle cases where geometry might be nothing (e.g., from Placemark.Geometry)
unwrap_single_part_multigeometry(::Nothing) = nothing