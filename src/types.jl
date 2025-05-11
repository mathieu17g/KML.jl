#------------------------------------------------------------------------------
#  types.jl  –  all KML data structures *without* GeoInterface extensions
#------------------------------------------------------------------------------

# ─── internal helpers / constants ────────────────────────────────────────────
const Coord2 = SVector{2,Float64}
const Coord3 = SVector{3,Float64}

const TAG_TO_TYPE = Dict{Symbol,DataType}()      # XML tag => Julia type
const _FIELD_MAP_CACHE = IdDict{DataType,Dict{Symbol,Type}}() # reflect once, reuse

macro def(name, definition)
    quote
        macro $(esc(name))()
            esc($(Expr(:quote, definition)))
        end
    end
end

@def altitude_mode_elements begin
    altitudeMode::Union{Nothing,Enums.altitudeMode} = nothing
    gx_altitudeMode::Union{Nothing,Enums.gx_altitudeMode} = nothing
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

# printing (does *not* depend on GeoInterface)
function Base.show(io::IO, o::T) where {names,T<:KMLElement{names}}
    printstyled(io, T; color = :light_cyan)
    print(io, ": [")
    show(io, Node(o))
    print(io, "]")
end

# ─── XML interface helpers ───────────────────────────────────────────────────
XML.tag(o::KMLElement) = name(o)
function XML.attributes(o::T) where {names,T<:KMLElement{names}}
    OrderedDict(k => getfield(o, k) for k in names if !isnothing(getfield(o, k)))
end
XML.children(o::KMLElement) = XML.children(Node(o))

function typemap(::Type{T}) where {T<:KMLElement}
    get!(_FIELD_MAP_CACHE, T) do
        Dict(fieldnames(T) .=> Base.nonnothingtype.(fieldtypes(T)))
    end
end
function typemap(o::KMLElement)
    typemap(typeof(o))
end

Base.:(==)(a::T, b::T) where {T<:KMLElement} = all(getfield(a, f) == getfield(b, f) for f in fieldnames(T))

# ─── minimal "Enums" sub‑module (no external deps) ───────────────────────────
module Enums
import ..NoAttributes
using XML
abstract type AbstractKMLEnum <: NoAttributes end
Base.show(io::IO, o::AbstractKMLEnum) = print(io, typeof(o), ": ", repr(o.value))
Base.convert(::Type{T}, x::String) where {T<:AbstractKMLEnum} = T(x)
Base.string(o::AbstractKMLEnum) = o.value
macro kml_enum(T, vals...)
    esc(quote
        struct $T <: AbstractKMLEnum
            value::String
            function $T(v)
                string(v) ∈ $(string.(vals)) || error("$(T) ∉ $(vals). Found: " * string(v))
                new(string(v))
            end
        end
    end)
end
@kml_enum altitudeMode clampToGround relativeToGround absolute
@kml_enum gx_altitudeMode relativeToSeaFloor clampToSeaFloor
@kml_enum refreshMode onChange onInterval onExpire
@kml_enum viewRefreshMode never onStop onRequest onRegion
@kml_enum shape rectangle cylinder sphere
@kml_enum gridOrigin lowerLeft upperLeft
@kml_enum displayMode default hide
@kml_enum listItemType check checkOffOnly checkHideChildren radioFolder
@kml_enum units fraction pixels insetPixels
@kml_enum itemIconState open closed error fetching0 fetching1 fetching2
@kml_enum styleState normal highlight
@kml_enum colorMode normal random
@kml_enum flyToMode smooth bounce
end # module Enums

# ─── KMLFile + core object hierarchy (NO GeoInterface code) ──────────────────
mutable struct KMLFile
    children::Vector{Union{Node,KMLElement}}
end
KMLFile(content::KMLElement...) = KMLFile(collect(content))
Base.push!(k::KMLFile, x::Union{Node,KMLElement}) = push!(k.children, x)

function Base.show(io::IO, k::KMLFile)
    print(io, "KMLFile ")
    printstyled(io, '(', Base.format_bytes(Base.summarysize(k)), ')'; color = :light_black)
