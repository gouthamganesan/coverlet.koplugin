--[[
Every piece of text on the sleep screen, as pure functions.

No KOReader modules in here, so tests/run.lua can exercise it with a bare
luajit. The wording rules come from the design canvas:

  * nothing refers to the time of day ("today", never "tonight")
  * no singular/plural splits where a unit can avoid it: "11 min",
    "4 day streak", "Best run: 12"
  * encouraging, never discouraging: time read rounds down, time left rounds
    up, and a row with nothing to say drops out rather than scolding
]]

local F = {}

F.SEP = " · "
F.CHAPTER_TITLE_MAX = 20
F.LOW_BATTERY = 15
F.SEGMENTS_MAX = 24 -- book goals up to this many draw one cell per book

F.NOTE_IN = "Today is in the chain."
F.NOTE_BEST = "Your longest run so far."
F.NOTE_NEW = "One page starts a new run."

F.FINISHED = "Finished"
F.NO_BOOK_TITLE = "No book open"
F.NO_BOOK_SUB = "Your shelf is one tap away."
F.STATS_OFF_NOTE = "Your streak appears once Reading statistics is on."
F.STATS_OFF_HINT = "Turn it on in Tools · Reading statistics."

F.WEEKDAYS = { "M", "T", "W", "T", "F", "S", "S" }

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

-- Time already read, rounded down, in the short form the ledger uses:
-- "45 min", "3 h 07".
function F.spent(seconds)
    local m = math.floor((seconds or 0) / 60)
    if m < 60 then return m .. " min" end
    return string.format("%d h %02d", math.floor(m / 60), m % 60)
end

-- A goal in minutes, as hours: "10 h", "2 h 30", or "45 min".
function F.goalHours(minutes)
    if minutes < 60 then return minutes .. " min" end
    if minutes % 60 == 0 then return math.floor(minutes / 60) .. " h" end
    return string.format("%d h %02d", math.floor(minutes / 60), minutes % 60)
end

--[[
The next step, the line under the author.
  o.finished          book is done: no next step
  o.has_chapters      the book has a table of contents
  o.in_last_chapter   no chapter after this one
  o.chapter_title     title of the current chapter
  o.generic           force "this chapter"
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

-- The line under the author: the next step, or "Finished".
function F.stepLine(step_opts, finished)
    if finished then return F.FINISHED end
    return F.nextStep(step_opts or {})
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

-- "Best run: 12", only while the best run is ahead of the current one.
function F.bestLine(best, streak)
    if best and best >= 2 and best > (streak or 0) then
        return "Best run: " .. best
    end
    return nil
end

-- The hero: time to the end as a number and its unit, "38" / "min to the end"
-- or "2 h 40" / "to the end".
function F.heroTime(seconds)
    local m = math.max(1, math.ceil((seconds or 0) / 60))
    if m < 60 then return tostring(m), "min to the end" end
    return string.format("%d h %02d", math.floor(m / 60), m % 60), "to the end"
end

-- Without reading statistics there is no pace, so the hero is the page.
function F.heroPages(page, total)
    return tostring(page), "of " .. total .. " pages"
end

local function shortDate(t)
    return tonumber(os.date("%d", t)) .. " " .. os.date("%b", t)
end

-- Time in this book so far and since when: "6 h 40 in, since 12 Sep".
-- Before a first full minute it's only the date.
function F.bookSoFar(seconds, first, now)
    if not first then return nil end
    now = now or os.time()
    local since
    if os.date("%Y-%m-%d", first) == os.date("%Y-%m-%d", now) then
        since = "started today"
    else
        since = "since " .. shortDate(first)
        if os.date("%Y", first) ~= os.date("%Y", now) then since = since .. " " .. os.date("%Y", first) end
    end
    if math.floor((seconds or 0) / 60) < 1 then
        return (since:gsub("^%l", string.upper))
    end
    return F.spent(seconds) .. " in, " .. since
end

--[[
The Today column.
  num, unit   "33" / "min to today’s goal"; "52" / "min today" once the goal is
              met, or when no daily goal is set
  fraction    0..1 of the daily goal read today; nil without a goal
  rows        { { label, value }, ... }: the goal, pages today, goal day streak
]]
function F.today(today_seconds, goal_minutes, pages, goal_streak)
    local read = math.floor((today_seconds or 0) / 60)
    local t = { rows = {} }
    if goal_minutes then
        if read >= goal_minutes then
            t.num, t.unit, t.fraction, t.done = tostring(read), "min today", 1, true
            table.insert(t.rows, { "Daily goal", "Done" })
        else
            t.num, t.unit, t.fraction, t.done = tostring(goal_minutes - read), "min to today’s goal", read / goal_minutes, false
            table.insert(t.rows, { "Read", read .. " of " .. goal_minutes .. " min" })
        end
    else
        t.num, t.unit = tostring(read), "min today"
    end
    if pages then table.insert(t.rows, { "Pages today", tostring(pages) }) end
    if goal_minutes then table.insert(t.rows, { "Goal day streak", tostring(goal_streak or 0) }) end
    return t
end

local function bookGoal(label, books, goal)
    books = books or 0
    return {
        label = label,
        value = books .. " of " .. goal .. (goal == 1 and " book" or " books"),
        fraction = math.min(1, books / goal),
        segments = goal <= F.SEGMENTS_MAX and goal or nil,
        filled = math.min(books, goal),
    }
end

--[[
The Goals column: a row for each of Bookshelf's goals that is on.
  o = { now, weekly (minutes), week_seconds, monthly (books), books_month,
        yearly (books), books_year }
  -> { { label, value, fraction, segments = n | nil, filled }, ... }
]]
function F.goalRows(o)
    local now = o.now or os.time()
    local rows = {}
    if o.weekly then
        table.insert(rows, {
            label = "This week",
            value = F.spent(o.week_seconds) .. " of " .. F.goalHours(o.weekly),
            fraction = math.min(1, (o.week_seconds or 0) / (o.weekly * 60)),
        })
    end
    if o.monthly then table.insert(rows, bookGoal(os.date("%B", now), o.books_month, o.monthly)) end
    if o.yearly then table.insert(rows, bookGoal(os.date("%Y", now), o.books_year, o.yearly)) end
    return rows
end

-- The bigger picture under the goals: "Read in 2026" / "86 h".
function F.yearLine(seconds, now)
    local m = math.floor((seconds or 0) / 60)
    local value = m < 60 and (m .. " min") or (math.floor(m / 60) .. " h")
    return { label = "Read in " .. os.date("%Y", now or os.time()), value = value }
end

function F.monthName(t)
    return os.date("%B", t)
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
