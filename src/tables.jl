module TablesBridge

export PlacemarkTable

using Tables
import ..KML: KMLFile, read, Feature, Document, Folder, Placemark, Geometry, object
import XML: parse, Node
using Base.Iterators: flatten
# For HTML descriptions' conversion to plain text
using Gumbo, AbstractTrees
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

function _select_layer(cont::Vector{<:Feature}, direct::Vector{Placemark}, parent, layer::Union{Nothing,String})
    if layer !== nothing
        for c in cont
            if c.name === layer
                return c
            end
        end
        if isempty(cont) && parent !== nothing && parent.name === layer
            return parent
        end
        error("Layer \"$layer\" not found")
    end

    opts, cand = String[], Any[]
    for c in cont
        push!(opts, c.name !== nothing ? c.name : "<Unnamed>")
        push!(cand, c)
    end
    if !isempty(direct)
        push!(opts, "<Ungrouped Placemarks>")
        push!(cand, direct)
    end

    if length(cand) ≤ 1
        return isempty(cand) ? nothing : cand[1]
    end

    interactive = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()
    if interactive
        idx = request("Select a layer:", RadioMenu(opts; pagesize = min(10, length(opts))))
        idx == -1 && error("Selection cancelled")
        cand[idx]
    else
        @warn "Multiple layers - picking first ($(opts[1])) automatically"
        cand[1]
    end
end

# Helper function to convert HTML to plain text
function _simple_html_to_plaintext(html_string::AbstractString)
    if isempty(html_string) || !occursin(r"<[^>]+>", html_string)
        return html_string
    end
    try
        doc = Gumbo.parsehtml(html_string)
        buffer = IOBuffer()

        # Helper function to recursively process nodes
        function process_node(element)
            if element isa HTMLText
                # Sanitize text a bit (e.g., replace non-breaking spaces)
                text_content = replace(element.text, r"\s+" => " ") # Consolidate whitespace within text nodes
                print(buffer, text_content)
            elseif element isa HTMLElement
                tag_sym = Gumbo.tag(element)

                # --- Pre-children processing ---
                # For certain block elements, ensure we're on a new line if buffer has content
                # and doesn't already end with a newline.
                if tag_sym in (:p, :div, :h1, :h2, :h3, :h4, :h5, :h6, :li, :tr, :article, :section, :header, :footer)
                    if position(buffer) > 0
                        # Check last char
                        temp_pos = position(buffer)
                        seek(buffer, temp_pos - 1)
                        last_char = read(buffer, Char)
                        seek(buffer, temp_pos) # Reset position
                        if last_char != '\n'
                            println(buffer) # Start this block on a new line
                        end
                    end
                end

                # --- Process children ---
                for child in Gumbo.children(element)
                    process_node(child)
                end

                # --- Post-children processing ---
                if tag_sym === :br
                    println(buffer)
                    # Ensure a newline after these block elements if not already ending with one
                elseif tag_sym in (:p, :div, :h1, :h2, :h3, :h4, :h5, :h6, :li, :tr, :article, :section, :header, :footer)
                    if position(buffer) > 0
                        temp_pos = position(buffer)
                        seek(buffer, temp_pos - 1)
                        last_char = read(buffer, Char)
                        seek(buffer, temp_pos)
                        if last_char != '\n'
                            println(buffer)
                        end
                    else # If buffer is empty and it's a block element, still good to have a newline for structure
                        println(buffer)
                    end
                    # Add a tab separator after table cells
                elseif tag_sym in (:td, :th)
                    print(buffer, "\t")
                    # For other inline elements, ensure a space if followed by more text or certain elements
                    # This helps prevent words from mashing together.
                elseif !(
                    tag_sym in
                    (:html, :head, :body, :meta, :style, :script, :title, :table, :tbody, :thead, :tfoot, :colgroup, :col)
                ) # Avoid adding spaces after structural/invisible tags
                    if position(buffer) > 0
                        temp_pos = position(buffer)
                        seek(buffer, temp_pos - 1)
                        last_char = read(buffer, Char)
                        seek(buffer, temp_pos)
                        if !isspace(last_char) # Only add space if not already ending with whitespace
                            print(buffer, " ")
                        end
                    end
                end
            end
        end

        process_node(doc.root) # Start processing from the root

        raw_text = String(take!(buffer))

        # --- Final cleanup ---
        # Normalize all forms of newlines to \n and then consolidate
        clean_text = replace(raw_text, r"\r\n|\r" => "\n")
        # Replace multiple spaces/tabs (but not newlines) with a single space/tab
        clean_text = replace(clean_text, r"([ \t]){2,}" => s"\1")
        # Remove spaces/tabs directly before or after a newline
        clean_text = replace(clean_text, r"[ \t]+\n" => "\n")
        clean_text = replace(clean_text, r"\n[ \t]+" => "\n")
        # Consolidate multiple newlines to at most two (for paragraph breaks)
        clean_text = replace(clean_text, r"\n{3,}" => "\n\n")
        return strip(clean_text) # Final strip for leading/trailing whitespace

    catch e
        @warn "Failed to parse HTML description, returning original. Error: $e. Snippet: $(first(html_string,100))..."
        # For debugging:
        # showerror(stderr, e)
        # Base.show_backtrace(stderr, catch_backtrace())
        return html_string
    end
end

#────────────────────────── streaming iterator over placemarks ──────────────────────────#
function _placemark_iterator(file::KMLFile, layer)
    feats = _top_level_features(file)
    cont, direct, parent = _determine_layers(feats)
    sel = _select_layer(cont, direct, parent, layer)
    return _iter_feat(sel) # Remove flatten()
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
    PlacemarkTable(source; layer=nothing, strip_html=false)

A lazy, streaming Tables.jl table of the placemarks in a KML file.
You can call it either with a path or with an already-loaded `KMLFile`.

# Keyword Arguments

  - `layer::Union{Nothing,String}=nothing`: The name of the layer (Folder or Document) to extract Placemarks from.
    If `nothing`, the function attempts to find a default layer or prompts if multiple are available and in interactive mode.
  - `strip_html::Bool=false`: If `true`, HTML content in description fields will be converted to plain text.
    If `false`, the raw HTML string is preserved.
"""
struct PlacemarkTable
    file::KMLFile
    layer::Union{Nothing,String}
    strip_html::Bool
end

# Updated constructors:
PlacemarkTable(path::AbstractString; layer = nothing, strip_html::Bool = false) =
    PlacemarkTable(read(path, KMLFile), layer, strip_html)
PlacemarkTable(file::KMLFile; layer = nothing, strip_html::Bool = false) = PlacemarkTable(file, layer, strip_html)

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
            elseif tbl.strip_html # Check the option
                _simple_html_to_plaintext(pl.description)
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
function Tables.schema(k::KMLFile; layer = nothing, strip_html::Bool = false)
    return Tables.schema(PlacemarkTable(k, layer = layer, strip_html = strip_html))
end

# Pass the new option through
function Tables.rows(k::KMLFile; layer = nothing, strip_html::Bool = false)
    return Tables.rows(PlacemarkTable(k, layer = layer, strip_html = strip_html))
end

end # module TablesBridge
