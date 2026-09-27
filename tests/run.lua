--[[
Unit tests for the pure modules (text rules and day math). No KOReader
needed: run from the repo root with any Lua 5.1 or LuaJIT,

    luajit tests/run.lua
]]

package.path = "./?.lua;" .. package.path

local F = require("streakchain/format")
local C = require("streakchain/chain")
local Q = require("streakchain/quote")

local passed, failed = 0, 0
local function eq(got, want, name)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s\n  want: %s\n  got:  %s", name, tostring(want), tostring(got)))
    end
end

-- ------------------------------------------------------------ titles ---
eq(F.cleanTitle("The Metamorphosis"), "The Metamorphosis", "title plain")
eq(F.cleanTitle("Good Strategy Bad Strategy: The Difference and Why It Matters"), "Good Strategy Bad Strategy", "title drops subtitle")
eq(F.cleanTitle("Re:Zero"), "Re:Zero", "title colon without space survives")
eq(F.cleanTitle("  Spaced  "), "Spaced", "title trimmed")
eq(F.cleanTitle(""), nil, "title empty")
eq(F.cleanTitle(nil), nil, "title nil")

-- ----------------------------------------------------------- authors ---
eq(F.authorLine("Franz Kafka"), "Franz Kafka", "author single")
eq(F.authorLine("Crichton, Michael"), "Michael Crichton", "author flipped")
eq(F.authorLine("Forster, E M"), "E M Forster", "author flipped initials")
eq(F.authorLine("Jason Fried\nDavid Heinemeier Hansson"), "Jason Fried & David Heinemeier Hansson", "author two lines")
eq(F.authorLine("J K Rowling, Mary GrandPré"), "J K Rowling & Mary GrandPré", "author two by comma")
eq(F.authorLine("Perchtold-Stefan\nAndreas Fink\nChristian Rominger"), "Perchtold-Stefan et al.", "author three")
eq(F.authorLine(""), nil, "author empty")
eq(F.authorLine(nil), nil, "author nil")

-- --------------------------------------------------------- durations ---
eq(F.left(0), "1 min", "left zero rounds up to 1")
eq(F.left(30), "1 min", "left under a minute")
eq(F.left(61), "2 min", "left rounds up")
eq(F.left(660), "11 min", "left minutes")
eq(F.left(3900), "1 h 05 min", "left over an hour")
eq(F.spent(0), "0 min", "spent zero")
eq(F.spent(2700), "45 min", "spent minutes")
eq(F.spent(7200), "2 h 00", "spent hours")
eq(F.spent(11239), "3 h 07", "spent rounds down")
eq(F.goalHours(600), "10 h", "goal whole hours")
eq(F.goalHours(150), "2 h 30", "goal hours and minutes")
eq(F.goalHours(45), "45 min", "goal under an hour")

-- --------------------------------------------------------- next step ---
local base = { has_chapters = true, chapter_title = "Part II", chapter_seconds = 660, book_seconds = 2280 }
eq(F.nextStep(base), "11 min left in Part II", "step chapter title")
local long = { has_chapters = true, chapter_title = "Chapter Twelve: The Man Who Was Almost", chapter_seconds = 660 }
eq(F.nextStep(long), "11 min left in this chapter", "step long title")
eq(F.nextStep({ has_chapters = true, chapter_title = "", chapter_seconds = 660 }), "11 min left in this chapter", "step untitled")
eq(F.nextStep({ has_chapters = true, in_last_chapter = true, chapter_title = "Part III", book_seconds = 360 }), "6 min left in the book", "step last chapter")
eq(F.nextStep({ has_chapters = false, book_seconds = 4320 }), "1 h 12 min left in the book", "step no chapters")
eq(F.nextStep({ has_chapters = true, chapter_title = "Part II", chapter_pages = 12, book_pages = 40 }), "12 pages left in Part II", "step pages")
eq(F.nextStep({ has_chapters = true, chapter_title = "Part II", chapter_pages = 1 }), "1 page left in Part II", "step one page")
eq(F.nextStep({ finished = true, book_seconds = 60 }), nil, "step finished")
eq(F.nextStep({ has_chapters = true, chapter_title = "Part II", generic = true, chapter_seconds = 660 }), "11 min left in this chapter", "step generic")
eq(F.stepLine({ has_chapters = true, chapter_title = "Chapter Thirteen", chapter_seconds = 1320 }, false),
    "22 min left in Chapter Thirteen", "step line keeps the chapter name")
