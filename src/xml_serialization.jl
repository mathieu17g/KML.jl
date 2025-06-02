module XMLSerialization

export Node

using OrderedCollections: OrderedDict
import XML
import ..Types: KMLElement, KMLFile, LazyKMLFile
import ..Enums
import ..Coordinates: coordinate_string

# ─── Type tag mapping ────────────────────────────────────────────────────────
typetag(T) = replace(string(T), r"([a-zA-Z]*\.)" => "", "_" => ":")

# ─── KMLElement → Node conversion ────────────────────────────────────────────
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

# ─── KMLFile → Node conversion ───────────────────────────────────────────────
function Node(k::KMLFile)
    children = map(k.children) do child
        if child isa XML.AbstractXMLNode && !(child isa XML.Node)
            XML.Node(child)
        elseif child isa KMLElement
            Node(child)
        else
            child
        end
    end

    XML.Node(
        XML.Document,
        nothing,
        nothing,
        nothing,
        [
            XML.Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8")),
            XML.Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, children),
        ],
    )
end

# ─── Helper to enable XML.children on KMLElement ─────────────────────────────
XML.children(o::KMLElement) = XML.children(Node(o))

end # module XMLSerialization