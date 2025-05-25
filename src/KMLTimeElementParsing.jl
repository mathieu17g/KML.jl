using Dates, TimeZones, Automa

# Define regex patterns for ISO 8601 formats
const digit = re"[0-9]"
const year = digit * digit * digit * digit
const month = re"[01][0-9]"  # 00-19, will need runtime validation for 01-12
const day = re"[0-3][0-9]"    # 00-39, will need runtime validation for 01-31
const week = re"W" * re"[0-5][0-9]"  # W00-W59, will need runtime validation for W01-W53
const weekday = re"[1-7]"
const ordinal = re"[0-3][0-9][0-9]"  # 000-399, will need runtime validation for 001-366

# Time components
const hour = re"[0-2][0-9]"   # 00-29, will need runtime validation for 00-23
const minute = re"[0-5][0-9]"  # 00-59
const second = re"[0-6][0-9]"  # 00-69, allows for leap seconds
const fraction = re"\." * digit * rep(digit)

# Timezone components
const tz_utc = re"Z"
const tz_offset = re"[+-]" * digit * digit * opt(re":") * digit * digit
const tz_name = re"[A-Za-z_]" * rep(re"[A-Za-z_]") * re"/" * re"[A-Za-z_]" * rep(re"[A-Za-z_]")

# Complete patterns (ordered by frequency)
# DateTime with timezone
const datetime_tz_extended = year * re"-" * month * re"-" * day * re"[T ]" * 
                             hour * re":" * minute * re":" * second * opt(fraction) * (tz_utc | tz_offset | tz_name)
const datetime_tz_basic = year * month * day * re"T" * hour * minute * second * opt(fraction) * (tz_utc | tz_offset)

# DateTime without timezone
const datetime_extended = year * re"-" * month * re"-" * day * re"[T ]" * 
                         hour * re":" * minute * re":" * second * opt(fraction)
const datetime_basic = year * month * day * re"T" * hour * minute * second * opt(fraction)

# Date only
const date_extended = year * re"-" * month * re"-" * day
const date_basic = year * month * day

# Week dates
const week_extended = year * re"-" * week * re"-" * weekday
const week_basic = year * week * weekday

# Ordinal dates
const ordinal_extended = year * re"-" * ordinal
const ordinal_basic = year * ordinal

# Generate validator functions for each format
@eval $(Automa.generate_buffer_validator(:is_datetime_tz_extended, datetime_tz_extended))
@eval $(Automa.generate_buffer_validator(:is_datetime_tz_basic, datetime_tz_basic))
@eval $(Automa.generate_buffer_validator(:is_datetime_extended, datetime_extended))
@eval $(Automa.generate_buffer_validator(:is_datetime_basic, datetime_basic))
@eval $(Automa.generate_buffer_validator(:is_date_extended, date_extended))
@eval $(Automa.generate_buffer_validator(:is_date_basic, date_basic))
@eval $(Automa.generate_buffer_validator(:is_week_extended, week_extended))
@eval $(Automa.generate_buffer_validator(:is_week_basic, week_basic))
@eval $(Automa.generate_buffer_validator(:is_ordinal_extended, ordinal_extended))
@eval $(Automa.generate_buffer_validator(:is_ordinal_basic, ordinal_basic))

"""
    parse_iso8601(s::AbstractString) -> Union{ZonedDateTime, DateTime, Date, String}

Parse an ISO 8601 formatted string into the appropriate Julia type.
Returns the original string if the format is not recognized.
"""
function parse_iso8601(s::AbstractString)
    # Check formats in order of frequency
    format = if is_datetime_tz_extended(s) === nothing
        :datetime_tz_extended
    elseif is_datetime_tz_basic(s) === nothing
        :datetime_tz_basic
    elseif is_datetime_extended(s) === nothing
        :datetime_extended
    elseif is_datetime_basic(s) === nothing
        :datetime_basic
    elseif is_date_extended(s) === nothing
        :date_extended
    elseif is_date_basic(s) === nothing
        :date_basic
    elseif is_week_extended(s) === nothing
        :week_extended
    elseif is_week_basic(s) === nothing
        :week_basic
    elseif is_ordinal_extended(s) === nothing
        :ordinal_extended
    elseif is_ordinal_basic(s) === nothing
        :ordinal_basic
    else
        nothing
    end
    
    if format === nothing
        return String(s)
    end
    
    try
        return parse_by_format(s, format)
    catch
        return String(s)
    end
end

