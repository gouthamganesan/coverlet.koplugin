--[[
Day arithmetic for the chain: current streak, best run, the 28 squares and
this week's total. Pure Lua, fed a map of "YYYY-MM-DD" -> seconds read.

Any page counts: a day with any recorded reading is a reading day. KOReader
already drops pages read for under 5 seconds before they reach the database.

Square codes:
  n  before the first reading day ever     x  missed day
  l  under 20 min   m  20 to 39 min   h  40 min or more
  te today, not read yet   tl/tm/th  today, read   f  after today
]]

local C = {}

C.LOW = 20 * 60
C.MID = 40 * 60
C.WEEKS = 4

local DAY = 86400

-- Noon keeps day stepping clear of DST jumps.
local function noon(y, m, d)
    return os.time{ year = y, month = m, day = d, hour = 12 }
end

function C.key(t)
    return os.date("%Y-%m-%d", t)
end

function C.dayOf(t)
    local d = os.date("*t", t)
    return noon(d.year, d.month, d.day)
end

function C.addDays(t, n)
    local d = os.date("*t", t + n * DAY)
    return noon(d.year, d.month, d.day)
end

function C.keyToTime(k)
    local y, m, d = k:match("^(%d+)-(%d+)-(%d+)$")
    return noon(tonumber(y), tonumber(m), tonumber(d))
end

-- Monday = 0 ... Sunday = 6
function C.weekdayIndex(t)
    return (tonumber(os.date("%w", t)) + 6) % 7
end

function C.level(seconds)
    if seconds < C.LOW then return "l" end
    if seconds < C.MID then return "m" end
    return "h"
end

function C.compute(days, now)
    days = days or {}
    local today = C.dayOf(now or os.time())
    local tk = C.key(today)
    local read_today = (days[tk] or 0) > 0

    local streak = 0
    local cursor = read_today and today or C.addDays(today, -1)
    while (days[C.key(cursor)] or 0) > 0 do
        streak = streak + 1
        cursor = C.addDays(cursor, -1)
    end

    local keys = {}
    for k, s in pairs(days) do
        if s > 0 then table.insert(keys, k) end
    end
    table.sort(keys)
    local best, run, prev_key = 0, 0, nil
    for _, k in ipairs(keys) do
        if prev_key and C.key(C.addDays(C.keyToTime(prev_key), 1)) == k then
            run = run + 1
        else
            run = 1
        end
        if run > best then best = run end
        prev_key = k
    end
    local first = keys[1]

    local start = C.addDays(today, -(C.weekdayIndex(today) + 7 * (C.WEEKS - 1)))
    local cells = {}
    for i = 0, 7 * C.WEEKS - 1 do
        local k = C.key(C.addDays(start, i))
        local s = days[k] or 0
        local code
        if k > tk then
            code = "f"
        elseif k == tk then
            code = s > 0 and ("t" .. C.level(s)) or "te"
        elseif not first or k < first then
            code = "n"
        elseif s <= 0 then
            code = "x"
        else
            code = C.level(s)
        end
        cells[i + 1] = code
    end

    local week = 0
    for i = 0, C.weekdayIndex(today) do
        week = week + (days[C.key(C.addDays(today, -i))] or 0)
    end

    return {
        streak = streak,
        best = best,
        read_today = read_today,
        cells = cells,
        week_seconds = week,
        first_day = first,
    }
end

return C
