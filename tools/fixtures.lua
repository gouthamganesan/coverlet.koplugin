--[[
One model per state on the design canvas, built with the plugin's own text
and chain rules so the renders exercise the real wording.

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

local function stats(days, books, goal)
    local c = C.compute(days, NOW)
    return {
        cells = c.cells,
        streak = c.streak,
        note = F.streakNote(c.streak, c.read_today, c.best),
        line = F.statsLine(c.best, c.streak, c.week_seconds, books or 14, goal == nil and 24 or goal),
    }
end

local function history()
    local d = seq({}, "2026-08-01", "m m m m m m m m m m m m")
    return seq(d, "2026-08-31", "m m x l h h m  x x m l h h x  l m x m m m x  m h l m")
end

local function kafka(cover, o)
    o = o or {}
    local step = o.step or { has_chapters = true, chapter_title = "Part II", chapter_seconds = 660, book_seconds = 2280 }
    local pct = o.pct or 0.58
    return {
        title = "The Metamorphosis",
        author = "Franz Kafka",
        pct = pct,
        finished = o.finished or false,
        ticks = { 0.34, 0.69 },
        meta = F.metaVariants("Franz Kafka", pct, step, o.finished or false),
        cover = cover("metamorphosis"),
    }
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

    local list = {
        { "01-default", { header = header(), book = kafka(cover), stats = stats(history()) } },
        { "02-read-today", { header = header(), book = kafka(cover), stats = stats(read_today) } },
        { "03-longest-run", { header = header(), book = kafka(cover), stats = stats(long) } },
        { "04-run-broken", { header = header(), book = kafka(cover), stats = stats(broken) } },
        { "05-first-days", { header = header(), book = kafka(cover, {
            pct = 0.12, step = { has_chapters = true, chapter_title = "Part I", chapter_seconds = 1200 } }),
            stats = stats(first, 0, 0) } },
        { "06-last-chapter", { header = header(), book = kafka(cover, {
            pct = 0.94, step = { has_chapters = true, in_last_chapter = true, book_seconds = 360 } }),
            stats = stats(history()) } },
        { "07-finished", { header = header(), book = kafka(cover, { pct = 1, finished = true }),
            stats = stats(read_today, 15) } },
        { "08-no-chapters", { header = header(), book = {
            title = "The Simplicity Shift", author = "Scott Jenson", pct = 0.58, ticks = {},
            meta = F.metaVariants("Scott Jenson", 0.58, { has_chapters = false, book_seconds = 4320 }, false),
            cover = cover("simplicity") }, stats = stats(history()) } },
        { "09-no-cover", { header = header(), book = {
            title = "The Machine Stops", author = F.authorLine("Forster, E. M."), pct = 0.23, ticks = { 0.33, 0.66 },
            meta = F.metaVariants(F.authorLine("Forster, E. M."), 0.23,
                { has_chapters = true, chapter_title = "The Air-Ship", chapter_seconds = 840 }, false) },
            stats = stats(history()) } },
        { "10-no-book", { header = header(), stats = stats(history()) } },
        { "11-stats-off", { header = header(), book = kafka(cover, {
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12, book_pages = 40 } }) } },
        { "12-low-battery", { header = header("Battery 8%"), book = kafka(cover), stats = stats(history()) } },
        { "13-landscape", { header = header(), book = kafka(cover), stats = stats(history()) }, 1680, 1264 },
        -- extra edge cases beyond the canvas
        { "14-long-title", { header = header(), book = {
            title = F.cleanTitle("Alice’s Adventures in Wonderland and Through the Looking-Glass and What Alice Found There"),
            author = F.authorLine("Carroll, Lewis"), pct = 0.58, ticks = {},
            meta = F.metaVariants(F.authorLine("Carroll, Lewis"), 0.58,
                { has_chapters = true, chapter_title = "Down the Rabbit-Hole and Beyond", chapter_seconds = 660 }, false),
            cover = cover("metamorphosis") }, stats = stats(history()) } },
        { "15-low-res-cover", { header = header(), book = {
            title = "Jurassic Park", author = F.authorLine("Crichton, Michael"), pct = 0.31, ticks = {},
            meta = F.metaVariants(F.authorLine("Crichton, Michael"), 0.31,
                { has_chapters = true, chapter_title = "Chapter 12: A Very Long Title Indeed", chapter_seconds = 3900 }, false),
            cover = cover("jurassic") }, stats = stats(history()) } },
        { "16-landscape-no-book", { header = header(), stats = stats(history()) }, 1680, 1264 },
        { "17-landscape-stats-off", { header = header(), book = kafka(cover, {
            step = { has_chapters = true, chapter_title = "Part II", chapter_pages = 12 } }) }, 1680, 1264 },
    }
    return list, NOW
end
