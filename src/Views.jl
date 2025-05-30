module Views

export Camera, LookAt

using ..Core: AbstractView, @option, @object, @altitude_mode_elements
import ..Enums
import ..TimeElements: TimePrimitive


# ─── Abstract View Elements ──────────────────────────────────────────────────

Base.@kwdef mutable struct Camera <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option roll ::Float64
    @altitude_mode_elements
end

Base.@kwdef mutable struct LookAt <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option range ::Float64
    @altitude_mode_elements
end

end # module Views