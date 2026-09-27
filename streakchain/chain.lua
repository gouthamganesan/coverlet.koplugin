--[[
Day arithmetic: the current streak, the best run, the goal-day streak, this
week's and this year's reading time, the three-month calendar and the flame.
Pure Lua, fed a map of "YYYY-MM-DD" -> seconds read.

Any page counts: a day with any recorded reading is a reading day. KOReader
already drops pages read for under 5 seconds before they reach the database.

Weeks start on Monday, for the calendar and for the weekly goal.

Day levels:
  o  nothing read     l  under 20 min     m  20 to 39 min     h  40 min or more
  f  after today
]]

local C = {}

C.LOW = 20 * 60
C.MID = 40 * 60
C.MONTHS = 3

local DAY = 86400

-- Noon keeps day stepping clear of DST jumps.
local function noon(y, m, d)
    return os.time{ year = y, month = m, day = d, hour = 12 }
end

local function midnight(y, m, d)
    return os.time{ year = y, month = m, day = d, hour = 0 }
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
    seconds = seconds or 0
    if seconds <= 0 then return "o" end
    if seconds < C.LOW then return "l" end
    if seconds < C.MID then return "m" end
    return "h"
end

-- Local midnight at the start of the day, week (Monday), month and year of t.
function C.startOfDay(t)
    local d = os.date("*t", t)
    return midnight(d.year, d.month, d.day)
end

function C.startOfWeek(t)
    local d = os.date("*t", C.addDays(C.dayOf(t), -C.weekdayIndex(t)))
    return midnight(d.year, d.month, d.day)
end

function C.startOfMonth(t)
    local d = os.date("*t", t)
    return midnight(d.year, d.month, 1)
end

function C.startOfYear(t)
    return midnight(tonumber(os.date("%Y", t)), 1, 1)
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

    local week = 0
    for i = 0, C.weekdayIndex(today) do
        week = week + (days[C.key(C.addDays(today, -i))] or 0)
    end
    local year, year_prefix = 0, tk:sub(1, 5)
    for k, s in pairs(days) do
        if k:sub(1, 5) == year_prefix and k <= tk then year = year + s end
    end

    return {
        streak = streak,
        best = best,
        read_today = read_today,
        today_seconds = days[tk] or 0,
        week_seconds = week,
        year_seconds = year,
    }
end

-- Days in a row on which the whole daily goal was read. Today counts once
-- it's met; until then the run through yesterday stands.
function C.goalStreak(days, now, goal_seconds)
    if not (goal_seconds and goal_seconds > 0) then return 0 end
    days = days or {}
    local today = C.dayOf(now or os.time())
    local cursor = (days[C.key(today)] or 0) >= goal_seconds and today or C.addDays(today, -1)
    local n = 0
    while (days[C.key(cursor)] or 0) >= goal_seconds do
        n = n + 1
        cursor = C.addDays(cursor, -1)
    end
    return n
end

--[[
The calendar: this month and the (n - 1) before it, each laid out
Monday-first. Days in the current run are marked so the screen can join them
with a line, including across a week's or a month's edge.
  { { time (noon on the 1st), offset (0 = starts on a Monday), days = {
      { day, level = "o"|"l"|"m"|"h"|"f", today, run, joins_prev, joins_next } } } }
]]
function C.calendar(days, now, streak, read_today, n)
    days = days or {}
    n = n or C.MONTHS
    streak = streak or 0
    local today = C.dayOf(now or os.time())
    local tk = C.key(today)
    local run_first, run_last
    if streak > 0 then
        local last = read_today and today or C.addDays(today, -1)
        run_last = C.key(last)
        run_first = C.key(C.addDays(last, -(streak - 1)))
    end

    local d = os.date("*t", today)
    local months = {}
    for i = n - 1, 0, -1 do
        local y, m = d.year, d.month - i
        while m < 1 do
            m = m + 12
            y = y - 1
        end
        local first = noon(y, m, 1)
        local count = os.date("*t", noon(y, m + 1, 0)).day
        local month = { time = first, offset = C.weekdayIndex(first), days = {} }
        for day = 1, count do
            local k = C.key(noon(y, m, day))
            local run = run_first ~= nil and k >= run_first and k <= run_last
            month.days[day] = {
                day = day,
                level = k > tk and "f" or C.level(days[k]),
                today = k == tk,
                run = run,
                joins_prev = run and k > run_first,
                joins_next = run and k < run_last,
            }
        end
        table.insert(months, month)
    end
    return months
end

--[[
The flame beside the day streak. Its size follows the run; until a page is
read today it is only an outline, and with no run at all it is dashed.
  variant  "dashed" (no run), "outline" (today not read yet), "solid",
           "core" (30 days or more, read today)
  w, h     design px; drop  how far its foot sits above the number's line box
  muted    the number and label go gray (no run)
]]
C.FLAME = {
    small = { w = 32, h = 36, drop = 6 },
    medium = { w = 46, h = 52, drop = 4 },
    large = { w = 56, h = 64, drop = 0 },
}

function C.flame(streak, read_today)
    streak = streak or 0
    local size, variant
    if streak <= 0 then
        size, variant = "medium", "dashed"
    else
        size = streak <= 2 and "small" or streak <= 6 and "medium" or "large"
        if not read_today then
            variant = "outline"
        elseif streak >= 30 then
            variant = "core"
        else
            variant = "solid"
        end
    end
    local dims = C.FLAME[size]
    return { size = size, variant = variant, w = dims.w, h = dims.h, drop = dims.drop, muted = streak <= 0 }
end

-- Chapter marks for the progress bar, as fractions of the book. Front and
-- back matter (Praise, Title Page, Acknowledgements...) bunch up at the ends,
-- so a mark closer than MIN_GAP to the one before it is dropped, as are marks
-- in the first and last 1%.
C.MIN_GAP = 0.015

function C.thinTicks(ticks)
    local sorted = {}
    for _, t in ipairs(ticks or {}) do table.insert(sorted, t) end
    table.sort(sorted)
    local kept, last = {}, nil
    for _, t in ipairs(sorted) do
        if t > 0.01 and t < 0.99 and (not last or t - last >= C.MIN_GAP) then
            table.insert(kept, t)
            last = t
        end
    end
    return kept
end

-- The marks either side of the reading position: the current chapter's start
-- and end, which the bar draws full height. Either can be nil (the first or
-- the last chapter).
function C.chapterBounds(ticks, pct)
    local from, to
    for _, t in ipairs(ticks or {}) do
        if t <= pct then
            from = t
        elseif not to then
            to = t
        end
    end
    return from, to
end

return C
