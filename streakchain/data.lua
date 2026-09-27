--[[
Gathers everything the sleep screen shows into one plain table (the model),
so streakchain/screen.lua only ever draws and never asks KOReader anything.

  model.header = { date, battery = "Battery 8%" | nil }
  model.book   = nil (no book) | {
      title, author, pct (0..1), finished, page, total,
      ticks = { 0..1, ... },                   -- where each chapter starts, front matter folded in
      bar = { chapter = { left, fallback, right }, pages = { left, right } },
      step = "22 min left in Chapter Thirteen" | "Finished" | nil,
      hero = { num, unit } | nil,              -- nil when finished
      so_far = "6 h 40 in, since 12 Sep" | nil,
      cover = BlitBuffer | nil,                -- freed by the screen
  }
  model.stats  = nil (Reading statistics off) | {
      today = { num, unit, fraction | nil, done, rows = { { label, value } } },
      goals = { { label, value, fraction, segments | nil, filled }, ... },
      year = { label, value },                 -- "Read in 2026" / "86 h"
      streak, best, read_today, best_line,
      flame = { variant, w, h, drop, muted },
      calendar = { { name, offset, days = { { day, level, today, run, joins_prev, joins_next } } } },
  }
  model.quotes = { list, state, save, random }   -- the screen picks one that fits
]]

local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Chain = require("streakchain/chain")
local Format = require("streakchain/format")
local QUOTES = require("streakchain/quotes")

local Data = {}

local DEFAULT_MAX_SEC = 120 -- KOReader's statistics default

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function statsSettings()
    return G_reader_settings:readSetting("statistics") or {}
end

-- KOReader's own fallback pace for a book with no history: half the per-page
-- cap, 60 s with default settings.
local function defaultPace()
    return 0.5 * (statsSettings().max_sec or DEFAULT_MAX_SEC)
end

function Data.statsEnabled(ui)
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if disabled and disabled.statistics then return false end
    local settings = (ui and ui.statistics and ui.statistics.settings) or statsSettings()
    if settings.is_enabled == false then return false end
    return lfs.attributes(dbPath(), "mode") == "file"
end

local function withDB(path, fn)
    local ok_req, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_req then return nil end
    local ok_open, conn = pcall(SQ3.open, path or dbPath())
    if not ok_open or not conn then return nil end
    local ok, res = pcall(fn, conn)
    pcall(conn.close, conn)
    if not ok then
        logger.warn("streakchain: statistics query failed:", res)
        return nil
    end
    return res
end

-- "YYYY-MM-DD" (local time) -> seconds read that day.
function Data.readDays(path)
    return withDB(path, function(conn)
        local days = {}
        local res = conn:exec([[
            SELECT date(start_time, 'unixepoch', 'localtime'), sum(duration)
            FROM page_stat_data GROUP BY 1;]])
        if res and res[1] then
            for i = 1, #res[1] do
                days[tostring(res[1][i])] = tonumber(res[2][i]) or 0
            end
        end
        return days
    end)
end

-- A book counts as finished the first time a page at 99% or later was read.
function Data.booksFinishedSince(path, since)
    return withDB(path, function(conn)
        local n = conn:rowexec(string.format([[
            SELECT count(*) FROM (
                SELECT id_book, min(start_time) AS t FROM page_stat_data
                WHERE total_pages > 0 AND page * 100 >= total_pages * 99
                GROUP BY id_book
            ) WHERE t >= %d;]], since))
        return tonumber(n) or 0
    end) or 0
end

-- Pages read since a time, counted the way KOReader's own "Today" statistics
-- count them: each page of each book once, in the book's current layout.
function Data.pagesSince(path, since)
    return withDB(path, function(conn)
        local n = conn:rowexec(string.format([[
            SELECT count(*) FROM (
                SELECT 1 FROM page_stat WHERE start_time >= %d GROUP BY id_book, page
            );]], since))
        return tonumber(n) or 0
    end)
end

