module KML

# ─── base deps ────────────────────────────────────────────────────────────────
using OrderedCollections: OrderedDict
import XML: XML, read as xmlread, parse as xmlparse, write as xmlwrite, Node # xml parsing / writing
using InteractiveUtils: subtypes    # all subtypes of a type
using StaticArrays                  # small fixed‑size coordinate vectors
using Parsers

# ─── split implementation files ──────────────────────────────────────────────
include("types.jl")             # all KML data types & helpers (no GeoInterface)
include("geointerface.jl")      # GeoInterface extensions & pretty printing
include("parsing.jl")           # XML → struct & struct → XML
# include("TablesInterface.jl")   # Tables.jl wrapper for Placemarks
include("tables.jl")            # Tables.jl wrapper for Placemarks
using .TablesBridge             # re‑export ?

# ─── re‑export public names ──────────────────────────────────────────────────
export KMLFile, Enums, object  # the “root” objects most users need
export PlacemarkTable

for T in vcat(
    all_concrete_subtypes(KMLElement),        # concrete types
    all_abstract_subtypes(Object),            # abstract sub‑hierarchy
)
    T === KML.Pair && continue                # skip internal helper
    @eval export $(Symbol(replace(string(T), "KML." => "")))
end

end # module