end

function Node(k::KMLFile)
    Node(
        XML.Document,
        nothing,
        nothing,
        nothing,
        [
            Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8")),
            Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, Node.(k.children)),
        ],
    )
end

Base.:(==)(a::KMLFile, b::KMLFile) = all(getfield(a,f) == getfield(b,f) for f in fieldnames(KMLFile))

#──────────────────────────────────────────────────────────────────────────────
#  OBJECT / FEATURE HIERARCHY
#  (everything that represents real KML elements – but *no* GeoInterface)
#──────────────────────────────────────────────────────────────────────────────

#------------------------------------------------------------------------
#  Abstract roots
#------------------------------------------------------------------------
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

#------------------------------------------------------------------------
#  helper macro for the common :id / :targetId pair
#------------------------------------------------------------------------
@def object begin
    @option id ::String
    @option targetId ::String
end

#────────────────────────────── UTILITY / SIMPLE SHARED COMPONENT NODES ───────────────────── 
# Define these early as they are used by various KML elements like ScreenOverlay and IconStyle.

# Represents KML elements like <hotSpot>, <ScreenXY>, <OverlayXY>, etc., which share x, y, xunits, yunits attributes.
Base.@kwdef mutable struct hotSpot <: KMLElement{(:x, :y, :xunits, :yunits)}
    @option x ::Float64
    @option y ::Float64
    @option xunits ::Enums.units
    @option yunits ::Enums.units
end

# Aliases for hotSpot, used in specific contexts (e.g., ScreenOverlay fields) 
const overlayXY = hotSpot
const screenXY = hotSpot
const rotationXY = hotSpot
const size = hotSpot # KML <size> for ScreenOverlay has x, y, xunits, yunits, matching hotSpot structure.

#────────────────────  OBJECT‑LEVEL ELEMENTS (Reusable Components)   ─────────────────
# These are general KML Objects that can be children of other elements or define properties.
# They are not Features or Geometries themselves but are often used by them.

Base.@kwdef mutable struct Link <: Object
    @object
    @option href ::String
    @option refreshMode ::Enums.refreshMode
    @option refreshInterval ::Float64
    @option viewRefreshMode ::Enums.viewRefreshMode
    @option viewRefreshTime ::Float64
    @option viewBoundScale ::Float64
    @option viewFormat ::String
    @option httpQuery ::String
end

Base.@kwdef mutable struct Icon <: Object
    @object
    @option href ::String
    @option refreshMode ::Enums.refreshMode
    @option refreshInterval::Float64
    @option viewRefreshMode::Enums.viewRefreshMode
    @option viewRefreshTime::Float64
    @option viewBoundScale ::Float64
    @option viewFormat ::String
    @option httpQuery ::String
end

Base.@kwdef mutable struct Orientation <: Object
    @object
    @option heading::Float64
    @option tilt ::Float64
    @option roll ::Float64
end

Base.@kwdef mutable struct Location <: Object
    @object
    @option longitude::Float64
    @option latitude ::Float64
    @option altitude ::Float64
end

Base.@kwdef mutable struct Scale <: Object
    @object
    @option x::Float64
    @option y::Float64
    @option z::Float64
end

Base.@kwdef mutable struct Lod <: Object
    @object
    minLodPixels::Int = 128
    @option maxLodPixels ::Int
    @option minFadeExtent ::Int
    @option maxFadeExtent ::Int
end

Base.@kwdef mutable struct LatLonBox <: Object
    @object
    north::Float64 = 0
    south::Float64 = 0
    east::Float64 = 0
    west::Float64 = 0
    @option rotation::Float64
end

Base.@kwdef mutable struct LatLonAltBox <: Object
    @object
    north::Float64 = 0
    south::Float64 = 0
    east::Float64 = 0
    west::Float64 = 0
    @option minAltitude::Float64
    @option maxAltitude::Float64
    @altitude_mode_elements
end