local function bookId(conn, md5)
    local stmt = conn:prepare("SELECT id, pages FROM book WHERE md5 = ?;")
    local row = stmt:reset():bind(md5):step()
    stmt:close()
    if not row then return nil end
    return tonumber(row[1]), tonumber(row[2])
end

-- Pages and average seconds per page for one book, by its partial md5.
function Data.bookPace(path, md5)
    return withDB(path, function(conn)
        local id, pages = bookId(conn, md5)
        if not id then return nil end
        local n, t = conn:rowexec(string.format(
            "SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", id))
        n, t = tonumber(n) or 0, tonumber(t) or 0
        return { pages = pages, avg = n > 0 and t / n or nil }
    end)
end

-- Time spent in one book and when its first page was read: { seconds, first }.
function Data.bookTime(path, md5)
    return withDB(path, function(conn)
        local id = bookId(conn, md5)
        if not id then return nil end
        local t, first = conn:rowexec(string.format(
            "SELECT sum(duration), min(start_time) FROM page_stat_data WHERE id_book = %d;", id))
        first = tonumber(first)
        if not first then return nil end
        return { seconds = tonumber(t) or 0, first = first }
    end)
end

--[[
Reading goals are set in Bookshelf's Reading goal module, not here, each with
its own on/off switch: daily in minutes, weekly in minutes, monthly and yearly
in books. Read them live from Bookshelf's settings store when Bookshelf is
loaded, else from its file. Daily and yearly fall back to Bookshelf's defaults;
weekly and monthly only count once a value is set.
Returns { daily, weekly, monthly, yearly }, each nil when off.
]]
local BOOKSHELF_DEFAULTS = { daily = 30, yearly = 24 }

function Data.goals()
    local read
    local store = package.loaded["lib/bookshelf_settings_store"]
    if type(store) == "table" and type(store.read) == "function" then
        read = function(key, default) return store.read(key, default) end
    else
        local path = DataStorage:getSettingsDir() .. "/bookshelf_micromodules.lua"
        if lfs.attributes(path, "mode") ~= "file" then return {} end
        local ok, settings = pcall(function() return require("luasettings"):open(path) end)
        if not ok or not settings then return {} end
        read = function(key, default) return settings:readSetting(key, default) end
    end
    local active = read("micromodule_reading_goal_active", nil)
    if type(active) ~= "table" then active = { daily = true, yearly = true } end
    local goals = {}
    for _, kind in ipairs({ "daily", "weekly", "monthly", "yearly" }) do
        if active[kind] then
            local default = BOOKSHELF_DEFAULTS[kind]
            local value = tonumber(read("micromodule_reading_goal_" .. kind, default)) or default
            if value and value > 0 then goals[kind] = math.max(1, math.floor(value)) end
        end
    end
    return goals
end

--[[
The stats half of the model, from the day map and the counts only the
database has. Pure: tools/fixtures.lua builds its states through it too.
  counts = { pages_today, books_month, books_year }
]]
function Data.statsModel(days, now, goals, counts)
    goals, counts = goals or {}, counts or {}
    local c = Chain.compute(days, now)
    local goal_streak = goals.daily and Chain.goalStreak(days, now, goals.daily * 60) or nil
    local calendar = Chain.calendar(days, now, c.streak, c.read_today)
    for _, month in ipairs(calendar) do month.name = Format.monthName(month.time) end
    return {
        today = Format.today(c.today_seconds, goals.daily, counts.pages_today, goal_streak),
        goals = Format.goalRows{
            now = now,
            weekly = goals.weekly, week_seconds = c.week_seconds,
            monthly = goals.monthly, books_month = counts.books_month,
            yearly = goals.yearly, books_year = counts.books_year,
        },
        year = Format.yearLine(c.year_seconds, now),
        streak = c.streak,
        best = c.best,
        read_today = c.read_today,
        best_line = Format.bestLine(c.best, c.streak),
        flame = Chain.flame(c.streak, c.read_today),
        calendar = calendar,
    }
end

