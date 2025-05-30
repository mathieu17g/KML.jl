#------------------------------------------------------------------------------
#  types.jl  –  Aggregates all KML type modules
#------------------------------------------------------------------------------

# Include Core first and make it available
include("Core.jl")

# Include other modules in dependency order
include("TimeElements.jl")
include("Components.jl")
include("Styles.jl")
include("Views.jl")
include("Geometries.jl")
include("Features.jl")

# Import everything from submodules into the parent module namespace
using .Core
using .TimeElements
using .Components
using .Styles
using .Views
using .Geometries
using .Features

# Re-export all types
for mod in [Core, TimeElements, Components, Styles, Views, Geometries, Features]
    for name in names(mod; all = false)
        if name != nameof(mod)  # Don't export the module name itself
            @eval export $name
        end
    end
end

# Import for TAG_TO_TYPE population
import .Core: TAG_TO_TYPE, all_concrete_subtypes, KMLElement

# ─── TAG → Type map population ───────────────────────────────────────────────
function _collect_concrete!(root)
    for S in all_concrete_subtypes(root)
        TAG_TO_TYPE[Symbol(replace(string(S), r".*\." => ""))] = S
    end
end
_collect_concrete!(KMLElement)

# Manual mappings (use fully qualified names)
TAG_TO_TYPE[:kml] = Core.KMLFile
TAG_TO_TYPE[:Placemark] = Features.Placemark
TAG_TO_TYPE[:Point] = Geometries.Point
TAG_TO_TYPE[:Polygon] = Geometries.Polygon
TAG_TO_TYPE[:LineString] = Geometries.LineString
TAG_TO_TYPE[:LinearRing] = Geometries.LinearRing
TAG_TO_TYPE[:Style] = Styles.Style
TAG_TO_TYPE[:Document] = Features.Document
TAG_TO_TYPE[:Folder] = Features.Folder
TAG_TO_TYPE[:overlayXY] = Components.hotSpot
TAG_TO_TYPE[:screenXY] = Components.hotSpot
TAG_TO_TYPE[:rotationXY] = Components.hotSpot
TAG_TO_TYPE[:size] = Components.hotSpot
TAG_TO_TYPE[:snippet] = Components.Snippet
TAG_TO_TYPE[:Url] = Components.Link