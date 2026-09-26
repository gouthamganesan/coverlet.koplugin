--[[
Gathers everything the sleep screen shows into one plain table (the model),
so streakchain/screen.lua only ever draws and never asks KOReader anything.

  model.header = { date, battery = "Battery 8%" | nil }
  model.book   = nil (no book) | {
      title, author, meta = { line variants, most detailed first },
      progress = "58% · 11 min left in Part II" (the meta line without the author),
      pct (0..1), finished, page, total,
      chapters = { { pos = 0..1, title }, ... },  -- for timeline names
      ticks = { 0..1, ... },                       -- thinned chapter marks
      hero = { num, unit } | nil,                  -- nil when finished
      forecast = { line, today_share, label } | nil,
      cover = BlitBuffer | nil,                    -- freed by the screen
  }
  model.stats  = nil (Reading statistics off) | {
      streak, best, read_today, note, best_line, strip = { n, filled, pending, best, bar },
      week = { value, sub }, books = { value, sub },
  }
]]

local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Chain = require("streakchain/chain")
local Format = require("streakchain/format")

local Data = {}

local DEFAULT_MAX_SEC = 120 -- KOReader's statistics default
local MIN_TIMED_PAGES = 10  -- below this the book has no pace of its own yet

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

-- Pages, average seconds per page and timed pages for one book, by its partial md5.
function Data.bookPace(path, md5)
    return withDB(path, function(conn)
        local stmt = conn:prepare("SELECT id, pages FROM book WHERE md5 = ?;")
        local row = stmt:reset():bind(md5):step()
        stmt:close()
        if not row then return nil end
        local id, pages = tonumber(row[1]), tonumber(row[2])
        local n, t = conn:rowexec(string.format(
            "SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", id))
        n, t = tonumber(n) or 0, tonumber(t) or 0
        return { pages = pages, avg = n > 0 and t / n or nil, timed = n }
    end)
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
        chapters = {},
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
                    local pos = (entry.page - 1) / total
                    table.insert(state.chapters, { pos = pos, title = toc:cleanUpTocTitle(entry.title or "") })
                    table.insert(fractions, pos)
                end
            end
            state.ticks = Chain.thinTicks(fractions)
        end
    end

    local st = ui.statistics
    if stats_on and st then
        local avg = st.avg_time
        state.timed = st.book_read_pages or 0
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

-- Book fields shared by both paths: meta line, hero and forecast.
local function finishBook(state, finished, stats, now)
    local step = state.step or {}
    local book = {
        title = state.title,
        author = state.author,
        pct = finished and 1 or (state.pct or 0),
        finished = finished,
        page = state.page,
        total = state.total,
        chapters = state.chapters or {},
        ticks = state.ticks or {},
        meta = Format.metaVariants(state.author, state.pct or 0, step, finished),
        progress = Format.progressLine(state.pct or 0, step, finished),
    }
    if finished then return book end
    if step.book_seconds then
        book.hero = { Format.heroTime(step.book_seconds) }
        local has_pace = (state.timed or 0) >= MIN_TIMED_PAGES
        if has_pace and stats and stats.avg_day_seconds then
            book.forecast = Format.forecast(step.book_seconds, stats.today_seconds, stats.avg_day_seconds, now)
        end
    elseif state.page and state.total then
        book.hero = { Format.heroPages(state.page, state.total) }
    end
    return book
end

local function readerBook(ui, stats_on, stats, now)
    local state = readerState(ui, stats_on)
    pcall(Data.saveSnapshot, ui, state)
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    local finished = (summary and summary.status == "complete") or false
    local book = finishBook(state, finished, stats, now)
    book.cover = coverFor(ui, ui.document, ui.document.file)
    return book
end

-- The last book, from its sidecar and the snapshot the reader saved when it
-- closed (sleeping from the file browser or Bookshelf).
local function lastBook(ui, stats_on, stats, now)
    local file = G_reader_settings:readSetting("lastfile")
    if not file or lfs.attributes(file, "mode") ~= "file" then return nil end
    local ok, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok or not ds then return nil end
    local props = ds:readSetting("doc_props") or {}
    local summary = ds:readSetting("summary")

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
        local md5 = ds:readSetting("partial_md5_checksum")
        local pace = md5 and Data.bookPace(nil, md5)
        if pace and pace.pages and pace.pages > 0 then
            local pages_left = math.max(1, math.ceil((1 - pct) * pace.pages))
            state.page = pace.pages - pages_left + 1
            state.total = pace.pages
            state.timed = pace.timed
            state.step.book_pages = pages_left
            state.step.book_seconds = pages_left * (pace.avg or defaultPace())
        end
    end
    local book = finishBook(state, finished, stats, now)
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
    local c = Chain.compute(days, now)
    local year_start = os.time{ year = tonumber(os.date("%Y", now)), month = 1, day = 1, hour = 0 }
    local books = Data.booksFinishedSince(nil, year_start)
    local goal = G_reader_settings:readSetting("streakchain_goal")
    local week_value, week_sub = Format.weekTile(c.week_seconds, c.last_week_seconds)
    local books_value, books_sub = Format.booksTile(books, goal, now)
    return {
        streak = c.streak,
        best = c.best,
        read_today = c.read_today,
        today_seconds = c.today_seconds,
        avg_day_seconds = c.avg_day_seconds,
        note = Format.streakNote(c.streak, c.read_today, c.best),
        best_line = Format.bestLine(c.best, c.streak),
        strip = Chain.strip(c.streak, c.best, c.read_today),
        week = { value = week_value, sub = week_sub },
        books = { value = books_value, sub = books_sub },
    }
end

function Data.build(ui, now)
    now = now or os.time()
    local model = { header = { date = Format.headerDate(now), battery = batteryWarning() } }
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
        ok, book = pcall(readerBook, ui, stats_on, model.stats, now)
    else
        ok, book = pcall(lastBook, ui, stats_on, model.stats, now)
    end
    if ok then
        model.book = book
    else
        logger.warn("streakchain: could not read the book:", book)
    end
    logger.info("streakchain: sleep screen from", ui.document and "the reader" or "the file browser",
        "| book:", model.book and model.book.title or "none",
        "| progress:", model.book and model.book.progress or "-",
        "| forecast:", model.book and model.book.forecast and model.book.forecast.line or "-")
    return model
end

return Data