eq(F.stepLine(base, true), "Finished", "step line finished")
eq(F.stepLine({}, false), nil, "step line with nothing to say")

-- ------------------------------------------------------------ best run ---
eq(F.bestLine(12, 4), "Best run: 12 days", "best line")
eq(F.bestLine(2, 0), "Best run: 2 days", "best line at its smallest is still plural")
eq(F.bestLine(4, 4), nil, "best line hidden when current")
eq(F.bestLine(1, 0), nil, "best line hidden under 2, so never '1 days'")
for best = 1, 40 do
    local l = F.bestLine(best, 0)
    eq(l == nil or l:match(" days$") ~= nil and best >= 2, true, "best line reads right at " .. best)
end

-- ------------------------------------------------------------- header ---
local fri = os.time{ year = 2026, month = 9, day = 25, hour = 21 }
eq(F.headerDate(fri), "Friday · 25 September", "header date")
eq(F.batteryWarning(8, false), "Battery 8%", "battery low")
eq(F.batteryWarning(15, false), "Battery 15%", "battery at threshold")
eq(F.batteryWarning(16, false), nil, "battery fine")
eq(F.batteryWarning(8, true), nil, "battery charging")
eq(F.batteryWarning(0, false), nil, "battery unreadable")

-- --------------------------------------------------------------- hero ---
local a, b = F.heroTime(2280)
eq(a .. " " .. b, "38 min to the end", "hero minutes")
a, b = F.heroTime(9600)
eq(a .. " " .. b, "2 h 40 to the end", "hero hours")
a, b = F.heroTime(3600)
eq(a .. " " .. b, "1 h 00 to the end", "hero exactly an hour")
a, b = F.heroTime(20)
eq(a, "1", "hero never below 1 min")
a, b = F.heroPages(64, 110)
eq(a .. " " .. b, "64 of 110 pages", "hero pages")

-- --------------------------------------------------- time in the book ---
local sep12 = os.time{ year = 2026, month = 9, day = 12, hour = 20 }
eq(F.bookSoFar(24000, sep12, fri), "6 h 40 in, since 12 Sep", "so far hours")
eq(F.bookSoFar(2400, sep12, fri), "40 min in, since 12 Sep", "so far minutes")
eq(F.bookSoFar(600, fri - 3600, fri), "10 min in, started today", "so far started today")
eq(F.bookSoFar(30, fri - 600, fri), "Started today", "so far under a minute")
eq(F.bookSoFar(90000, os.time{ year = 2025, month = 12, day = 30, hour = 20 }, fri), "25 h 00 in, since 30 Dec 2025",
    "so far from last year")
eq(F.bookSoFar(600, nil, fri), nil, "so far without a start")

