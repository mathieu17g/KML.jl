# turn an XML.Node into a KMLFile by finding the <kml> element
function KMLFile(doc::XML.Node)
    i = findfirst(x -> x.tag == "kml", XML.children(doc))
    isnothing(i) && error("No <kml> tag found in file.")
    KML.KMLFile(map(KML.object, XML.children(doc[i])))
end

# ─────────────────────────────────────────────────────────────────────────────
#  I/O glue: read/write KMLFile via XML
# ─────────────────────────────────────────────────────────────────────────────
# Internal helper: pull the <kml> element out of an XML.Document node
function _parse_kmlfile(doc::XML.Node)
    i = findfirst(x -> x.tag == "kml", XML.children(doc))
    isnothing(i) && error("No <kml> tag found in file.")
    xml_children = XML.children(doc[i])
    kml_children = Vector{Union{Node,KMLElement}}(undef, length(xml_children)) # Preallocate
    for (idx, child_node) in enumerate(xml_children)
        kml_children[idx] = object(child_node) # Populate
    end
    KMLFile(kml_children)
end

# Read from any IO stream
function Base.read(io::IO, ::Type{KMLFile})
    doc = xmlread(io, Node)        # parse into XML.Node
    _parse_kmlfile(doc)
end

abstract type KMxFileType end # Abstract type for KML/KMZ dispatch
struct KML_KMxFileType <: KMxFileType end # Marker for .kml files
struct KMZ_KMxFileType <: KMxFileType end # Marker for .kmz files

# Read from a filename
function _read_file_from_path(::KML_KMxFileType, path::AbstractString) # No type argument needed if always KMLFile
    return xmlread(path, Node) |> _parse_kmlfile
end

function _read_kmz_file_from_path_error_hinter(io, exc, argtypes, kwargs)
    if isnothing(Base.get_extension(KML, :KMLZipArchivesExt)) &&
       exc.f == _read_file_from_path &&
       first(argtypes) == KMZ_KMxFileType
        printstyled("\nKMZ reading via extension failed for '$(exc.args[2])'.\n"; color = :yellow, bold = true)
        printstyled("  - Ensure the KMLZipArchivesExt module is loaded and available.\n"; color = :yellow)
        printstyled(
            "  - To enable KMZ support, you might need to install and load the ZipArchives package:\n";
            color = :yellow,
        )
        println("    In the Julia REPL: ")
        printstyled("      1. "; color = :cyan)
        println("`using Pkg`")
        printstyled("      2. "; color = :cyan)
        println("`Pkg.add(\"ZipArchives\")` (if not already installed)")
        printstyled("      3. "; color = :cyan)
        println("`using ZipArchives` (before `using KML` or ensure it's in your project environment)")
        printstyled(
            "  - If you don't need KMZ support, this warning can be ignored or the extension potentially removed.\n";
            color = :yellow,
        )
    end
end

function Base.read(path::AbstractString, ::Type{KMLFile})
    file_ext = lowercase(splitext(path)[2])
    if file_ext == ".kmz"
        return _read_file_from_path(KMZ_KMxFileType(), path) # Dispatch for KMZ
    elseif file_ext == ".kml"
        return _read_file_from_path(KML_KMxFileType(), path) # Dispatch for KML
    else
        error("Unsupported file extension: $file_ext. Only .kml and .kmz are supported.")
    end
end

# Parse from an in-memory string
Base.parse(::Type{KMLFile}, s::AbstractString) = _parse_kmlfile(xmlparse(s, Node))

# ─────────────────────────────────────────────────────────────────────────────
#  write back out (XML.write) for any of our core types
# ─────────────────────────────────────────────────────────────────────────────

# writable union for XML.write
const Writable = Union{KMLFile,KMLElement,XML.Node}

function Base.write(io::IO, o::Writable; kw...)
    xmlwrite(io, Node(o); kw...)
end

function Base.write(path::AbstractString, o::Writable; kw...)
    xmlwrite(path, Node(o); kw...)
end

Base.write(o::Writable; kw...) = Base.write(stdout, o; kw...)

#-----------------------------------------------------------------------------# XML.Node ←→ KMLElement
typetag(T) = replace(string(T), r"([a-zA-Z]*\.)" => "", "_" => ":")

coordinate_string(x::Tuple) = join(x, ',')
coordinate_string(x::StaticArraysCore.SVector) = join(x, ',')
coordinate_string(x::Vector) = join(coordinate_string.(x), '\n')

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

#-----------------------------------------------------------------------------# object (or enum)

const ENUM_NAMES_SET = Set(names(Enums; all = true))             # Get all names in Enums

