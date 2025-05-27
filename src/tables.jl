module TablesBridge

export PlacemarkTable, list_layers, get_layer_names, get_num_layers

using Tables
import ..KML:
    KMLFile,
    LazyKMLFile,
    read,
    Feature,
    Document,
    Folder,
    Placemark,
    Geometry,
    object,
    unwrap_single_part_multigeometry,
    LinearRing,
    Point,
    LineString,
    Polygon,
    MultiGeometry,
    Coord3,
    Coord2,
    _parse_coordinates_automa
import XML: XML, parse, Node, LazyNode, tag, children, attributes
using StaticArrays
using Base.Iterators: flatten
import REPL
using REPL.TerminalMenus

include("HtmlEntitiesAutoma.jl")
using .HtmlEntitiesAutoma: decode_named_entities

#────────────────────────────── helpers ──────────────────────────────#

# ===== Eager (KMLFile) helpers =====
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

# ===== Lazy (LazyKMLFile) helpers =====
function _find_kml_element(doc::XML.AbstractXMLNode)
    for child in children(doc)
        if tag(child) == "kml"
            return child
        end
    end
    error("No <kml> tag found in LazyKMLFile")
end

function _is_feature_tag(tag_name::String)
    tag_name in
    ("Document", "Folder", "Placemark", "NetworkLink", "GroundOverlay", "PhotoOverlay", "ScreenOverlay", "gx:Tour")
end

function _is_container_tag(tag_name::String)
    tag_name in ("Document", "Folder")
end

function _get_name_from_node(node::XML.AbstractXMLNode)
    # Check attributes first (some elements might have name as attribute)
    attrs = attributes(node)
    if attrs !== nothing && haskey(attrs, "name")
        return attrs["name"]
    end

    # Look for <name> child element
    for child in children(node)
        if tag(child) == "name"
            # Get text content
            for textnode in children(child)
                if XML.nodetype(textnode) === XML.Text
                    return XML.value(textnode)
                end
            end
        end
    end
    return nothing
end

function _lazy_top_level_features(file::LazyKMLFile)
    kml_elem = _find_kml_element(file.root_node)
    features = []

    for child in children(kml_elem)
        child_tag = tag(child)
        if _is_feature_tag(child_tag)
            push!(features, child)
        end
    end

    # If no direct features, look inside first container
    if isempty(features)
        for child in children(kml_elem)
            if _is_container_tag(tag(child))
                for subchild in children(child)
                    if _is_feature_tag(tag(subchild))
                        push!(features, subchild)
                    end
                end
                break  # Only look in first container
            end
        end
    end

    features
end

