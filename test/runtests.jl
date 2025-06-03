using KML
using GeoInterface
using Test
using XML
using StaticArrays  # Add this import



@testset "Issue Coverage" begin
    # https://github.com/JuliaComputing/KML.jl/issues/8
    @test_warn "Unhandled Tag" read(joinpath(@__DIR__, "outside_spec.kml"), KMLFile)

    # https://github.com/JuliaComputing/KML.jl/issues/12
    @test read(joinpath(@__DIR__, "issue12.kml"), KMLFile) isa KMLFile
end

@testset "Empty Constructors" begin
    for T in KML.all_concrete_subtypes(KML.Object)
        @test T() isa T
    end
    @testset "Empty constructor roundtrips with XML.Node" begin
        for T in KML.all_concrete_subtypes(KML.Object)
            o = T()
            n = KML.to_xml(o)
            tag = XML.tag(n)
            if !isnothing(tag)
                @test occursin(tag, replace(string(T), '_' => ':'))
            end
            o2 = KML.object(n)
            @test o2 isa T
            @test o == o2
        end
    end
end


@testset "GeoInterface" begin
    # Use SVector for coordinates instead of tuples
    @test GeoInterface.testgeometry(Point(coordinates = SVector(0.0, 0.0)))
    @test GeoInterface.testgeometry(LineString(coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0)]))
    @test GeoInterface.testgeometry(LinearRing(coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0), SVector(2.0, 2.0)]))

    p = Polygon(
        outerBoundaryIs = LinearRing(
            coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0), SVector(2.0, 2.0), SVector(0.0, 0.0)],
        ),
        innerBoundaryIs = [
            LinearRing(coordinates = [SVector(0.5, 0.5), SVector(0.7, 0.7), SVector(0.0, 0.0), SVector(0.5, 0.5)]),
        ],
    )
    @test GeoInterface.testgeometry(p)

    # Create a Placemark with some properties to avoid empty tuple issue
    placemark = Placemark(name = "Test Placemark", description = "A test placemark", Geometry = p)
    @test GeoInterface.testfeature(placemark)

    # Test that the geometry is correctly extracted
    @test GeoInterface.geometry(placemark) === p

    # Test that properties are correctly extracted
    props = GeoInterface.properties(placemark)
    @test props.name == "Test Placemark"
    @test props.description == "A test placemark"
end

@testset "KMLFile roundtrip" begin
    file = read(joinpath(@__DIR__, "example.kml"), KMLFile)
    @test file isa KMLFile

    temp = tempname() * ".kml"

    try
        # Write the file
        KML.write(temp, file)
        
        # Debug: Check file sizes AFTER writing
        original_size = filesize(joinpath(@__DIR__, "example.kml"))
        written_size = filesize(temp)
        println("Original file size: $original_size bytes")
        println("Written file size: $written_size bytes")
        
        # Debug: Read and print the written file content AFTER writing
        written_content = read(temp, String)
        println("Written file content (first 500 chars):")
        println(written_content[1:min(500, end)])

        # Now read it back
        file2 = read(temp, KMLFile)
        
        # Debug: Check what's in each KMLFile
        println("\nOriginal KMLFile children: ", length(file.children))
        println("Roundtrip KMLFile children: ", length(file2.children))
        
        @test file == file2
    finally
        # Clean up
        try
            rm(temp, force = true)
        catch
            # Ignore deletion errors
        end
    end
end

@testset "coordinates" begin
    # `coordinates` are single coordinate (2D or 3D)
    s = "<Point><coordinates>1,2,3</coordinates></Point>"
    p = KML.object(XML.parse(s, XML.Node)[1])
    @test p isa Point
    @test p.coordinates isa SVector{3,Float64}
    @test p.coordinates == SVector(1.0, 2.0, 3.0)

    # `coordinates` are vector of coordinates
    s = "<LineString><coordinates>1,2,3 4,5,6</coordinates></LineString>"
    ls = KML.object(XML.parse(s, XML.Node)[1])
    @test ls isa LineString
    @test ls.coordinates isa Vector{SVector{3,Float64}}
    @test length(ls.coordinates) == 2
    @test ls.coordinates[1] == SVector(1.0, 2.0, 3.0)
    @test ls.coordinates[2] == SVector(4.0, 5.0, 6.0)
end

# Add tests for new features
@testset "Lazy Loading" begin
    lazy_file = read(joinpath(@__DIR__, "example.kml"), LazyKMLFile)
    @test lazy_file isa LazyKMLFile

    # Test conversion to KMLFile
    kml_file = KMLFile(lazy_file)
    @test kml_file isa KMLFile
end

@testset "Navigation" begin
    file = read(joinpath(@__DIR__, "example.kml"), KMLFile)

    # Test children function
    kids = KML.children(file)
    @test length(kids) > 0

    # Test iteration
    count = 0
    for child in file
        count += 1
    end
    @test count == length(file)

    # Test indexing
    @test file[1] == kids[1]
end

@testset "Coordinate Parsing" begin
    # Test various coordinate formats
    coords = KML.parse_coordinates_automa("1,2")
    @test coords == [SVector(1.0, 2.0)]

    coords = KML.parse_coordinates_automa("1,2,3")
    @test coords == [SVector(1.0, 2.0, 3.0)]

    coords = KML.parse_coordinates_automa("1,2 3,4")
    @test coords == [SVector(1.0, 2.0), SVector(3.0, 4.0)]

    coords = KML.parse_coordinates_automa("1,2,3 4,5,6")
    @test coords == [SVector(1.0, 2.0, 3.0), SVector(4.0, 5.0, 6.0)]

    # Test with whitespace variations
    coords = KML.parse_coordinates_automa("  1.5 , 2.5  \n  3.5 , 4.5  ")
    @test coords == [SVector(1.5, 2.5), SVector(3.5, 4.5)]
end