# Fast object()  – deal with the handful of tags we care about
function object(node::XML.Node)
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
        add_attributes!(o, node) # Assumes add_attributes! correctly uses XML.attributes(node)

        if T === Snippet || T === SimpleData # Add KML.SimpleData here
            if hasfield(T, :content) && fieldtype(T, :content) === String
                text_parts = String[]
                for child_node_val in XML.children(node) # Iterate children of <Snippet> or <SimpleData>
                    if nodetype(child_node_val) === XML.Text || nodetype(child_node_val) === XML.CData # Corrected
                        push!(text_parts, XML.value(child_node_val))
                    elseif nodetype(child_node_val) === XML.Element && T === KML.Snippet
                        # If Snippet specifically could have other defined element children for other fields
                        # add_element!(o, child_node_val) 
                    end
                end
                setfield!(o, :content, String(strip(join(text_parts))))
            end
            # If Snippet/SimpleData have other fields defined as KML elements (unlikely for SimpleData)
            if T === KML.Snippet # Or more generally, if T can have other element children for other fields
                for child_element_node in XML.children(node)
                    if nodetype(child_element_node) === XML.Element
                        # Avoid re-processing if content was formed from these elements above,
                        # this loop is for distinct other fields of Snippet if any.
                        # add_element!(o, child_element_node) # This line might need to be more selective
                    end
                end
            end
            # For Snippet and SimpleData, usually no further KML *element* children define other fields.
            # If they could, the generic loop below would be needed, but filtered.
        else
            # Generic parsing of *child ELEMENTS* for all other KMLElement types
            for child_element_node in XML.children(node)
                if nodetype(child_element_node) === XML.Element
                    add_element!(o, child_element_node)
                end
            end
        end
        return o
    end

    # ──  2. Enums ───────────────────────────────────────────────────────────────
    if sym in ENUM_NAMES_SET
        node_children = XML.children(node)
        # Enum tag <myEnum>value</myEnum> should have one XML.Text child.
        if length(node_children) == 1 && XML.nodetype(node_children[1]) === XML.Text # Correct type check
            return getproperty(Enums, sym)(XML.value(node_children[1]))
        else
            @warn "Enum tag <$(XML.tag(node))> did not contain simple text as expected."
            text_parts = [XML.value(c) for c in node_children if XML.nodetype(c) === XML.Text] # Correct type check
            if !isempty(text_parts)
                return getproperty(Enums, sym)(strip(join(text_parts)))
            else
                return nothing
            end
        end
    end

    # ──  3. Simple leaf tags (handled if object() is called on them directly)
    if XML.is_simple(node) # True if no attrs, one child, and that child is Text or CData
        single_child = only(XML.children(node)) # This is safe due to is_simple definition
        return String(XML.value(single_child)) # Correctly gets content of Text or CData
    end

    # ──  4. Fallback ─────────────────────────────────────────────────────────────
    return _object_slow(node)
end

const KML_NAMES_SET = Set(names(KML; all = true, imported = true)) # Get all names in KML

function _object_slow(node::XML.Node)
    original_tag_name = XML.tag(node)
    sym = tagsym(original_tag_name) # Convert "namespace:tag" to :namespace_tag or :tag

    # This debug message helps trace when this fallback is even entered.
    # To see @debug messages, run `using Logging; global_logger(ConsoleLogger(stderr, Logging.Debug))`
    # at the start of your Julia session or script.
    @debug "Entered _object_slow for tag: '$original_tag_name' (symbol: :$sym). This means the tag was not handled by:" sympath =
        ("  - Explicit structural tag checks (e.g., for :outerBoundaryIs) in `object()`") *
        "\n  - The primary `TAG_TO_TYPE` lookup in `object()`." *
        "\n  - The Enum check (using `ENUM_NAMES_SET`) in `object()`." *
        "\n  - The simple text content check (`XML.is_simple`) in `object()`."

    # Path 1: Is it an Enum that was perhaps missed by the main object() check?
    # (This check might be redundant if the main object() function's Enum check is robust
    #  and uses the same ENUM_NAMES_SET, but kept for safety or if _object_slow can be called from other paths)
    if sym in ENUM_NAMES_SET
        @debug (
            "Tag '$original_tag_name' (symbol :$sym) is being parsed as an Enum by `_object_slow`. " *
            "Consider if this specific Enum should also be optimized in the main `object` function's Enum handling path."
        )
        return getproperty(Enums, sym)(XML.value(only(node)))
    end

    # Path 2: Is it a KML type defined in the KML module but somehow missed by TAG_TO_TYPE?
    # This is the case where @info was previously used.
    if sym in KML_NAMES_SET || sym == :Pair # Assuming :Pair is a special KML-like type here
        @warn begin # Changed to @warn as this implies a missing optimization.
            "Performance Hint: KML type `:$sym` (from tag `'$original_tag_name'`) is being instantiated " *
            "via reflection in `_object_slow`. This is a fallback and less efficient.\n" *
            "ACTION: To improve performance and maintainability, ensure that the tag `'$original_tag_name'` " *
            "correctly maps to the Julia type `KML.$(sym)` in the `TAG_TO_TYPE` dictionary.\n" *
            "  - Verify that the Julia struct `KML.$(sym)` is a concrete subtype of `KMLElement` " *
            "so it's automatically collected by `_collect_concrete!`.\n" *
            "  - Or, if it's a special case, add a manual mapping for `:$sym` to `TAG_TO_TYPE` during initialization.\n" *
            "  - Double-check that `tagsym(\"$original_tag_name\")` produces exactly `:$sym` as expected for the dictionary key."
        end

        # Object instantiation logic
        T = getproperty(KML, sym)
        o = T()
        add_attributes!(o, node)
        for child_xml_node in XML.children(node) # Ensure children are processed
            add_element!(o, child_xml_node)
        end
        return o
    end

    # Path 3: Fallthrough - truly unhandled or unrecognized tag by this KML parser's logic.
    # This means object() will return 'nothing' for this tag.
    # This 'nothing' might be handled by special logic in `add_element!` (e.g., for unknown tags within a known parent),
    # or it might result in the tag being effectively ignored if no specific handling exists.
    @warn sprint() do io
        # General information about the unhandled tag
        println(io, "Unhandled Tag: `'$original_tag_name'` (symbol: `:$sym`).")
        println(io, "This tag was not recognized by the `_object_slow` fallback parser as a known KML type,")
        println(io, "Enum, or specific structural element. Consequently, `object()` will return `nothing` for this tag.")
        println(io) # Blank line for separation

        # Actionable advice for the developer
        println(io, "DEVELOPER ACTION: Please evaluate `'$original_tag_name'`:")

        # Option 1: Standard KML element
        println(io, "  1. Is it a standard KML element that should be parsed?")
        println(io, "     - If YES: Define a corresponding Julia struct, e.g.,")
        println(io, "         `struct $(uppercasefirst(string(sym))) <: KMLElement ... end`")
        println(io, "       and ensure it's mapped in `TAG_TO_TYPE` (this is often automatic for")
        println(io, "       concrete subtypes of `KMLElement`).")
        println(io) # Blank line

        # Option 2: Structural tag needing special handling
        println(io, "  2. Is it a structural tag (e.g., `<coordinates>`, `<outerBoundaryIs>`) requiring")
        println(io, "     special logic in `add_element!` after `object()` returns `nothing` for it?")
        println(io, "     - If YES, and not yet handled:")
        println(io, "       a. Consider modifying `object()` to return `nothing` for `:$sym` *before* `_object_slow`.")
        println(io, "          (e.g., `if sym === :$sym return nothing end`)")
        println(io, "       b. Ensure `add_element!` contains the necessary parsing logic for `:$sym`.")
        println(io) # Blank line

        # Option 3: Vendor-specific, deprecated, or intentionally unsupported
        println(io, "  3. Is this tag vendor-specific, deprecated, or intentionally unsupported?")
        println(io, "     - If YES: This warning might be acceptable. To suppress it for known, intentionally")
        println(io, "       ignored tags, consider modifying `object()` to return `nothing` silently for `:$sym`")
        println(io, "       (e.g., by adding `:$sym` to an explicit ignore list before the `_object_slow` call).")
    end
    return nothing