# ===== Generic layer info function =====
function _get_layer_info(file::Union{KMLFile,LazyKMLFile})
    if file isa LazyKMLFile && file._layer_info_cache !== nothing
        return file._layer_info_cache
    end

    layer_infos = Tuple{Int,String,Any}[]
    idx_counter = 0

    # Logic based on _determine_layers and _select_layer from TablesBridge

    if file isa KMLFile
        #! Eager KMLFile implementation
        top_feats = _top_level_features(file)

        #───────────────────────────────────────────────────────────────────#
        # Scenario 1: Single Top-Level Document/Folder                      #
        #───────────────────────────────────────────────────────────────────#

        if length(top_feats) == 1 && (top_feats[1] isa Document || top_feats[1] isa Folder)
            main_container = top_feats[1]
            if main_container.Features !== nothing
                for feat in main_container.Features
                    if feat isa Document || feat isa Folder
                        idx_counter += 1
                        layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                        push!(layer_infos, (idx_counter, layer_name, feat))
                    end
                end
                # Check for direct placemarks in this main container
                direct_pms_in_container = [f for f in main_container.Features if f isa Placemark]
                if !isempty(direct_pms_in_container)
                    idx_counter += 1
                    push!(
                        layer_infos,
                        (
                            idx_counter,
                            "<Placemarks in $(main_container.name !== nothing ? main_container.name : "Top Container")>",
                            direct_pms_in_container,
                        ),
                    )
                end
            end

            #───────────────────────────────────────────────────────────────────#
            # Scenario 2: Multiple Top-Level Features or Direct Placemarks      #
            #───────────────────────────────────────────────────────────────────#

        else
            # Top-level containers (Documents/Folders)
            for feat in top_feats
                if feat isa Document || feat isa Folder
                    idx_counter += 1
                    layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                    push!(layer_infos, (idx_counter, layer_name, feat))
                end
            end
            # Top-level direct placemarks
            direct_top_pms = [f for f in top_feats if f isa Placemark]
            if !isempty(direct_top_pms)
                idx_counter += 1
                push!(layer_infos, (idx_counter, "<Ungrouped Top-Level Placemarks>", direct_top_pms))
            end
        end
    else
        #! LazyKMLFile implementation
        top_feats = _lazy_top_level_features(file)

        if length(top_feats) == 1 && _is_container_tag(tag(top_feats[1]))
            main_container = top_feats[1]
            main_container_name = _get_name_from_node(main_container)

            # Look for sub-containers and placemarks
            has_placemarks = false
            for child in children(main_container)
                child_tag = tag(child)
                if _is_container_tag(child_tag)
                    idx_counter += 1
                    layer_name = _get_name_from_node(child)
                    layer_name = layer_name !== nothing ? layer_name : "<Unnamed Container>"
                    push!(layer_infos, (idx_counter, layer_name, child))
                elseif child_tag == "Placemark"
                    has_placemarks = true
                end
            end

            if has_placemarks
                idx_counter += 1
                container_desc = main_container_name !== nothing ? main_container_name : "Top Container"
                push!(layer_infos, (idx_counter, "<Placemarks in $container_desc>", main_container))
            end
        else
            has_top_placemarks = false
            for feat in top_feats
                feat_tag = tag(feat)
                if _is_container_tag(feat_tag)
                    idx_counter += 1
                    layer_name = _get_name_from_node(feat)
                    layer_name = layer_name !== nothing ? layer_name : "<Unnamed Container>"
                    push!(layer_infos, (idx_counter, layer_name, feat))
                elseif feat_tag == "Placemark"
                    has_top_placemarks = true
                end
            end

            if has_top_placemarks
                idx_counter += 1
                # Store the kml element itself as the source for top-level placemarks
                kml_elem = _find_kml_element(file.root_node)
                push!(layer_infos, (idx_counter, "<Ungrouped Top-Level Placemarks>", kml_elem))
            end
        end

        # Cache the result
        file._layer_info_cache = layer_infos
    end

    return layer_infos
end

# ===== Layer selection (works for both types) =====
function _select_layer(file::Union{KMLFile,LazyKMLFile}, layer_spec::Union{Nothing,String,Integer})
    layer_options = _get_layer_info(file)

    if isempty(layer_options)
        return file isa KMLFile ? Feature[] : nothing
    end

    if layer_spec isa String
        for (_, name, source) in layer_options
            if name == layer_spec
                return source # Return the source (Document, Folder, or Placemark vector)
            end
        end
        error("Layer \"$layer_spec\" not found by name. Available: $(join([opt[2] for opt in layer_options], ", "))")
    elseif layer_spec isa Integer
        if 1 <= layer_spec <= length(layer_options)
            return layer_options[layer_spec][3] # Return the source (Document, Folder, or Placemark vector)
        else
            # Generate a detailed error message with all available layers
            layer_details_parts = String[]
            # Add header for available layers
            for (idx, name, origin) in layer_options
                item_count_str = ""
                if origin isa Vector{Placemark}
                    item_count_str = " ($(length(origin)) placemarks)"
                elseif origin isa Document || origin isa Folder
                    num_direct_children = origin.Features !== nothing ? length(origin.Features) : 0
                    item_count_str = " (Container with $num_direct_children direct items)"
                elseif origin isa XML.AbstractXMLNode
                    # For lazy nodes, count children
                    placemark_count = count(c -> tag(c) == "Placemark", children(origin))
                    item_count_str = " ($placemark_count placemarks)"
                end
                push!(layer_details_parts, "  [$idx] $name$item_count_str")
            end
            layer_details_str = join(layer_details_parts, "\n")
            error(
                "Layer index $layer_spec out of bounds. Must be between 1 and $(length(layer_options)).\nAvailable layers:\n$layer_details_str",
            )
        end
    elseif layer_spec === nothing # No specific layer requested
        if length(layer_options) == 1
            return layer_options[1][3]
        end
        # If multiple layers, prompt user for selection
        # Use REPL.TerminalMenus for interactive selection
        opts = [opt[2] for opt in layer_options]
        interactive = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()
        if interactive
            menu = RadioMenu(opts; pagesize = min(10, length(opts)))
            choice_idx = request("Select a layer:", menu)
            choice_idx == -1 && error("Layer selection cancelled.")
            return layer_options[choice_idx][3]
        else
            @warn "Multiple layers available. Picking first: \"$(layer_options[1][2])\"."
            return layer_options[1][3]
        end
    end
    return file isa KMLFile ? Feature[] : nothing
