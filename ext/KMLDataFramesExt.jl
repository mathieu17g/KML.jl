# ext/KMLDataFramesExt.jl

module KMLDataFramesExt

using DataFrames
import KML
import KML: KMLFile, PlacemarkTable, read


"""
    DataFrame(kml_file::KML.KMLFile; layer::Union{Nothing,String,Integer}=nothing)

Constructs a DataFrame from the Placemarks in a `KMLFile` object.

# Arguments
- `kml_file::KML.KMLFile`: The KMLFile object already read into memory.
- `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.
    - If `nothing` (default): The behavior is defined by `KML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
    - If `String`: The name of the Document or Folder to use as the layer.
    - If `Integer`: The index of the layer to use.
"""
function DataFrames.DataFrame(kml_file::KMLFile; layer::Union{Nothing,String,Integer}=nothing)
    # KML.PlacemarkTable already handles the layer selection logic 
    placemark_table = PlacemarkTable(kml_file; layer=layer)
    return DataFrame(placemark_table)
end

"""
    DataFrame(kml_path::AbstractString; layer::Union{Nothing,String,Integer}=nothing)

Constructs a DataFrame from the Placemarks in a KML file specified by its path.

# Arguments
- `kml_path::AbstractString`: Path to the .kml or .kmz file.
- `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.
    - If `nothing` (default): The behavior is defined by `KML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
    - If `String`: The name of the Document or Folder to use as the layer.
    - If `Integer`: The index of the layer to use.
"""
function DataFrames.DataFrame(kml_path::AbstractString; layer::Union{Nothing,String,Integer}=nothing)
    # Read the KML file first 
    # We read the whole KML file here, and let PlacemarkTable handle the layer filtering.
    # If you modify Base.read to accept a layer kwarg and filter at read time,
    # you might reconsider if you want to pass the layer argument to KML.read here.
    # For now, this approach is clean as PlacemarkTable is designed for this.
    kml_file_obj = read(kml_path, KMLFile) # from parsing.txt 

    # Then, use the KMLFile constructor for DataFrame
    return DataFrame(kml_file_obj; layer=layer)
end

end # module KMLDataFramesExt