end

# ───  Coordinates parsing function using Automata.jl  ─────────────────────────────────────

# ------------------------------------------------------------------
# 1.  Build the regular expression that recognises a 2‑D or 3‑D
#     coordinate list of the form  "x,y[,z][ … repeated … ]"
# ------------------------------------------------------------------

#? const coord_number_re = rep1(re"[0-9.+\-Ee]+") # Alternative
const coord_number_re = rep1(re"[^\t\n\r ,]+")
const coord_delim_re = rep1(re"[\t\n\r ,]+")

const _coord_number_actions = onexit!(onenter!(coord_number_re, :mark), :number)

const _coord_machine_pattern =
    opt(coord_delim_re) * opt(_coord_number_actions * rep(coord_delim_re * _coord_number_actions)) * opt(coord_delim_re)

const COORDINATE_MACHINE = compile(_coord_machine_pattern)

# ------------------------------------------------------------------
# 2.  Action table used by the FSM — created once, marked `const`
# ------------------------------------------------------------------
const PARSE_OPTIONS = Parsers.Options()#delim=nothing, quoted=false, stripwhitespace = false)
const AUTOMA_COORD_ACTIONS = Dict{Symbol,Expr}(
    # save the start position of a number
    :mark => :(current_mark = p),

    # convert the byte slice to Float64 and push!
    :number => quote
        #? println("Parsing: ", String(view(data_bytes, current_mark:p-1)))
        push!(results_vector, Parsers.parse(Float64, view(data_bytes, current_mark:p-1), PARSE_OPTIONS))
    end,
)

# ------------------------------------------------------------------
# 3.  Generate the low‑level FSM driver exactly once
#     and store it in the module’s global scope.
# ------------------------------------------------------------------

let ctx = CodeGenContext(vars = Variables(data = :data_bytes), generator = :goto)
    eval(quote
        function __core_automa_parser(data_bytes::AbstractVector{UInt8}, results_vector::Vector{Float64})
            current_mark = 0

            $(generate_init_code(ctx, COORDINATE_MACHINE))

            p_end = sizeof(data_bytes)
            p_eof = p_end

            $(generate_exec_code(ctx, COORDINATE_MACHINE, AUTOMA_COORD_ACTIONS))

            return cs          # final machine state
        end
    end)
end

# ------------------------------------------------------------------
# 4.  High‑level convenience wrapper
# ------------------------------------------------------------------

"""
    _parse_coordinates_automa(txt::AbstractString)

Parse a KML/GeoRSS-style coordinate string and return a vector of
`SVector{3,Float64}` (if the list length is divisible by 3) **or**
`SVector{2,Float64}` (if divisible by 2).
"""
function _parse_coordinates_automa(txt::AbstractString)
    parsed_floats = Float64[]
    # sizehint! does not bring any speedup here
    final_state = __core_automa_parser(codeunits(txt), parsed_floats)

    # --- basic FSM state checks -------------------------------------------------
    if final_state < 0
        error("Coordinate string is malformed (FSM error state $final_state).")
    end
    #? Check below if the FSM ended in a valid state dropping garbage at the end the string
    #? This check is overly strict and is not done for now (May 2025)
    # if final_state > 0 && !(final_state == COORDINATE_MACHINE.start_state && isempty(txt))
    #     error("Coordinate string is incomplete or has trailing garbage (FSM state $final_state).")
    # end

    # --- assemble SVectors ------------------------------------------------------
    len = length(parsed_floats)

    if len == 0
        return SVector{0,Float64}[]
    elseif len % 3 == 0
        n = len ÷ 3
        result = Vector{SVector{3,Float64}}(undef, n)
        @inbounds for i = 1:n
            off = (i - 1) * 3
            result[i] = SVector{3,Float64}(parsed_floats[off+1], parsed_floats[off+2], parsed_floats[off+3])
        end
        return result
    elseif len % 2 == 0
        n = len ÷ 2
        result = Vector{SVector{2,Float64}}(undef, n)
        @inbounds for i = 1:n
            off = (i - 1) * 2
            result[i] = SVector{2,Float64}(parsed_floats[off+1], parsed_floats[off+2])
        end
        return result
    else # len is not 0 and not a multiple of 2 or 3
        if !isempty(txt) && !all(isspace, txt)
            snippet = first(txt, min(50, lastindex(txt)))
            @warn "Parsed $len numbers from \"$snippet…\", which is not a multiple of 2 or 3. Returning empty coordinates." maxlog =
                1
        end
        return SVector{0,Float64}[] # Return empty instead of erroring
    end
