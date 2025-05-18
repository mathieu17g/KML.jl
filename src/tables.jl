module TablesBridge

export PlacemarkTable, list_layers

using Tables
import ..KML: KMLFile, read, Feature, Document, Folder, Placemark, Geometry, object
import XML: parse, Node
using Base.Iterators: flatten
import REPL
using REPL.TerminalMenus

include("HtmlEntitiesAutoma.jl")
using .HtmlEntitiesAutoma: decode_named_entities

#────────────────────────────── helpers ──────────────────────────────#
function _top_level_features(file::KMLFile)::Vector{Feature}
    feats = Feature[c for c in file.children if c isa Feature]
    if isempty(feats)
        for c in file.children
            if (c isa Document || c isa Folder) && c.Features !== nothing
                append!(feats, c.Features)
            end
        end
    end
    feats
end

function _determine_layers(features::Vector{Feature})
    if length(features) == 1
        f = features[1]
        if f isa Document || f isa Folder
            sub = (f.Features !== nothing ? f.Features : Feature[])
            return [x for x in sub if x isa Document || x isa Folder], Placemark[x for x in sub if x isa Placemark], f
        else
            return Feature[], (f isa Placemark ? [f] : Placemark[]), nothing
        end
    else
        return [x for x in features if x isa Document || x isa Folder],
        Placemark[x for x in features if x isa Placemark],
        nothing
    end
end

# Returns: Vector of Tuples: (index::Int, name::String, source_object_or_vector::Any)
function _get_layer_info(file::KMLFile)
    layer_infos = Tuple{Int,String,Any}[]
    idx_counter = 0

    # Logic based on _determine_layers and _select_layer from TablesBridge
    top_feats = TablesBridge._top_level_features(file)

    #───────────────────────────────────────────────────────────────────#
    # Scenario 1: Single Top-Level Document/Folder                      #
    #───────────────────────────────────────────────────────────────────#

    if length(top_feats) == 1 && (top_feats[1] isa Document || top_feats[1] isa Folder)
        main_container = top_feats[1]
        if main_container.Features !== nothing
            for feat in main_container.Features
                if feat isa Document || feat isa Folder
                    idx_counter += 1
                    layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                    push!(layer_infos, (idx_counter, layer_name, feat))
                end
            end
            # Check for direct placemarks in this main container
            direct_pms_in_container = [f for f in main_container.Features if f isa Placemark]
            if !isempty(direct_pms_in_container)
                idx_counter += 1
                push!(
                    layer_infos,
                    (
                        idx_counter,
                        "<Placemarks in $(main_container.name !== nothing ? main_container.name : "Top Container")>",
                        direct_pms_in_container,
                    ),
                )
            end
        end

        #───────────────────────────────────────────────────────────────────#
        # Scenario 2: Multiple Top-Level Features or Direct Placemarks      #
        #───────────────────────────────────────────────────────────────────#

    else
        # Top-level containers (Documents/Folders)
        for feat in top_feats
            if feat isa Document || feat isa Folder
                idx_counter += 1
                layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                push!(layer_infos, (idx_counter, layer_name, feat))
            end
        end
        # Top-level direct placemarks
        direct_top_pms = [f for f in top_feats if f isa Placemark]
        if !isempty(direct_top_pms)
            idx_counter += 1
            push!(layer_infos, (idx_counter, "<Ungrouped Top-Level Placemarks>", direct_top_pms))
        end
    end

    #───────────────────────────────────────────────────────────────────────────#
    #  No layers or placemarks found by the above logic                         #
    #  → The KMLFile may be empty, malformed, or follow an unusual structure    #
    #  → Verify the input or extend parsing logic for custom scenarios          #
    #───────────────────────────────────────────────────────────────────────────#

    if isempty(layer_infos) && !isempty(file.children)
        # This case might indicate placemarks directly under <kml> if parsing.jl handles that,
        # or just no recognizable layer structure.
    end

    return layer_infos
end

