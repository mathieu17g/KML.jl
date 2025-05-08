#-----------------------------------------------------------------------------# XML.Node ←→ KMLElement
typetag(T) = replace(string(T), r"([a-zA-Z]*\.)" => "", "_" => ":")

coordinate_string(x::Tuple) = join(x, ',')
coordinate_string(x::Vector) = join(coordinate_string.(x), '\n')

# KMLElement → Node
Node(o::T) where {T<:Enums.AbstractKMLEnum} = XML.Element(typetag(T), o.value)

function Node(o::T) where {names, T <: KMLElement{names}}
    tag = typetag(T)
    attributes = Dict(string(k) => string(getfield(o, k)) for k in names if !isnothing(getfield(o, k)))
    element_fields = filter(x -> !isnothing(getfield(o,x)), setdiff(fieldnames(T), names))
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

# original implementation, renamed
_object_slow(node::XML.Node) = begin
    sym = tagsym(node)
    if sym in names(Enums, all=true)
        return getproperty(Enums, sym)(XML.value(only(node)))
    end
    if sym in names(KML) || sym == :Pair
        T = getproperty(KML, sym)
        o = T()
        add_attributes!(o, node)
        for child in XML.children(node)
            add_element!(o, child)
        end
        return o
    end
    nothing
end

function add_element!(parent::Union{Object,KMLElement}, child::XML.Node)
    # ── 0. pre‑compute a few things ───────────────────────────────
    fname  = Symbol(replace(child.tag, ":" => "_"))           # tag → field name
    simple = XML.is_simple(child)

    # ── 1. *Scalar* leaf node (fast path) ─────────────────────────
    if simple
        hasfield(typeof(parent), fname) || return             # ignore strangers

        txt    = String(XML.value(XML.only(child)))           # raw text
        ftype  = typemap(typeof(parent))[fname]               # cached Dict

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
            # Many public KML files omit the comma after an altitude `0`, leaving only a
            # space before the next longitude.  Google Earth and GDAL accept this. See 
            # https://kml4earth.appspot.com/kmlErrata.html#validation
            vec = [Tuple(parse.(Float64, split(v, r"[,\s]+"))) for v in split(txt)]
            (ftype <: Union{Nothing,Tuple}) ? first(vec) : vec
        # (c) fallback – let the generic helper take a stab
        else
            autosetfield!(parent, fname, txt); return
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
    !isnothing(attr) && for (k,v) in attr
        autosetfield!(o, tagsym(k), v)
    end
end

function autosetfield!(o::Union{Object,KMLElement}, sym::Symbol, txt::String)
    ftype = typemap(o)[sym]

    val  = if ftype <: AbstractString
        txt
    elseif ftype <: Integer
        txt == "" ? zero(ftype) : parse(ftype, txt)
    elseif ftype <: AbstractFloat
        txt == "" ? zero(ftype) : parse(ftype, txt)
    elseif ftype <: Bool
        txt == "1" || lowercase(txt) == "true"
    elseif ftype <: Enums.AbstractKMLEnum
        ftype(txt)
    elseif sym === :coordinates
        # Many public KML files omit the comma after an altitude `0`, leaving only a
        # space before the next longitude.  Google Earth and GDAL accept this. See 
        # https://kml4earth.appspot.com/kmlErrata.html#validation
        vec = [Tuple(parse.(Float64, split(v, r"[,\s]+"))) for v in split(txt)]
        (ftype <: Union{Nothing,Tuple}) ? first(vec) : vec
    else
        txt   # last‑ditch: store the raw string
    end

    setfield!(o, sym, val)
    return
end