end

# -----------------------------------------------------------------------------
# Main add_element! function (now much shorter)
# -----------------------------------------------------------------------------
function add_element!(parent::Union{KML.Object,KML.KMLElement}, child_xml_node::XML.Node)
    child_parsed_val = object(child_xml_node) # Returns KML.KMLElement, String, or nothing

    if child_parsed_val isa KML.KMLElement
        _assign_complex_kml_object!(parent, child_parsed_val, XML.tag(child_xml_node))
        return
    elseif child_parsed_val isa String
        # object() parsed child_xml_node into a simple String value.
        # The tag name of child_xml_node itself is the field in 'parent'.
        field_name_sym = tagsym(XML.tag(child_xml_node))
        _convert_and_set_simple_field!(parent, field_name_sym, child_parsed_val, XML.tag(child_xml_node))
        return
    else # child_parsed_val is nothing (or unexpected type)
        # This means child_xml_node is structural, a simple field that object() didn't pre-parse to string,
        # or an unhandled tag.
        field_name_sym = tagsym(XML.tag(child_xml_node)) # child_xml_node is, e.g., <description>

        if parent isa KML.Polygon && (field_name_sym === :outerBoundaryIs || field_name_sym === :innerBoundaryIs)
            _handle_polygon_boundary!(parent, child_xml_node, field_name_sym)
            return
        end

        # Check if the parent expects a String for this field name.
        # This should catch <description>, <text> in BalloonStyle, etc.
        if hasfield(typeof(parent), field_name_sym) &&
           Base.nonnothingtype(fieldtype(typeof(parent), field_name_sym)) === String

            # Aggressively get all inner content as a string, including serializing child HTML elements.
            buffer = IOBuffer()
            for content_child_node in XML.children(child_xml_node) # Iterate children of <description>
                # XML.jl's print method for Node should serialize it back to XML string form
                print(buffer, content_child_node)
            end
            text_content_for_field = String(strip(String(take!(buffer))))

            # If the tag was truly empty (e.g., <description/>), children might be empty.
            if isempty(XML.children(child_xml_node)) && isempty(text_content_for_field)
                text_content_for_field = ""
            end

            # Call _convert_and_set_simple_field!, which will just assign the string
            # as the target type is String.
            _convert_and_set_simple_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return

            # Fallback for other simple fields (if XML.is_simple is true and it wasn't a String field above)
        elseif XML.is_simple(child_xml_node) && hasfield(typeof(parent), field_name_sym)
            # child_xml_node has no attributes and exactly one Text or CData child.
            single_child = only(XML.children(child_xml_node)) # Known to be Text or CData
            text_content_for_field = String(XML.value(single_child))

            _convert_and_set_simple_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return
        end

        # If still unhandled
        @warn "Unhandled tag $field_name_sym (from XML <$(XML.tag(child_xml_node))>) for parent $(typeof(parent)). `object()` returned `nothing`, and it wasn't a recognized simple field or handled structural tag."
    end
end

# -----------------------------------------------------------------------------
# Helper Function: Assigning parsed KML.KMLElement objects
# -----------------------------------------------------------------------------
function _assign_complex_kml_object!(
    parent::Union{KML.Object,KML.KMLElement},
    child_kml_object::KML.KMLElement,
    child_xml_tag_str::String,
)
    T_child_obj = typeof(child_kml_object)
    assigned = false
    for (field_name_sym, field_type_in_parent) in typemap(parent)
        if T_child_obj <: field_type_in_parent
            setfield!(parent, field_name_sym, child_kml_object)
            assigned = true
            break
        elseif field_type_in_parent <: AbstractVector && T_child_obj <: eltype(field_type_in_parent)
            vec = getfield(parent, field_name_sym)
            if vec === nothing
                setfield!(parent, field_name_sym, eltype(field_type_in_parent)[])
                vec = getfield(parent, field_name_sym)
            end
            push!(vec, child_kml_object)
            assigned = true
            break
        end
    end
    if !assigned
        @warn "Parsed KML object of type $(T_child_obj) (from tag <$(child_xml_tag_str)>) could not be assigned to any compatible field in parent $(typeof(parent)). Review type definitions."
    end
end