function _select_layer(file::KMLFile, layer_spec::Union{Nothing,String,Integer})
    layer_options = _get_layer_info(file) # Assuming _get_layer_info is accessible here

    if isempty(layer_options)
        return Feature[] # Or throw error("No layers or placemarks found to select from.")
    end

    if layer_spec isa String
        for (_, name, source) in layer_options
            if name == layer_spec
                return source # source is Document, Folder, or Vector{Placemark}
            end
        end
        error("Layer \"$layer_spec\" not found by name. Available: $(join([opt[2] for opt in layer_options], ", "))")
    elseif layer_spec isa Integer
        if 1 <= layer_spec <= length(layer_options)
            return layer_options[layer_spec][3] # Return the source_object_or_vector
        else
            # Construct the detailed layer list string
            layer_details_parts = String[]
            # layer_options is already available and is the result of _get_layer_info(file)
            for (idx, name, origin) in layer_options
                item_count_str = ""
                if origin isa Vector{Placemark}
                    item_count_str = " ($(length(origin)) placemarks)"
                elseif origin isa Document || origin isa Folder
                    num_direct_children = origin.Features !== nothing ? length(origin.Features) : 0
                    item_count_str = " (Container with $num_direct_children direct items)"
                end
                push!(layer_details_parts, "  [$idx] $name$item_count_str")
            end
            layer_details_str = join(layer_details_parts, "\n")
            error(
                "Layer index $layer_spec out of bounds. Must be between 1 and $(length(layer_options)).\nAvailable layers:\n$layer_details_str",
            )
        end
    elseif layer_spec === nothing # Interactive or default selection
        if length(layer_options) == 1
            return layer_options[1][3]
        end
        # Interactive selection logic (from your current _select_layer)
        opts = [opt[2] for opt in layer_options] # Get just names for menu
        interactive = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()
        if interactive
            menu = RadioMenu(opts; pagesize = min(10, length(opts)))
            choice_idx = request("Select a layer:", menu)
            choice_idx == -1 && error("Layer selection cancelled.")
            return layer_options[choice_idx][3]
        else
            @warn "Multiple layers available. Picking first: \"$(layer_options[1][2])\"."
            return layer_options[1][3]
        end
    end
    return Feature[] # Should not be reached if logic is correct
end

#───────────────────────────── list_layers function ────────────────────────────#
"""
    list_layers(kml_input::Union{AbstractString,KMLFile})

Prints a list of available "layers" found within a KML file to the console.

Layers are identified based on common KML structuring patterns, such as:

  - Direct `Placemark`s within a `Document` or `Folder`.
  - `Folder`s or `Document`s themselves, which can act as containers for `Placemark`s or other features.

For each identified layer, the function displays:

  - An index number (for easy reference, e.g., when using `get_placemarks_from_layer`).
  - The name of the layer (e.g., `Document` name, `Folder` name, or a generic name if not specified).
  - A count of items within that layer (e.g., number of `Placemark`s or direct children in a container).

If no distinct layers are found, or if the KML contains no `Placemark`s within common structural elements, a message indicating this is printed.

# Arguments

  - `kml_input`: Either a string representing the path to a KML file or a `KMLFile` object that has already been read.
"""
function list_layers(kml_input::Union{AbstractString,KMLFile})
    file = kml_input isa KMLFile ? kml_input : read(kml_input, KMLFile)
    println("Available layers:")
    layer_infos = _get_layer_info(file)

    if isempty(layer_infos)
        println("  No distinct layers found (or KML contains no Placemarks in common structures).")
        return
    end

    for (idx, name, origin) in layer_infos
        item_count_str = ""
        if origin isa Vector{Placemark}
            item_count_str = " ($(length(origin)) placemarks)"
        elseif origin isa Document || origin isa Folder
            # Quick check for direct placemarks or sub-features for context
            num_direct_children = origin.Features !== nothing ? length(origin.Features) : 0
            item_count_str = " (Container with $num_direct_children direct items)"
        end
        println("  [$idx] $name$item_count_str")
    end
end

#─────────────────────────── get_layer_names function ───────────────────────────#
"""
    get_layer_names(kml_input::Union{AbstractString,KMLFile})::Vector{String}

Returns an array of strings containing the names of available "layers"
found within a KML file.

Layers are identified based on common KML structuring patterns, such as:
  - Direct `Placemark`s within a `Document` or `Folder`.
  - `Folder`s or `Document`s themselves, which can act as containers for `Placemark`s or other features.

If no distinct layers are found, or if the KML contains no `Placemark`s
within common structural elements, an empty array is returned.

# Arguments
  - `kml_input`: Either a string representing the path to a KML file or a `KMLFile` object that has already been read.

# Returns
  - `Vector{String}`: An array of layer names.
"""
function get_layer_names(kml_input::Union{AbstractString,KMLFile})::Vector{String}
    file = kml_input isa KMLFile ? kml_input : read(kml_input, KMLFile)
    layer_infos = _get_layer_info(file)

    if isempty(layer_infos)
        return String[]
    end

    return [name for (_, name, _) in layer_infos]
end

