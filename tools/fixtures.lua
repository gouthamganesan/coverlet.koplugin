--[[
One model per state, built with the plugin's own text and chain rules so the
renders exercise the real wording.

cover(name): returns a fresh cover BlitBuffer (or nil) on every call, because
the screen owns and frees the cover it is given.
]]

local C = require("streakchain/chain")
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

-- Goals as set in Bookshelf's Reading goal module: 45 min a day, 6 books a year.
local DAILY, YEARLY = 45, 6

local function stats(days, books, yearly, daily)
    local c = C.compute(days, NOW)
    if daily == nil then daily = DAILY elseif daily == 0 then daily = nil end
    if yearly == nil then yearly = YEARLY elseif yearly == 0 then yearly = nil end
    local wv, ws = F.weekTile(c.week_seconds, c.last_week_seconds)
    local bv, bs = F.booksTile(books or 4, yearly, NOW)
    return {
        goal_minutes = daily,
        daily = daily and F.dailyGoal(c.today_seconds, daily) or nil,
        streak = c.streak, best = c.best, read_today = c.read_today,
        today_seconds = c.today_seconds, avg_day_seconds = c.avg_day_seconds,
        note = F.streakNote(c.streak, c.read_today, c.best),
        best_line = F.bestLine(c.best, c.streak),
        strip = C.strip(c.streak, c.best, c.read_today),
        week = { value = wv, sub = ws },
        books = { value = bv, sub = bs },
    }
end

local function history()
    local d = seq({}, "2026-08-01", "m m m m m m m m m m m m")
    return seq(d, "2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h l m")
end

-- A book model the way data.lua's finishBook builds it.
local function book(o, st)
    local step = o.step or {}
    local finished = o.finished or false
    local b = {
        title = o.title, author = o.author, pct = finished and 1 or o.pct, finished = finished,
        page = o.page, total = o.total, chapters = o.chapters or {},
        ticks = C.thinTicks((function()
            local f = {}
            for _, c in ipairs(o.chapters or {}) do table.insert(f, c.pos) end
            return f
        end)()),
        meta = F.metaVariants(o.author, o.pct, step, finished),
        progress = F.progressLine(o.pct, step, finished),
        cover = o.cover,
    }
    if not finished then
        if step.book_seconds then
            b.hero = { F.heroTime(step.book_seconds) }
            local daily = st and (st.goal_minutes and st.goal_minutes * 60 or st.avg_day_seconds)
            if (o.timed or 40) >= 10 and daily then
                b.forecast = F.forecast(step.book_seconds, st.today_seconds, daily, NOW, st.goal_minutes)
            end
        elseif o.page then
            b.hero = { F.heroPages(o.page, o.total) }
        end
    end
    return b
end

local PARTS = { { pos = 0, title = "Part I" }, { pos = 0.34, title = "Part II" }, { pos = 0.69, title = "Part III" } }

local function kafka(cover, st, o)
    o = o or {}
    return book({
        title = "The Metamorphosis", author = "Franz Kafka", pct = o.pct or 0.58,
        page = o.page or 64, total = 110, chapters = PARTS, finished = o.finished, timed = o.timed,
        step = o.step or { has_chapters = true, chapter_title = "Part II", chapter_seconds = 660, book_seconds = 2280 },
        cover = cover("metamorphosis"),
    }, st)
end

local function header(battery)
    return { date = F.headerDate(NOW), battery = battery }
end