--[[
The daily quote: the list and where the rotation stands. The screen picks
the next one that fits the gap beside the cover (the gap is only known once
it's laid out) and saves the rotation through save().
]]
local QUOTE_KEY = "streakchain_quote"

function Data.quotes()
    math.randomseed(os.time())
    return {
        list = QUOTES,
        state = G_reader_settings:readSetting(QUOTE_KEY),
        save = function(state) G_reader_settings:saveSetting(QUOTE_KEY, state) end,
        random = function(k) return math.random(k) end,
    }
end

local function fileTitle(file)
    return file and (file:match("([^/]+)%.[^./]+$") or file:match("([^/]+)$")) or nil
end

local function coverFor(ui, document, file)
    if not (ui and ui.bookinfo) then return nil end
    local ok, bb = pcall(ui.bookinfo.getCoverImage, ui.bookinfo, document, file)
    if ok and bb then return bb end
    return nil
end

-- What the open book's reader knows: title, position, chapters, pace. Plain
-- values only, so it can also be saved for the file browser.
local function readerState(ui, stats_on)
    local doc = ui.document
    local props = ui.doc_props or {}
    local page = ui:getCurrentPage() or 1
    local total = doc:getPageCount() or 1
    if total < 1 then total = 1 end

    local state = {
        file = doc.file,
        title = Format.cleanTitle(props.display_title or props.title) or fileTitle(doc.file) or "",
        author = Format.authorLine(props.authors),
        page = page,
        total = total,
        pct = page / total,
        ticks = {},
        step = { book_pages = total - page + 1 },
    }
    local step = state.step

    local toc = ui.toc
    if toc then
        pcall(toc.fillToc, toc)
        local has = toc.toc and #toc.toc > 0 or false
        step.has_chapters = has
        if has then
            local next_ch = toc:getNextChapter(page)
            step.in_last_chapter = next_ch == nil
            step.chapter_title = toc:getTocTitleByPage(page)
            if next_ch then step.chapter_pages = next_ch - page end
            local fractions = {}
            for _, entry in ipairs(toc.toc) do
                if (entry.depth or 1) == 1 and type(entry.page) == "number" and entry.page <= total then
                    table.insert(fractions, (entry.page - 1) / total)
                end
            end
            state.ticks = Chain.thinTicks(fractions)
        end
    end

    local st = ui.statistics
    if stats_on and st then
        local avg = st.avg_time
        if not (avg and avg == avg and avg > 0) then avg = defaultPace() end
        step.book_seconds = step.book_pages * avg
        if step.chapter_pages then step.chapter_seconds = step.chapter_pages * avg end
    end
    return state
end

-- Saved whenever the reader closes or sleeps, so the sleep screen shown from
-- the file browser (or Bookshelf) still knows the chapter and time left.
function Data.saveSnapshot(ui, state)
    state = state or readerState(ui, Data.statsEnabled(ui))
    G_reader_settings:saveSetting("streakchain_snapshot", state)
    return state
end

--[[
The book half of the model, shared by both paths and by the fixtures.
  time = { seconds, first } | nil   time in this book so far, from the database
]]
function Data.bookModel(state, finished, time, now)
    local step = state.step or {}
    local book = {
        title = state.title,
        author = state.author,
        pct = finished and 1 or (state.pct or 0),
        finished = finished,
        page = state.page,
        total = state.total,
        ticks = state.ticks or {},
        step = Format.stepLine(step, finished),
        bar = Format.barLabels(step, state.page, state.total, finished),
        so_far = time and Format.bookSoFar(time.seconds, time.first, now) or nil,
    }
    if finished then return book end
    if step.book_seconds then
        book.hero = { Format.heroTime(step.book_seconds) }
    elseif state.page and state.total then
        book.hero = { Format.heroPages(state.page, state.total) }
    end
    return book
end

local function readerBook(ui, stats_on, now)
    local state = readerState(ui, stats_on)
    pcall(Data.saveSnapshot, ui, state)
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    local finished = (summary and summary.status == "complete") or false
    local md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    local time = stats_on and md5 and Data.bookTime(nil, md5) or nil
    local book = Data.bookModel(state, finished, time, now)
    book.cover = coverFor(ui, ui.document, ui.document.file)
    return book
end

-- The last book, from its sidecar and the snapshot the reader saved when it
-- closed (sleeping from the file browser or Bookshelf).
local function lastBook(ui, stats_on, now)
    local file = G_reader_settings:readSetting("lastfile")
    if not file or lfs.attributes(file, "mode") ~= "file" then return nil end
    local ok, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok or not ds then return nil end
    local props = ds:readSetting("doc_props") or {}
    local summary = ds:readSetting("summary")
    local md5 = ds:readSetting("partial_md5_checksum")

    local snap = G_reader_settings:readSetting("streakchain_snapshot")
    if type(snap) ~= "table" or snap.file ~= file then snap = nil end
    local pct = ds:readSetting("percent_finished") or (snap and snap.pct) or 0
    local finished = (summary and summary.status == "complete") or pct >= 1

    local state = snap or {
        title = Format.cleanTitle(props.display_title or props.title) or fileTitle(file) or "",
        author = Format.authorLine(props.authors),
        step = { has_chapters = false },
    }
    state.pct = pct
    if not snap and stats_on then
        local pace = md5 and Data.bookPace(nil, md5)
        if pace and pace.pages and pace.pages > 0 then
            local pages_left = math.max(1, math.ceil((1 - pct) * pace.pages))
            state.page = pace.pages - pages_left + 1
            state.total = pace.pages
            state.step.book_pages = pages_left
            state.step.book_seconds = pages_left * (pace.avg or defaultPace())
        end
    end
    local time = stats_on and md5 and Data.bookTime(nil, md5) or nil
    local book = Data.bookModel(state, finished, time, now)
    book.cover = coverFor(ui, nil, file)
    return book
end

local function batteryWarning()
    if not Device:hasBattery() then return nil end
    local ok, power = pcall(Device.getPowerDevice, Device)
    if not ok or not power then return nil end
    local ok_cap, capacity = pcall(power.getCapacity, power)
    local ok_chg, charging = pcall(power.isCharging, power)
    return Format.batteryWarning(ok_cap and capacity or nil, ok_chg and charging or false)
end

local function readerStats(now)
    local days = Data.readDays()
    if not days then return nil end
    local goals = Data.goals()
    return Data.statsModel(days, now, goals, {
        pages_today = Data.pagesSince(nil, Chain.startOfDay(now)),
        books_month = goals.monthly and Data.booksFinishedSince(nil, Chain.startOfMonth(now)) or nil,
        books_year = goals.yearly and Data.booksFinishedSince(nil, Chain.startOfYear(now)) or nil,
    })
end

function Data.build(ui, now)
    now = now or os.time()
    local model = { header = { date = Format.headerDate(now), battery = batteryWarning() }, quotes = Data.quotes() }
    local stats_on = Data.statsEnabled(ui)

    -- The statistics plugin buffers the current session in memory and only
    -- writes it on suspend, which comes after the sleep screen is drawn.
    -- Flush it now so today's pages are counted.
    if stats_on and ui.document and ui.statistics and ui.statistics.insertDB then
        pcall(ui.statistics.insertDB, ui.statistics)
    end

    if stats_on then
        local ok, stats = pcall(readerStats, now)
        if ok then
            model.stats = stats
        else
            logger.warn("streakchain: could not read the statistics:", stats)
        end
    end

    local ok, book
    if ui.document then
        ok, book = pcall(readerBook, ui, stats_on, now)
    else
        ok, book = pcall(lastBook, ui, stats_on, now)
    end
    if ok then
        model.book = book
    else
        logger.warn("streakchain: could not read the book:", book)
    end
    logger.info("streakchain: sleep screen from", ui.document and "the reader" or "the file browser",
        "| book:", model.book and model.book.title or "none",
        "| next:", model.book and model.book.step or "-",
        "| so far:", model.book and model.book.so_far or "-")
    return model
end

return Data
