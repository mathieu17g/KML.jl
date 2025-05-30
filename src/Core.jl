module Core

export KMLElement, NoAttributes, Object, Feature, Overlay, Container, Geometry, 
       StyleSelector, TimePrimitive, AbstractView, SubStyle, ColorStyle, 
       gx_TourPrimitive, AbstractUpdateOperation,
       @def, @option, @required, name, all_concrete_subtypes, all_abstract_subtypes,
       TAG_TO_TYPE, typemap, KMLFile, LazyKMLFile, _parse_kmlfile,
       Node

using OrderedCollections: OrderedDict
using InteractiveUtils: subtypes
import XML
import XML: Node

# ─── internal helpers / constants ────────────────────────────────────────────
const TAG_TO_TYPE = Dict{Symbol,DataType}()      # XML tag => Julia type
const _FIELD_MAP_CACHE = IdDict{DataType,Dict{Symbol,Type}}() # reflect once, reuse

macro def(name, definition)
    quote
        macro $(esc(name))()
            esc($(Expr(:quote, definition)))
        end
    end
end

macro option(ex)
    ex.head == :(::) || error("@option must annotate a field, e.g. f::T")
    ex.args[2] = Expr(:curly, :Union, :Nothing, ex.args[2])      # T  ➜  Union{Nothing,T}
    :($(esc(ex)) = nothing)
end

macro required(ex)
    ex.head == :(::) || error("@required must annotate a field, e.g. f::T")
    ex.args[2] = Expr(:curly, :Union, :Nothing, ex.args[2])
    :($(esc(ex)) = (@warn "Required field :$(ex.args[1]) initialised as nothing"; nothing))
end

name(T::Type) = replace(string(T), r"([a-zA-Z]*\.)" => "")    # strip module prefix
name(x) = name(typeof(x))

function all_concrete_subtypes(T)
    out = DataType[]
    for S in subtypes(T)
        isabstracttype(S) ? append!(out, all_concrete_subtypes(S)) : push!(out, S)
    end
    out
end

function all_abstract_subtypes(T)
    out = filter(isabstracttype, subtypes(T))
    for S in copy(out)
        append!(out, all_abstract_subtypes(S))
    end
    out
end

# ─── KMLElement base ─────────────────────────────────────────────────────────
abstract type KMLElement{attr_names} <: XML.AbstractXMLNode end
const NoAttributes = KMLElement{()}

# ─── XML interface helpers ───────────────────────────────────────────────────
XML.tag(o::KMLElement) = name(o)
function XML.attributes(o::T) where {names,T<:KMLElement{names}}
    OrderedDict(k => getfield(o, k) for k in names if !isnothing(getfield(o, k)))
end

function typemap(::Type{T}) where {T<:KMLElement}
    get!(_FIELD_MAP_CACHE, T) do
        field_names = fieldnames(T)
        field_types = fieldtypes(T)
        # Store both original type and its non-nothing version
        Dict(fn => Base.nonnothingtype(ft) for (fn, ft) in zip(field_names, field_types))
    end
end

function fieldtype_info(::Type{T}, field::Symbol) where {T<:KMLElement}
    return (original = fieldtype(T, field), nonnothingtype = typemap(T)[field])
end

function typemap(o::KMLElement)
    typemap(typeof(o))
end

Base.:(==)(a::T, b::T) where {T<:KMLElement} = all(getfield(a, f) == getfield(b, f) for f in fieldnames(T))

# ─── Object hierarchy abstract types ─────────────────────────────────────────
abstract type Object <: KMLElement{(:id, :targetId)} end
abstract type Feature <: Object end
abstract type Overlay <: Feature end
abstract type Container <: Feature end
abstract type Geometry <: Object end
abstract type StyleSelector <: Object end
abstract type TimePrimitive <: Object end
abstract type AbstractView <: Object end
abstract type SubStyle <: Object end
abstract type ColorStyle <: SubStyle end
abstract type gx_TourPrimitive <: Object end
abstract type AbstractUpdateOperation <: Object end

# ─── Helper macro for common :id/:targetId fields ───────────────────────────
@def object begin
    @option id ::String
    @option targetId ::String
end

# ─── KMLFile type (core container) ──────────────────────────────────────────
mutable struct KMLFile
    children::Vector{Union{XML.AbstractXMLNode,KMLElement}}
end
KMLFile(content::KMLElement...) = KMLFile(collect(content))
Base.push!(k::KMLFile, x::Union{XML.AbstractXMLNode,KMLElement}) = push!(k.children, x)

function Base.show(io::IO, k::KMLFile)
    print(io, "KMLFile ")
    printstyled(io, '(', Base.format_bytes(Base.summarysize(k)), ')'; color = :light_black)
end

# function Node(k::KMLFile)
#     # Convert any AbstractXMLNodes to Nodes when serializing
#     children = map(k.children) do child
#         if child isa XML.AbstractXMLNode && !(child isa Node)
#             Node(child)  # Convert LazyNode or other XML nodes to Node
#         elseif child isa KMLElement
#             Node(child)  # Use existing Node(::KMLElement) method
#         else
#             child  # Already a Node
#         end
#     end

#     Node(
#         XML.Document,
#         nothing,
#         nothing,
#         nothing,
#         [
#             Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8")),
#             Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, children),
#         ],
#     )
# end
# We need to move this to parsing.jl since it depends on Node conversions
# For now, provide a stub
# function Node(k::KMLFile)
#     error("Node conversion should be imported from parsing module")
# end

Base.:(==)(a::KMLFile, b::KMLFile) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(KMLFile))

# ─── LazyKMLFile for efficient DataFrame extraction ─────────────────────────
mutable struct LazyKMLFile
    root_node::XML.AbstractXMLNode
    _layer_cache::Dict{String,Any}
    _layer_info_cache::Union{Nothing,Vector{Tuple{Int,String,Any}}}

    LazyKMLFile(root_node::XML.AbstractXMLNode) = new(root_node, Dict{String,Any}(), nothing)
end

function Base.show(io::IO, k::LazyKMLFile)
    print(io, "LazyKMLFile ")
    printstyled(io, "(lazy, ", Base.format_bytes(Base.summarysize(k.root_node)), ')'; color = :light_black)
end

Base.:(==)(a::LazyKMLFile, b::LazyKMLFile) = a.root_node == b.root_node

function is_cached(k::LazyKMLFile, key::String)
    haskey(k._layer_cache, key)
end

function get_cached_layer(k::LazyKMLFile, key::String)
    get(k._layer_cache, key, nothing)
end

function cache_layer!(k::LazyKMLFile, key::String, value)
    k._layer_cache[key] = value
    value
end

# function KMLFile(lazy::LazyKMLFile)
#     _parse_kmlfile(lazy.root_node)
# end
# function KMLFile(lazy::LazyKMLFile)
#     error("Conversion should be imported from parsing module")
# end

Base.convert(::Type{KMLFile}, lazy::LazyKMLFile) = KMLFile(lazy)

# Forward declare _parse_kmlfile - will be defined in parsing module
function _parse_kmlfile end

# ─── Common field definitions ────────────────────────────────────────────────
@def altitude_mode_elements begin
    altitudeMode::Union{Nothing,Enums.altitudeMode} = nothing
    gx_altitudeMode::Union{Nothing,Enums.gx_altitudeMode} = nothing
end

end # module Core