#─────────────────────────── get_num_layers function ───────────────────────────#
"""
    get_num_layers(kml_input::Union{AbstractString,KMLFile})::Int

Returns the number of available "layers" found within a KML file.

Layers are identified based on common KML structuring patterns, such as:
  - Direct `Placemark`s within a `Document` or `Folder`.
  - `Folder`s or `Document`s themselves, which can act as containers for `Placemark`s or other features.

If no distinct layers are found, or if the KML contains no `Placemark`s
within common structural elements, 0 is returned.

# Arguments
  - `kml_input`: Either a string representing the path to a KML file or a `KMLFile` object that has already been read.

# Returns
  - `Int`: The number of layers.
"""
function get_num_layers(kml_input::Union{AbstractString,KMLFile})::Int
    file = kml_input isa KMLFile ? kml_input : read(kml_input, KMLFile)
    layer_infos = _get_layer_info(file)
    return length(layer_infos)
end

#────────────────────────── streaming iterator over placemarks ──────────────────────────#
function _placemark_iterator(file::KMLFile, layer_spec::Union{Nothing,String,Integer})
    selected_source = _select_layer(file, layer_spec)
    return _iter_feat(selected_source) # _iter_feat handles Document, Folder, or Vector{Placemark}
end

function _iter_feat(x)
    if x isa Placemark
        return (x for _ = 1:1)
    elseif (x isa Document || x isa Folder) && x.Features !== nothing
        return flatten(_iter_feat.(x.Features))
    elseif x isa AbstractVector{<:Feature} # Or more specifically AbstractVector{<:Placemark}
        # If x is a vector of features (e.g., Placemarks),
        # iterate over each feature and recursively call _iter_feat.
        # This ensures that if it's a vector of Placemarks, each Placemark
        # is properly processed by the 'x isa Placemark' case.
        return flatten(_iter_feat.(x))
    else
        return () # Fallback for any other type or empty collections
    end
end

#──────────────────────────── streaming PlacemarkTable type ────────────────────────────#
"""
    PlacemarkTable(source; layer=nothing)

A lazy, streaming Tables.jl table of the placemarks in a KML file.
You can call it either with a path or with an already-loaded `KMLFile`.

# Keyword Arguments

  - `layer::Union{Nothing,String, Integer}=nothing`: The name of the layer (Folder or Document) to extract Placemarks from.
    If `nothing`, the function attempts to find a default layer or prompts if multiple are available and in interactive mode.
"""
struct PlacemarkTable
    file::KMLFile
    layer::Union{Nothing,String,Integer} # layer can be a String or an Integer (index)
end

PlacemarkTable(file::KMLFile; layer::Union{Nothing,String,Integer} = nothing) = PlacemarkTable(file, layer)
PlacemarkTable(path::AbstractString; layer::Union{Nothing,String,Integer} = nothing) =
    PlacemarkTable(read(path, KMLFile); layer = layer)

#──────────────────────────────── Tables.jl API ──────────────────────────────────#
Tables.istable(::Type{<:PlacemarkTable}) = true # Use <:PlacemarkTable for dispatch on instances
Tables.rowaccess(::Type{<:PlacemarkTable}) = true

# Schema remains the same, as the output type of description is still String
Tables.schema(::PlacemarkTable) = Tables.Schema(
    (:name, :description, :geometry),
    (String, String, Union{Missing,Geometry}), # Geometry can be missing
)

function Tables.rows(tbl::PlacemarkTable)
    it = _placemark_iterator(tbl.file, tbl.layer)
    return (
        let pl = pl # Ensure `pl` is captured for each iteration for the closure
            desc = if pl.description === nothing
                ""
            else
                pl.description # Return raw HTML
            end
            name_str = pl.name === nothing ? "" : pl.name
            processed_name = if pl.name !== nothing && occursin('&', name_str) # Quick check
                decode_named_entities(name_str)
            else
                name_str
            end
            (
                name = processed_name, # Use the processed name
                description = desc, # Use the processed or raw description
                geometry = pl.Geometry,
            )
        end for pl in it if pl isa Placemark # Ensure we only process Placemarks
    )
end

# --- Tables.jl API for KMLFile (delegating to PlacemarkTable) ---
Tables.istable(::Type{KMLFile}) = true
Tables.rowaccess(::Type{KMLFile}) = true

# Pass the new option through
function Tables.schema(k::KMLFile; layer::Union{Nothing,String,Integer} = nothing)
    return Tables.schema(PlacemarkTable(k, layer = layer))
end

# Pass the new option through
function Tables.rows(k::KMLFile; layer::Union{Nothing,String,Integer} = nothing)
    return Tables.rows(PlacemarkTable(k, layer = layer))
end

end # module TablesBridge