Base.@kwdef mutable struct Region <: Object
    @object
    LatLonAltBox::LatLonAltBox = LatLonAltBox()
    @option Lod::Lod
end

Base.@kwdef mutable struct gx_LatLonQuad <: Object
    @object
    coordinates::Vector{Coord2} = [(0, 0), (0, 0), (0, 0), (0, 0)]
    gx_LatLonQuad(id, targetId, c) = (@assert length(c) == 4; new(id, targetId, c))
end

#────────────────────────────  SUBSTYLES / COLOURS  ──────────────────────────
# SubStyle elements are components of <Style>. They define the appearance of Features.
# They are used by Placemarks, GroundOverlays, and PhotoOverlays.
# They are also used by gx_Track and gx_MultiTrack, which are used by gx_Tour.

@def colorstyle begin
    @object
    @option color ::String
    @option colorMode ::Enums.colorMode
end

Base.@kwdef mutable struct LineStyle <: ColorStyle
    @colorstyle
    @option width ::Float64
    @option gx_outerColor ::String
    @option gx_outerWidth ::Float64
    @option gx_physicalWidth::Float64
    @option gx_labelVisibility::Bool
end
Base.@kwdef mutable struct PolyStyle <: ColorStyle
    @colorstyle
    @option fill ::Bool
    @option outline::Bool
end
Base.@kwdef mutable struct IconStyle <: ColorStyle
    @colorstyle
    @option scale ::Float64
    @option heading ::Float64
    @option Icon ::Icon
    @option hotSpot ::hotSpot
end
Base.@kwdef mutable struct LabelStyle <: ColorStyle
    @colorstyle
    @option scale::Float64
end

#──────────────────────────────  LIST‑STYLE SUPPORT  ─────────────────────────
# ListStyle is used by the <ListStyle> element, which is a child of <Style>.
# It is used to define the appearance of the list of items in the Places panel.
# BalloonStyle is used by the <BalloonStyle> element, which is a child of <Style>.
# It is used to define the appearance of the balloon that appears when a user clicks on a placemark.

Base.@kwdef mutable struct ItemIcon <: NoAttributes
    @option state::Enums.itemIconState 
    @option href ::String
end

Base.@kwdef mutable struct ListStyle <: SubStyle
    @object
    @option listItemType::Symbol
    @option bgColor ::String
    @option ItemIcons ::Vector{ItemIcon}
end

Base.@kwdef mutable struct BalloonStyle <: SubStyle
    @object
    @option bgColor ::String
    @option textColor ::String
    @option text ::String
    @option displayMode::Enums.displayMode
end

#────────────────────────────  STYLE SELECTORS  ──────────────────────────────
# StyleSelectors define how Features are drawn.
# They are used by Placemarks, GroundOverlays, and PhotoOverlays.
# They are also used by gx_Track and gx_MultiTrack, which are used by gx_Tour.

Base.@kwdef mutable struct Style <: StyleSelector
    @object
    @option IconStyle ::IconStyle
    @option LabelStyle ::LabelStyle
    @option LineStyle ::LineStyle
    @option PolyStyle ::PolyStyle
    @option BalloonStyle::BalloonStyle
    @option ListStyle ::ListStyle
end

Base.@kwdef mutable struct StyleMapPair <: Object
    @object
    @option key ::Enums.styleState
    @option styleUrl::String
    @option Style ::Style
end

Base.@kwdef mutable struct StyleMap <: StyleSelector
    @object
    @option Pairs::Vector{StyleMapPair}
end

#────────────────────────────────  GEOMETRIES  ───────────────────────────────
# Geometry elements define the shape and location of Features.
# They are used by Placemarks, GroundOverlays, and PhotoOverlays.
# They are also used by gx_Track and gx_MultiTrack, which are used by gx_Tour.

Base.@kwdef mutable struct Point <: Geometry
    @object
    @option extrude::Bool
    @altitude_mode_elements
    @option coordinates::Union{Coord2,Coord3}
end

