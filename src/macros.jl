# src/macros.jl
module Macros

export @for_each_immediate_child, @find_immediate_child, @count_immediate_children

using XML

"""
    @for_each_immediate_child node child body

Iterate over immediate children of a node with zero overhead.
Completely inlines the iteration code at compile time.
"""
macro for_each_immediate_child(node_expr, child_var, body)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node)
                    
                    # Cache raw pointer for faster access
                    _raw = _current === nothing ? nothing : _current.raw
                    
                    while _raw !== nothing
                        # Access depth directly from raw (it's already an XML.Raw)
                        _cur_depth = XML.depth(_raw)
                        
                        if _cur_depth <= _initial_depth
                            break
                        elseif _cur_depth == _target_depth
                            # Only create LazyNode when needed
                            let $(esc(child_var)) = XML.LazyNode(_raw)
                                $(esc(body))
                            end
                        end
                        
                        # Advance using raw pointer
                        # XML.next returns XML.Raw or nothing directly
                        _raw = XML.next(_raw)
                    end
                end
            else
                # Regular Node - use children()
                for $(esc(child_var)) in XML.children(_node)
                    $(esc(body))
                end
            end
        end
        nothing
    end
end

"""
    @find_immediate_child node child condition

Find the first immediate child matching the condition.
Returns the child or nothing. Zero overhead implementation.
"""
macro find_immediate_child(node_expr, child_var, condition)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node),
                    _result = nothing
                    
                    # Cache raw pointer
                    _raw = _current === nothing ? nothing : _current.raw
                    
                    while _raw !== nothing && isnothing(_result)
                        _cur_depth = XML.depth(_raw)
                        
                        if _cur_depth <= _initial_depth
                            break
                        elseif _cur_depth == _target_depth
                            # Create LazyNode for condition check
                            let _candidate = XML.LazyNode(_raw)
                                let $(esc(child_var)) = _candidate
                                    if $(esc(condition))
                                        _result = _candidate
                                    end
                                end
                            end
                        end
                        
                        if isnothing(_result)
                            # Advance using raw pointer
                            # XML.next returns XML.Raw or nothing directly
                            _raw = XML.next(_raw)
                        end
                    end
                    _result
                end
            else
                # Regular Node
                let _result = nothing
                    for $(esc(child_var)) in XML.children(_node)
                        if $(esc(condition))
                            _result = $(esc(child_var))
                            break
                        end
                    end
                    _result
                end
            end
        end
    end
end

"""
    @count_immediate_children node child condition

Count immediate children matching the condition.
Zero overhead implementation.
"""
macro count_immediate_children(node_expr, child_var, condition)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node),
                    _count = 0
                    
                    # Cache raw pointer
                    _raw = _current === nothing ? nothing : _current.raw
                    
                    while _raw !== nothing
                        _cur_depth = XML.depth(_raw)
                        
                        if _cur_depth <= _initial_depth
                            break
                        elseif _cur_depth == _target_depth
                            # Create LazyNode only for condition check
                            let _candidate = XML.LazyNode(_raw)
                                let $(esc(child_var)) = _candidate
                                    if $(esc(condition))
                                        _count += 1
                                    end
                                end
                            end
                        end
                        
                        # Advance using raw pointer
                        # XML.next returns XML.Raw or nothing directly
                        _raw = XML.next(_raw)
                    end
                    _count
                end
            else
                # Regular Node
                let _count = 0
                    for $(esc(child_var)) in XML.children(_node)
                        if $(esc(condition))
                            _count += 1
                        end
                    end
                    _count
                end
            end
        end
    end
end

end # module Macros