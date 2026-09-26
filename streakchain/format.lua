--[[
Every piece of text on the sleep screen, as pure functions.

No KOReader modules in here, so tests/run.lua can exercise it with a bare
luajit. The wording rules come from the design canvas:

  * nothing refers to the time of day ("today", never "tonight")
  * no singular/plural splits where a unit can avoid it: "11 min",
    "4 day streak", "14 finished this year"
  * a stats-line part drops out rather than changing its words
]]

local F = {}

F.SEP = " · "
F.CHAPTER_TITLE_MAX = 20
F.LOW_BATTERY = 15

F.NOTE_IN = "Today is in the chain."
F.NOTE_BEST = "Your longest run so far."
F.NOTE_NEW = "One page starts a new run."

F.NO_BOOK_TITLE = "No book open"
F.NO_BOOK_SUB = "Your shelf is one tap away."
F.STATS_OFF_NOTE = "Your streak appears once Reading statistics is on."
F.STATS_OFF_HINT = "Turn it on in Tools · Reading statistics."

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
F.trim = trim

-- Length in characters, not bytes.
function F.ulen(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- "Good Strategy Bad Strategy: The Difference and Why It Matters"
--   -> "Good Strategy Bad Strategy". Only a colon followed by a space counts,
-- so "Re:Zero" survives.
function F.cleanTitle(title)
    if type(title) ~= "string" then return nil end
    title = trim(title)
    if title == "" then return nil end
    local main = title:match("^(.-)%s*:%s+.+$")
    if main and main ~= "" then title = main end
    return title
end

-- KOReader keeps several authors newline-separated. Also handles
-- "Crichton, Michael" (flipped) and "J K Rowling, Mary GrandPré" (two people).
function F.authorLine(authors)
    if type(authors) ~= "string" then return nil end
    local list = {}
    for part in (authors .. "\n"):gmatch("(.-)[\n;]") do
        part = trim(part)
        if part ~= "" then table.insert(list, part) end
    end
    if #list == 1 then
        local a, b = list[1]:match("^(.-),%s*(.+)$")
        if a and a:find(" ") and b:find(" ") then
            list = { trim(a), trim(b) }
        end
    end
    for i, name in ipairs(list) do
        local last, first = name:match("^([^,%s]+),%s*([^,]+)$")
        if last then list[i] = trim(first) .. " " .. last end
    end
    if #list == 0 then return nil end
    if #list == 1 then return list[1] end
    if #list == 2 then return list[1] .. " & " .. list[2] end
    return list[1] .. " et al."
end

local function clock(m)
    if m < 60 then return m .. " min" end
    return string.format("%d h %02d min", math.floor(m / 60), m % 60)
end

-- Time still ahead: rounded up, never below 1 min.
function F.left(seconds)
    return clock(math.max(1, math.ceil((seconds or 0) / 60)))
end

-- Time already read: rounded down, can be 0.
function F.total(seconds)
    return clock(math.floor((seconds or 0) / 60))
end

function F.percent(p)
    p = math.max(0, math.min(1, p or 0))
    return math.floor(p * 100 + 1e-9) .. "%"
end

--[[
The next step, the end of the line under the title.
  o.finished          book is done: no next step
  o.has_chapters      the book has a table of contents
  o.in_last_chapter   no chapter after this one
  o.chapter_title     title of the current chapter
  o.generic           force "this chapter" (the line was too long)
  o.chapter_seconds / o.book_seconds   time left, when a pace is known
  o.chapter_pages / o.book_pages       pages left, used without a pace
]]
function F.nextStep(o)
    if o.finished then return nil end
    local where = "the book"
    if o.has_chapters and not o.in_last_chapter then
        local t = o.chapter_title and trim(o.chapter_title) or ""
        if t ~= "" and not o.generic and F.ulen(t) <= F.CHAPTER_TITLE_MAX then
            where = t
        else
            where = "this chapter"
        end
    end
    local in_chapter = where ~= "the book"
    local seconds = in_chapter and o.chapter_seconds or o.book_seconds
    if seconds then
        return F.left(seconds) .. " left in " .. where
    end
    local pages = in_chapter and o.chapter_pages or o.book_pages
    if pages then
        pages = math.max(1, math.floor(pages))
        return pages .. (pages == 1 and " page" or " pages") .. " left in " .. where
    end
    return nil
end

function F.metaLine(author, pct, next_step, finished)
    local parts = {}
    if author then table.insert(parts, author) end
    if finished then
        table.insert(parts, "finished")
    else
        table.insert(parts, F.percent(pct))
        if next_step then table.insert(parts, next_step) end
    end
    return table.concat(parts, F.SEP)
end

-- The meta line without the author, for layouts that give the author its own
-- line: "58% · 11 min left in Part II", or "finished".
function F.progressLine(pct, step_opts, finished)
    local o = {}
    for k, v in pairs(step_opts or {}) do o[k] = v end
    o.finished = finished
    return F.metaLine(nil, pct, F.nextStep(o), finished)
end

-- The meta line, from most to least detailed. The screen uses the first one
-- that fits on a single line.
function F.metaVariants(author, pct, step_opts, finished)
    local variants = {}
    local function add(a, generic)
        local o = {}
        for k, v in pairs(step_opts or {}) do o[k] = v end
        o.generic = generic
        o.finished = finished
        local line = F.metaLine(a, pct, F.nextStep(o), finished)
        if variants[#variants] ~= line then table.insert(variants, line) end
    end
    add(author, false)
    add(author, true)
    add(nil, true)
    return variants
end

-- Streak guard: the run is alive but today isn't in it yet.
function F.noteGuard(streak)
    return "Read today to make it " .. (streak + 1) .. "."
end

function F.streakNote(streak, read_today, best)
    if (streak or 0) == 0 then return F.NOTE_NEW end
    if not read_today then return F.noteGuard(streak) end
    if streak >= 2 and streak >= (best or 0) then return F.NOTE_BEST end
    return F.NOTE_IN
end

-- "Best run: 12 days", only while the best run is ahead of the current one.
function F.bestLine(best, streak)
    if best and best >= 2 and best > (streak or 0) then
        return "Best run: " .. best .. " days"
    end
    return nil
end

-- The hero: time to the end as a number and its unit, "38" / "min to the end"
-- or "6 h 40" / "min to the end".
function F.heroTime(seconds)
    local m = math.max(1, math.ceil((seconds or 0) / 60))
    if m < 60 then return tostring(m), "min to the end" end
    return string.format("%d h %02d", math.floor(m / 60), m % 60), "min to the end"
end

-- Without reading statistics there is no pace, so the hero is the page.
function F.heroPages(page, total)
    return tostring(page), "of " .. total .. " pages"
end

local function dayAfter(now, n)
    local d = os.date("*t", now)
    return os.time{ year = d.year, month = d.month, day = d.day + n, hour = 12 }
end

--[[
The finish forecast, framed around the daily goal rather than reading speed.
Each day from today reads one daily session: the daily goal when one is set,
otherwise an average reading day. Today's share is what's left of today's
session. Returns nil when there is nothing to forecast from.
  line         "45 min a day finishes it Saturday." / "Today’s goal finishes it."
               or, without a daily goal, "Done by Saturday." / "Done today."
  today_share  the part of what's left that today covers, 0..1
  label        finish-day label under the timeline: "SAT", "12 OCT", or nil (today)
]]
function F.forecast(remaining, today_read, daily, now, goal_minutes)
    if not (remaining and remaining > 0 and daily and daily > 0) then return nil end
    now = now or os.time()
    local budget = math.max(0, daily - (today_read or 0))
    if remaining <= budget then
        return { line = goal_minutes and "Today’s goal finishes it." or "Done today.", today_share = 1 }
    end
    local days = math.ceil((remaining - budget) / daily)
    local t = dayAfter(now, days)
    local when, label
    if days <= 6 then
        when = os.date("%A", t)
        label = string.upper(os.date("%a", t))
    else
        local day = tonumber(os.date("%d", t))
        when = day .. " " .. os.date("%B", t)
        label = day .. " " .. string.upper(os.date("%b", t))
    end
    local line = goal_minutes and (goal_minutes .. " min a day finishes it " .. when .. ".") or ("Done by " .. when .. ".")
    return { line = line, today_share = budget / remaining, label = label }
end

--[[
Today's goal, the top row of the reader band.
  num, unit   "33" / "min to today’s goal", or "52" / "min today" once done
  right       "12 of 45 min", or "Goal done"
  fraction    0..1 of the goal read today
]]
function F.dailyGoal(today_seconds, goal_minutes)
    local read = math.floor((today_seconds or 0) / 60)
    if read >= goal_minutes then
        return { num = tostring(read), unit = "min today", right = "Goal done", fraction = 1, done = true }
    end
    return {
        num = tostring(goal_minutes - read),
        unit = "min to today’s goal",
        right = read .. " of " .. goal_minutes .. " min",
        fraction = read / goal_minutes,
        done = false,
    }
end

-- Where a yearly goal says you should be by today.
function F.goalPace(goal, now)
    now = now or os.time()
    local d = os.date("*t", now)
    local year_days = os.date("*t", os.time{ year = d.year, month = 12, day = 31, hour = 12 }).yday
    return math.floor(goal * d.yday / year_days + 0.5)
end

function F.weekTile(week_seconds, last_week_seconds)
    return F.total(week_seconds), "Last week: " .. F.total(last_week_seconds)
end

function F.booksTile(books, goal, now)
    books = books or 0
    if goal and goal > 0 then
        return books .. " of " .. goal, "Goal pace: " .. F.goalPace(goal, now) .. " by today"
    end
    return tostring(books), "finished so far"
end

function F.statsLine(best, streak, week_seconds, books, goal)
    local parts = {}
    if best and best >= 2 and best > (streak or 0) then
        table.insert(parts, "Best run: " .. best .. " days")
    end
    table.insert(parts, F.total(week_seconds) .. " this week")
    if goal and goal > 0 then
        table.insert(parts, (books or 0) .. " of " .. goal .. " books")
    else
        table.insert(parts, (books or 0) .. " finished this year")
    end
    return table.concat(parts, F.SEP)
end

function F.headerDate(t)
    t = t or os.time()
    return os.date("%A", t) .. F.SEP .. tonumber(os.date("%d", t)) .. " " .. os.date("%B", t)
end

-- Battery text for the header's right side, or nil for the default "Sleeping".
-- 0 means the level couldn't be read (a device that is really at 0% is off).
function F.batteryWarning(capacity, charging)
    if capacity and not charging and capacity > 0 and capacity <= F.LOW_BATTERY then
        return "Battery " .. capacity .. "%"
    end
    return nil
end

return F
