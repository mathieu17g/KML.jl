module Styles

export LineStyle, PolyStyle, IconStyle, LabelStyle, ListStyle, BalloonStyle,
       Style, StyleMapPair, StyleMap

using ..Core: StyleSelector, SubStyle, ColorStyle, Object, TAG_TO_TYPE,
              @option, @object, @def
import ..Enums
import ..Components: Icon, hotSpot, ItemIcon

# ─── Color Style Base ────────────────────────────────────────────────────────

@def colorstyle begin
    @object
    @option color ::String
    @option colorMode ::Enums.colorMode
end

# ─── SubStyle Elements ───────────────────────────────────────────────────────

Base.@kwdef mutable struct LineStyle <: ColorStyle
    @colorstyle
    @option width ::Float64
    @option gx_outerColor ::String
    @option gx_outerWidth ::Float64
    @option gx_physicalWidth::Float64
    @option gx_labelVisibility::Bool
end

Base.@kwdef mutable struct PolyStyle <: ColorStyle
    @colorstyle
    @option fill ::Bool
    @option outline::Bool
end

Base.@kwdef mutable struct IconStyle <: ColorStyle
    @colorstyle
    @option scale ::Float64
    @option heading ::Float64
    @option Icon ::Icon
    @option hotSpot ::hotSpot
end

Base.@kwdef mutable struct LabelStyle <: ColorStyle
    @colorstyle
    @option scale::Float64
end

Base.@kwdef mutable struct ListStyle <: SubStyle
    @object
    @option listItemType::Symbol
    @option bgColor ::String
    @option ItemIcons ::Vector{ItemIcon}
end

Base.@kwdef mutable struct BalloonStyle <: SubStyle
    @object
    @option bgColor ::String
    @option textColor ::String
    @option text ::String
    @option displayMode::Enums.displayMode
end

# ─── Style Selectors ─────────────────────────────────────────────────────────

Base.@kwdef mutable struct Style <: StyleSelector
    @object
    @option IconStyle ::IconStyle
    @option LabelStyle ::LabelStyle
    @option LineStyle ::LineStyle
    @option PolyStyle ::PolyStyle
    @option BalloonStyle::BalloonStyle
    @option ListStyle ::ListStyle
end

Base.@kwdef mutable struct StyleMapPair <: Object
    @object
    @option key ::Enums.styleState
    @option styleUrl::String
    @option Style ::Style
end

Base.@kwdef mutable struct StyleMap <: StyleSelector
    @object
    @option Pairs::Vector{StyleMapPair}
end

# Add to TAG_TO_TYPE
TAG_TO_TYPE[:Pair] = StyleMapPair  # Manual mapping for <Pair> tag

end # module Styles