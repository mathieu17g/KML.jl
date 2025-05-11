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

# Read from a filename
function Base.read(path::AbstractString, ::Type{KMLFile})
    xmlread(path, Node) |> _parse_kmlfile
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
        o = T()                               # no reflection
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
        return String(XML.value(only(node)))   # plain text
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

const COORD_RE = r"[,\s]+"     # one-time compile

function _parse_coordinates(txt::AbstractString)
    parts = split(txt, COORD_RE; keepempty = false)
    len_parts = length(parts)

    if mod(len_parts, 3) == 0
        n_coords = len_parts ÷ 3
        # This assumes suggestion 1 (pre-allocation of result vector) is in place
        result = Vector{SVector{3,Float64}}(undef, n_coords)
        for i = 1:n_coords
            offset = (i - 1) * 3

            # Using Parsers.jl for parsing
            # Parsers.parse will throw an error if parsing fails, which is usually
            # desired for malformed coordinate data.
            # It directly accepts SubString{String}, which `parts` contains.
            x = Parsers.parse(Float64, parts[offset+1])
            y = Parsers.parse(Float64, parts[offset+2])
            z = Parsers.parse(Float64, parts[offset+3])

            result[i] = SVector{3,Float64}(x, y, z)
        end
        return result
    elseif mod(len_parts, 2) == 0
        n_coords = len_parts ÷ 2
        result = Vector{SVector{2,Float64}}(undef, n_coords)
        for i = 1:n_coords
            offset = (i - 1) * 2

            x = Parsers.parse(Float64, parts[offset+1])
            y = Parsers.parse(Float64, parts[offset+2])

            result[i] = SVector{2,Float64}(x, y)
        end
        return result
    else
        # Consider making the error message more informative, e.g., include part of 'txt'
        error("Coordinate list length $(len_parts) from string snippet '$(first(txt, 50))...' is not a multiple of 2 or 3")
    end
end

function add_element!(parent::Union{Object,KMLElement}, child::XML.Node)
    # ── 0. pre‑compute a few things ───────────────────────────────
    fname = Symbol(replace(child.tag, ":" => "_"))      # tag → field name
    simple = XML.is_simple(child)

    # ── 1. *Scalar* leaf node (fast path) ─────────────────────────
    if simple
        hasfield(typeof(parent), fname) || return       # ignore strangers

        txt = String(XML.value(XML.only(child)))        # raw text
        ftype = typemap(typeof(parent))[fname]          # cached Dict

        # (a) the easy built‑ins
        val = if ftype === String
            txt
        elseif ftype <: Integer
            txt == "" ? zero(ftype) : parse(ftype, txt)
        elseif ftype <: AbstractFloat
            txt == "" ? zero(ftype) : parse(ftype, txt)
        elseif ftype <: Bool
            txt == "1" || lowercase(txt) == "true"
        elseif ftype <: Enums.AbstractKMLEnum
            ftype(txt)
            # (b) the special coordinate string
        elseif fname === :coordinates
            vec = _parse_coordinates(txt)
            val = (ftype <: Union{Nothing,Tuple}) ? first(vec) : vec
            # (c) fallback – let the generic helper take a stab
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
            setfield!(parent, :outerBoundaryIs, object(XML.only(child)))
        elseif fname === :innerBoundaryIs
            setfield!(parent, :innerBoundaryIs, object.(XML.children(child)))
        else
            @warn "Unhandled tag $fname for $(typeof(parent))"
        end
    end
end


tagsym(x::String) = Symbol(replace(x, ':' => '_'))
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
        txt == "1" || lowercase(txt) == "true"
    elseif ftype <: Enums.AbstractKMLEnum
        ftype(txt)
    elseif fname === :coordinates
        vec = _parse_coordinates(txt)
        val = (ftype <: Union{Nothing,Tuple}) ? first(vec) : vec
    else
        txt   # last‑ditch: store the raw string
    end

    setfield!(o, sym, val)
    return
end