end

#───────────────────────────── list_layers function ────────────────────────────#
"""
    list_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})

Prints a list of available "layers" found within a KML file to the console.
"""
function list_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})
    file = if kml_input isa AbstractString
        # Try lazy loading first for efficiency
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end

    println("Available layers:")
    layer_infos = _get_layer_info(file)

    if isempty(layer_infos)
        println("  No distinct layers found (or KML contains no Placemarks in common structures).")
        return
    end

    for (idx, name, origin) in layer_infos
        item_count_str = ""
        if origin isa Vector{Placemark}
            item_count_str = " ($(length(origin)) placemarks)"
        elseif origin isa Document || origin isa Folder
            # Count direct children in Document/Folder
            num_direct_children = origin.Features !== nothing ? length(origin.Features) : 0
            item_count_str = " (Container with $num_direct_children direct items)"
        elseif origin isa XML.AbstractXMLNode
            # For lazy nodes, count placemarks
            placemark_count = count(c -> tag(c) == "Placemark", children(origin))
            item_count_str = " ($placemark_count placemarks)"
        end
        println("  [$idx] $name$item_count_str")
    end
end

#─────────────────────────── get_layer_names function ───────────────────────────#
"""
    get_layer_names(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Vector{String}

Returns an array of strings containing the names of available "layers"
found within a KML file.
"""
function get_layer_names(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Vector{String}
    file = if kml_input isa AbstractString
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end
    layer_infos = _get_layer_info(file)

    if isempty(layer_infos)
        return String[]
    end

    return [name for (_, name, _) in layer_infos]
end

#─────────────────────────── get_num_layers function ───────────────────────────#
"""
    get_num_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Int

Returns the number of available "layers" found within a KML file.
"""
function get_num_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Int
    file = if kml_input isa AbstractString
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end
    layer_infos = _get_layer_info(file)
    return length(layer_infos)
end

#────────────────────────── NEW: Optimized Lazy Iterator Types ──────────────────────────#

# ===== Optimized Eager Collection (FASTEST - Recommended) =====
struct EagerLazyPlacemarkIterator
    placemarks::Vector{NamedTuple{(:name, :description, :geometry), Tuple{String, String, Union{Missing,Geometry}}}}
    
    function EagerLazyPlacemarkIterator(root_node::XML.AbstractXMLNode)
        placemarks = Vector{NamedTuple{(:name, :description, :geometry), Tuple{String, String, Union{Missing,Geometry}}}}()
        sizehint!(placemarks, 1000)  # Pre-allocate for typical layer size
        
        _collect_placemarks_optimized!(placemarks, root_node)
        
        # Shrink to fit
        sizehint!(placemarks, length(placemarks))
        
        new(placemarks)
    end
end

# Optimized collection with minimal allocations
function _collect_placemarks_optimized!(placemarks::Vector, node::XML.AbstractXMLNode)
    node_children = children(node)
    
    @inbounds for i in 1:length(node_children)
        child = node_children[i]
        
        # Skip non-element nodes early
        XML.nodetype(child) === XML.Element || continue
        
        child_tag = tag(child)
        
        if child_tag == "Placemark"
            # Extract only what we need - no full object materialization!
            placemark_data = extract_placemark_fields_lazy(child)
            push!(placemarks, placemark_data)
            
        elseif child_tag in ("Document", "Folder")  # Inline container check
            _collect_placemarks_optimized!(placemarks, child)
        end
    end
end

# Fast iteration for eager collection
Base.iterate(iter::EagerLazyPlacemarkIterator, state=1) = 
    state > length(iter.placemarks) ? nothing : (iter.placemarks[state], state + 1)

Base.length(iter::EagerLazyPlacemarkIterator) = length(iter.placemarks)
Base.IteratorSize(::Type{EagerLazyPlacemarkIterator}) = Base.HasLength()
Base.eltype(::Type{EagerLazyPlacemarkIterator}) = eltype(iter.placemarks)

#─────────────────────────────────────────────────────────────────────────────────────#

# Direct text extraction without object materialization
function extract_text_content(node::XML.AbstractXMLNode)
    return extract_text_content_fast(node)
end

# Fast text extraction with minimal allocations
function extract_text_content_fast(node::XML.AbstractXMLNode)
    node_children = children(node)
    
    # Common case: single text node
    if length(node_children) == 1
        child = node_children[1]
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            return strip(XML.value(child))
        end
    end
    
    # Multiple or no text nodes
    if isempty(node_children)
        return ""
    end
    
    # Use IOBuffer for multiple text nodes
    io = IOBuffer()
    found_text = false
    for child in node_children
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            found_text && write(io, ' ')  # Add space between text nodes
            write(io, XML.value(child))
            found_text = true
        end
    end
    return strip(String(take!(io)))
end

# Minimal geometry parsing - only what's needed for DataFrame
function parse_geometry_lazy(geom_node::XML.AbstractXMLNode)
    geom_tag = tag(geom_node)

    if geom_tag == "Point"
        # Extract coordinates directly
        for child in children(geom_node)
            if tag(child) == "coordinates"
                coord_text = extract_text_content(child)
                coords = _parse_single_coordinate(coord_text)
                return Point(; coordinates = coords)
            end
        end
    elseif geom_tag == "LineString"
        for child in children(geom_node)
            if tag(child) == "coordinates"
                coord_text = extract_text_content(child)
                coords = _parse_coordinate_list(coord_text)
                return LineString(; coordinates = coords)
            end
        end
    elseif geom_tag == "Polygon"
        outer_ring = nothing
        inner_rings = LinearRing[]

        for child in children(geom_node)
            child_tag = tag(child)
            if child_tag == "outerBoundaryIs"
                for boundary_child in children(child)
                    if tag(boundary_child) == "LinearRing"
                        outer_ring = parse_linear_ring_lazy(boundary_child)
                        break
                    end
                end
            elseif child_tag == "innerBoundaryIs"
                for boundary_child in children(child)
                    if tag(boundary_child) == "LinearRing"
                        push!(inner_rings, parse_linear_ring_lazy(boundary_child))
                    end
                end
            end
        end

        if outer_ring !== nothing
            return Polygon(; outerBoundaryIs = outer_ring, innerBoundaryIs = isempty(inner_rings) ? nothing : inner_rings)
        end
    elseif geom_tag == "MultiGeometry"
        geometries = Geometry[]
        for child in children(geom_node)
            if tag(child) in ("Point", "LineString", "Polygon", "MultiGeometry")
                push!(geometries, parse_geometry_lazy(child))
            end
        end
        return MultiGeometry(; Geometries = geometries)
    end

    return missing
end

function parse_linear_ring_lazy(ring_node::XML.AbstractXMLNode)
    for child in children(ring_node)
        if tag(child) == "coordinates"
            coord_text = extract_text_content(child)
            coords = _parse_coordinate_list(coord_text)
            return LinearRing(; coordinates = coords)
        end
    end
    return LinearRing()
end

# Fast coordinate parsing for single points
function _parse_single_coordinate(text::AbstractString)
    parts = split(strip(text), ',')
    if length(parts) >= 3
        return Coord3(parse(Float64, parts[1]), parse(Float64, parts[2]), parse(Float64, parts[3]))
    elseif length(parts) == 2
        return Coord2(parse(Float64, parts[1]), parse(Float64, parts[2]))
    else
        return nothing
    end
end

# Simple coordinate list parser for common cases
function _parse_coordinate_list(text::AbstractString)
    # For simple cases, avoid the heavy Automa parser
    text = strip(text)
    if isempty(text)
        return Coord3[]  # Use the KML type alias
    end

    # Quick check if it's a simple format
    if !occursin('\n', text) && count(',', text) <= 100
        # Simple single-line format
        coords = Coord3[]
        for coord_str in split(text, r"\s+")
            isempty(coord_str) && continue
            parts = split(coord_str, ',')
            if length(parts) >= 2
                if length(parts) >= 3
                    push!(coords, Coord3(parse(Float64, parts[1]), parse(Float64, parts[2]), parse(Float64, parts[3])))
                else
                    # Convert 2D to 3D with zero altitude
                    push!(coords, Coord3(parse(Float64, parts[1]), parse(Float64, parts[2]), 0.0))
                end
            end
        end
        # Return appropriate type based on dimensions
        if all(c -> c[3] == 0.0, coords)
            # All altitudes are zero, return 2D coordinates
            return [Coord2(c[1], c[2]) for c in coords]
        else
            return coords
        end
    else
        # Fall back to Automa for complex cases
        return _parse_coordinates_automa(text)
    end
end

# Extract only the fields needed for DataFrame
function extract_placemark_fields_lazy(placemark_node::XML.AbstractXMLNode)
    name = ""
    description = ""
    geometry = missing

    for child in children(placemark_node)
        child_tag = tag(child)

        if child_tag == "name"
            name = extract_text_content(child)
            # Handle HTML entities if needed
            if occursin('&', name)
                name = decode_named_entities(name)
            end
        elseif child_tag == "description"
            description = extract_text_content(child)
        elseif child_tag in ("Point", "LineString", "Polygon", "MultiGeometry")
            # Only parse geometry if we haven't found one yet
            if ismissing(geometry)
                geometry = parse_geometry_lazy(child)
            end
        end

        # Early exit if we have all fields
        if !isempty(name) && !isempty(description) && !ismissing(geometry)
            break
        end
    end

    return (name = name, description = description, geometry = geometry)
end

#────────────────────────── streaming iterator over placemarks ──────────────────────────#

# Eager iterator for KMLFile
function _placemark_iterator(file::KMLFile, layer_spec::Union{Nothing,String,Integer})
    selected_source = _select_layer(file, layer_spec)
    return _iter_feat(selected_source)
end

# Eager iteration
function _iter_feat(x)
    if x isa Placemark
        return (x for _ = 1:1)
    elseif (x isa Document || x isa Folder) && x.Features !== nothing
        return flatten(_iter_feat.(x.Features))
    elseif x isa AbstractVector{<:Feature}
        return flatten(_iter_feat.(x))
    else
        return ()
    end
end

# Lazy iterator for LazyKMLFile
function _placemark_iterator(file::LazyKMLFile, layer_spec::Union{Nothing,String,Integer})
    selected_source = _select_layer(file, layer_spec)
    if selected_source === nothing
        return (p for p in ())  # Empty iterator
    end
    return EagerLazyPlacemarkIterator(selected_source)
end

#──────────────────────────── streaming PlacemarkTable type ────────────────────────────#
"""
    PlacemarkTable(source; layer=nothing, simplify_single_parts=false)

A lazy, streaming Tables.jl table of the placemarks in a KML file.
You can call it either with a path or with an already-loaded `KMLFile` or `LazyKMLFile`.
"""
struct PlacemarkTable
    file::Union{KMLFile,LazyKMLFile}
    layer::Union{Nothing,String,Integer}
    simplify_single_parts::Bool
end

PlacemarkTable(
    file::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
) = PlacemarkTable(file, layer, simplify_single_parts)

PlacemarkTable(path::AbstractString; layer::Union{Nothing,String,Integer} = nothing, simplify_single_parts::Bool = false) =
    PlacemarkTable(read(path, LazyKMLFile); layer = layer, simplify_single_parts = simplify_single_parts)

#──────────────────────────────── Tables.jl API ──────────────────────────────────#
Tables.istable(::Type{<:PlacemarkTable}) = true
Tables.rowaccess(::Type{<:PlacemarkTable}) = true

Tables.schema(::PlacemarkTable) = Tables.Schema((:name, :description, :geometry), (String, String, Union{Missing,Geometry}))

function Tables.rows(tbl::PlacemarkTable)
    it = _placemark_iterator(tbl.file, tbl.layer)

    if tbl.file isa LazyKMLFile
        # Lazy path - data is already in the right format
        return (
            let pl = pl
                geom_to_return = pl.geometry
                if tbl.simplify_single_parts && !ismissing(geom_to_return)
                    geom_to_return = unwrap_single_part_multigeometry(geom_to_return)
                end
                (name = pl.name, description = pl.description, geometry = geom_to_return)
            end for pl in it
        )
    else
        # Eager path - existing logic
        return (
            let pl = pl
                desc = if pl.description === nothing
                    ""
                else
                    pl.description
                end
                name_str = pl.name === nothing ? "" : pl.name
                processed_name = if pl.name !== nothing && occursin('&', name_str)
                    decode_named_entities(name_str)
                else
                    name_str
                end
                geom_to_return = pl.Geometry
                if tbl.simplify_single_parts
                    geom_to_return = unwrap_single_part_multigeometry(geom_to_return)
                end
                (name = processed_name, description = desc, geometry = geom_to_return)
            end for pl in it if pl isa Placemark
        )
    end
end

# --- Tables.jl API for KMLFile and LazyKMLFile ---
Tables.istable(::Type{KMLFile}) = true
Tables.istable(::Type{LazyKMLFile}) = true
Tables.rowaccess(::Type{KMLFile}) = true
Tables.rowaccess(::Type{LazyKMLFile}) = true

function Tables.schema(
    k::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    return Tables.schema(PlacemarkTable(k; layer = layer, simplify_single_parts = simplify_single_parts))
end

function Tables.rows(
    k::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    return Tables.rows(PlacemarkTable(k; layer = layer, simplify_single_parts = simplify_single_parts))
end

end # module TablesBridge