Base.@kwdef mutable struct LineString <: Geometry
    @object
    @option gx_altitudeOffset::Float64
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    @option gx_drawOrder::Int
    @option coordinates::Union{Vector{Coord2},Vector{Coord3}}
end

Base.@kwdef mutable struct LinearRing <: Geometry
    @object
    @option gx_altitudeOffset::Float64
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    @option coordinates::Union{Vector{Coord2},Vector{Coord3}}
end

Base.@kwdef mutable struct Polygon <: Geometry
    @object
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    outerBoundaryIs::LinearRing = LinearRing()
    @option innerBoundaryIs::Vector{LinearRing}
end

Base.@kwdef mutable struct MultiGeometry <: Geometry
    @object
    @option Geometries::Vector{Geometry}
end

# Alias is a component of ResourceMap, which is a component of Model
Base.@kwdef mutable struct Alias <: NoAttributes
    @option targetHref::String
    @option sourceHref::String
end
Base.@kwdef mutable struct ResourceMap <: NoAttributes
    @option Aliases::Vector{Alias}
end
Base.@kwdef mutable struct Model <: Geometry
    @object
    @altitude_mode_elements
    @option Location ::Location
    @option Orientation ::Orientation
    @option Scale ::Scale
    @option Link ::Link
    @option ResourceMap ::ResourceMap
end

#────────────────────────────  ABSTRACT VIEWS  ───────────────────────────────
# AbstractView elements define the camera perspective.
# Used by Features and gx_FlyTo TourPrimitive.

Base.@kwdef mutable struct Camera <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option roll ::Float64
    @altitude_mode_elements
end

Base.@kwdef mutable struct LookAt <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option range ::Float64
    @altitude_mode_elements
end

#────────────────────────────────  MISC UTILS  ───────────────────────────────
# These elements provide additional data or unstructured content, often used by Features.
# They are not strictly necessary for KML but can enhance the information provided.
# They are used by Placemarks, GroundOverlays, and PhotoOverlays.
# They are also used by gx_Track and gx_MultiTrack, which are used by gx_Tour.

# Short description, used by Feature, gx_Track for custom data
Base.@kwdef mutable struct Snippet <: KMLElement{(:maxLines,)} 
    content::String = ""    # Plain text, no HTML
    maxLines::Int = 2
end

# Children can be <Data> (name/value pairs), <SchemaData> (typed data), or custom XML 
# Used by Feature, gx_Track for custom data 
Base.@kwdef mutable struct ExtendedData <: NoAttributes
    @required children::Vector{Any}
end

#──────────────  CONCRETE TOUR PRIMITIVES (Google Extensions)  ──────────────
# These are the building blocks for gx:Tour playlists.
# They are used to create a sequence of actions in a tour.

Base.@kwdef mutable struct gx_AnimatedUpdate <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option Update ::NoAttributes
    @option gx_delayedStart ::Float64
end

Base.@kwdef mutable struct gx_FlyTo <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option gx_flyToMode ::Enums.flyToMode
    @option AbstractView ::AbstractView
end

Base.@kwdef mutable struct gx_SoundCue <: gx_TourPrimitive
    @object
    @option href ::String
    @option gx_delayedStart::Float64
end

Base.@kwdef mutable struct gx_TourControl <: gx_TourPrimitive
    @object
    gx_playMode::String = "pause"
end

Base.@kwdef mutable struct gx_Wait <: gx_TourPrimitive
    @object
    @option gx_duration::Float64
end

Base.@kwdef mutable struct gx_Playlist <: Object
    @object
    gx_TourPrimitives::Vector{gx_TourPrimitive} = []
end

#────────────────────────────────  FEATURE LEVEL  ────────────────────────────
# Features are the core elements that are drawn on the Earth.

@def feature begin
    @object
    @option name ::String
    @option visibility ::Bool
    @option open ::Bool
    @option atom_author ::String
    @option atom_link ::String
    @option address ::String
    @option xal_AddressDetails::String
    @option phoneNumber ::String
    @option Snippet ::Snippet
    @option description ::String
    @option AbstractView ::AbstractView
    @option TimePrimitive ::TimePrimitive
    @option styleUrl ::String
    @option StyleSelectors ::Vector{StyleSelector}
    @option Region ::Region
    @option ExtendedData ::ExtendedData
