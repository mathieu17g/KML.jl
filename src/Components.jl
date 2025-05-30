module Components

export Link, Icon, Orientation, Location, Scale, Lod, LatLonBox, LatLonAltBox, 
       Region, gx_LatLonQuad, hotSpot, overlayXY, screenXY, rotationXY, size,
       ItemIcon, ViewVolume, ImagePyramid, Snippet, Data, SimpleData, SchemaData,
       ExtendedData, Alias, ResourceMap, SimpleField, Schema, AtomAuthor, AtomLink

using ..Core: Object, NoAttributes, KMLElement, TAG_TO_TYPE, @option, @object, @altitude_mode_elements
using ..Enums
using ..Coordinates: Coord2

# ─── Utility / Simple Shared Component Nodes ─────────────────────────────────

Base.@kwdef mutable struct hotSpot <: KMLElement{(:x, :y, :xunits, :yunits)}
    @option x ::Float64
    @option y ::Float64
    @option xunits ::Enums.units
    @option yunits ::Enums.units
end

# Aliases for hotSpot
const overlayXY = hotSpot
const screenXY = hotSpot
const rotationXY = hotSpot
const size = hotSpot

# ─── Object-level Elements (Reusable Components) ─────────────────────────────

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
    @option w ::Int
    @option h ::Int
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

# ─── List Style Support ──────────────────────────────────────────────────────

Base.@kwdef mutable struct ItemIcon <: NoAttributes
    @option state::Enums.itemIconState
    @option href ::String
end

# ─── Photo Overlay Support ───────────────────────────────────────────────────

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

# ─── Data Elements ───────────────────────────────────────────────────────────

Base.@kwdef mutable struct Snippet <: KMLElement{(:maxLines,)}
    content::String = ""
    maxLines::Int = 2
end

Base.@kwdef mutable struct Data <: KMLElement{(:name,)}
    @object
    @option value ::String
    @option displayName ::String
end
TAG_TO_TYPE[:Data] = Data

Base.@kwdef mutable struct SimpleData <: KMLElement{(:name,)}
    content::String = ""
end
TAG_TO_TYPE[:SimpleData] = SimpleData

Base.@kwdef mutable struct SchemaData <: KMLElement{(:schemaUrl,)}
    @object
    @option SimpleDataVec ::Vector{SimpleData}
end
TAG_TO_TYPE[:SchemaData] = SchemaData

Base.@kwdef mutable struct ExtendedData <: NoAttributes
    @object
    @option children ::Vector{Union{Data,SchemaData,KMLElement}}  # Already fixed
end

# ─── Model Support ───────────────────────────────────────────────────────────

Base.@kwdef mutable struct Alias <: NoAttributes
    @option targetHref::String
    @option sourceHref::String
end

Base.@kwdef mutable struct ResourceMap <: NoAttributes
    @option Aliases::Vector{Alias}
end

# ─── Document Schema Support ─────────────────────────────────────────────────

Base.@kwdef mutable struct SimpleField <: KMLElement{(:type, :name)}
    type::String
    name::String
    @option displayName::String
end

Base.@kwdef mutable struct Schema <: KMLElement{(:id,)}
    id::String
    @option SimpleFields::Vector{SimpleField}
end

# ─── Atom Support ────────────────────────────────────────────────────────────

Base.@kwdef mutable struct AtomAuthor <: KMLElement{()}
    @option name::String
    @option uri::String
    @option email::String
end
TAG_TO_TYPE[:atom_author] = AtomAuthor

Base.@kwdef mutable struct AtomLink <: KMLElement{(:href, :rel, :type, :hreflang, :title, :length)}
    @option href::String
    @option rel::String
    @option type::String
    @option hreflang::String
    @option title::String
    @option length::Int
end
TAG_TO_TYPE[:atom_link] = AtomLink

end # module Components