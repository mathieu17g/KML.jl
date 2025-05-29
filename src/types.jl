#------------------------------------------------------------------------------
#  types.jl  –  all KML data structures *without* GeoInterface extensions
#------------------------------------------------------------------------------

using Dates, TimeZones
# include("Coordinates.jl")
using .Coordinates: Coord2, Coord3

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

# ─── minimal "Enums" sub‑module (no external deps) ───────────────────────────
module Enums
import ..NoAttributes
using XML
abstract type AbstractKMLEnum <: NoAttributes end
Base.show(io::IO, o::AbstractKMLEnum) = print(io, typeof(o), ": ", repr(o.value))
Base.convert(::Type{T}, x::String) where {T<:AbstractKMLEnum} = T(x)
Base.string(o::AbstractKMLEnum) = o.value
macro kml_enum(enum_name::Symbol, vals...)
    # enum_name is the symbol for the enum type, e.g., :altitudeMode
    # vals is a tuple of symbols for the valid values, e.g., (:clampToGround, :relativeToGround, :absolute)

    # Create a string version of the enum's name (e.g., "altitudeMode")
    enum_name_as_string = string(enum_name)

    # Create a tuple of strings for the valid enum values (e.g., ("clampToGround", "relativeToGround", "absolute"))
    # This tuple will be used for both the runtime check and the error message.
    valid_values_as_strings_tuple = map(string, vals)

    esc(
        quote
            struct $enum_name <: AbstractKMLEnum # AbstractKMLEnum is defined in the same Enums module
                value::String # The validated string value

                # Constructor that takes a String
                function $enum_name(input_string::String)
                    # Check if the input_string is one of the valid values
                    # $valid_values_as_strings_tuple is spliced in directly here
                    if !(input_string ∈ $valid_values_as_strings_tuple)
                        # Construct the error message using the pre-stringified components
                        # $enum_name_as_string and $valid_values_as_strings_tuple are spliced in
                        error_msg = string(
                            $enum_name_as_string,
                            " must be one of ",
                            $valid_values_as_strings_tuple, # This will show as ("val1", "val2", ...)
                            ", but got: '",
                            input_string,
                            "'",
                        )
                        error(error_msg)
                    end
                    new(input_string) # Store the validated string
                end

                # Convenience constructor for any AbstractString input (delegates to the String constructor)
                function $enum_name(input_abstract_string::AbstractString)
                    $enum_name(String(input_abstract_string))
                end
            end
        end,
    )
end
# @kml_enum altitudeMode clampToGround relativeToGround absolute
struct altitudeMode <: AbstractKMLEnum
    value::String # Stores the KML standard-compliant value

    function altitudeMode(input_value::AbstractString)
        # Convert input to String for consistent processing
        input_str = String(input_value)

        # Normalize "clampedToGround" to "clampToGround"
        normalized_str = if input_str == "clampedToGround"
            "clampToGround"
        else
            input_str
        end

        # Define the standard valid options
        valid_options = ("clampToGround", "relativeToGround", "absolute")

        # Check if the normalized string is one of the valid options
        if !(normalized_str ∈ valid_options)
            error_message = string(
                "altitudeMode must be one of ",
                valid_options,
                ", but got original value: '",
                input_str, # Show the original value in the error
                "'",
            )
            error(error_message)
        end
        new(normalized_str) # Store the (potentially normalized) standard value
    end
end
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
    children::Vector{Union{XML.AbstractXMLNode,KMLElement}}
end
KMLFile(content::KMLElement...) = KMLFile(collect(content))
Base.push!(k::KMLFile, x::Union{XML.AbstractXMLNode,KMLElement}) = push!(k.children, x)

function Base.show(io::IO, k::KMLFile)
    print(io, "KMLFile ")
    printstyled(io, '(', Base.format_bytes(Base.summarysize(k)), ')'; color = :light_black)
end

function Node(k::KMLFile)
    # Convert any AbstractXMLNodes to Nodes when serializing
    # KMLElements already have their Node() method defined
    children = map(k.children) do child
        if child isa XML.AbstractXMLNode && !(child isa Node)
            Node(child)  # Convert LazyNode or other XML nodes to Node
        elseif child isa KMLElement
            Node(child)  # Use existing Node(::KMLElement) method
        else
            child  # Already a Node
        end
    end

    Node(
        XML.Document,
        nothing,
        nothing,
        nothing,
        [
            Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8")),
            Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, children),
        ],
    )