function parse_by_format(s::AbstractString, format::Symbol)
    if format == :datetime_tz_extended || format == :datetime_tz_basic
        return parse_datetime_with_timezone(s, format)
    elseif format == :datetime_extended || format == :datetime_basic
        return parse_datetime_without_timezone(s, format)
    elseif format == :date_extended
        return Date(s, dateformat"yyyy-mm-dd")
    elseif format == :date_basic
        return Date(s, dateformat"yyyymmdd")
    elseif format == :week_extended || format == :week_basic
        return parse_week_date(s, format)
    elseif format == :ordinal_extended || format == :ordinal_basic
        return parse_ordinal_date(s, format)
    else
        return String(s)
    end
end

function parse_datetime_with_timezone(s::AbstractString, format::Symbol)
    # Extract timezone part
    tz_match = match(r"(Z|[+-]\d{2}:?\d{2}|[A-Za-z_]+/[A-Za-z_]+)$", s)
    if tz_match === nothing
        throw(ArgumentError("No timezone found"))
    end
    
    tz_str = tz_match.captures[1]
    dt_str = s[1:tz_match.offset-1]
    
    # Parse the datetime part
    if format == :datetime_tz_extended
        # Try different separators
        dt = try
            DateTime(dt_str, dateformat"yyyy-mm-dd HH:MM:SS.s")
        catch
            try
                DateTime(dt_str, dateformat"yyyy-mm-dd HH:MM:SS")
            catch
                DateTime(dt_str, dateformat"yyyy-mm-ddTHH:MM:SS.s")
            end
        end
    else  # basic format
        # Handle fractional seconds
        if occursin(".", dt_str)
            parts = split(dt_str, ".")
            base_dt = DateTime(parts[1], dateformat"yyyymmddTHHMMSS")
            frac = parse(Float64, "0." * parts[2])
            dt = base_dt + Millisecond(round(Int, frac * 1000))
        else
            dt = DateTime(dt_str, dateformat"yyyymmddTHHMMSS")
        end
    end
    
    # Parse timezone
    if tz_str == "Z"
        tz = tz"UTC"
    elseif startswith(tz_str, "+") || startswith(tz_str, "-")
        # Parse offset
        sign = tz_str[1] == '+' ? 1 : -1
        offset_str = tz_str[2:end]
        if contains(offset_str, ":")
            hours, minutes = parse.(Int, split(offset_str, ":"))
        else
            hours = parse(Int, offset_str[1:2])
            minutes = parse(Int, offset_str[3:4])
        end
        offset_seconds = sign * (hours * 3600 + minutes * 60)
        tz = FixedTimeZone("UTC" * tz_str, offset_seconds)
    else
        # Named timezone
        tz = TimeZone(tz_str)
    end
    
    return ZonedDateTime(dt, tz)
end

function parse_datetime_without_timezone(s::AbstractString, format::Symbol)
    if format == :datetime_extended
        # Try different separators and with/without fractional seconds
        try
            DateTime(s, dateformat"yyyy-mm-dd HH:MM:SS.s")
        catch
            try
                DateTime(s, dateformat"yyyy-mm-dd HH:MM:SS")
            catch
                try
                    DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS.s")
                catch
                    DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
                end
            end
        end
    else  # basic format
        if occursin(".", s)
            parts = split(s, ".")
            base_dt = DateTime(parts[1], dateformat"yyyymmddTHHMMSS")
            frac = parse(Float64, "0." * parts[2])
            base_dt + Millisecond(round(Int, frac * 1000))
        else
            DateTime(s, dateformat"yyyymmddTHHMMSS")
        end
    end
end

function parse_week_date(s::AbstractString, format::Symbol)
    if format == :week_extended
        m = match(r"^(\d{4})-W(\d{2})-(\d)$", s)
    else  # basic format
        m = match(r"^(\d{4})W(\d{2})(\d)$", s)
    end
    
    year = parse(Int, m.captures[1])
    week = parse(Int, m.captures[2])
    dayofweek = parse(Int, m.captures[3])
    
    # Calculate the date
    # First day of year
    jan1 = Date(year, 1, 1)
    # Find the Monday of week 1
    dow_jan1 = dayofweek(jan1)
    days_to_monday = dow_jan1 == 1 ? 0 : 8 - dow_jan1
    week1_monday = jan1 + Day(days_to_monday)
    
    # Calculate the target date
    target_date = week1_monday + Week(week - 1) + Day(dayofweek - 1)
    
    return target_date
end

