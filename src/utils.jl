"""
    extract_text_content_fast(node::XML.AbstractXMLNode) -> String

Efficiently extract text content from an XML node, optimized for the common
case of a single text/CDATA child node. Returns stripped string content.

This function concatenates multiple text nodes without separators to preserve
data integrity for enums, URLs, and other structured content in KML.
"""
function extract_text_content_fast(node::XML.AbstractXMLNode)
    node_children = XML.children(node)
    
    # Fast path: single text node (most common in KML)
    if length(node_children) == 1
        child = node_children[1]
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            return strip(XML.value(child))
        end
    end
    
    # Empty node
    if isempty(node_children)
        return ""
    end
    
    # Multiple nodes: concatenate without separator
    io = IOBuffer()
    for child in node_children
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            write(io, XML.value(child))
        end
    end
    return strip(String(take!(io)))
end

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