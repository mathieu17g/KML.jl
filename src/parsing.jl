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

function add_element!(o::Union{Object,KMLElement}, child::Node)
    sym = tagsym(child)

    # ──────────────────────────────────────────────────────────────────────────────────────
    #  1. fast‑path for simple leaf tags (<name>, <description>, <coordinates>, etc.)
    # ──────────────────────────────────────────────────────────────────────────────────────
    if XML.is_simple(child)
        fname = Symbol(replace(child.tag, ":" => "_"))
        hasfield(typeof(o), fname) || return            # parent has no such field
        txt = XML.value(XML.only(child))                # the text content
        ftype = typemap(typeof(o))[fname]               # cached dict, O(1)

        if ftype === String
            val = txt
        elseif ftype <: Integer
            val = parse(Int, txt)                       # id, visibility, etc.
        elseif ftype <: AbstractFloat
            val = parse(Float64, txt)                   # longitude, latitude, etc.
        elseif ftype <: Bool
            val = (txt == "1" || lowercase(txt) == "true")
        elseif ftype <: Enum
            val = ftype(txt)                            # altitudeMode, etc.
        else                                            # fallback (rare)
            # complex or container type (Vector, Union of Vectors, etc.)
            # → let the original logic handle it (includes coordinates parsing)
            autosetfield!(o, fname, txt)
            return
        end

        setfield!(o, fname, val)
        return
    end

    # ──────────────────────────────────────────────────────────────────────────────────────
    # 2. complex child → recurse
    # ──────────────────────────────────────────────────────────────────────────────────────
    o_child = object(child)

    if !isnothing(o_child)
        @goto child_is_object
    else
        @goto child_is_not_object
    end

    @label child_is_not_object
    return if sym == :outerBoundaryIs
        setfield!(o, :outerBoundaryIs, object(XML.only(child)))
    elseif sym == :innerBoundaryIs
        setfield!(o, :innerBoundaryIs, object.(XML.children(child)))
    elseif hasfield(typeof(o), sym) && XML.is_simple(child)
        autosetfield!(o, sym, XML.value(only(child)))
    else
        @warn "Unhandled case encountered while trying to add child with tag `$sym` to parent `$o`."
    end

    @label child_is_object
    T = typeof(o_child)

    for (field, FT) in typemap(o)
        T <: FT && return setfield!(o, field, o_child)
        if FT <: AbstractVector && T <: eltype(FT)
            v = getfield(o, field)
            if isnothing(v)
                setfield!(o, field, eltype(FT)[])
            end
            push!(getfield(o, field), o_child)
            return
        end
    end
    error("This was not handled: $o_child")
end


tagsym(x::String) = Symbol(replace(x, ':' => '_'))
tagsym(x::Node) = tagsym(XML.tag(x))

function add_attributes!(o::Union{Object,KMLElement}, source::Node)
    attr = XML.attributes(source)
    !isnothing(attr) && for (k,v) in attr
        autosetfield!(o, tagsym(k), v)
    end
end

function autosetfield!(o::Union{Object,KMLElement}, sym::Symbol, x::String)
    T = typemap(o)[sym]
    T <: Number && return setfield!(o, sym, parse(T, x))
    T <: AbstractString && return setfield!(o, sym, x)
    T <: Enums.AbstractKMLEnum && return setfield!(o, sym, T(x))
    if sym == :coordinates
        val = [Tuple(parse.(Float64, split(v, ','))) for v in split(x)]
        # coordinates can be a tuple or a vector of tuples, so we need to do this:
        if fieldtype(typeof(o), sym) <: Union{Nothing, Tuple}
            val = val[1]
        end
        return setfield!(o, sym, val)
    end
    setfield!(o, sym, x)
end
