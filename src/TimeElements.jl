module TimeElements

export TimeStamp, TimeSpan

using Dates, TimeZones
using ..Core: TimePrimitive, Object, TAG_TO_TYPE, @option, @object

# ─── Time Primitive Elements ─────────────────────────────────────────────────

Base.@kwdef mutable struct TimeStamp <: TimePrimitive
    @object
    @option when ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end
TAG_TO_TYPE[:TimeStamp] = TimeStamp

Base.@kwdef mutable struct TimeSpan <: TimePrimitive
    @object
    @option begin_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
    @option end_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end
TAG_TO_TYPE[:TimeSpan] = TimeSpan

end # module TimeElements