return function(cover)
    cover = cover or function() return nil end
    local read_today = seq(history(), "2026-09-25", "1320")
    local broken = seq({}, "2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h")
    local first = seq({}, "2026-09-22", "l 1320 m")
    local long = {}
    local t = C.keyToTime("2026-08-26")
    for _ = 1, 31 do long[C.key(t)] = 2700; t = C.addDays(t, 1) end

    local s_default, s_read, s_long = stats(history()), stats(read_today), stats(long)
    local s_broken, s_first = stats(broken), stats(first, 0, 0)

    local sharp_chapters = {}
    local starts = { 4, 7, 8, 9, 31, 53, 80, 108, 135, 156, 165, 189, 223, 257, 274, 305, 328, 356, 382, 389, 396, 401, 403, 410, 438, 439 }
    local names = { "Praise", "Title Page", "Dedication", "Chapter One", "Chapter Two", "Chapter Three", "Chapter Four",
        "Chapter Five", "Chapter Six", "Chapter Seven", "Chapter Eight", "Chapter Nine", "Chapter Ten", "Chapter Eleven",
        "Chapter Twelve", "Chapter Thirteen", "Chapter Fourteen", "Chapter Fifteen", "Chapter Sixteen",
        "Chapter Seventeen", "Epilogue", "Acknowledgements", "Reading Notes", "Dark Places Sample Chapter",
        "More from W&N Fiction", "Copyright Page" }
    for i, p in ipairs(starts) do table.insert(sharp_chapters, { pos = (p - 1) / 440, title = names[i] }) end

    local goal_done = seq(history(), "2026-09-25", "3120")
    local s_done = stats(goal_done)
    local s_nogoal = stats(history(), 14, 0, 0)

    local list = {
        { "01-default", { header = header(), book = kafka(cover, s_default), stats = s_default } },
        { "02-read-today", { header = header(), book = kafka(cover, s_read), stats = s_read } },
        { "03-longest-run", { header = header(), book = kafka(cover, s_long), stats = s_long } },
        { "04-run-broken", { header = header(), book = kafka(cover, s_broken), stats = s_broken } },
        { "05-first-days", { header = header(), book = kafka(cover, s_first, { pct = 0.12, page = 13, timed = 4,
            step = { has_chapters = true, chapter_title = "Part I", chapter_seconds = 1200, book_seconds = 5820 } }),
            stats = s_first } },
        { "06-last-chapter", { header = header(), book = kafka(cover, s_default, { pct = 0.94, page = 104,
            step = { has_chapters = true, in_last_chapter = true, book_seconds = 360 } }), stats = s_default } },
        { "07-finished", { header = header(), book = kafka(cover, s_read, { pct = 1, page = 110, finished = true }),
            stats = stats(read_today, 5) } },
        { "08-no-chapters-far-date", { header = header(), book = book({
            title = "The Simplicity Shift", author = "Scott Jenson", pct = 0.2, page = 38, total = 188,
            step = { has_chapters = false, book_seconds = 40000 }, cover = cover("simplicity") }, s_default),
            stats = s_default } },
        { "09-no-cover", { header = header(), book = book({
            title = "The Machine Stops", author = F.authorLine("Forster, E. M."), pct = 0.23, page = 12, total = 52,
            chapters = { { pos = 0, title = "The Air-Ship" }, { pos = 0.33, title = "The Mending Apparatus" }, { pos = 0.66, title = "The Homeless" } },
            step = { has_chapters = true, chapter_title = "The Air-Ship", chapter_seconds = 840, book_seconds = 2400 } }, s_default),
            stats = s_default } },
        { "10-no-book", { header = header(), stats = s_default } },
        { "11-stats-off", { header = header(), book = kafka(cover, nil, {
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12, book_pages = 47 } }) } },
        { "12-low-battery", { header = header("Battery 8%"), book = kafka(cover, s_default), stats = s_default } },
        { "13-landscape", { header = header(), book = kafka(cover, s_default), stats = s_default }, 1680, 1264 },
        { "14-long-title", { header = header(), book = book({
            title = F.cleanTitle("Alice’s Adventures in Wonderland and Through the Looking-Glass and What Alice Found There"),
            author = F.authorLine("Carroll, Lewis"), pct = 0.58, page = 150, total = 260,
            step = { has_chapters = true, chapter_title = "Down the Rabbit-Hole and Beyond", chapter_seconds = 660, book_seconds = 7800 },
            cover = cover("metamorphosis") }, s_default), stats = s_default } },
        { "15-low-res-cover", { header = header(), book = book({
            title = "Jurassic Park", author = F.authorLine("Crichton, Michael"), pct = 0.31, page = 190, total = 612,
            step = { has_chapters = true, chapter_title = "Chapter 12: A Very Long Title Indeed", chapter_seconds = 3900, book_seconds = 25320 },
            cover = cover("jurassic") }, s_default), stats = s_default } },
        { "16-landscape-no-book", { header = header(), stats = s_default }, 1680, 1264 },
        { "17-landscape-stats-off", { header = header(), book = kafka(cover, nil, {
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12 } }) }, 1680, 1264 },
        { "19-daily-goal-done", { header = header(), book = kafka(cover, s_done), stats = s_done } },
        { "20-no-goals-set", { header = header(), book = kafka(cover, s_nogoal), stats = s_nogoal } },
        { "18-many-chapters", { header = header(), book = book({
            title = "Sharp Objects", author = "Gillian Flynn", pct = 305 / 440, page = 306, total = 440, chapters = sharp_chapters,
            step = { has_chapters = true, chapter_title = "Chapter Thirteen", chapter_seconds = 1320, book_seconds = 8040 },
            cover = cover("sharp") }, s_default), stats = s_default } },
    }
    return list, NOW
end
