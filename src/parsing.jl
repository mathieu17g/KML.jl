export Node, _parse_kmlfile, _read_kmz_file_from_path_error_hinter

# Include the time parsing module
include("KMLTimeElementParsing.jl")

# Include field conversion and assignment modules
include("FieldConversion.jl")
include("FieldAssignment.jl")

using TimeZones
using Dates

# Import from the new modules
using .FieldConversion: convert_field_value, FieldConversionError
using .FieldAssignment: assign_field!, assign_complex_object!, handle_polygon_boundary!

# Import other dependencies
import ..Core: TAG_TO_TYPE, KMLElement, NoAttributes, typemap, _parse_kmlfile, KMLFile
import ..Enums
import ..Coordinates: parse_coordinates_automa, coordinate_string, Coord2, Coord3
import ..Components: Snippet, SimpleData
import ..Geometries: Polygon
import ..TimeElements
import ..Styles
import ..Views
import ..Features
import ..extract_text_content_fast
import XML
import XML: nodetype
using .KMLTimeElementParsing: parse_iso8601

# ─────────────────────────────────────────────────────────────────────────────
#  I/O glue: read/write KMLFile via XML
# ─────────────────────────────────────────────────────────────────────────────

# Internal helper: pull the <kml> element out of an XML.Document node
function _parse_kmlfile(doc::XML.AbstractXMLNode)
    doc_children = XML.children(doc)
    i = findfirst(x -> x.tag == "kml", doc_children)
    isnothing(i) && error("No <kml> tag found in file.")
    kml_element = doc_children[i]
    xml_children = XML.children(kml_element)
    kml_children = Vector{Union{XML.AbstractXMLNode,KMLElement}}(undef, length(xml_children))
    for (idx, child_node) in enumerate(xml_children)
        kml_children[idx] = object(child_node)
    end
    KMLFile(kml_children)
end

# ──────────────────────────────────────────────────────────────────────────────
#  KMx File Types
# ──────────────────────────────────────────────────────────────────────────────

abstract type KMxFileType end
struct KML_KMxFileType <: KMxFileType end
struct KMZ_KMxFileType <: KMxFileType end

# ──────────────────────────────────────────────────────────────────────────────
#  KMLFile reading - materializes all KML objects
# ──────────────────────────────────────────────────────────────────────────────

# Read from any IO stream
function Base.read(io::IO, ::Type{KMLFile})
    return XML.read(io, Node) |> _parse_kmlfile
end

# Internal helper for KMLFile reading from file path
function _read_file_from_path(::KML_KMxFileType, path::AbstractString)
    return XML.read(path, Node) |> _parse_kmlfile
end

# Read from KML or KMZ file path
function Base.read(path::AbstractString, ::Type{KMLFile})
    file_ext = lowercase(splitext(path)[2])
    if file_ext == ".kmz"
        # Check if extension is loaded
        if !hasmethod(_read_file_from_path, Tuple{KMZ_KMxFileType, AbstractString})
            error("KMZ support requires the KMLZipArchivesExt extension. Please load ZipArchives.jl first.")
        end
        return _read_file_from_path(KMZ_KMxFileType(), path)
    elseif file_ext == ".kml"
        return _read_file_from_path(KML_KMxFileType(), path)
    else
        error("Unsupported file extension: $file_ext. Only .kml and .kmz are supported.")
    end
end

# Parse KMLFile from string
Base.parse(::Type{KMLFile}, s::AbstractString) = _parse_kmlfile(XML.parse(s, Node))

# ─────────────────────────────────────────────────────────────────────────────
#  LazyKMLFile reading - just store the XML without materializing KML objects
# ─────────────────────────────────────────────────────────────────────────────

# Read LazyKMLFile from IO stream
function Base.read(io::IO, ::Type{LazyKMLFile})
    return XML.read(io, LazyNode) |> LazyKMLFile
end

# Internal helper for LazyKMLFile reading from file path
function _read_lazy_file_from_path(::KML_KMxFileType, path::AbstractString)
    doc = XML.read(path, LazyNode)
    return LazyKMLFile(doc)
end

# Read LazyKMLFile from file path
function Base.read(path::AbstractString, ::Type{LazyKMLFile})
    file_ext = lowercase(splitext(path)[2])
    if file_ext == ".kmz"
        # Check if extension is loaded
        if !hasmethod(_read_lazy_file_from_path, Tuple{KMZ_KMxFileType, AbstractString})
            error("KMZ support for LazyKMLFile requires the KMLZipArchivesExt extension. Please load ZipArchives.jl first.")
        end
        return _read_lazy_file_from_path(KMZ_KMxFileType(), path)
    elseif file_ext == ".kml"
        return _read_lazy_file_from_path(KML_KMxFileType(), path)
    else
        error("Unsupported file extension: $file_ext. Only .kml and .kmz are supported.")
    end
end

# Parse LazyKMLFile from string
Base.parse(::Type{LazyKMLFile}, s::AbstractString) = LazyKMLFile(XML.parse(s, LazyNode))