# -----------------------------------------------------------------------------
# Helper Function: Converting string values and setting simple fields
# Main Dispatcher for Simple Fields
# -----------------------------------------------------------------------------
function _convert_and_set_simple_field!(
    parent::Union{KML.Object,KML.KMLElement},
    field_name_sym::Symbol,
    raw_text_from_kml::String,
    child_xml_tag_str::String, # Original XML tag string for warnings
)
    # Field name mapping for KML <begin>/<end> tags to Julia :begin_/:end_ fields
    true_field_name = field_name_sym
    if parent isa KML.TimeSpan # Specific to TimeSpan parent
        if field_name_sym === :begin
            true_field_name = :begin_
        end
        if field_name_sym === :end
            true_field_name = :end_
        end
    end

    if !hasfield(typeof(parent), true_field_name)
        @warn "Tag <$(child_xml_tag_str)> resolved by object() to String '$(raw_text_from_kml)', but no field named '$field_name_sym' (or mapped '$true_field_name') exists in parent of type $(typeof(parent))." [
            cite:190,
            384,
            500,
        ]
        return
    end

    ftype_original = fieldtype(typeof(parent), true_field_name)
    processed_string_val = String(raw_text_from_kml)

    # Handle empty string for optional fields at the top level
    if isempty(processed_string_val) && Nothing <: ftype_original
        setfield!(parent, true_field_name, nothing)
        return
    end

    # Dispatch to vector or scalar handler
    # Base.nonnothingtype is used because ftype_original could be Union{Nothing, Vector{...}} or Union{Nothing, ScalarType}
    non_nothing_ftype = Base.nonnothingtype(ftype_original)

    if true_field_name === :coordinates || true_field_name === :gx_coord
        parsed_coords_vec = _parse_coordinates_automa(processed_string_val) # 
        final_val_to_set = nothing
        if isempty(parsed_coords_vec)
            final_val_to_set =
                Nothing <: ftype_original ? nothing : (non_nothing_ftype <: AbstractVector ? non_nothing_ftype() : nothing) # 
        elseif non_nothing_ftype <: Union{KML.Coord2,KML.Coord3} # For Point.coordinates
            if length(parsed_coords_vec) == 1
                final_val_to_set = convert(non_nothing_ftype, parsed_coords_vec[1]) # 
            else
                @warn "Point field $true_field_name expected 1 coordinate, got $(length(parsed_coords_vec)). Assigning $(Nothing <: ftype_original ? "nothing" : "first if possible")." # 
                final_val_to_set =
                    Nothing <: ftype_original ? nothing :
                    (length(parsed_coords_vec) >= 1 ? convert(non_nothing_ftype, parsed_coords_vec[1]) : nothing) # 
            end
        elseif non_nothing_ftype <: AbstractVector # For LineString.coordinates, LinearRing.coordinates etc.
            final_val_to_set = convert(non_nothing_ftype, parsed_coords_vec) # 
        else
            @warn "Unhandled type $non_nothing_ftype for coordinate field $true_field_name parsing '$processed_string_val'" # 
            final_val_to_set = processed_string_val # Fallback
        end
        setfield!(parent, true_field_name, final_val_to_set)
        return # Coordinates handled

    # Dispatch to vector or scalar handler for other simple types
    elseif non_nothing_ftype <: AbstractVector && let el_type = eltype(non_nothing_ftype) # Check element type of the vector
        # Ensure this logic correctly identifies vectors of simple, non-KMLElement types
        # Example: true if el_type is String, Int, or the TimeUnion.
        # This was the previous condition: !(el_type <: KML.KMLElement)
        # A more specific check might be better:
        Base.nonnothingtype(el_type) === String ||
            Base.nonnothingtype(el_type) <: Integer ||
            Base.nonnothingtype(el_type) <: AbstractFloat ||
            Base.nonnothingtype(el_type) <: Bool ||
            Base.nonnothingtype(el_type) <: KML.Enums.AbstractKMLEnum ||
            el_type == Union{TimeZones.ZonedDateTime,Dates.Date,String} ||
            el_type == Union{Dates.Date,TimeZones.ZonedDateTime,String} ||
            el_type == Union{TimeZones.ZonedDateTime,String,Dates.Date} ||
            el_type == Union{String,TimeZones.ZonedDateTime,Dates.Date} ||
            el_type == Union{Dates.Date,String,TimeZones.ZonedDateTime} ||
            el_type == Union{String,Dates.Date,TimeZones.ZonedDateTime}
    end
        _parse_and_append_to_simple_vector!(
            parent,
            true_field_name,
            ftype_original,
            non_nothing_ftype,
            processed_string_val,
            child_xml_tag_str,
        )
    else # It's a scalar field (and not coordinates)
        _parse_and_set_scalar_field!(
            parent,
            true_field_name,
            ftype_original,
            non_nothing_ftype,
            processed_string_val,
            child_xml_tag_str,
        )
    end
end