function parse_ordinal_date(s::AbstractString, format::Symbol)
    if format == :ordinal_extended
        m = match(r"^(\d{4})-(\d{3})$", s)
    else  # basic format
        m = match(r"^(\d{4})(\d{3})$", s)
    end
    
    year = parse(Int, m.captures[1])
    dayofyear = parse(Int, m.captures[2])
    
    return Date(year) + Day(dayofyear - 1)
end

# Helper function to check if parsing was successful
function is_valid_iso8601(s::AbstractString)
    result = parse_iso8601(s)
    return !(result isa String && result == s)
end

# Additional helper functions for convenience
matches_iso8601_format(s::AbstractString, format::Symbol) = begin
    validator = Symbol("is_", format)
    getfield(@__MODULE__, validator)(s) === nothing
end

# Test strings for ISO 8601 parser
test_strings = [
    # DateTime with timezone - Extended format
    "2023-12-25T15:30:45Z",                    # UTC
    "2023-12-25T15:30:45.123Z",                # UTC with milliseconds
    "2023-12-25T15:30:45+01:00",               # Positive offset with colon
    "2023-12-25T15:30:45-05:00",               # Negative offset with colon
    "2023-12-25T15:30:45.500+02:30",           # With fractional seconds and offset
    "2023-12-25 15:30:45Z",                    # Space separator instead of T
    "2023-12-25T15:30:45America/New_York",     # Named timezone
    "2023-12-25T15:30:45Europe/Paris",         # Named timezone
    
    # DateTime with timezone - Basic format
    "20231225T153045Z",                        # UTC
    "20231225T153045.123Z",                    # UTC with milliseconds
    "20231225T153045+0100",                    # Positive offset without colon
    "20231225T153045-0500",                    # Negative offset without colon
    "20231225T153045.999+0230",                # With fractional seconds
    
    # DateTime without timezone - Extended format
    "2023-12-25T15:30:45",                     # Standard format
    "2023-12-25T15:30:45.123",                 # With milliseconds
    "2023-12-25 15:30:45",                     # Space separator
    "2023-12-25 15:30:45.999",                 # Space separator with milliseconds
    
    # DateTime without timezone - Basic format
    "20231225T153045",                         # Standard format
    "20231225T153045.123",                     # With milliseconds
    
    # Date only - Extended format
    "2023-12-25",                              # Standard date
    "2023-01-01",                              # New Year
    "2023-02-28",                              # End of February (non-leap)
    
    # Date only - Basic format
    "20231225",                                # Standard date
    "20230101",                                # New Year
    "20230228",                                # End of February
    
    # Week dates - Extended format
    "2023-W52-1",                              # Week 52, Monday
    "2023-W01-7",                              # Week 1, Sunday
    "2023-W26-3",                              # Week 26, Wednesday
    
    # Week dates - Basic format
    "2023W521",                                # Week 52, Monday
    "2023W017",                                # Week 1, Sunday
    "2023W263",                                # Week 26, Wednesday
    
    # Ordinal dates - Extended format
    "2023-365",                                # Last day of year
    "2023-001",                                # First day of year
    "2023-180",                                # Middle of year
    
    # Ordinal dates - Basic format
    "2023365",                                 # Last day of year
    "2023001",                                 # First day of year
    "2023180",                                 # Middle of year
    
    # Edge cases with valid formats
    "2023-12-31T23:59:59Z",                   # End of year
    "2023-01-01T00:00:00Z",                   # Start of year
    "2023-12-31T23:59:60Z",                   # Leap second
    "2023-12-25T15:30:45.123456789Z",         # Many decimal places
    
    # Invalid strings (should return as-is)
    "not-a-date",
    "2023-13-01",                              # Invalid month
    "2023-12-32",                              # Invalid day
    "2023-12-25T25:00:00",                    # Invalid hour
    "202a-12-25",                              # Invalid year
    "2023/12/25",                              # Wrong separator
]

# Test the parser
"""
    run_iso8601_tests(; strings=test_strings)

Runs the ISO 8601 parser on a set of predefined test‐strings
(or on a custom vector of strings passed via `strings`),
prints each input together with its parsed result and type,
and returns a Vector of (input, output) pairs.
"""
function run_iso8601_tests(; strings = [
    "2023-12-25T15:30:45Z",
    "2023-12-25T15:30:45.123Z",
    "2023-12-25T15:30:45+01:00",
    # … all the other test strings …
    "not-a-date",
    "2023-13-01",
])
    results = Vector{Tuple{String,Any}}(undef, length(strings))
    for (i, s) in pairs(strings)
        out = parse_iso8601(s)
        # println("$s => $(typeof(out)): $out")
        results[i] = (s, out)
    end
    return results
end