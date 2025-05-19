# ext/KMLDataFramesExt.jl

module KMLDataFramesExt

using DataFrames
import KML
import KML: KMLFile, PlacemarkTable, read


"""
    DataFrame(kml_file::KML.KMLFile; layer::Union{Nothing,String,Integer}=nothing, simplify_single_parts::Bool=false)

Constructs a DataFrame from the Placemarks in a `KMLFile` object.

# Arguments

  - `kml_file::KML.KMLFile`: The KMLFile object already read into memory.

  - `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.

      + If `nothing` (default): The behavior is defined by `KML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
      + If `String`: The name of the Document or Folder to use as the layer.
      + If `Integer`: The index of the layer to use.
  - `simplify_single_parts::Bool=false`: If `true`, when a MultiGeometry contains only a single geometry part, that part is extracted directly, simplifying the structure. For example, a MultiGeometry containing a single LineString will be treated as a LineString. Defaults to `false`.
"""
function DataFrames.DataFrame(
    kml_file::KML.KMLFile;
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    placemark_table = KML.PlacemarkTable(kml_file; layer = layer, simplify_single_parts = simplify_single_parts)
    return DataFrames.DataFrame(placemark_table)
end

"""
    DataFrame(kml_path::AbstractString; layer::Union{Nothing,String,Integer}=nothing, simplify_single_parts::Bool=false)

Constructs a DataFrame from the Placemarks in a KML file specified by its path.

# Arguments

  - `kml_path::AbstractString`: Path to the .kml or .kmz file.
  - `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.

      + If `nothing` (default): The behavior is defined by `KML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
      + If `String`: The name of the Document or Folder to use as the layer.
      + If `Integer`: The index of the layer to use.
  - `simplify_single_parts::Bool=false`: If `true`, when a MultiGeometry contains only a single geometry part, it will be simplified to that single geometry. For example, a MultiGeometry containing a single Point will become just a Point. Defaults to `false`.
"""
function DataFrames.DataFrame(
    kml_path::AbstractString;
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    kml_file_obj = KML.read(kml_path, KML.KMLFile)
    return DataFrames.DataFrame(kml_file_obj; layer = layer, simplify_single_parts = simplify_single_parts)
end

end # module KMLDataFramesExt