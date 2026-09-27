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
  { { time (noon on the 1st), offset (0 = starts on a Monday), seconds (read that month), days = {
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
        local month = { time = first, offset = C.weekdayIndex(first), days = {}, seconds = 0 }
        for day = 1, count do
            local k = C.key(noon(y, m, day))
            if k <= tk then month.seconds = month.seconds + (days[k] or 0) end
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

--[[
The book's chapters for the bar, as fractions of the book where each one
starts (the first, at 0, left out). Front and back matter (Praise, Title
Page, Copyright...) are a page or two each; a chapter shorter than
MIN_SHARE of the median one joins its shorter neighbour, again and again,
until none is left. A book of 64 even chapters keeps all 64.
]]
C.MIN_SHARE = 0.25

function C.thinTicks(ticks)
    local sorted, seen = {}, {}
    for _, t in ipairs(ticks or {}) do
        if t > 0 and t < 1 and not seen[t] then
            seen[t] = true
            table.insert(sorted, t)
        end
    end
    table.sort(sorted)
    local starts = { 0 }
    for _, t in ipairs(sorted) do table.insert(starts, t) end
    local function len(i) return (starts[i + 1] or 1) - starts[i] end
    local lengths = {}
    for i = 1, #starts do lengths[i] = len(i) end
    table.sort(lengths)
    local min = C.MIN_SHARE * (lengths[math.floor((#lengths + 1) / 2)] or 0)
    while #starts > 1 do
        local short, i_short = min, nil
        for i = 1, #starts do
            if len(i) < short then short, i_short = len(i), i end
        end
        if not i_short then break end
        -- Merge into the shorter neighbour: dropping a start joins a chapter
        -- to the one before it.
        local prev = i_short > 1 and len(i_short - 1) or math.huge
        local next = i_short < #starts and len(i_short + 1) or math.huge
        if prev <= next then
            table.remove(starts, i_short)
        else
            table.remove(starts, i_short + 1)
        end
    end
    table.remove(starts, 1)
    return starts
end

--[[
The magnified chapter bar, laid out across `width` px: the current chapter
gets MAGNIFY of the width, the others share the rest in proportion to their
length with gaps between them (4 px, 2 px when they're many, and read and
unread each drawn as one piece when even that leaves them too thin).
`s` scales those design px. Returns nil for a book without chapters.
  { box = { x, w, fill (0..1 of the chapter read) }, before = { { x, w } },
    after = { { x, w } }, count, index, gap }
]]
C.MAGNIFY = 0.4

function C.chapterBar(ticks, pct, width, s, finished)
    ticks = ticks or {}
    if #ticks == 0 then return nil end
    s = s or 1
    local starts = { 0 }
    for _, t in ipairs(ticks) do table.insert(starts, t) end
    local n = #starts
    pct = math.max(0, math.min(1, pct or 0))
    local k = 1
    if finished then
        k = n
    else
        for i = 1, n do
            if starts[i] <= pct then k = i end
        end
    end
    local function len(i) return (starts[i + 1] or 1) - starts[i] end
    local box_w = width * C.MAGNIFY
    local rest_len = 1 - len(k)
    local others = n - 1

    local gap, merged
    if (width - box_w - others * 4 * s) / others >= 16 * s then
        gap = 4 * s
    elseif (width - box_w - others * 2 * s) / others >= 4 * s then
        gap = 2 * s
    else
        gap, merged = 4 * s, true
    end

    local pieces = {} -- { length, side } in order, the box as side "box"
    if merged then
        if k > 1 then table.insert(pieces, { starts[k], "before" }) end
        table.insert(pieces, { len(k), "box" })
        if k < n then table.insert(pieces, { 1 - (starts[k + 1] or 1), "after" }) end
    else
        for i = 1, n do
            table.insert(pieces, { len(i), i < k and "before" or i == k and "box" or "after" })
        end
    end
    local share = width - box_w - (#pieces - 1) * gap
    local bar = { before = {}, after = {}, count = n, index = k, gap = gap }
    local x = 0
    for _, p in ipairs(pieces) do
        local w = p[2] == "box" and box_w or (rest_len > 0 and share * p[1] / rest_len or 0)
        if p[2] == "box" then
            local fill = finished and 1 or (pct - starts[k]) / len(k)
            bar.box = { x = x, w = w, fill = math.max(0, math.min(1, fill)) }
        else
            table.insert(bar[p[2]], { x = x, w = w })
        end
        x = x + w + gap
    end
    return bar
end

return C
