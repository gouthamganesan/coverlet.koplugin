--[[
One model per state, built through data.lua's own model functions so the
renders exercise the real wording and day maths.

cover(name): returns a fresh cover BlitBuffer (or nil) on every call, because
the screen owns and frees the cover it is given.
]]

local C = require("streakchain/chain")
local Data = require("streakchain/data")
local F = require("streakchain/format")

local NOW = os.time{ year = 2026, month = 9, day = 25, hour = 21 } -- a Friday

local SECS = { l = 900, m = 1800, h = 2700 }

local function seq(days, start_key, codes)
    local t = C.keyToTime(start_key)
    for code in codes:gmatch("%S+") do
        if code ~= "x" then days[C.key(t)] = SECS[code] or tonumber(code) end
        t = C.addDays(t, 1)
    end
    return days
end

-- Goals as set in Bookshelf's Reading goal module: 45 min a day, 10 h a week,
-- 2 books a month, 6 a year.
local GOALS = { daily = 45, weekly = 600, monthly = 2, yearly = 6 }
local COUNTS = { pages_today = 14, books_month = 1, books_year = 4 }

local function stats(days, goals, counts)
    return Data.statsModel(days, NOW, goals or GOALS, counts or COUNTS)
end

local function history()
    local d = seq({}, "2026-07-01", "l h m x x m l  m h l m l m l  m l x m h m l  x x l m m h l  x m x")
    d = seq(d, "2026-08-01", "m m m m m m m m m m m m")
    return seq(d, "2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h l m")
end

local function run(days, from_key, n, seconds)
    local t = C.keyToTime(from_key)
    for _ = 1, n do
        days[C.key(t)] = seconds
        t = C.addDays(t, 1)
    end
    return days
end

-- A book model the way data.lua builds one, 6 h 40 into the book since 12 Sep.
local function book(o)
    local fractions = {}
    for _, p in ipairs(o.chapters or {}) do table.insert(fractions, p) end
    local b = Data.bookModel({
        title = o.title, author = o.author, pct = o.pct, page = o.page, total = o.total,
        ticks = C.thinTicks(fractions), step = o.step or {},
    }, o.finished or false, o.time == nil and { seconds = 24000, first = NOW - 13 * 86400 } or o.time or nil, NOW)
    b.cover = o.cover
    return b
end

local PARTS = { 0, 0.34, 0.69 }

local function kafka(cover, o)
    o = o or {}
    return book{
        title = "The Metamorphosis", author = "Franz Kafka", pct = o.pct or 0.58,
        page = o.page or 64, total = 110, chapters = PARTS, finished = o.finished, time = o.time,
        step = o.step or { has_chapters = true, chapter_title = "Part II", chapter_seconds = 660, book_seconds = 2280 },
        cover = cover("metamorphosis"),
    }
end

local function header(battery, now)
    return { date = F.headerDate(now or NOW), battery = battery }
end

-- The fixtures keep their own four quotes, so a new list in quotes.lua
-- doesn't move them. quotes(3, 1) starts the rotation at Descartes, then King.
local QUOTES = {
    { text = "Books are a uniquely portable magic.", author = "Stephen King", source = "On Writing" },
    { text = "A book must be the axe for the frozen sea inside us.", author = "Franz Kafka" },
    { text = "The reading of all good books is like conversation with the finest minds of past centuries.", author = "René Descartes" },
    { text = "Reading furnishes the mind only with materials of knowledge; it is thinking that makes what we read ours.", author = "John Locke" },
    -- Three lines at 7b's width: never fits, always skipped.
    { text = "What an astonishing thing a book is. It’s a flat object made from a tree with flexible parts on which are imprinted lots of funny dark squiggles.",
      author = "Carl Sagan", source = "Cosmos" },
}

local function quotes(...)
    local order, seen = {}, {}
    for _, i in ipairs({ ... }) do table.insert(order, i); seen[i] = true end
    for i = 1, #QUOTES do
        if not seen[i] then table.insert(order, i) end
    end
    local q = { list = QUOTES, state = { order = order, pos = 1 }, saves = 0 }
    q.save = function(state) q.saved = state; q.saves = q.saves + 1 end
    return q
end

