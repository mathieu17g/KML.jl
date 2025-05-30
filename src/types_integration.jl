# This file provides the integration between Core types and parsing functions
# It must be included AFTER both types.jl and parsing.jl

import .Core
import XML
using OrderedCollections: OrderedDict

# Import Node and _parse_kmlfile from parsing module
import ..Node, .._parse_kmlfile

# Define Node conversion for KMLFile (only defined here)
function Node(k::Core.KMLFile)
    children = map(k.children) do child
        if child isa XML.AbstractXMLNode && !(child isa XML.Node)
            XML.Node(child)
        elseif child isa Core.KMLElement
            Node(child)
        else
            child
        end
    end

    XML.Node(
        XML.Document,
        nothing,
        nothing,
        nothing,
        [
            XML.Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8")),
            XML.Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, children),
        ],
    )
end

# Provide KMLFile conversion from LazyKMLFile (only defined here)
function Core.KMLFile(lazy::Core.LazyKMLFile)
    _parse_kmlfile(lazy.root_node)
end

# Define the show method for KMLElement (only defined here)
function Base.show(io::IO, o::T) where {names,T<:Core.KMLElement{names}}
    printstyled(io, T; color = :light_cyan)
    print(io, ": [")
    show(io, Node(o))  
    print(io, "]")
end

# Define XML.children for KMLElement (only defined here)
XML.children(o::Core.KMLElement) = XML.children(Node(o))