# -----------------------------------------------------------------------------
# Helper Function: Parse and Append to a Vector of Simple Types
# -----------------------------------------------------------------------------
function _parse_and_append_to_simple_vector!(
    parent::Union{KML.Object,KML.KMLElement},
    true_field_name::Symbol,
    ftype_original::Type, # Original field type, e.g., Union{Nothing, Vector{Union{ZonedDateTime,Date,String}}}
    vec_type::Type,       # Non-nothing vector type, e.g., Vector{Union{ZonedDateTime,Date,String}}
    processed_string_val::String, # The string value of *one* child XML tag (e.g., one <when> tag)
    child_xml_tag_str::String,
)
    el_type_original = eltype(vec_type) # Element type, e.g., Union{ZonedDateTime,Date,String}
    actual_el_type = Base.nonnothingtype(el_type_original) # Non-nothing element type for parsing

    parsed_element_val = nothing

    # Handle empty string for an element if the element type itself can be Nothing
    # (This check is also at the top of _convert_and_set_simple_field!, but specific to element here)
    if isempty(processed_string_val) && Nothing <: el_type_original
        parsed_element_val = nothing
        # TimePrimitive Union handling for vector elements
    elseif el_type_original == Union{TimeZones.ZonedDateTime,Dates.Date,String} ||
           el_type_original == Union{Dates.Date,TimeZones.ZonedDateTime,String} ||
           el_type_original == Union{TimeZones.ZonedDateTime,String,Dates.Date} ||
           el_type_original == Union{String,TimeZones.ZonedDateTime,Dates.Date} ||
           el_type_original == Union{Dates.Date,String,TimeZones.ZonedDateTime} ||
           el_type_original == Union{String,Dates.Date,TimeZones.ZonedDateTime}

        parsed_time_successfully_for_vector = false
        try
            parsed_element_val = TimeZones.ZonedDateTime(processed_string_val)
            parsed_time_successfully_for_vector = true
        catch e_zoned_vec
            try
                parsed_element_val = Dates.Date(processed_string_val)
                parsed_time_successfully_for_vector = true
            catch e_date_vec
                try
                    parsed_element_val = Dates.DateTime(processed_string_val) # KML dateTime can include time
                    parsed_time_successfully_for_vector = true
                catch e_datetime_vec
                    if (length(processed_string_val) == 4 && occursin(r"^\d{4}$", processed_string_val)) ||
                       (length(processed_string_val) == 7 && occursin(r"^\d{4}-\d{2}$", processed_string_val))
                        parsed_element_val = processed_string_val # Store YYYY or YYYY-MM as String
                        parsed_time_successfully_for_vector = true
                        @info "Storing KML partial date '$processed_string_val' as String element for vector field $true_field_name."
                    else
                        @warn "Failed to parse '$processed_string_val' as ZonedDateTime, Date, or DateTime for vector element in field $true_field_name. Storing as raw string. Errors: ZDT: $e_zoned_vec, Date: $e_date_vec, DT: $e_datetime_vec"
                        parsed_element_val = processed_string_val
                        parsed_time_successfully_for_vector = true
                    end
                end
            end
        end
        if !parsed_time_successfully_for_vector && !(Nothing <: el_type_original && isempty(processed_string_val))
            @warn "Final fallback for time vector element field $true_field_name with value '$processed_string_val', storing as string."
            parsed_element_val = processed_string_val
        end
        # Other simple types for vector elements
    else
        if actual_el_type === String
            parsed_element_val = processed_string_val
        elseif actual_el_type <: Integer
            parsed_element_val =
                isempty(processed_string_val) ? (Nothing <: el_type_original ? nothing : zero(actual_el_type)) :
                Parsers.parse(actual_el_type, processed_string_val)
        elseif actual_el_type <: AbstractFloat
            parsed_element_val =
                isempty(processed_string_val) ? (Nothing <: el_type_original ? nothing : zero(actual_el_type)) :
                Parsers.parse(actual_el_type, processed_string_val)
        elseif actual_el_type <: Bool
            len_el = length(processed_string_val)
            if len_el == 1
                parsed_element_val = (processed_string_val[1] == '1')
            elseif len_el == 4 && uppercase(processed_string_val) == "TRUE"
                parsed_element_val = true
            elseif len_el == 5 && uppercase(processed_string_val) == "FALSE"
                parsed_element_val = false
            else
                parsed_element_val = (Nothing <: el_type_original ? nothing : false)
            end
        elseif actual_el_type <: KML.Enums.AbstractKMLEnum
            parsed_element_val =
                isempty(processed_string_val) && Nothing <: el_type_original ? nothing : actual_el_type(processed_string_val)
        else
            @warn "Unhandled element type $actual_el_type for vector field $true_field_name. Storing raw string '$processed_string_val' for element."
            parsed_element_val = processed_string_val # Fallback to string
        end
    end

    # Get or initialize the vector in the parent object
    current_vector = getfield(parent, true_field_name)
    if current_vector === nothing
        # Initialize with an empty vector. The eltype of `vec_type` is `el_type_original`.
        new_empty_vector = el_type_original[] # This creates Vector{UnionProperty{Nothing, ZonedDateTime, Date, String}} for instance
        setfield!(parent, true_field_name, new_empty_vector)
        current_vector = new_empty_vector
    end

    # Push the parsed element, respecting if `parsed_element_val` is `nothing` and the vector's eltype allows `Nothing`
    if parsed_element_val !== nothing || (Nothing <: el_type_original)
        push!(current_vector, parsed_element_val)
    elseif !isempty(processed_string_val)
        @warn "Could not push unparsed non-empty value '$processed_string_val' into vector for $true_field_name as element type $el_type_original does not allow it or parsing failed."
    end
end