# ─────────────────────────────────────────────────────────────────────────────
#  KMZ reading error hinter
# ─────────────────────────────────────────────────────────────────────────────

function _read_kmz_file_from_path_error_hinter(io, exc, argtypes, kwargs)
    parent_module = parentmodule(@__MODULE__)
    # Check if this is a KMZ-related error
    if exc isa ErrorException && occursin("KMZ support", exc.msg)
        printstyled("\nKMZ support not available.\n"; color = :yellow, bold = true)
        printstyled("  - To enable KMZ support, you need to install and load the ZipArchives package:\n"; color = :yellow)
        println("    In the Julia REPL: ")
        printstyled("      1. "; color = :cyan)
        println("`using Pkg`")
        printstyled("      2. "; color = :cyan)
        println("`Pkg.add(\"ZipArchives\")` (if not already installed)")
        printstyled("      3. "; color = :cyan)
        println("`using ZipArchives` (before `using KML` or ensure it's in your project environment)")
        printstyled("  - If you don't need KMZ support, this warning can be ignored.\n"; color = :yellow)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
#  write back out (XML.write) for any of our core types
# ─────────────────────────────────────────────────────────────────────────────

# writable union for XML.write
const Writable = Union{KMLFile,KMLElement,XML.Node}

function Base.write(io::IO, o::Writable; kw...)
    XML.write(io, Node(o); kw...)
end

function Base.write(path::AbstractString, o::Writable; kw...)
    XML.write(path, Node(o); kw...)
end

Base.write(o::Writable; kw...) = Base.write(stdout, o; kw...)

# ─────────────────────────────────────────────────────────────────────────────
# XML.Node ←→ KMLElement
# ─────────────────────────────────────────────────────────────────────────────

typetag(T) = replace(string(T), r"([a-zA-Z]*\.)" => "", "_" => ":")

# KMLElement → Node
Node(o::T) where {T<:Enums.AbstractKMLEnum} = XML.Element(typetag(T), o.value)

function Node(o::T) where {names,T<:KMLElement{names}}
    tag = typetag(T)
    attributes = Dict(string(k) => string(getfield(o, k)) for k in names if !isnothing(getfield(o, k)))
    element_fields = filter(x -> !isnothing(getfield(o, x)), setdiff(fieldnames(T), names))
    isempty(element_fields) && return XML.Node(XML.Element, tag, attributes)
    children = Node[]
    for field in element_fields
        val = getfield(o, field)
        if field == :innerBoundaryIs
            push!(children, XML.Element(:innerBoundaryIs, Node.(val)))
        elseif field == :outerBoundaryIs
            push!(children, XML.Element(:outerBoundaryIs, Node(val)))
        elseif field == :coordinates
            push!(children, XML.Element("coordinates", coordinate_string(val)))
        elseif val isa KMLElement
            push!(children, Node(val))
        elseif val isa Vector{<:KMLElement}
            append!(children, Node.(val))
        else
            push!(children, XML.Element(field, val))
        end
    end
    return XML.Node(XML.Element, tag, attributes, nothing, children)
end

# ─────────────────────────────────────────────────────────────────────────────
# object() – main entry point for parsing XML nodes into KML objects
# ─────────────────────────────────────────────────────────────────────────────

const ENUM_NAMES_SET = Set(names(Enums; all = true))

# Fast object()  – deal with the handful of tags we care about
function object(node::XML.AbstractXMLNode)
    # Assuming 'node' is always an XML.Element when object() is called for KML types
    sym = tagsym(XML.tag(node))

    # ──  0. Structural tags (handled by add_element!) ─────────────────────────
    if sym === :outerBoundaryIs || sym === :innerBoundaryIs
        return nothing
    end

    # ──  1. Tags mapping directly to KML types via TAG_TO_TYPE ──────────────────
    if haskey(TAG_TO_TYPE, sym)
        T = TAG_TO_TYPE[sym]
        o = T()
        add_attributes!(o, node)
        node_children = XML.children(node)

        if T === Snippet || T === SimpleData
            if hasfield(T, :content) && fieldtype(T, :content) === String
                setfield!(o, :content, extract_text_content_fast(node))
            end
            # For Snippet, still process any element children
            if T === Snippet
                for child_element_node in node_children
                    if nodetype(child_element_node) === XML.Element
                        add_element!(o, child_element_node)
                    end
                end
            end
        else
            # Generic parsing of child ELEMENTS for all other KMLElement types
            for child_element_node in node_children
                if nodetype(child_element_node) === XML.Element
                    add_element!(o, child_element_node)
                end
            end
        end
        return o
    end

    # ──  2. Enums ───────────────────────────────────────────────────────────────
    if sym in ENUM_NAMES_SET
        text_content = extract_text_content_fast(node)
        if !isempty(text_content)
            return getproperty(Enums, sym)(text_content)
        else
            @warn "Enum tag <$(XML.tag(node))> did not contain text content."
            return nothing
        end
    end

    # ──  3. Simple leaf tags (handled if object() is called on them directly)
    if XML.is_simple(node)
        text_content = extract_text_content_fast(node)
        return isempty(text_content) ? nothing : text_content
    end

    # ──  4. Fallback ─────────────────────────────────────────────────────────────
    return _object_slow(node)