end

Base.:(==)(a::KMLFile, b::KMLFile) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(KMLFile))

# ─── LazyKMLFile for efficient DataFrame extraction ─────────────────────────
"""
    LazyKMLFile

A lazy representation of a KML file that keeps the XML structure without
materializing KML objects. Optimized for extracting specific layers to DataFrames.

# Fields

  - `root_node::XML.AbstractXMLNode`: The root XML document node
  - `_layer_cache::Dict{String,Any}`: Cache for accessed layers to avoid re-parsing
  - `_layer_info_cache::Union{Nothing,Vector{Tuple{Int,String,Any}}}`: Cached layer information
"""
mutable struct LazyKMLFile
    root_node::XML.AbstractXMLNode
    _layer_cache::Dict{String,Any}
    _layer_info_cache::Union{Nothing,Vector{Tuple{Int,String,Any}}}

    # Constructor
    LazyKMLFile(root_node::XML.AbstractXMLNode) = new(root_node, Dict{String,Any}(), nothing)
end

# Basic methods for LazyKMLFile
function Base.show(io::IO, k::LazyKMLFile)
    print(io, "LazyKMLFile ")
    printstyled(io, "(lazy, ", Base.format_bytes(Base.summarysize(k.root_node)), ')'; color = :light_black)
end

Base.:(==)(a::LazyKMLFile, b::LazyKMLFile) = a.root_node == b.root_node

# Helper to check if a LazyKMLFile has been partially materialized
function is_cached(k::LazyKMLFile, key::String)
    haskey(k._layer_cache, key)
end

# Helper to get cached layer
function get_cached_layer(k::LazyKMLFile, key::String)
    get(k._layer_cache, key, nothing)
end

# Helper to cache a layer
function cache_layer!(k::LazyKMLFile, key::String, value)
    k._layer_cache[key] = value
    value
end

# Convert LazyKMLFile to regular KMLFile (materializes everything)
"""
    KMLFile(lazy::LazyKMLFile)

Convert a LazyKMLFile to a regular KMLFile, materializing all KML objects.
"""
function KMLFile(lazy::LazyKMLFile)
    _parse_kmlfile(lazy.root_node)
end

# Also provide as a convert method
Base.convert(::Type{KMLFile}, lazy::LazyKMLFile) = KMLFile(lazy)

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

#────────────────────────  TIME ELEMENTS  ────────────────────────────────
Base.@kwdef mutable struct TimeStamp <: TimePrimitive
    @object
    @option when ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end
TAG_TO_TYPE[:TimeStamp] = TimeStamp

Base.@kwdef mutable struct TimeSpan <: TimePrimitive
    @object
    @option begin_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
    @option end_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end
TAG_TO_TYPE[:TimeSpan] = TimeSpan

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
    @option x ::Int
    @option y ::Int
    @option w ::Int  # Width in pixels if the <href> specifies an icon palette
    @option h ::Int  # Height in pixels if the <href> specifies an icon palette
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

# For <Data name="string">
#   <value>string_value</value>
#   <displayName>string_display_name</displayName> # </Data>
Base.@kwdef mutable struct Data <: KMLElement{(:name,)} # 'name' is an attribute
    @object # If Data elements can have their own IDs (less common but possible)
    # name::String is implicitly handled by KMLElement{(:name,)} if required as an attribute
    # If 'name' is a required attribute, it should be a regular field:
    # name::String -> This will be handled by add_attributes!

    @option value ::String          # From <value> child tag
    @option displayName ::String    # From <displayName> child tag
end
TAG_TO_TYPE[:Data] = Data

# For <SimpleData name="string">string_value</SimpleData> (used within SchemaData)
Base.@kwdef mutable struct SimpleData <: KMLElement{(:name,)} # 'name' is an attribute
    # name::String is implicitly handled by KMLElement{(:name,)}
    content::String = "" # To store the direct text content of <SimpleData>
end
TAG_TO_TYPE[:SimpleData] = SimpleData