# -----------------------------------------------------------------------------
# Helper Function: Parse and Set a Scalar Simple Field
# -----------------------------------------------------------------------------
function _parse_and_set_scalar_field!(
    parent::Union{KML.Object,KML.KMLElement},
    true_field_name::Symbol,
    ftype_original::Type,    # Original field type from struct, e.g. Union{Nothing, String}
    non_nothing_ftype::Type, # Result of Base.nonnothingtype(ftype_original), e.g. String
    processed_string_val::String,
    child_xml_tag_str::String,
)
    final_val_to_set = nothing # Initialize

    # Note: The case for `isempty(processed_string_val) && Nothing <: ftype_original`
    # is handled in the main _convert_and_set_simple_field! before dispatching here.
    # So, if we are here and processed_string_val is empty, it means the field is NOT optional.

    # TimePrimitive handling for SCALAR fields (Union{TimeZones.ZonedDateTime, Dates.Date, String})
    if non_nothing_ftype == Union{TimeZones.ZonedDateTime,Dates.Date,String} ||
       non_nothing_ftype == Union{Dates.Date,TimeZones.ZonedDateTime,String} || # Order variations
       non_nothing_ftype == Union{TimeZones.ZonedDateTime,String,Dates.Date} ||
       non_nothing_ftype == Union{String,TimeZones.ZonedDateTime,Dates.Date} ||
       non_nothing_ftype == Union{Dates.Date,String,TimeZones.ZonedDateTime} ||
       non_nothing_ftype == Union{String,Dates.Date,TimeZones.ZonedDateTime}

        parsed_time_successfully = false
        try
            final_val_to_set = TimeZones.ZonedDateTime(processed_string_val)
            parsed_time_successfully = true
        catch e_zoned
            try
                final_val_to_set = Dates.Date(processed_string_val)
                parsed_time_successfully = true
            catch e_date
                try
                    final_val_to_set = Dates.DateTime(processed_string_val)
                    parsed_time_successfully = true
                catch e_datetime
                    if (length(processed_string_val) == 4 && occursin(r"^\d{4}$", processed_string_val)) ||
                       (length(processed_string_val) == 7 && occursin(r"^\d{4}-\d{2}$", processed_string_val))
                        final_val_to_set = processed_string_val
                        parsed_time_successfully = true
                        @info "Storing KML partial date '$processed_string_val' as String for scalar field $true_field_name."
                    else
                        @warn "Failed to parse '$processed_string_val' as ZonedDateTime, Date, or DateTime for scalar field $true_field_name. Storing as raw string. Errors: ZDT: $e_zoned, Date: $e_date, DT: $e_datetime"
                        final_val_to_set = processed_string_val
                        parsed_time_successfully = true
                    end
                end
            end
        end
        if !parsed_time_successfully && !(Nothing <: ftype_original && isempty(processed_string_val)) # Redundant check, already handled
            @warn "Final fallback for time field $true_field_name with value '$processed_string_val', storing as string."
            final_val_to_set = processed_string_val
        end
    else # Other scalar types
        # `non_nothing_ftype` here is the actual_type_scalar from your previous version
        if non_nothing_ftype === String
            final_val_to_set = processed_string_val
        elseif non_nothing_ftype <: Integer
            final_val_to_set =
                isempty(processed_string_val) ? (Nothing <: ftype_original ? nothing : zero(non_nothing_ftype)) :
                Parsers.parse(non_nothing_ftype, processed_string_val)
        elseif non_nothing_ftype <: AbstractFloat
            final_val_to_set =
                isempty(processed_string_val) ? (Nothing <: ftype_original ? nothing : zero(non_nothing_ftype)) :
                Parsers.parse(non_nothing_ftype, processed_string_val)
        elseif non_nothing_ftype <: Bool
            len = length(processed_string_val)
            if len == 1
                final_val_to_set = (processed_string_val[1] == '1')
            elseif len == 4 && uppercase(processed_string_val) == "TRUE"
                final_val_to_set = true
            elseif len == 5 && uppercase(processed_string_val) == "FALSE"
                final_val_to_set = false
            else
                final_val_to_set = (Nothing <: ftype_original ? nothing : false)
            end
        elseif non_nothing_ftype <: KML.Enums.AbstractKMLEnum
            final_val_to_set =
                isempty(processed_string_val) && Nothing <: ftype_original ? nothing :
                non_nothing_ftype(processed_string_val)
        elseif true_field_name === :coordinates || true_field_name === :gx_coord
            parsed_coords_vec = _parse_coordinates_automa(processed_string_val)
            if isempty(parsed_coords_vec)
                final_val_to_set =
                    Nothing <: ftype_original ? nothing :
                    (non_nothing_ftype <: AbstractVector ? non_nothing_ftype() : nothing)
            elseif non_nothing_ftype <: Union{KML.Coord2,KML.Coord3}
                if length(parsed_coords_vec) == 1
                    final_val_to_set = convert(non_nothing_ftype, parsed_coords_vec[1])
                else
                    @warn "Point field $true_field_name expected 1 coordinate, got $(length(parsed_coords_vec)). Assigning $(Nothing <: ftype_original ? "nothing" : "first if possible")."
                    final_val_to_set =
                        Nothing <: ftype_original ? nothing :
                        (length(parsed_coords_vec) >= 1 ? convert(non_nothing_ftype, parsed_coords_vec[1]) : nothing)
                end
            elseif non_nothing_ftype <: AbstractVector # This is for scalar fields, so this might be an odd case unless it's for single SVector
                final_val_to_set = convert(non_nothing_ftype, parsed_coords_vec)
            else
                @warn "Unhandled type $non_nothing_ftype for coordinate field $true_field_name parsing '$processed_string_val'"
                final_val_to_set = processed_string_val
            end
        else
            @warn "Tag <$(child_xml_tag_str)> (field '$true_field_name') was string '$processed_string_val'. Unhandled conversion for $non_nothing_ftype (original: $ftype_original). Storing as String if field type allows."
            if non_nothing_ftype === String || (Nothing <: ftype_original && non_nothing_ftype === String)
                final_val_to_set = processed_string_val
            elseif Nothing <: ftype_original
                final_val_to_set = nothing
                @warn "Could not parse '$processed_string_val' for optional field $true_field_name::$(ftype_original), setting to nothing."
            else
                error(
                    "Cannot convert string '$processed_string_val' to required type $non_nothing_ftype for non-optional, non-string field $true_field_name.",
                )
            end
        end
    end
    setfield!(parent, true_field_name, final_val_to_set)
end

