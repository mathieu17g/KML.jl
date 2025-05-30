module Features

export Placemark, NetworkLink, Document, Folder, GroundOverlay, ScreenOverlay,
       PhotoOverlay, gx_Tour, gx_Playlist, gx_AnimatedUpdate, gx_FlyTo, 
       gx_SoundCue, gx_TourControl, gx_Wait, Update, Create, Delete, Change

# Import from parent module's submodules
import ..Core
import ..Enums
import ..Coordinates
import ..Components
import ..TimeElements
import ..Styles
import ..Geometries
import ..Views

# Import specific items we need
using ..Core: Feature, Container, Overlay, Object, gx_TourPrimitive, KMLElement,
              AbstractView, AbstractUpdateOperation, TAG_TO_TYPE, 
              @option, @object, @def, @altitude_mode_elements

# ─── Feature Base Definition ─────────────────────────────────────────────────

@def feature begin
    @object
    @option name ::String
    @option visibility ::Bool
    @option open ::Bool
    @option atom_author ::Components.AtomAuthor      # Fully qualified
    @option atom_link ::Components.AtomLink          # Fully qualified
    @option address ::String
    @option xal_AddressDetails::String
    @option phoneNumber ::String
    @option Snippet ::Components.Snippet             # Fully qualified
    @option description ::String
    @option AbstractView ::AbstractView              # This one is from Core
    @option TimePrimitive ::TimeElements.TimePrimitive  # Fully qualified
    @option styleUrl ::String
    @option StyleSelectors ::Vector{Styles.StyleSelector}  # Fully qualified
    @option Region ::Components.Region               # Fully qualified
    @option ExtendedData ::Components.ExtendedData   # Fully qualified
    @altitude_mode_elements
    @option gx_balloonVisibility ::Bool
end

# ─── Basic Features ──────────────────────────────────────────────────────────

Base.@kwdef mutable struct Placemark <: Feature
    @feature
    @option Geometry ::Geometries.Geometry   # Fully qualified
end

Base.@kwdef mutable struct NetworkLink <: Feature
    @feature
    @option refreshVisibility::Bool
    @option flyToView ::Bool
    Link::Components.Link = Components.Link()   # Fully qualified
end

# ─── Container Features ──────────────────────────────────────────────────────

Base.@kwdef mutable struct Folder <: Container
    @feature
    @option Features::Vector{Feature}
end

Base.@kwdef mutable struct Document <: Container
    @feature
    @option Schemas ::Vector{Components.Schema}   # Fully qualified
    @option Features::Vector{Feature}
end

# ─── Overlay Features ────────────────────────────────────────────────────────

@def overlay begin
    @feature
    @option color ::String
    @option drawOrder::Int
    @option Icon ::Components.Icon   # Fully qualified
end

Base.@kwdef mutable struct GroundOverlay <: Overlay
    @overlay
    @option altitude ::Float64
    @option LatLonBox ::Components.LatLonBox         # Fully qualified
    @option gx_LatLonQuad ::Components.gx_LatLonQuad # Fully qualified
end

Base.@kwdef mutable struct ScreenOverlay <: Overlay
    @overlay
    @option overlayXY ::Components.overlayXY    # Fully qualified
    @option screenXY ::Components.screenXY      # Fully qualified
    @option rotationXY ::Components.rotationXY  # Fully qualified
    @option size ::Components.size              # Fully qualified
    rotation::Float64 = 0.0
end

Base.@kwdef mutable struct PhotoOverlay <: Overlay
    @overlay
    @option rotation ::Float64
    @option ViewVolume ::Components.ViewVolume      # Fully qualified
    @option ImagePyramid ::Components.ImagePyramid  # Fully qualified
    @option Point ::Geometries.Point                # Fully qualified
    @option shape ::Enums.shape                     # Fully qualified
end

# ─── Tour Primitives (Google Extensions) ─────────────────────────────────────

Base.@kwdef mutable struct Create <: AbstractUpdateOperation
    @object
    @option CreatedObjects::Vector{KMLElement}
end
TAG_TO_TYPE[:Create] = Create

Base.@kwdef mutable struct Delete <: AbstractUpdateOperation
    @object
    @option FeaturesToDelete::Vector{Feature}
end
TAG_TO_TYPE[:Delete] = Delete

Base.@kwdef mutable struct Change <: AbstractUpdateOperation
    @object
    @option ObjectsToChange::Vector{Object}
end
TAG_TO_TYPE[:Change] = Change

Base.@kwdef mutable struct Update <: KMLElement{()}
    @option targetHref ::String
    @option operations ::Vector{Union{Create,Delete,Change}}
end
TAG_TO_TYPE[:Update] = Update

Base.@kwdef mutable struct gx_AnimatedUpdate <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option Update ::Update
    @option gx_delayedStart ::Float64
end

Base.@kwdef mutable struct gx_FlyTo <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option gx_flyToMode ::Enums.flyToMode     # Fully qualified
    @option AbstractView ::AbstractView
end

Base.@kwdef mutable struct gx_SoundCue <: gx_TourPrimitive
    @object
    @option href ::String
    @option gx_delayedStart::Float64
end

Base.@kwdef mutable struct gx_TourControl <: gx_TourPrimitive
    @object
    gx_playMode::String = "pause"
end

Base.@kwdef mutable struct gx_Wait <: gx_TourPrimitive
    @object
    @option gx_duration::Float64
end

Base.@kwdef mutable struct gx_Playlist <: Object
    @object
    gx_TourPrimitives::Vector{gx_TourPrimitive} = []
end

Base.@kwdef mutable struct gx_Tour <: Feature
    @feature
    @option gx_Playlist ::gx_Playlist
end

end # module Features