end

const KML_NAMES_SET = let
    # Collect all names from KML submodules
    all_names = Set{Symbol}()
    for mod in [Core, TimeElements, Components, Styles, Views, Geometries, Features]
        union!(all_names, names(mod; all = true, imported = false))
    end
    all_names
end

function _object_slow(node::XML.AbstractXMLNode)
    original_tag_name = XML.tag(node)
    sym = tagsym(original_tag_name)

    @debug "Entered _object_slow for tag: '$original_tag_name' (symbol: :$sym)"

    # Path 1: Is it an Enum that was perhaps missed by the main object() check?
    if sym in ENUM_NAMES_SET
        @debug "Tag '$original_tag_name' (symbol :$sym) is being parsed as an Enum by `_object_slow`"
        return getproperty(Enums, sym)(extract_text_content_fast(node))
    end

    # Path 2: Is it a KML type defined in the KML module but somehow missed by TAG_TO_TYPE?
    if sym in KML_NAMES_SET || sym == :Pair
        @warn begin
            "Performance Hint: KML type `:$sym` (from tag `'$original_tag_name'`) is being instantiated " *
            "via reflection in `_object_slow`. This is a fallback and less efficient.\n" *
            "ACTION: To improve performance and maintainability, ensure that the tag `'$original_tag_name'` " *
            "correctly maps to the Julia type in the `TAG_TO_TYPE` dictionary."
        end

        # Object instantiation logic - need to find the type in the parent module
        T = if hasproperty(Core, sym)
            getproperty(Core, sym)
        elseif hasproperty(TimeElements, sym)
            getproperty(TimeElements, sym)
        elseif hasproperty(Components, sym)
            getproperty(Components, sym)
        elseif hasproperty(Styles, sym)
            getproperty(Styles, sym)
        elseif hasproperty(Views, sym)
            getproperty(Views, sym)
        elseif hasproperty(Geometries, sym)
            getproperty(Geometries, sym)
        elseif hasproperty(Features, sym)
            getproperty(Features, sym)
        else
            error("Type $sym not found in any KML submodule")
        end
        
        o = T()
        add_attributes!(o, node)
        for child_xml_node in XML.children(node)
            add_element!(o, child_xml_node)
        end
        return o
    end

    # Path 3: Fallthrough - truly unhandled or unrecognized tag
    @warn "Unhandled Tag: `'$original_tag_name'` (symbol: `:$sym`). This tag was not recognized."
    return nothing
end

# -----------------------------------------------------------------------------
# Main add_element! function - now using the new field conversion system
# -----------------------------------------------------------------------------
function add_element!(parent::KMLElement, child_xml_node::XML.AbstractXMLNode)
    child_parsed_val = object(child_xml_node)

    if child_parsed_val isa KMLElement
        assign_complex_object!(parent, child_parsed_val, XML.tag(child_xml_node))
        return
    elseif child_parsed_val isa AbstractString
        field_name_sym = tagsym(XML.tag(child_xml_node))
        assign_field!(parent, field_name_sym, child_parsed_val, XML.tag(child_xml_node); parse_iso8601_fn=parse_iso8601)
        return
    else
        field_name_sym = tagsym(XML.tag(child_xml_node))

        # Special handling for Polygon boundaries
        if parent isa Polygon && (field_name_sym === :outerBoundaryIs || field_name_sym === :innerBoundaryIs)
            handle_polygon_boundary!(parent, child_xml_node, field_name_sym, object)
            return
        end

        # Check if it's a simple field that needs text extraction
        if hasfield(typeof(parent), field_name_sym) &&
           Base.nonnothingtype(fieldtype(typeof(parent), field_name_sym)) === String

            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node); parse_iso8601_fn=parse_iso8601)
            return

        elseif XML.is_simple(child_xml_node) && hasfield(typeof(parent), field_name_sym)
            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node); parse_iso8601_fn=parse_iso8601)
            return
        end

        @warn "Unhandled tag $field_name_sym (from XML <$(XML.tag(child_xml_node))>) for parent $(typeof(parent))"
    end
end

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

const _TAGSYM_CACHE = Dict{String,Symbol}()
const _COLON_TO_UNDERSCORE = r":" => "_"
function tagsym(x::String)
    get!(_TAGSYM_CACHE, x) do
        Symbol(replace(x, _COLON_TO_UNDERSCORE))
    end
end
tagsym(x::XML.AbstractXMLNode) = tagsym(XML.tag(x))

function add_attributes!(o::KMLElement, source::XML.AbstractXMLNode)
    attr = XML.attributes(source)
    isnothing(attr) && return

    tm = typemap(o)
    for (k, v) in attr
        startswith(k, "xmlns") && continue
        sym = tagsym(k)
        haskey(tm, sym) || continue
        
        # Use the field assignment system for attributes
        assign_field!(o, sym, v, k; parse_iso8601_fn=parse_iso8601)
    end
end