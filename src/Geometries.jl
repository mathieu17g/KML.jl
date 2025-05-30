module Geometries

export Point, LineString, LinearRing, Polygon, MultiGeometry, Model, gx_Track, gx_MultiTrack

using ..Core: Geometry, Object, TAG_TO_TYPE, @option, @object, @altitude_mode_elements
using ..Enums
using ..Coordinates: Coord2, Coord3
using ..Components: Location, Orientation, Scale, Link, ResourceMap, ExtendedData, Icon  # Remove "Model as ModelComponent"
using ..TimeElements: TimePrimitive
using TimeZones, Dates

# ─── Basic Geometry Types ────────────────────────────────────────────────────

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

# ─── 3D Model Geometry ───────────────────────────────────────────────────────

Base.@kwdef mutable struct Model <: Geometry
    @object
    @altitude_mode_elements
    @option Location ::Location
    @option Orientation ::Orientation
    @option Scale ::Scale
    @option Link ::Link
    @option ResourceMap ::ResourceMap
end

# ─── Google Extensions (gx:) ─────────────────────────────────────────────────

Base.@kwdef mutable struct gx_Track <: Geometry
    @object
    @altitude_mode_elements
    @option when ::Vector{Union{TimeZones.ZonedDateTime,Dates.Date,String}}
    @option gx_coord ::Union{Vector{Coord2},Vector{Coord3}}
    @option gx_angles ::String
    @option Model ::Model
    @option ExtendedData::ExtendedData
    @option Icon ::Icon
end

Base.@kwdef mutable struct gx_MultiTrack <: Geometry
    @object
    @option gx_interpolate::Bool
    @option gx_Track ::Vector{gx_Track}
end

end # module Geometries