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
    sym = tagsym(node)
    # ──  0. tags that ARE NOT KML types themselves ───────────────────────────
    if sym === :outerBoundaryIs || sym === :innerBoundaryIs
        return nothing
    end
    # ──  1. tags that map straight to KML types  ─────────────────────────────
    if haskey(TAG_TO_TYPE, sym)
        T = TAG_TO_TYPE[sym]
        o = T()                             # no reflection
        add_attributes!(o, node)
        for child in XML.children(node)
            add_element!(o, child)
        end
        return o
    end
    # ──  2. enums  ───────────────────────────────────────────────────────────
    if sym in ENUM_NAMES_SET
        return getproperty(Enums, sym)(XML.value(only(node)))
    end
    # ──  3. <name>, <description>, … fast scalar leafs  ──────────────────────
    if XML.is_simple(node)
        return XML.value(only(node))        # plain text
    end
    # ──  4. fallback to the generic code with logging  ───────────────────────
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
    @warn begin
        "Unhandled Tag: Tag `'$original_tag_name'` (symbol `:$sym`) was not recognized as a known KML type, " *
        "Enum, or handled structural element by `_object_slow`. `object()` will return `nothing`.\n" *
        "DEVELOPER ACTION: Evaluate this tag:\n" *
        "  1. Is `'$original_tag_name'` a standard KML element that this parser should support?\n" *
        "     - If YES: Define a corresponding Julia struct (e.g., `struct $(uppercasefirst(string(sym))) <: KMLElement ... end`), " *
        "       and ensure it's added to `TAG_TO_TYPE` (usually automatic if it's a concrete subtype of `KMLElement`).\n" *
        "  2. Is `'$original_tag_name'` a structural tag (like `<coordinates>`, `<outerBoundaryIs>`) that needs special " *
        "     parsing logic within `add_element!` after `object()` returns `nothing`?\n" *
        "     - If YES, and it's not already handled: The main `object()` function should ideally return `nothing` for it *before* " *
        "       calling `_object_slow` (by adding an explicit check `if sym === :$sym return nothing end`). " *
        "       Then, ensure `add_element!` has the required logic for `:$sym`.\n" *
        "  3. Is this tag vendor-specific, deprecated, or intentionally unsupported?\n" *
        "     - If YES: This warning might be acceptable, or you could add `:$sym` to a list of known-to-ignore tags " *
        "       in the main `object()` function to suppress this warning for common, intentionally ignored tags."
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
    else
        snippet = first(txt, min(50, lastindex(txt)))
        error("Parsed $len numbers from \"$snippet…\", which is not a multiple of 2 or 3.")
    end
end

