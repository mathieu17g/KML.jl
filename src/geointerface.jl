#------------------------------------------------------------------------------
#  geointerface.jl – adds GeoInterface + pretty printing for KML geometries
#------------------------------------------------------------------------------

using GeoInterface
import Base: show

# bring the KML types from parent module into local scope ---------------------
const GI = GeoInterface

# --- Generic helpers ---------------------------------------------------------
GI.isgeometry(::KML.Geometry) = true
GI.isgeometry(::Type{<:KML.Geometry}) = true
GI.crs(::KML.Geometry) = GI.default_crs()

# --- Point -------------------------------------------------------------------
GI.geomtrait(::KML.Point) = GI.PointTrait()
GI.ncoord(::GI.PointTrait, p::KML.Point) = length(p.coordinates)
GI.getcoord(::GI.PointTrait, p::KML.Point, i) = p.coordinates[i]

# --- LineString --------------------------------------------------------------
GI.geomtrait(::KML.LineString) = GI.LineStringTrait()
GI.ncoord(::GI.LineStringTrait, ls::KML.LineString) = length(ls.coordinates)
GI.getcoord(::GI.LineStringTrait, ls::KML.LineString, i) = ls.coordinates[i]
GI.ngeom(::GI.LineStringTrait, ls::KML.LineString) = GI.ncoord(GI.LineStringTrait(), ls)
GI.getgeom(::GI.LineStringTrait, ls::KML.LineString, i) = ls.coordinates[i]

# --- LinearRing --------------------------------------------------------------
GI.geomtrait(::KML.LinearRing) = GI.LinearRingTrait()
GI.ncoord(::GI.LinearRingTrait, lr::KML.LinearRing) = lr.coordinates === nothing ? 0 : length(lr.coordinates)
GI.getcoord(::GI.LinearRingTrait, lr::KML.LinearRing, i) = lr.coordinates[i]
GI.ngeom(::GI.LinearRingTrait, lr::KML.LinearRing) = GI.ncoord(GI.LinearRingTrait(), lr)
GI.getgeom(::GI.LinearRingTrait, lr::KML.LinearRing, i) = lr.coordinates[i]

# --- Polygon -----------------------------------------------------------------
GI.geomtrait(::KML.Polygon) = GI.PolygonTrait()
GI.ngeom(::GI.PolygonTrait, poly::KML.Polygon) = 1 + (poly.innerBoundaryIs === nothing ? 0 : length(poly.innerBoundaryIs))
GI.getgeom(::GI.PolygonTrait, poly::KML.Polygon, i) = (i == 1 ? poly.outerBoundaryIs : poly.innerBoundaryIs[i-1])
GI.ncoord(::GI.PolygonTrait, poly::KML.Polygon) =
    (poly.outerBoundaryIs === nothing ? 0 : length(poly.outerBoundaryIs.coordinates))
GI.ncoord(::GI.PolygonTrait, poly::KML.Polygon, ring::Int) =
    ring == 1 ? length(poly.outerBoundaryIs.coordinates) : length(poly.innerBoundaryIs[ring-1].coordinates)
GI.getcoord(::GI.PolygonTrait, poly::KML.Polygon, ring::Int, i::Int) =
    ring == 1 ? poly.outerBoundaryIs.coordinates[i] : poly.innerBoundaryIs[ring-1].coordinates[i]

# --- MultiGeometry -----------------------------------------------------------
GI.geomtrait(::KML.MultiGeometry) = GI.GeometryCollectionTrait()
GI.ngeom(::GI.GeometryCollectionTrait, mg::KML.MultiGeometry) = (mg.Geometries === nothing ? 0 : length(mg.Geometries))
GI.getgeom(::GI.GeometryCollectionTrait, mg::KML.MultiGeometry, i) = mg.Geometries[i]
GI.ncoord(::GI.GeometryCollectionTrait, mg::KML.MultiGeometry) =
    (isempty(mg.Geometries) ? 0 : GI.ncoord(GI.geomtrait(mg.Geometries[1]), mg.Geometries[1]))

# --- Placemark feature helpers ----------------------------------------------
GI.isfeature(::KML.Placemark) = true
GI.isfeature(::Type{KML.Placemark}) = true
const _PLACEMARK_PROP_FIELDS = Tuple(filter(!=(Symbol("Geometry")), fieldnames(KML.Placemark)))
GI.properties(p::KML.Placemark) = (; (f => getfield(p, f) for f in _PLACEMARK_PROP_FIELDS)...)
GI.trait(::KML.Placemark) = GI.FeatureTrait()
GI.geometry(p::KML.Placemark) = p.Geometry
GI.crs(::KML.Placemark) = GI.default_crs()

# --- pretty print helpers ----------------------------------------------------
function show(io::IO, g::KML.Geometry)
    color_ok = (io isa Base.TTY) && get(io, :color, false)
    trait = GI.geomtrait(g)
    verts = GI.ncoord(trait, g)
    parts = GI.ngeom(trait, g)
    color_ok ? printstyled(io, nameof(typeof(g)); color = :cyan) : print(io, nameof(typeof(g)))
    print(io, "(vertices=", verts, ", parts=", parts, ")")
end