-- -------------------------------------------------------------- today ---
local t = F.today(720, 45, 14, 3)
eq(t.num .. " " .. t.unit, "33 min to today’s goal", "today partway")
eq(math.abs(t.fraction - 12 / 45) < 1e-9, true, "today fraction")
eq(#t.rows, 3, "today rows")
eq(t.rows[1][1] .. " | " .. t.rows[1][2], "Read | 12 of 45 min", "today read row")
eq(t.rows[2][1] .. " | " .. t.rows[2][2], "Pages today | 14", "today pages row")
eq(t.rows[3][1] .. " | " .. t.rows[3][2], "Goal day streak | 3", "today goal streak row")
t = F.today(0, 45, 0, 0)
eq(t.num .. " | " .. t.rows[1][2], "45 | 0 of 45 min", "today not started")
t = F.today(3120, 45, 30, 4)
eq(t.num .. " " .. t.unit .. " | " .. t.rows[1][1] .. " " .. t.rows[1][2], "52 min today | Daily goal Done", "today goal done")
eq(t.fraction, 1, "today goal done is full")
eq(tostring(F.today(2700, 45, 1, 1).done), "true", "today goal exactly met")
t = F.today(1320, nil, 9, nil)
eq(t.num .. " " .. t.unit, "22 min today", "today without a goal")
eq(t.fraction, nil, "today without a goal has no bar")
eq(#t.rows, 1, "today without a goal: pages only")
eq(#F.today(1320, 45, nil, 0).rows, 2, "today drops pages it couldn't count")

-- -------------------------------------------------------------- goals ---
local rows = F.goalRows{ now = fri, weekly = 600, week_seconds = 11239, monthly = 2, books_month = 1, yearly = 6, books_year = 4 }
eq(#rows, 3, "goal rows, all on")
eq(rows[1].label .. " | " .. rows[1].value, "This week | 3 h 07 of 10 h", "goal week")
eq(math.abs(rows[1].fraction - 11239 / 36000) < 1e-9, true, "goal week fraction")
eq(rows[1].segments, nil, "goal week is one bar")
eq(rows[2].label .. " | " .. rows[2].value .. " | " .. rows[2].segments .. " " .. rows[2].filled, "September | 1 of 2 books | 2 1", "goal month")
eq(rows[3].label .. " | " .. rows[3].value .. " | " .. rows[3].segments .. " " .. rows[3].filled, "2026 | 4 of 6 books | 6 4", "goal year")
rows = F.goalRows{ now = fri, weekly = 150, week_seconds = 10320 }
eq(#rows, 1, "goal rows, weekly only")
eq(rows[1].value .. " " .. rows[1].fraction, "2 h 52 of 2 h 30 1", "goal week met")
rows = F.goalRows{ now = fri, monthly = 1, books_month = 0, yearly = 52, books_year = 60 }
eq(rows[1].value, "0 of 1 book", "goal one book")
eq(rows[2].value .. " | " .. tostring(rows[2].segments) .. " " .. rows[2].fraction, "60 of 52 books | nil 1", "goal many books is one bar")
eq(#F.goalRows{ now = fri }, 0, "no goals, no rows")
local yl = F.yearLine(310000, fri)
eq(yl.label .. " | " .. yl.value, "Read in 2026 | 86 h", "year hours")
eq(F.yearLine(2700, fri).value, "45 min", "year under an hour")

-- -------------------------------------------------------------- chain ---
-- Friday 25 September 2026.
local function build(map)
    local days = {}
    local secs = { l = 900, m = 1800, h = 2700 }
    for k, v in pairs(map) do days[k] = secs[v] or tonumber(v) end
    return days
end
local function seq(start_key, codes)
    local out, tt = {}, C.keyToTime(start_key)
    for code in codes:gmatch("%S+") do
        if code ~= "x" then out[C.key(tt)] = code end
        tt = C.addDays(tt, 1)
    end
    return out
end
local function merge(...)
    local out = {}
    for _, m in ipairs({ ... }) do for k, v in pairs(m) do out[k] = v end end
    return out
end

local history = merge(
    seq("2026-08-01", "m m m m m m m m m m m m"), -- a 12-day run in early August
    seq("2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h l m"))
local r = C.compute(build(history), fri)
eq(r.streak, 4, "chain default streak")
eq(r.best, 12, "chain default best")
eq(r.read_today, false, "chain default not read")
eq(r.week_seconds, 7200, "chain default week")
eq(r.today_seconds, 0, "chain today seconds")
eq(r.year_seconds, 22 * 1800 + 4 * 900 + 5 * 2700, "chain year total")

local read = merge(history, { ["2026-09-25"] = 1320 })
r = C.compute(build(read), fri)
eq(r.streak, 5, "chain read streak")
eq(r.week_seconds, 7200 + 1320, "chain read week")

local broken = merge(seq("2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h"))
r = C.compute(build(broken), fri)
eq(r.streak, 0, "chain broken streak")

r = C.compute(build(seq("2026-09-22", "l 1320 m")), fri)
eq(r.streak, 3, "chain first days streak")
eq(r.best, 3, "chain first days best")
eq(r.week_seconds, 900 + 1320 + 1800, "chain first days week")

r = C.compute({}, fri)
eq(r.streak, 0, "chain empty streak")
eq(r.best, 0, "chain empty best")
eq(r.year_seconds, 0, "chain empty year")

local run31 = {}
local tt = C.keyToTime("2026-08-26")
for _ = 1, 31 do run31[C.key(tt)] = 2700; tt = C.addDays(tt, 1) end
r = C.compute(run31, fri)
eq(r.streak, 31, "chain long streak")
eq(r.best, 31, "chain long best")
eq(F.bestLine(r.best, r.streak), nil, "chain long run is its own best")

-- Month and year boundaries.
local ny = os.time{ year = 2027, month = 1, day = 1, hour = 9 }
r = C.compute(build(seq("2026-12-30", "m m m")), ny)
eq(r.streak, 3, "chain across new year")
eq(r.year_seconds, 1800, "year total starts again on 1 January")
eq(C.weekdayIndex(ny), 4, "1 Jan 2027 is a Friday")
eq(r.week_seconds, 3 * 1800, "week runs across the new year from Monday")

-- Period starts.
eq(os.date("%Y-%m-%d %H:%M", C.startOfDay(fri)), "2026-09-25 00:00", "start of day")
eq(os.date("%Y-%m-%d %H:%M", C.startOfWeek(fri)), "2026-09-21 00:00", "week starts Monday")
eq(os.date("%Y-%m-%d", C.startOfWeek(os.time{ year = 2026, month = 9, day = 27, hour = 23 })), "2026-09-21", "Sunday is the week's last day")
eq(os.date("%Y-%m-%d", C.startOfWeek(os.time{ year = 2026, month = 9, day = 21, hour = 1 })), "2026-09-21", "Monday starts its own week")
eq(os.date("%Y-%m-%d %H:%M", C.startOfMonth(fri)), "2026-09-01 00:00", "start of month")
eq(os.date("%Y-%m-%d %H:%M", C.startOfYear(fri)), "2026-01-01 00:00", "start of year")

-- ------------------------------------------------------ goal day streak ---
local goal = 45 * 60
local gdays = build(seq("2026-09-19", "h h l h h h"))
eq(C.goalStreak(gdays, fri, goal), 3, "goal streak through yesterday, today not met yet")
eq(C.goalStreak(merge(gdays, { ["2026-09-25"] = 2700 }), fri, goal), 4, "goal streak counts today once met")
eq(C.goalStreak(merge(gdays, { ["2026-09-25"] = 1800 }), fri, goal), 3, "goal streak stands while today is short")
eq(C.goalStreak(build(seq("2026-09-22", "h h l")), fri, goal), 0, "goal streak broken yesterday")
eq(C.goalStreak(gdays, fri, nil), 0, "no goal, no goal streak")
eq(C.goalStreak({}, fri, goal), 0, "goal streak empty")

-- ------------------------------------------------------------ calendar ---
local cal = C.calendar(build(read), fri, 5, true)
eq(#cal, 3, "calendar three months")
eq(os.date("%B", cal[1].time) .. " " .. os.date("%B", cal[3].time), "July September", "calendar July to September")
eq(cal[1].offset, 2, "July 2026 starts on a Wednesday")
eq(cal[2].offset, 5, "August 2026 starts on a Saturday")
eq(cal[3].offset, 1, "September 2026 starts on a Tuesday")
eq(#cal[1].days .. " " .. #cal[2].days .. " " .. #cal[3].days, "31 31 30", "calendar month lengths")
local sep = cal[3].days
eq(sep[25].today, true, "calendar today")
eq(sep[25].level, "m", "calendar today's level")
eq(sep[26].level, "f", "calendar after today")
eq(sep[20].level, "o", "calendar nothing read")
eq(sep[23].level, "l", "calendar under 20 min")
eq(sep[22].level, "h", "calendar 40 min or more")
eq(sep[1].level, "m", "calendar 20 to 39 min")
eq(tostring(sep[20].run) .. " " .. tostring(sep[21].run) .. " " .. tostring(sep[25].run), "false true true", "calendar the run")
eq(tostring(sep[21].joins_prev) .. " " .. tostring(sep[21].joins_next), "false true", "calendar run starts")
eq(tostring(sep[25].joins_prev) .. " " .. tostring(sep[25].joins_next), "true false", "calendar run ends today")
cal = C.calendar(build(history), fri, 4, false)
eq(tostring(cal[3].days[24].joins_next) .. " " .. tostring(cal[3].days[25].run), "false false", "calendar run ends yesterday until today is read")
cal = C.calendar(run31, fri, 31, true)
eq(tostring(cal[2].days[31].joins_next) .. " " .. tostring(cal[3].days[1].joins_prev), "true true", "calendar run crosses the month")
eq(tostring(cal[2].days[25].run) .. " " .. tostring(cal[2].days[26].joins_prev), "false false", "calendar run's first day")
cal = C.calendar({}, ny, 0, false)
eq(os.date("%Y-%m", cal[1].time) .. " " .. os.date("%Y-%m", cal[3].time), "2026-11 2027-01", "calendar across the new year")
eq(cal[3].days[1].today and cal[3].days[2].level, "f", "calendar new year's day")
cal = C.calendar({}, os.time{ year = 2028, month = 3, day = 1, hour = 9 }, 0, false)
eq(#cal[2].days, 29, "calendar leap February")

-- -------------------------------------------------------------- flame ---
local function flame(streak, read_today)
    local f = C.flame(streak, read_today)
    return f.size .. " " .. f.variant .. " " .. f.h .. (f.muted and " muted" or "")
end
eq(flame(0, false), "medium dashed 52 muted", "flame no run")
eq(flame(1, true), "small solid 36", "flame 1 day")
eq(flame(2, true), "small solid 36", "flame 2 days")
eq(flame(3, true), "medium solid 52", "flame 3 days")
eq(flame(6, true), "medium solid 52", "flame 6 days")
eq(flame(7, true), "large solid 64", "flame 7 days")
eq(flame(29, true), "large solid 64", "flame 29 days")
eq(flame(30, true), "large core 64", "flame 30 days has a core")
eq(flame(1, false), "small outline 36", "flame 1 day, today not read")
eq(flame(2, false), "small outline 36", "flame 2 days, today not read")
eq(flame(3, false), "medium outline 52", "flame 3 days, today not read")
eq(flame(6, false), "medium outline 52", "flame 6 days, today not read")
eq(flame(7, false), "large outline 64", "flame 7 days, today not read")
eq(flame(29, false), "large outline 64", "flame 29 days, today not read")
eq(flame(30, false), "large outline 64", "flame 30 days, today not read is an outline")
eq(C.flame(1, true).w .. " " .. C.flame(3, true).w .. " " .. C.flame(7, true).w, "32 46 56", "flame widths")

-- ------------------------------------------------------------ chapters ---
local sharp = { 4, 7, 8, 9, 31, 53, 80, 108, 135, 156, 165, 189, 223, 257, 274, 305, 328, 356, 382, 389, 396, 401, 403, 410, 438, 439 }
local fr = {}
for _, p in ipairs(sharp) do table.insert(fr, (p - 1) / 440) end
local kept = C.thinTicks(fr)
local kept_pages = {}
for _, t in ipairs(kept) do table.insert(kept_pages, math.floor(t * 440 + 1.5)) end
eq(table.concat(kept_pages, " "), "9 31 53 80 108 135 156 165 189 223 257 274 305 328 356 382 389 396 403 410",
    "front and back matter fold into their neighbours, every chapter stays")
eq(#C.thinTicks({}), 0, "no chapters, no marks")
eq(#C.thinTicks({ 0, 1 }), 0, "marks at the very ends are not chapters")
local even = {}
for i = 1, 63 do table.insert(even, i / 64) end
eq(#C.thinTicks(even), 63, "64 even chapters all stay")
eq(#C.thinTicks({ 0.5, 0.501 }), 1, "a sliver of a chapter joins its neighbour")

-- The magnified bar at 7b's 1152 px.
local bar = C.chapterBar(kept, 305 / 440, 1152, 1, false)
eq(bar.count .. " " .. bar.index, "21 14", "bar: Chapter Thirteen is the 14th of 21")
eq(bar.box.w, 1152 * 0.4, "bar: the current chapter gets 40%")
eq(bar.gap, 4, "bar: 4 px between a few chapters")
eq(#bar.before .. " " .. #bar.after, "13 7", "bar: read before, unread after")
local last = bar.after[#bar.after]
eq(math.abs(last.x + last.w - 1152) < 1e-6, true, "bar: spans the whole width")
eq(math.abs(bar.box.fill - (305 / 440 - 304 / 440) / (327 / 440 - 304 / 440)) < 1e-9, true, "bar: filled as far as the chapter is read")
local ratio = bar.before[3].w / bar.before[4].w
eq(math.abs(ratio - (52 - 30) / (79 - 52)) < 1e-9, true, "bar: other chapters in proportion to their length")
bar = C.chapterBar(even, 0.41, 1152, 1, false)
eq(bar.count .. " " .. bar.gap, "64 2", "bar: 2 px between many chapters")
eq(bar.index, 27, "bar: 41% is in the 27th of 64")
local two = {}
for i = 1, 399 do table.insert(two, i / 400) end
bar = C.chapterBar(two, 0.5, 1152, 1, false)
eq(#bar.before .. " " .. #bar.after, "1 1", "bar: too many to draw one by one, read and unread each one piece")
bar = C.chapterBar({ 0.34, 0.69 }, 0.9, 1152, 1, true)
eq(bar.index .. " " .. bar.box.fill .. " " .. #bar.after, "3 1 0", "bar: finished, the last chapter full")
eq(C.chapterBar({}, 0.4, 1152, 1, false), nil, "bar: no chapters, one box")
bar = C.chapterBar({ 0.34, 0.69 }, 0.1, 600, 0.5, false)
eq(bar.gap .. " " .. bar.box.x, "2 0", "bar: scaled, and the first chapter starts at the left")

local labels = F.barLabels({ has_chapters = true, chapter_title = "Chapter Thirteen", chapter_seconds = 1320 }, 306, 440, false)
eq(labels.chapter.left .. " | " .. labels.chapter.right, "Chapter Thirteen | 22 min left", "bar labels: the chapter and time left")
labels = F.barLabels({ has_chapters = true, chapter_title = "7", chapter_pages = 12 }, 10, 90, false)
eq(labels.chapter.left .. " | " .. labels.chapter.right, "Chapter 7 | 12 pages left", "bar labels: a bare number, pages without statistics")
labels = F.barLabels({ has_chapters = true, in_last_chapter = true, chapter_title = "Epilogue", book_seconds = 360 }, 104, 110, false)
eq(labels.chapter.right, "6 min left", "bar labels: the last chapter runs to the end")
labels = F.barLabels({ has_chapters = true, chapter_title = "", chapter_pages = 1 }, 10, 90, false)
eq(labels.chapter.left .. " | " .. labels.chapter.right, "This chapter | 1 page left", "bar labels: untitled chapter, one page")
labels = F.barLabels({ has_chapters = false }, 87, 230, false)
eq(labels.pages.left .. " | " .. labels.pages.right, "Page 87 of 230 | 143 pages to go", "bar labels: no chapters")
eq(F.barLabels({}, 229, 230, false).pages.right, "1 page to go", "bar labels: one page to go")
eq(F.barLabels({}, 230, 230, false).pages.right, "Last page", "bar labels: the last page")
eq(F.barLabels({ has_chapters = true }, 110, 110, true).chapter.left, "Finished", "bar labels: finished")
eq(next(F.barLabels({}, nil, nil, false).pages), nil, "bar labels: nothing known, nothing said")

-- -------------------------------------------------------------- quote ---
eq(F.quoteText({ text = "Books are a uniquely portable magic." }), "“Books are a uniquely portable magic.”", "quote in curly quotes")
eq(F.quoteBy({ author = "Stephen King", source = "On Writing" }), "Stephen King · On Writing", "quote by, with source")
eq(F.quoteBy({ author = "Franz Kafka" }), "Franz Kafka", "quote by, author only")

-- Fit: lines of 38, 8 + 28 for who said it, 14 clear above and below.
eq(Q.height(1), 74, "quote one line tall")
eq(Q.height(2), 112, "quote two lines tall")
eq(Q.fits(1, 102), true, "one line fits its exact gap")
eq(Q.fits(1, 101), false, "one line needs 14 clear each side")
eq(Q.fits(2, 140), true, "two lines fit their exact gap")
eq(Q.fits(2, 139), false, "two lines don't fit a pixel less")
eq(Q.fits(3, 1000), false, "three lines never fit")
eq(Q.fits(0, 1000), false, "an empty quote doesn't fit")

-- Rotation: a fixed random so the shuffle is known.
local function first(k) return 1 end -- Fisher-Yates with j = 1 every time
local order = Q.shuffle(4, first)
eq(table.concat(order, " "), "2 3 4 1", "shuffle with a fixed random")
local all = function() return true end
local state, seen, picks = nil, {}, {}
for _ = 1, 4 do
    local i
    i, state = Q.pick(state, 4, all, first)
    seen[i] = (seen[i] or 0) + 1
    table.insert(picks, i)
end
local once = true
for i = 1, 4 do once = once and seen[i] == 1 end
eq(once, true, "no repeat until all have shown: " .. table.concat(picks, " "))
eq(state.pos, 5, "round used up")
local i5
i5, state = Q.pick(state, 4, all, first)
eq(state.pos, 2, "a new round starts after the last")
eq(i5 ~= nil, true, "the new round shows a quote")

-- Skip: 4 is too long today, so 2 shows and 4 waits its turn.
local fits = function(i) return i ~= 4 end
local picked, st = Q.pick({ order = { 4, 2, 1, 3 }, pos = 1 }, 4, fits)
eq(picked, 2, "a quote too long is skipped for the next that fits")
eq(table.concat(st.order, " ") .. " @" .. st.pos, "2 4 1 3 @2", "the skipped quote stays next in the round")
picked, st = Q.pick(st, 4, all)
eq(picked, 4, "on a roomier day the skipped quote shows")
-- Only too-long ones left in the round: start the next round.
picked, st = Q.pick({ order = { 1, 2, 3, 4 }, pos = 4 }, 4, fits, first)
eq(picked ~= nil and picked ~= 4, true, "only unfit ones left: a new round")
-- Nothing fits at all: nothing shows and the rotation stays put.
local none = function() return false end
local keep = { order = { 3, 1, 2, 4 }, pos = 2 }
picked, st = Q.pick(keep, 4, none)
eq(picked, nil, "nothing fits, the gap stays empty")
eq(st, keep, "nothing fits, the rotation doesn't move")
-- A saved rotation that no longer matches the list is started afresh.
picked, st = Q.pick({ order = { 1, 2, 3 }, pos = 2 }, 4, all, first)
eq(#st.order .. " " .. st.pos, "4 2", "a list of a new length starts a new round")
picked, st = Q.pick({ order = { 1, 1, 2, 3 }, pos = 1 }, 4, all, first)
eq(table.concat(st.order, " "), "2 3 4 1", "a corrupt rotation is replaced")
eq(Q.pick(nil, 0, all), nil, "no quotes, nothing to show")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