# For <SchemaData schemaUrl="anyURI">
#   (<SimpleData name="string">string_value</SimpleData>)+
# </SchemaData>
Base.@kwdef mutable struct SchemaData <: KMLElement{(:schemaUrl,)} # 'schemaUrl' is an attribute
    @object # If SchemaData elements can have their own IDs
    # schemaUrl::String is implicitly handled by KMLElement{(:schemaUrl,)}

    # Using SimpleDataVec to avoid potential naming conflicts if a field was just 'SimpleData'
    @option SimpleDataVec ::Vector{SimpleData}
end
TAG_TO_TYPE[:SchemaData] = SchemaData

# Now, modify the ExtendedData definition:
Base.@kwdef mutable struct ExtendedData <: NoAttributes # Or KMLElement{()}
    @object # If ExtendedData itself can have an ID (uncommon, usually it's just a container)
    # Use a Union to allow specific types and a fallback for other XML.
    # Node can be used to store unparsed/untyped XML elements.
    # If you only want to store recognized KML elements, replace Node with a more specific KMLElement.
    @option children ::Vector{Union{Data,SchemaData,KMLElement,Node}}
    # Using KMLElement allows any other KML types you've defined to also be children if valid.
    # Using Node allows for truly arbitrary XML from other namespaces.
    # If you expect only Data and SchemaData, it would be Vector{Union{Data, SchemaData}}.
    # The previous @required children::Vector{Any} is very loose.
end

#──────────────  CONCRETE TOUR PRIMITIVES (Google Extensions)  ──────────────
# These are the building blocks for gx:Tour playlists.
# They are used to create a sequence of actions in a tour.

# Abstract type for operations within an Update
abstract type AbstractUpdateOperation <: Object end # Or KMLElement{()} if they don't have id/targetId

# <Create> can contain any number of Features, Geometries, etc.
Base.@kwdef mutable struct Create <: AbstractUpdateOperation
    @object # If <Create> itself can have an ID
    # KML spec says Create contains a Container (Folder, Document, Placemark)
    # For simplicity, let's allow a vector of Features or KMLElements.
    # If it always contains a single container, then use: @option Container ::Container
    @option CreatedObjects::Vector{KMLElement} # Can hold any KML element being created
end
TAG_TO_TYPE[:Create] = Create

# <Delete> targets Features to remove. Its children are Features (often just references or empty)
Base.@kwdef mutable struct Delete <: AbstractUpdateOperation
    @object # If <Delete> itself can have an ID
    # KML spec says Delete contains Features to be deleted, referenced by targetId or with children.
    # For simplicity, can also store Features directly if they are fully defined for deletion.
    @option FeaturesToDelete::Vector{Feature}
end
TAG_TO_TYPE[:Delete] = Delete

# <Change> modifies existing elements. Its children are the new state of those elements.
Base.@kwdef mutable struct Change <: AbstractUpdateOperation
    @object # If <Change> itself can have an ID
    # Children are any Object elements (Feature, Geometry, Style, etc.) with targetId implicit or explicit
    @option ObjectsToChange::Vector{Object} # Any Object can be a child representing the change
end
TAG_TO_TYPE[:Change] = Change

# The <Update> element itself
Base.@kwdef mutable struct Update <: KMLElement{()} # KML spec shows no attributes for <Update> itself
    # targetHref is a child element of <Update>
    @option targetHref ::String
    # Create, Delete, Change operations
    @option operations ::Vector{Union{Create,Delete,Change}}
end
TAG_TO_TYPE[:Update] = Update # Add Update itself to TAG_TO_TYPE

# Modify gx_AnimatedUpdate
Base.@kwdef mutable struct gx_AnimatedUpdate <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option Update ::Update # Changed from NoAttributes to the new Update struct
    @option gx_delayedStart ::Float64
end
# gx_AnimatedUpdate is already in TAG_TO_TYPE via _collect_concrete!

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

#──────────────────────────────  ATOM SUPPORT  ──────────────────────────────
# These are the building blocks for ATOM syndication, used in KML for metadata.

# For <atom:author>
Base.@kwdef mutable struct AtomAuthor <: KMLElement{()} # No top-level attributes for <atom:author> itself
    @option name::String     # Corresponds to <atom:name> child
    @option uri::String      # Corresponds to <atom:uri> child
    @option email::String    # Corresponds to <atom:email> child
    # Add other atomPersonConstruct fields if needed
