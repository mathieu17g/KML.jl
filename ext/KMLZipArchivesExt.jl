module KMLZipArchivesExt

using ZipArchives
import KML
import KML: KMZ_KMxFileType, xmlread, _parse_kmlfile, KMLFile, LazyKMLFile, Node, LazyNode

# Helper function to find the main KML file in a KMZ archive
function _find_kml_entry_in_kmz(zip_reader)
    potential_kmls = String[]
    for entry_name_str in zip_names(zip_reader)
        if lowercase(splitext(entry_name_str)[2]) == ".kml"
            push!(potential_kmls, entry_name_str)
        end
    end

    if isempty(potential_kmls)
        error("No .kml file found within the KMZ archive")
    end

    # Prioritization logic for KML entry
    if "doc.kml" in potential_kmls
        return "doc.kml"
    elseif any(name -> lowercase(basename(name)) == "doc.kml", potential_kmls)
        return first(filter(name -> lowercase(basename(name)) == "doc.kml", potential_kmls))
    elseif "root.kml" in potential_kmls
        return "root.kml"
    elseif any(name -> lowercase(basename(name)) == "root.kml", potential_kmls)
        return first(filter(name -> lowercase(basename(name)) == "root.kml", potential_kmls))
    else
        root_kmls = filter(name -> !occursin('/', name) && !occursin('\\', name), potential_kmls)
        if !isempty(root_kmls)
            return first(root_kmls)
        else
            return first(potential_kmls)
        end
    end
end

# Existing function for regular KMLFile
function KML._read_file_from_path(::KMZ_KMxFileType, kmz_path::AbstractString)::KML.KMLFile
    try
        zip_reader = ZipReader(read(kmz_path))
        kml_entry_name = _find_kml_entry_in_kmz(zip_reader)

        kml_content_stream = zip_openentry(zip_reader, kml_entry_name)
        doc = xmlread(kml_content_stream, Node)
        close(kml_content_stream)

        return _parse_kmlfile(doc)::KMLFile
    catch e
        @error "KMZ reading via extension failed for '$kmz_path'." exception = (e, catch_backtrace())
        rethrow()
    end
end

# New function for LazyKMLFile
function KML._read_lazy_file_from_path(::KMZ_KMxFileType, kmz_path::AbstractString)::KML.LazyKMLFile
    try
        zip_reader = ZipReader(read(kmz_path))
        kml_entry_name = _find_kml_entry_in_kmz(zip_reader)

        kml_content_stream = zip_openentry(zip_reader, kml_entry_name)
        doc = xmlread(kml_content_stream, LazyNode)
        close(kml_content_stream)

        return LazyKMLFile(doc)
    catch e
        @error "Lazy KMZ reading via extension failed for '$kmz_path'." exception = (e, catch_backtrace())
        rethrow()
    end
end

end # module KMLZipArchivesExt