function add_element!(parent::Union{Object,KMLElement}, child::XML.Node)
    # ── 0. pre‑compute a few things ───────────────────────────────
    fname = tagsym(child.tag)                     # tag → field name
    simple = XML.is_simple(child)

    # ── 1. *Scalar* leaf node (fast path) ─────────────────────────
    if simple
        hasfield(typeof(parent), fname) || return       # ignore strangers

        txt = XML.value(XML.only(child))                # raw text
        ftype = typemap(typeof(parent))[fname]          # cached Dict

        # ─────────────────────────────────────────────────────────────
        # (a) the easy built‑ins
        # ─────────────────────────────────────────────────────────────

        val = if ftype === String
            txt
        elseif ftype <: Integer
            txt == "" ? zero(ftype) : Parsers.parse(ftype, txt)
        elseif ftype <: AbstractFloat
            txt == "" ? zero(ftype) : Parsers.parse(ftype, txt)
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

            # ─────────────────────────────────────────────────────────────────────
            # (b) Special handling for the “coordinates” field name:
            #     - the raw tag contains a whitespace-delimited list of 2D or 3D points (lon,lat[,alt])
            #     - use the Automata‐based parser (_parse_coordinates_automa) for robust, high-performance parsing
            #     - convert the parsed Float64 values into:
            #         • a Vector{SVector{3,Float64}} or Vector{SVector{2,Float64}} when the field expects a sequence
            #         • a single SVector{3,Float64} or SVector{2,Float64} when the field expects one coordinate
            # ─────────────────────────────────────────────────────────────────────

        elseif fname === :coordinates
            parsed_coords_vec = _parse_coordinates_automa(txt)

            if isempty(parsed_coords_vec)
                if ftype <: AbstractVector
                    val = ftype()
                elseif ftype <: Union{Coord2,Coord3} # For Point.coordinates
                    # This is an error as Point requires coordinates.
                    error(
                        "Field '$fname' in $(typeof(parent)) (e.g., KML.Point) expects a single coordinate, but input '$txt' yielded no valid coordinates.",
                    )
                elseif Nothing <: ftype # If the field type allows Nothing
                    val = nothing
                else
                    error(
                        "Empty coordinate data for field '$fname' of type $ftype in $(typeof(parent)). Input: '$(first(txt,50))'",
                    )
                end
            elseif ftype <: AbstractVector # e.g. LineString.coordinates
                val = convert(ftype, parsed_coords_vec)
            elseif ftype <: Union{Coord2,Coord3} # Expects a single coordinate
                if length(parsed_coords_vec) == 1
                    val = convert(ftype, parsed_coords_vec[1])
                else
                    error(
                        "Coordinate string '$txt' for field '$fname' in $(typeof(parent)) (type $ftype) resulted in $(length(parsed_coords_vec)) coordinates. Expected one.",
                    )
                end
            else
                error("Unexpected field type $ftype for coordinate data from '$txt' in $(typeof(parent)).")
            end

            # ─────────────────────────────────────────────────────────────────────
            # (c) Special handling for the Google Earth extension field `gx_coord` (from <gx:coord>):
            #     - parse the raw coordinate text using the Automata-based parser
            #     - if no coordinates are found, assign `nothing` when allowed or create an empty container
            #     - otherwise, convert the parsed vectors of Float64 into the declared `ftype` (e.g. Vector{SVector{2,Float64}})
            # ─────────────────────────────────────────────────────────────────────

        elseif fname === :gx_coord
            parsed_vec = _parse_coordinates_automa(txt)
            if isempty(parsed_vec)
                # Decide: error, or assign empty Vector of a default SVector type, or Nothing if allowed
                if Nothing <: ftype
                    val = nothing
                else
                    # gx_Track might allow empty gx_coord conceptually.
                    # Choose a default empty vector type, e.g. Vector{Coord2}()
                    # This needs care if _parse_coordinates_automa doesn't give enough info for Coord2 vs Coord3 when empty
                    # For now, let's assume _parse_coordinates_automa returns Vector{SVector{0,Float64}}[] or similar
                    # which convert would handle.
                    val = ftype() # Tries to create an empty instance of the Vector{CoordN} part
                end
            else
                val = convert(ftype, parsed_vec) # convert will pick the right Vector{CoordN} from Union
            end

            # ─────────────────────────────────────────────────────────────────────
            # (d) Fallback – delegate to the generic helper for any remaining field
            #     • No specialized parsing matched; let `autosetfield!` apply the raw text
            #     • This covers edge‐cases or unexpected tags uniformly
            # ─────────────────────────────────────────────────────────────────────

        else
            autosetfield!(parent, fname, txt)
            return
        end

        setfield!(parent, fname, val)
        return
    end

    # ── 2. complex child object – recurse ─────────────────────────
    child_obj = object(child)
    if child_obj !== nothing
        # push it into the FIRST matching slot we find
        T = typeof(child_obj)
        for (field, FT) in typemap(parent)
            if T <: FT
                setfield!(parent, field, child_obj)
                return
            elseif FT <: AbstractVector && T <: eltype(FT)
                vec = getfield(parent, field)
                if vec === nothing
                    setfield!(parent, field, eltype(FT)[])
                    vec = getfield(parent, field)
                end
                push!(vec, child_obj)
                return
            end
        end
        error("Unhandled child type: $(T) for parent $(typeof(parent))")
    else
        # legacy edge‑cases (<outerBoundaryIs>, <innerBoundaryIs>, …)
        if fname === :outerBoundaryIs
            # Ensure parent is a Polygon and it expects a LinearRing here
            if parent isa KML.Polygon && hasfield(typeof(parent), :outerBoundaryIs)
                # XML.only(child) should get the <LinearRing> node
                lr_node = XML.only(child)
                if lr_node !== nothing
                    setfield!(parent, :outerBoundaryIs, object(lr_node))
                else
                    @warn "<outerBoundaryIs> was empty for Polygon."
                end
            else
                @warn "Encountered <outerBoundaryIs> for non-Polygon parent or parent without :outerBoundaryIs field: $(typeof(parent))"
            end
        elseif fname === :innerBoundaryIs
            # Ensure parent is a Polygon
            if parent isa KML.Polygon && hasfield(typeof(parent), :innerBoundaryIs)
                # XML.only(child) should get the <LinearRing> node within the current <innerBoundaryIs>
                lr_node = XML.only(child)
                if lr_node !== nothing
                    parsed_linear_ring_obj = object(lr_node) # This should be a KML.LinearRing
                    if parsed_linear_ring_obj isa KML.LinearRing
                        # Initialize the vector if it's the first innerBoundaryIs encountered for this Polygon
                        if getfield(parent, :innerBoundaryIs) === nothing
                            setfield!(parent, :innerBoundaryIs, KML.LinearRing[])
                        end
                        # Push the new KML.LinearRing to the vector
                        push!(getfield(parent, :innerBoundaryIs), parsed_linear_ring_obj)
                    else
                        @warn "Parsed object inside <innerBoundaryIs> is not a KML.LinearRing, but $(typeof(parsed_linear_ring_obj)). Parent: $(typeof(parent))"
                    end
                else
                    @warn "<innerBoundaryIs> was empty for Polygon."
                end
            else
                @warn "Encountered <innerBoundaryIs> for non-Polygon parent or parent without :innerBoundaryIs field: $(typeof(parent))"
            end
        else
            @warn "Unhandled tag $fname for $(typeof(parent))"
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