-- 64 chapters of uneven length (a fixed sequence, so renders don't move).
local SIXTY_FOUR = (function()
    local lengths, seed, total = {}, 7, 0
    for i = 1, 64 do
        seed = (seed * 1103515245 + 12345) % 2147483648
        lengths[i] = 5 + seed % 8
        total = total + lengths[i]
    end
    local starts, at = {}, 0
    for i = 1, 64 do
        table.insert(starts, at / total)
        at = at + lengths[i]
    end
    return starts
end)()

local SHARP_STARTS = { 4, 7, 8, 9, 31, 53, 80, 108, 135, 156, 165, 189, 223, 257, 274, 305, 328, 356, 382, 389,
    396, 401, 403, 410, 438, 439 }

local function sharp(cover)
    local chapters = {}
    for _, p in ipairs(SHARP_STARTS) do table.insert(chapters, (p - 1) / 440) end
    return book{
        title = "Sharp Objects", author = "Gillian Flynn", pct = 305 / 440, page = 306, total = 440, chapters = chapters,
        step = { has_chapters = true, chapter_title = "Chapter Thirteen", chapter_seconds = 1320, book_seconds = 9600 },
        cover = cover("sharp"),
    }
end

return function(cover)
    cover = cover or function() return nil end
    local read_today = seq(history(), "2026-09-25", "1320")
    local broken = seq({}, "2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h")
    local first = seq({}, "2026-09-22", "l 1320 m")
    local long = run({}, "2026-08-26", 31, 2700)
    -- As drawn in 7b: 12 min so far today, the goal met the three days before.
    local as_drawn = seq(history(), "2026-09-22", "h h h 720")
    local goal_done = seq(history(), "2026-09-25", "3120")
    -- A quiet August between a busy July and a new run in September.
    local quiet = seq({}, "2026-07-01", "l h m x x m l  m h l m l m l  m l x m h m l  x x l m m h l  x m x")
    quiet = seq(quiet, "2026-09-21", "m l h m 900")

    local s_default, s_read, s_long = stats(history()), stats(read_today), stats(long)
    local s_broken, s_first = stats(broken), stats(first, { daily = 45 }, { pages_today = 0 })
    local s_drawn = stats(as_drawn)

    -- A June screen: every month in its calendar fits five rows.
    local JUNE = os.time{ year = 2026, month = 6, day = 26, hour = 21 }
    local june = seq({}, "2026-06-15", "m h l m m h m m h l 900")

    local list = {
        { "01-default", { header = header(), book = kafka(cover), stats = s_default } },
        { "02-read-today", { header = header(), book = kafka(cover), stats = s_read } },
        { "03-longest-run", { header = header(), book = kafka(cover), stats = s_long } },
        { "04-run-broken", { header = header(), book = kafka(cover), stats = s_broken } },
        { "05-first-days", { header = header(), book = kafka(cover, { pct = 0.12, page = 13,
            time = { seconds = 2400, first = NOW - 3 * 86400 },
            step = { has_chapters = true, chapter_title = "Part I", chapter_seconds = 1200, book_seconds = 5820 } }),
            stats = s_first } },
        { "06-last-chapter", { header = header(), book = kafka(cover, { pct = 0.94, page = 104,
            step = { has_chapters = true, in_last_chapter = true, book_seconds = 360 } }), stats = s_default } },
        { "07-finished", { header = header(), book = kafka(cover, { pct = 1, page = 110, finished = true }),
            stats = stats(read_today, GOALS, { pages_today = 22, books_month = 2, books_year = 5 }) } },
        { "08-no-chapters-far-date", { header = header(), book = book{
            title = "The Simplicity Shift", author = "Scott Jenson", pct = 0.2, page = 38, total = 188,
            step = { has_chapters = false, book_seconds = 40000 }, cover = cover("simplicity") },
            stats = s_default } },
        { "09-no-cover", { header = header(), book = book{
            title = "The Machine Stops", author = F.authorLine("Forster, E. M."), pct = 0.23, page = 12, total = 52,
            chapters = { 0, 0.33, 0.66 }, time = { seconds = 50, first = NOW - 600 },
            step = { has_chapters = true, chapter_title = "The Air-Ship", chapter_seconds = 840, book_seconds = 2400 } },
            stats = s_default } },
        { "10-no-book", { header = header(), stats = s_default } },
        { "11-stats-off", { header = header(), book = kafka(cover, { time = false,
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12, book_pages = 47 } }) } },
        { "12-low-battery", { header = header("Battery 8%"), book = kafka(cover), stats = s_default } },
        { "13-landscape", { header = header(), book = sharp(cover), stats = s_drawn }, 1680, 1264 },
        { "14-long-title", { header = header(), book = book{
            title = F.cleanTitle("Alice’s Adventures in Wonderland and Through the Looking-Glass and What Alice Found There"),
            author = F.authorLine("Carroll, Lewis"), pct = 0.58, page = 150, total = 260,
            time = { seconds = 90000, first = os.time{ year = 2025, month = 12, day = 30, hour = 20 } },
            step = { has_chapters = true, chapter_title = "Down the Rabbit-Hole and Beyond", chapter_seconds = 660, book_seconds = 7800 },
            cover = cover("metamorphosis") }, stats = s_default } },
        { "15-low-res-cover", { header = header(), book = book{
            title = "Jurassic Park", author = F.authorLine("Crichton, Michael"), pct = 0.31, page = 190, total = 612,
            step = { has_chapters = true, chapter_title = "Chapter 12: A Very Long Title Indeed", chapter_seconds = 3900, book_seconds = 25320 },
            cover = cover("jurassic") }, stats = s_default } },
        { "16-landscape-no-book", { header = header(), stats = s_default }, 1680, 1264 },
        { "17-landscape-stats-off", { header = header(), book = kafka(cover, { time = false,
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12 } }) }, 1680, 1264 },
        { "18-many-chapters", { header = header(), book = sharp(cover), stats = s_drawn } },
        { "19-daily-goal-done", { header = header(), book = kafka(cover), stats = stats(goal_done) } },
        { "20-no-goals-set", { header = header(), book = kafka(cover), stats = stats(history(), {}, { pages_today = 0 }) } },
        { "21-weekly-goal-met", { header = header(), book = sharp(cover), stats = stats(goal_done,
            { daily = 45, weekly = 150, monthly = 2, yearly = 30 }, { pages_today = 31, books_month = 2, books_year = 31 }) } },
        { "22-quiet-month", { header = header(), book = kafka(cover), stats = stats(quiet) } },
        { "23-streak-two", { header = header(), book = kafka(cover), stats = stats(seq({}, "2026-09-24", "m 600")) } },
        { "24-streak-twelve", { header = header(), book = kafka(cover), stats = stats(run({}, "2026-09-14", 12, 1500)) } },
        { "25-landscape-goal-done", { header = header(), book = kafka(cover), stats = stats(goal_done) }, 1680, 1264 },
        { "26-quote-short", { header = header(), book = sharp(cover), stats = s_drawn, quotes = quotes(1) } },
        -- Two full lines need the room a five-row calendar leaves.
        { "27-quote-long", { header = header(nil, JUNE), book = sharp(cover), stats = Data.statsModel(june, JUNE, GOALS, COUNTS),
            quotes = quotes(4) } },
        -- A title on two lines leaves too little room for any quote.
        { "28-quote-none-fits", { header = header(), book = book{
            title = "The Strange Case of Dr Jekyll and Mr Hyde", author = "Robert Louis Stevenson", pct = 0.4, page = 40, total = 100,
            chapters = { 0, 0.2, 0.45, 0.7 },
            step = { has_chapters = true, chapter_title = "Search for Mr Hyde", chapter_seconds = 900, book_seconds = 4200 },
            cover = cover("jurassic") }, stats = s_drawn, quotes = quotes(1) } },
        -- Sagan is next but too long, so Kafka shows and Sagan waits.
        { "29-quote-skips-long", { header = header(), book = sharp(cover), stats = s_drawn, quotes = quotes(5, 2) } },
        { "31-sixty-four-chapters", { header = header(), book = book{
            title = "Middlemarch", author = "George Eliot", pct = 0.41, page = 369, total = 900, chapters = SIXTY_FOUR,
            step = { has_chapters = true, chapter_title = "Chapter 28", chapter_seconds = 840, book_seconds = 64000 },
            cover = cover("simplicity") }, stats = s_drawn } },
        { "32-pdf-no-chapters", { header = header(), book = book{
            title = "Designing Data-Intensive Applications", author = "Martin Kleppmann", pct = 87 / 230, page = 87, total = 230,
            step = { has_chapters = false, book_seconds = 51480 } }, stats = s_drawn } },
        { "33-landscape-sixty-four", { header = header(), book = book{
            title = "Middlemarch", author = "George Eliot", pct = 0.41, page = 369, total = 900, chapters = SIXTY_FOUR,
            step = { has_chapters = true, chapter_title = "Chapter 28", chapter_seconds = 840, book_seconds = 64000 },
            cover = cover("simplicity") }, stats = s_drawn }, 1680, 1264 },
        { "30-landscape-quote", { header = header(), book = sharp(cover), stats = s_drawn, quotes = quotes(2) }, 1680, 1264 },
    }
    -- Every other state starts the rotation at Descartes, as drawn in 7b; where
    -- two lines don't fit, King's one line shows instead.
    for _, s in ipairs(list) do
        if not s[2].quotes then s[2].quotes = quotes(3) end
    end
    return list, NOW
end
