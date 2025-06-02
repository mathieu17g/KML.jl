module KMLMakieExt

using KML
using Makie

# Define plotting recipes for KML geometry types
Makie.plottype(::KML.Point) = Makie.Scatter
Makie.plottype(::KML.LineString) = Makie.Lines
Makie.plottype(::KML.LinearRing) = Makie.Lines
Makie.plottype(::KML.Polygon) = Makie.Poly

# Point plotting
function Makie.convert_arguments(P::Type{<:Scatter}, point::KML.Point)
    coords = point.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(coords[1], coords[2])],)
end

# LineString plotting
function Makie.convert_arguments(P::Type{<:Lines}, ls::KML.LineString)
    coords = ls.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(c[1], c[2]) for c in coords],)
end

# LinearRing plotting (same as LineString)
function Makie.convert_arguments(P::Type{<:Lines}, lr::KML.LinearRing)
    coords = lr.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(c[1], c[2]) for c in coords],)
end

# Polygon plotting
function Makie.convert_arguments(P::Type{<:Poly}, poly::KML.Polygon)
    outer = poly.outerBoundaryIs
    if isnothing(outer) || isnothing(outer.coordinates)
        return ([Point2f(NaN, NaN)],)
    end
    
    # Convert to Point2f array
    points = [Point2f(c[1], c[2]) for c in outer.coordinates]
    
    # Handle holes if present
    if !isnothing(poly.innerBoundaryIs) && !isempty(poly.innerBoundaryIs)
        # For polygons with holes, we need to return a vector of polygons
        # where the first is the outer boundary and the rest are holes
        holes = [Point2f.([(c[1], c[2]) for c in ring.coordinates]) 
                 for ring in poly.innerBoundaryIs 
                 if !isnothing(ring.coordinates)]
        return ([points, holes...],)
    end
    
    return (points,)
end

# Recipe for MultiGeometry
@recipe(KMLMultiGeom, multigeometry) do scene
    Attributes()
end

function Makie.plot!(plot::KMLMultiGeom)
    mg = plot.multigeometry[]
    if !isnothing(mg.Geometries)
        for geom in mg.Geometries
            Makie.plot!(plot, geom)
        end
    end
    plot
end

# Register MultiGeometry to use the recipe
Makie.plottype(::KML.MultiGeometry) = KMLMultiGeom

# Handle arrays of KML geometries
function Makie.convert_arguments(P::Type{<:Scatter}, points::AbstractVector{<:KML.Point})
    coords = Point2f[]
    for p in points
        if !isnothing(p.coordinates)
            push!(coords, Point2f(p.coordinates[1], p.coordinates[2]))
        end
    end
    return (coords,)
end

function Makie.convert_arguments(P::Type{<:Lines}, lines::AbstractVector{<:Union{KML.LineString, KML.LinearRing}})
    all_coords = Vector{Point2f}[]
    for line in lines
        if !isnothing(line.coordinates)
            push!(all_coords, [Point2f(c[1], c[2]) for c in line.coordinates])
        end
    end
    return (all_coords,)
end

function Makie.convert_arguments(P::Type{<:Poly}, polys::AbstractVector{<:KML.Polygon})
    all_polys = Vector{Point2f}[]
    for poly in polys
        if !isnothing(poly.outerBoundaryIs) && !isnothing(poly.outerBoundaryIs.coordinates)
            push!(all_polys, [Point2f(c[1], c[2]) for c in poly.outerBoundaryIs.coordinates])
        end
    end
    return (all_polys,)
end

end # module KMLMakieExt