# -----------------------------------------------------------------------------
# Helper Function: Handling Polygon Boundaries
# -----------------------------------------------------------------------------
function _handle_polygon_boundary!(parent_polygon::KML.Polygon, boundary_xml_node::XML.Node, boundary_type_sym::Symbol)
    # boundary_xml_node is <outerBoundaryIs> or <innerBoundaryIs>
    # boundary_type_sym is :outerBoundaryIs or :innerBoundaryIs

    element_children_of_boundary = [
        c for c in XML.children(boundary_xml_node) if nodetype(c) === XML.Element # Or your XML.jl equivalent
    ]

    if boundary_type_sym === :outerBoundaryIs
        if length(element_children_of_boundary) == 1
            lr_xml_node = element_children_of_boundary[1]
            if tagsym(XML.tag(lr_xml_node)) === :LinearRing
                lr_kml_obj = object(lr_xml_node)
                if lr_kml_obj isa KML.LinearRing
                    setfield!(parent_polygon, :outerBoundaryIs, lr_kml_obj)
                else
                    @warn "<outerBoundaryIs> content <$(XML.tag(lr_xml_node))> did not parse to KML.LinearRing. Got: $(typeof(lr_kml_obj))"
                end
            else
                @warn "<outerBoundaryIs> for Polygon expected <LinearRing> child, got <$(XML.tag(lr_xml_node))>"
            end
        else
            @warn "<outerBoundaryIs> for Polygon did not contain exactly one element child. Found $(length(element_children_of_boundary)) elements: $([XML.tag(el) for el in element_children_of_boundary])"
        end
    elseif boundary_type_sym === :innerBoundaryIs # Lenient parsing for multiple LinearRings
        if isempty(element_children_of_boundary)
            @warn "<innerBoundaryIs> for Polygon contained no element children."
        else
            if getfield(parent_polygon, :innerBoundaryIs) === nothing
                setfield!(parent_polygon, :innerBoundaryIs, KML.LinearRing[])
            end
            rings_processed_count = 0
            for lr_xml_node in element_children_of_boundary
                if tagsym(XML.tag(lr_xml_node)) === :LinearRing
                    lr_kml_obj = object(lr_xml_node)
                    if lr_kml_obj isa KML.LinearRing
                        push!(getfield(parent_polygon, :innerBoundaryIs), lr_kml_obj)
                        rings_processed_count += 1
                    else
                        @warn "Child <$(XML.tag(lr_xml_node))> of <innerBoundaryIs> did not parse to KML.LinearRing. Got: $(typeof(lr_kml_obj))"
                    end
                else
                    @warn "<innerBoundaryIs> for Polygon contained unexpected element <$(XML.tag(lr_xml_node))>. Only <LinearRing> children are expected."
                end
            end
            if length(element_children_of_boundary) > 1 && rings_processed_count > 0
                @info "Leniently processed $rings_processed_count LinearRing(s) from a single <innerBoundaryIs> tag that contained $(length(element_children_of_boundary)) elements (KML standard expects one LinearRing per <innerBoundaryIs>)." maxlog =
                    1
            elseif rings_processed_count == 0 && !isempty(element_children_of_boundary)
                @warn "No valid LinearRings were processed from <innerBoundaryIs> that had $(length(element_children_of_boundary)) element children: $([XML.tag(el) for el in element_children_of_boundary])"
            elseif rings_processed_count != length(element_children_of_boundary)
                @warn "Not all children of <innerBoundaryIs> were valid LinearRings. Processed $rings_processed_count of $(length(element_children_of_boundary)) elements."
            end
        end
    end
end

const _TAGSYM_CACHE = Dict{String,Symbol}()
function tagsym(x::String)
    # Use get! to look up the string in the cache.
    # If not found, compute it (replace ':' and convert to Symbol),
    # store it in the cache, and then return it.
    get!(_TAGSYM_CACHE, x) do
        Symbol(replace(x, ':' => '_'))
    end
end
tagsym(x::Node) = tagsym(XML.tag(x))

function add_attributes!(o::Union{Object,KMLElement}, source::Node)
    attr = XML.attributes(source)
    isnothing(attr) && return

    tm = typemap(o)                             # cached Dict
    for (k, v) in attr
        startswith(k, "xmlns") && continue      # skip namespace decls
        sym = tagsym(k)
        haskey(tm, sym) || continue             # skip unknown attrs
        autosetfield!(o, sym, v)
    end
end

function autosetfield!(o::Union{Object,KMLElement}, sym::Symbol, txt::String)
    ftype = typemap(o)[sym]

    val = if ftype <: AbstractString
        txt
    elseif ftype <: Integer
        txt == "" ? zero(ftype) : parse(ftype, txt)
    elseif ftype <: AbstractFloat
        txt == "" ? zero(ftype) : parse(ftype, txt)
    elseif ftype <: Bool
        len = length(txt)
        if len == 1
            txt[1] == '1'
            # KML spec often uses "true"/"false" as well as "1"/"0"
        elseif len == 4 && # "true"
               (txt[1] == 't' || txt[1] == 'T') &&
               (txt[2] == 'r' || txt[2] == 'R') &&
               (txt[3] == 'u' || txt[3] == 'U') &&
               (txt[4] == 'e' || txt[4] == 'E')
            true
        elseif len == 5 && # "false"
               (txt[1] == 'f' || txt[1] == 'F') &&
               (txt[2] == 'a' || txt[2] == 'A') &&
               (txt[3] == 'l' || txt[3] == 'L') &&
               (txt[4] == 's' || txt[4] == 'S') &&
               (txt[5] == 'e' || txt[5] == 'E')
            false
        else
            # Fallback for "0" or other KML-valid representations if necessary,
            # or treat as false/error for non-standard.
            # Assuming "0" should also be false if not "1" or "true":
            false # Or: error("Invalid KML boolean string: '$txt'")
        end
    elseif ftype <: Enums.AbstractKMLEnum
        ftype(txt)
    elseif fname === :coordinates
        vec = _parse_coordinates_automa(txt)
        val = (ftype <: Union{Nothing,Tuple}) ? first(vec) : vec
    else
        txt   # last‑ditch: store the raw string
    end

    setfield!(o, sym, val)
    return
end
