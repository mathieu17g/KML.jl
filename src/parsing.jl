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
    kml_children = Vector{Union{Node, KMLElement}}(undef, length(xml_children)) # Preallocate
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
# Fast object()  – deal with the handful of tags we care about
function object(node::XML.Node)
    sym = tagsym(node)

    # 1.   tags that map straight to KML types  --------------------
    if haskey(TAG_TO_TYPE, sym)
        T = TAG_TO_TYPE[sym]
        o = T()                               # no reflection
        add_attributes!(o, node)
        for child in XML.children(node)
            add_element!(o, child)
        end
        return o
    end
    # 2.   enums ---------------------------------------------------
    if sym in names(Enums, all = true)
        return getproperty(Enums, sym)(XML.value(only(node)))
    end
    # 3.   <name>, <description>, … fast scalar leafs -------------
    if XML.is_simple(node)
        return String(XML.value(only(node)))   # plain text
    end
    # 4.   fallback to the old generic code ------------------------
    return _object_slow(node)
end

const KML_NAMES_SET = Set(names(KML; all=true, imported=true)) # Get all names in KML
const ENUM_NAMES_SET = Set(names(Enums; all=true))          # Get all names in Enums

function _object_slow(node::XML.Node) 
    sym = tagsym(node)
    if sym in ENUM_NAMES_SET 
        return getproperty(Enums, sym)(XML.value(only(node)))
    end
    if sym in KML_NAMES_SET || sym == :Pair
        T = getproperty(KML, sym)
        o = T()
        add_attributes!(o, node)
        for child in XML.children(node)
            add_element!(o, child)
        end
        return o
    end
    return nothing # Ensure a return path if no conditions met
end

const COORD_RE = r"[,\s]+"     # one-time compile

function _parse_coordinates(txt::AbstractString)
    parts = split(txt, COORD_RE; keepempty=false)
    len_parts = length(parts)

    if mod(len_parts, 3) == 0
        n_coords = len_parts ÷ 3
        # This assumes suggestion 1 (pre-allocation of result vector) is in place
        result = Vector{SVector{3, Float64}}(undef, n_coords)
        for i in 1:n_coords
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
        result = Vector{SVector{2, Float64}}(undef, n_coords)
        for i in 1:n_coords
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
