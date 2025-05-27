module KML

# ─── base deps ────────────────────────────────────────────────────────────────
using OrderedCollections: OrderedDict
import XML: XML, read as xmlread, parse as xmlparse, write as xmlwrite, Node, LazyNode, nodetype # xml parsing / writing
using InteractiveUtils: subtypes    # all subtypes of a type
using StaticArrays                  # small fixed‑size coordinate vectors
using Automa, Parsers               # for coordinates parsing

# ─── split implementation files ──────────────────────────────────────────────
include("types.jl")             # all KML data types & helpers (no GeoInterface)
include("utils.jl")             # utility functions (e.g., for parsing)
include("geointerface.jl")      # GeoInterface extensions & pretty printing
include("parsing.jl")           # XML → struct & struct → XML
include("tables.jl")            # Tables.jl wrapper for Placemarks
using .TablesBridge             # re‑export ?

# ─── re‑export public names ──────────────────────────────────────────────────
export KMLFile, LazyKMLFile, Enums, object   # the "root" objects most users need
export unwrap_single_part_multigeometry       # utility function
export PlacemarkTable, list_layers, get_layer_names, get_num_layers

for T in vcat(
    all_concrete_subtypes(KMLElement),        # concrete types
    all_abstract_subtypes(Object),            # abstract sub‑hierarchy
)
    T === KML.Pair && continue                # skip internal helper
    @eval export $(Symbol(replace(string(T), "KML." => "")))
end

function __init__()
    # Handle all available errors!
    Base.Experimental.register_error_hint(_read_kmz_file_from_path_error_hinter, MethodError)
end

end # module