end
TAG_TO_TYPE[:atom_author] = AtomAuthor # Manual mapping for namespaced tag

# For <atom:link>
# Attributes of <atom:link> become fields with the @ KMLElement{attr_names} macro
Base.@kwdef mutable struct AtomLink <: KMLElement{(:href, :rel, :type, :hreflang, :title, :length)}
    @option href::String
    @option rel::String
    @option type::String
    @option hreflang::String
    @option title::String
    @option length::Int # KML spec says 'length' attribute is xs:positiveInteger
    # Note: <atom:link> is typically an empty element with attributes.
    # If it could have text content you want to capture, add a 'content::String' field here.
    # Standard Atom links usually don't have direct text content.
end
TAG_TO_TYPE[:atom_link] = AtomLink # Manual mapping for namespaced tag

#────────────────────────────────  FEATURE LEVEL  ────────────────────────────
# Features are the core elements that are drawn on the Earth.

@def feature begin
    @object
    @option name ::String
    @option visibility ::Bool
    @option open ::Bool
    @option atom_author ::AtomAuthor
    @option atom_link ::AtomLink
    @option address ::String
    @option xal_AddressDetails::String # Consider if this is simple text or a complex type
    @option phoneNumber ::String
    @option Snippet ::Snippet
    @option description ::String
    @option AbstractView ::AbstractView
    @option TimePrimitive ::TimePrimitive # KML standard TimeStamp/TimeSpan
    @option styleUrl ::String
    @option StyleSelectors ::Vector{StyleSelector}
    @option Region ::Region
    @option ExtendedData ::ExtendedData

    # --- Google Extension (gx:) Fields for Features ---
    @altitude_mode_elements # This brings in gx_altitudeMode if it's not already there
    @option gx_balloonVisibility ::Bool
    # Add others that are simple children of Feature types:
    # @option gx_snippet ::String  // If there's a gx version of Snippet (less common for Feature directly)

    # Note: More complex gx types like gx:Tour, gx:Track, gx:MultiTrack are usually defined
    # as separate KMLElement structs and added via TAG_TO_TYPE, then become fields
    # where appropriate (e.g. gx_Playlist might have gx_TourPrimitives which include gx:Track).
    # Your gx_Track and gx_MultiTrack are already defined as Geometry/Object subtypes.
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
    @option when ::Vector{Union{TimeZones.ZonedDateTime,Dates.Date,String}}
    @option gx_coord ::Union{Vector{Coord2},Vector{Coord3}}
    @option gx_angles ::String # gx:angles is a space-separated string of 3 tuples usually
    @option Model ::Model
    @option ExtendedData::ExtendedData
    @option Icon ::Icon
end
Base.@kwdef mutable struct gx_MultiTrack <: Geometry
    @object
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
TAG_TO_TYPE[:kml] = KMLFile
TAG_TO_TYPE[:Placemark] = Placemark
TAG_TO_TYPE[:Point] = Point
TAG_TO_TYPE[:Polygon] = Polygon
TAG_TO_TYPE[:LineString] = LineString
TAG_TO_TYPE[:LinearRing] = LinearRing
TAG_TO_TYPE[:Style] = Style
TAG_TO_TYPE[:Document] = Document
TAG_TO_TYPE[:Folder] = Folder
# Manually map aliases for hotSpot to improve performance
TAG_TO_TYPE[:overlayXY] = KML.hotSpot
TAG_TO_TYPE[:screenXY] = KML.hotSpot
TAG_TO_TYPE[:rotationXY] = KML.hotSpot
TAG_TO_TYPE[:size] = KML.hotSpot
# MAnually handle <snippet> as if it were <Snippet>
TAG_TO_TYPE[:snippet] = KML.Snippet
# Manual mapping for <Pair> tag to KML.StyleMapPair
TAG_TO_TYPE[:Pair] = KML.StyleMapPair
# Manual mapping for <Url> tag to KML.Link. <Url> is a KML v2.1 element that is used to 
# specify a URL for a link. It has been deprecated in favor of <Link> in KML v2.2.
TAG_TO_TYPE[:Url] = KML.Link