end

Base.@kwdef mutable struct Placemark <: Feature
    @feature
    @option Geometry ::Geometry
end

Base.@kwdef mutable struct NetworkLink <: Feature
    @feature
    @option refreshVisibility::Bool
    @option flyToView ::Bool
    Link::Link = Link()
end

Base.@kwdef mutable struct gx_Tour <: Feature
    @feature
    @option gx_Playlist ::gx_Playlist
end

Base.@kwdef mutable struct gx_Track <: Geometry
    @object
    @altitude_mode_elements
    @option when ::String
    @option gx_coord ::String
    @option gx_angles ::String
    @option Model ::Model
    @option ExtendedData::ExtendedData
end
Base.@kwdef mutable struct gx_MultiTrack
    @object
    @altitude_mode_elements
    @option gx_interpolate::Bool
    @option gx_Track ::Vector{gx_Track}
end

#──────────────────────────────  PHOTO‑OVERLAY SUPPORT  ──────────────────────
# These are specific components for PhotoOverlay.

Base.@kwdef mutable struct ViewVolume <: NoAttributes
    @option leftFov ::Float64
    @option rightFov ::Float64
    @option bottomFov ::Float64
    @option topFov ::Float64
    @option near ::Float64
end

Base.@kwdef mutable struct ImagePyramid <: NoAttributes
    @option tileSize ::Int
    @option maxWidth ::Int
    @option maxHeight ::Int
    @option gridOrigin::Enums.gridOrigin
end

#────────────────────────────  OVERLAYS  ─────────────────────────────────────
# Overlays are a type of Feature used to superimpose images on the globe or screen.

@def overlay begin
    @feature
    @option color ::String
    @option drawOrder::Int
    @option Icon ::Icon
end

Base.@kwdef mutable struct PhotoOverlay <: Overlay
    @overlay
    @option rotation ::Float64
    @option ViewVolume ::ViewVolume
    @option ImagePyramid ::ImagePyramid
    @option Point ::Point
    @option shape ::Enums.shape
end

Base.@kwdef mutable struct ScreenOverlay <: Overlay
    @overlay
    @option overlayXY ::overlayXY
    @option screenXY ::screenXY
    @option rotationXY ::rotationXY
    @option size ::size
    rotation::Float64 = 0.0
end

Base.@kwdef mutable struct GroundOverlay <: Overlay
    @overlay
    @option altitude ::Float64
    @altitude_mode_elements
    @option LatLonBox ::LatLonBox
    @option gx_LatLonQuad ::gx_LatLonQuad
end

#───────────────  DOCUMENT SCHEMA SUPPORT (for Document Container)  ──────────
# Defines structures for KML Schemas, used within <Document>.
# SimpleField is a component of Schema. Schema is a component of Document.

Base.@kwdef mutable struct SimpleField <: KMLElement{(:type, :name)}
    type::String
    name::String
    @option displayName::String
end

Base.@kwdef mutable struct Schema <: KMLElement{(:id,)}
    id::String
    @option SimpleFields::Vector{SimpleField}
end

#────────────────────  CONTAINERS (Folders, Document)  ──────────────────────
# Containers are Features that can hold other Features.
# They are used to group Features together and can be nested.

Base.@kwdef mutable struct Folder <: Container
    @feature
    @option Features::Vector{Feature}
end

Base.@kwdef mutable struct Document <: Container
    @feature
    @option Schemas ::Vector{Schema}
    @option Features::Vector{Feature}
end

# ─── TAG → Type map (used during XML parsing) ───────────────────────────────
function _collect_concrete!(root)
    for S in subtypes(root)
        isabstracttype(S) ? _collect_concrete!(S) : (TAG_TO_TYPE[Symbol(replace(string(S), "KML." => ""))] = S)
    end
end
_collect_concrete!(KMLElement)
