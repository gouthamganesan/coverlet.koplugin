--[[
Unit tests for the pure modules (text rules and day math). No KOReader
needed: run from the repo root with any Lua 5.1 or LuaJIT,

    luajit tests/run.lua
]]

package.path = "./?.lua;" .. package.path

local F = require("streakchain/format")
local C = require("streakchain/chain")

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
eq(F.total(0), "0 min", "total zero")
eq(F.total(2700), "45 min", "total minutes")
eq(F.total(7200), "2 h 00 min", "total hours")
eq(F.total(4020), "1 h 07 min", "total rounds down")
eq(F.percent(0.58), "58%", "percent")
eq(F.percent(0.996), "99%", "percent never rounds up to 100")

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

local variants = F.metaVariants("Franz Kafka", 0.58, base, false)
eq(variants[1], "Franz Kafka · 58% · 11 min left in Part II", "meta full")
eq(variants[2], "Franz Kafka · 58% · 11 min left in this chapter", "meta generic")
eq(variants[3], "58% · 11 min left in this chapter", "meta without author")
eq(F.metaVariants("Franz Kafka", 1, base, true)[1], "Franz Kafka · finished", "meta finished")
eq(F.metaVariants(nil, 0.58, base, false)[1], "58% · 11 min left in Part II", "meta no author")

-- -------------------------------------------------------- streak note ---
eq(F.streakNote(0, false, 12), F.NOTE_NEW, "note no run")
eq(F.streakNote(4, false, 12), F.NOTE_EMPTY, "note today empty")
eq(F.streakNote(5, true, 12), F.NOTE_IN, "note today read")
eq(F.streakNote(31, true, 31), F.NOTE_BEST, "note longest")
eq(F.streakNote(1, true, 1), F.NOTE_IN, "note first day is not a record")
eq(F.streakNote(4, false, 4), F.NOTE_EMPTY, "note empty wins over record")

-- --------------------------------------------------------- stats line ---
eq(F.statsLine(12, 4, 7200, 14, 24), "Best run: 12 days · 2 h 00 min this week · 14 of 24 books", "stats default")
eq(F.statsLine(31, 31, 13200, 14, 24), "3 h 40 min this week · 14 of 24 books", "stats best hidden when current")
eq(F.statsLine(1, 0, 0, 0, nil), "0 min this week · 0 finished this year", "stats best hidden under 2")
eq(F.statsLine(12, 4, 2700, 14, nil), "Best run: 12 days · 45 min this week · 14 finished this year", "stats no goal")
eq(F.statsLine(12, 4, 7200, 26, 24), "Best run: 12 days · 2 h 00 min this week · 26 of 24 books", "stats goal passed")

-- ------------------------------------------------------------- header ---
local fri = os.time{ year = 2026, month = 9, day = 25, hour = 21 }
eq(F.headerDate(fri), "Friday · 25 September", "header date")
eq(F.batteryWarning(8, false), "Battery 8%", "battery low")
eq(F.batteryWarning(15, false), "Battery 15%", "battery at threshold")
eq(F.batteryWarning(16, false), nil, "battery fine")
eq(F.batteryWarning(8, true), nil, "battery charging")
eq(F.batteryWarning(0, false), nil, "battery unreadable")

-- -------------------------------------------------------------- chain ---
-- Friday 25 September 2026; the grid starts Monday 31 August.
local function build(map)
    local days = {}
    local secs = { l = 900, m = 1800, h = 2700 }
    for k, v in pairs(map) do days[k] = secs[v] or tonumber(v) end
    return days
end
local function seq(start_key, codes)
    local out, t = {}, C.keyToTime(start_key)
    for code in codes:gmatch("%S+") do
        if code ~= "x" then out[C.key(t)] = code end
        t = C.addDays(t, 1)
    end
    return out
end
local function merge(...)
    local out = {}
    for _, t in ipairs({ ... }) do for k, v in pairs(t) do out[k] = v end end
    return out
end
local function codes(cells) return table.concat(cells, " ") end

local history = merge(
    seq("2026-08-01", "m m m m m m m m m m m m"), -- a 12-day run in early August
    seq("2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h l m"))
local r = C.compute(build(history), fri)
eq(r.streak, 4, "chain default streak")
eq(r.best, 12, "chain default best")
eq(r.read_today, false, "chain default not read")
eq(r.week_seconds, 7200, "chain default week")
eq(codes(r.cells), "m m x l h h m x x m l h h x l m x m m m x m h l m te f f", "chain default cells")

local read = merge(history, { ["2026-09-25"] = 1320 })
r = C.compute(build(read), fri)
eq(r.streak, 5, "chain read streak")
eq(r.cells[26], "tm", "chain today read cell")
eq(r.week_seconds, 7200 + 1320, "chain read week")

local broken = merge(seq("2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h"))
r = C.compute(build(broken), fri)
eq(r.streak, 0, "chain broken streak")
eq(codes(r.cells), "m m x l h h m x x m l h h x l m x m m m x m h x x te f f", "chain broken cells")

r = C.compute(build(seq("2026-09-22", "l 1320 m")), fri)
eq(r.streak, 3, "chain first days streak")
eq(r.best, 3, "chain first days best")
eq(r.week_seconds, 900 + 1320 + 1800, "chain first days week")
eq(codes(r.cells), "n n n n n n n n n n n n n n n n n n n n n n l m m te f f", "chain first days cells")

r = C.compute({}, fri)
eq(r.streak, 0, "chain empty streak")
eq(r.best, 0, "chain empty best")
eq(r.cells[26], "te", "chain empty today")
eq(r.cells[1], "n", "chain empty past")

local run31 = {}
local t = C.keyToTime("2026-08-26")
for _ = 1, 31 do run31[C.key(t)] = 2700; t = C.addDays(t, 1) end
r = C.compute(run31, fri)
eq(r.streak, 31, "chain long streak")
eq(r.best, 31, "chain long best")
eq(F.streakNote(r.streak, r.read_today, r.best), F.NOTE_BEST, "chain long note")

-- Month and year boundaries.
local ny = os.time{ year = 2027, month = 1, day = 1, hour = 9 }
r = C.compute(build(seq("2026-12-30", "m m m")), ny)
eq(r.streak, 3, "chain across new year")
eq(C.weekdayIndex(ny), 4, "1 Jan 2027 is a Friday")

-- ------------------------------------------------------ chapter marks ---
local sharp = { 4, 7, 8, 9, 31, 53, 80, 108, 135, 156, 165, 189, 223, 257, 274, 305, 328, 356, 382, 389, 396, 401, 403, 410, 438, 439 }
local fr = {}
for _, p in ipairs(sharp) do table.insert(fr, (p - 1) / 440) end
local kept = C.thinTicks(fr)
eq(#kept, 20, "ticks thinned from 26")
local closest = 1
for i = 2, #kept do closest = math.min(closest, kept[i] - kept[i - 1]) end
eq(closest >= C.MIN_GAP, true, "no two marks closer than the minimum gap")
eq(kept[#kept] < 0.99, true, "no marks in the last 1%")
eq(#C.thinTicks({}), 0, "no chapters, no marks")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
