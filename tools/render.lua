--[[
Renders every state with the real KOReader engine, headless, and runs the
KOReader-side checks: statistics SQL against a synthetic database, and the
sleep-screen hook end to end through core's Screensaver.

Run from KOReader's install directory (the one holding reader.lua):

    SDL_VIDEO_DRIVER=offscreen ./luajit /plugin/tools/render.lua /out /covers

tools/test.sh does this inside a Debian container.
]]

local out_dir = arg[1] or "/tmp/coverlet-out"
local covers_dir = arg[2]
local plugin_dir = os.getenv("PLUGIN_DIR") or "/plugin"

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
-- The same two steps reader.lua takes: the (offscreen) screen that fonts
-- scale against, and the canvas context the font list reads.
local Device = require("device")
require("document/canvascontext"):init(Device)

local failures = 0
local function check(cond, name, detail)
    if cond then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

lfs.mkdir(out_dir)

local function png(widget, name, w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    widget:paintTo(bb, 0, 0)
    bb:writePNG(out_dir .. "/" .. name .. ".png")
    bb:free()
end

-- ------------------------------------------------------ 1. every state ---
local StreakScreen = require("coverlet/screen")
local logger = require("logger")
local warned = {}
local orig_warn = logger.warn
logger.warn = function(...) table.insert(warned, table.concat({ ... }, " ")); return orig_warn(...) end

local function loadCover(name)
    if not covers_dir then return nil end
    local path = covers_dir .. "/" .. name .. ".png"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    return RenderImage:renderImageFile(path, false)
end

-- Every block the screen drew stays on the screen and clear of the others,
-- and no row ran into its own value.
local function layoutProblems(layout, w, h)
    local problems = {}
    for _, what in ipairs(layout.clashes) do table.insert(problems, what) end
    local boxes = layout.boxes
    for i, a in ipairs(boxes) do
        if a.x < 0 or a.y < 0 or a.x + a.w > w or a.y + a.h > h then
            table.insert(problems, a.name .. " off the screen")
        end
        for j = i + 1, #boxes do
            local b = boxes[j]
            if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                table.insert(problems, a.name .. " overlaps " .. b.name)
            end
        end
    end
    return problems
end

local states = require("tools/fixtures")(loadCover)
local rendered = {}
for _, s in ipairs(states) do
    local name, model, w, h = s[1], s[2], s[3] or 1264, s[4] or 1680
    local before = #warned
    local widget = StreakScreen:new{ model = model, width = w, height = h }
    rendered[name] = widget
    local ok, err = pcall(function() png(widget, name, w, h) end)
    check(ok and #warned == before, "render " .. name, err or warned[#warned])
    local problems = widget.layout and layoutProblems(widget.layout, w, h) or { "no layout recorded" }
    check(#problems == 0, name .. ": nothing overlaps or spills (" .. (widget.layout and #widget.layout.boxes or 0) .. " blocks)",
        table.concat(problems, "; "))
    -- The cover must keep its own pixels whenever it fits: never enlarged,
    -- never reshaped, only shrunk when the screen has no room.
    local b = model.book
    if b and b.cover and b.cover_w then
        local dw, dh = b.cover:getWidth(), b.cover:getHeight()
        check(dw <= b.cover_w and dh <= b.cover_h, name .. ": cover never enlarged", dw .. "x" .. dh)
        check(math.abs(dw / dh - b.cover_w / b.cover_h) < 0.01, name .. ": cover keeps its proportions", dw .. "x" .. dh)
        if name == "18-many-chapters" then
            -- 7b draws covers 420 px tall: a taller sample cover shrinks to fit, evenly.
            local want_h = math.min(420, b.cover_h)
            check(dh == want_h and dw == math.floor(b.cover_w * want_h / b.cover_h), name .. ": cover shrunk to 7b's 420 px",
                dw .. "x" .. dh)
        end
    end
end

-- The chapter bar: the current chapter at 40% of the width, every other
-- chapter a visible piece, and one box for a book without chapters.
local function barCheck(name, want_count, want_gap)
    local bar = rendered[name] and rendered[name].bar_layout
    local w = rendered[name].dimen.w > rendered[name].dimen.h and 1012 or 1152
    local ok_bar = bar and bar.count == want_count and math.abs(bar.box.w - 0.4 * w) < 0.5
        and math.abs(bar.gap - want_gap) < 0.01
    local thinnest = math.huge
    for _, side in ipairs({ "before", "after" }) do
        for _, p in ipairs(bar and bar[side] or {}) do thinnest = math.min(thinnest, p.w) end
    end
    check(ok_bar and thinnest >= 1, name .. ": " .. want_count .. " chapters, the current one magnified",
        bar and (bar.count .. " chapters, box " .. bar.box.w .. ", gap " .. bar.gap .. ", thinnest " .. thinnest) or "no bar")
end
barCheck("18-many-chapters", 21, 4)
barCheck("31-sixty-four-chapters", 64, 2)
barCheck("33-landscape-sixty-four", 64, 2)
check(rendered["32-pdf-no-chapters"].bar_layout == nil, "32-pdf-no-chapters: one box for the whole book")
check(rendered["32-pdf-no-chapters"].model.book.bar.pages.right == "143 pages to go", "32-pdf-no-chapters: pages to go",
    rendered["32-pdf-no-chapters"].model.book.bar.pages.right)

-- The daily quote: the next in the rotation that fits, a long one skipped
-- for a shorter one when the gap is tight, none when nothing fits.
local function shown(name)
    local c = rendered[name] and rendered[name].quote_choice
    if c == false then return "none" end
    return c and c.author or "?"
end
for name, want in pairs({
    ["18-many-chapters"] = "Stephen King", ["26-quote-short"] = "Stephen King",
    ["27-quote-long"] = "John Locke", ["28-quote-none-fits"] = "none",
    ["29-quote-skips-long"] = "Franz Kafka", ["30-landscape-quote"] = "Franz Kafka",

}) do
    check(shown(name) == want, name .. ": quote is " .. want, shown(name))
end
local long_q = rendered["27-quote-long"].model.quotes
check(long_q.saves == 1 and long_q.saved.pos == 2 and long_q.saved.order[1] == 4,
    "the rotation is saved once, moved on past the quote shown")
local skip_q = rendered["29-quote-skips-long"].model.quotes
check(skip_q.saved and skip_q.saved.order[1] == 2 and skip_q.saved.order[2] == 5 and skip_q.saved.pos == 2,
    "a quote skipped for length stays next in the round")
check(rendered["28-quote-none-fits"].model.quotes.saves == 0, "no quote shown, rotation left as it was")
do
    local again = Blitbuffer.new(1264, 1680, Blitbuffer.TYPE_BB8)
    rendered["26-quote-short"]:paintTo(again, 0, 0)
    again:free()
    local q = rendered["26-quote-short"].model.quotes
    check(q.saves == 1 and shown("26-quote-short") == "Stephen King", "a repaint keeps the same quote")
end
-- Every quote in the shipped list sets whole, in two lines at most, in 7b's
-- text column beside a 2:3 cover.
local column = 1264 - 2 * 56 - 315 - 14 - 48
for i, q in ipairs(require("coverlet/quotes")) do
    local ok_q = type(q.text) == "string" and q.text ~= "" and type(q.author) == "string" and q.author ~= ""
    local h, lines = StreakScreen:quote(nil, 0, 0, column, function(v) return v end, q)
    check(ok_q and h ~= nil, "quotes.lua #" .. i .. " fits two lines at " .. column .. " px", lines or "too long")
end

-- --------------------------------------------- 2. statistics SQL, synthetic ---
local SQ3 = require("lua-ljsqlite3/init")
local Data = require("coverlet/data")
local C = require("coverlet/chain")

local db_path = out_dir .. "/test-statistics.sqlite3"
os.remove(db_path)
local conn = SQ3.open(db_path)
conn:exec([[
    CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer,
        last_open integer, highlights integer, pages integer, series text, language text, md5 text,
        total_read_time integer, total_read_pages integer);
    CREATE TABLE page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
        start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0,
        total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
    CREATE TABLE numbers (number INTEGER PRIMARY KEY);
    WITH RECURSIVE counter AS (SELECT 1 as N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000)
        INSERT INTO numbers SELECT N AS number FROM counter;
    CREATE VIEW page_stat AS
        SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
        FROM (SELECT id_book, page, total_pages, pages, start_time, duration,
                ((page - 1) * pages) / total_pages + 1 AS first_page,
                max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page, idx
            FROM page_stat_data JOIN book ON book.id = id_book
            JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1));
    INSERT INTO book (id, title, pages, md5) VALUES (1, 'Kafka', 100, 'aaa'), (2, 'Short', 10, 'bbb'),
        (3, 'Today', 50, 'ccc');
]])
local now = os.time{ year = 2026, month = 9, day = 25, hour = 21 }
local function at(days_ago, hour)
    local d = os.date("*t", now - days_ago * 86400)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = hour or 20 }
end
local stmt = conn:prepare("INSERT INTO page_stat_data VALUES (?, ?, ?, ?, ?);")
-- Kafka: pages 1..30 over the last four days, 60 s a page.
for i = 1, 30 do
    stmt:reset():bind(1, i, at(math.floor((i - 1) / 8) + 1, 20) + i * 60, 60, 100):step()
end
-- Short book: finished this year (page 10 of 10) five days ago.
for i = 1, 10 do
    stmt:reset():bind(2, i, at(5, 10) + i * 60, 45, 10):step()
end
-- A late-night page just before midnight still counts for that day.
stmt:reset():bind(1, 31, at(6, 23) + 30 * 60, 50, 100):step()
-- Today: pages 1..5 of a third book, and page 5 read twice.
for i = 1, 5 do
    stmt:reset():bind(3, i, at(0, 19) + i * 60, 60, 50):step()
end
stmt:reset():bind(3, 5, at(0, 19) + 10 * 60, 60, 50):step()
stmt:close()
conn:close()

local days = Data.readDays(db_path)
check(days ~= nil, "sql readDays returns data")
local function secs(ago) return days[C.key(now - ago * 86400)] end
check(secs(1) == 8 * 60, "sql day total yesterday", secs(1))
check(secs(4) == 6 * 60, "sql day total four days ago", secs(4))
check(secs(5) == 10 * 45, "sql second book's day", secs(5))
check(secs(6) == 50, "sql late-night page lands on its own day", secs(6))
check(secs(0) == 6 * 60, "sql today's total", secs(0))
local chain = C.compute(days, now)
check(chain.streak == 7, "sql-fed streak", chain.streak)
check(chain.week_seconds == 30 * 60 + 6 * 60, "sql-fed week, Monday to today", chain.week_seconds)
check(chain.year_seconds == 30 * 60 + 50 + 10 * 45 + 6 * 60, "sql-fed year total", chain.year_seconds)
check(C.goalStreak(days, now, 5 * 60) == 6, "sql-fed goal day streak", C.goalStreak(days, now, 5 * 60))
local year_start = C.startOfYear(now)
-- Books for the goals, the way Bookshelf counts them: from the reading
-- history and each book's sidecar, by when it was last opened.
do
    local DocSettings = require("docsettings")
    local function book(name, status, pct)
        local file = out_dir .. "/" .. name .. ".epub"
        local f = io.open(file, "w"); f:write("x"); f:close()
        local ds = DocSettings:open(file)
        if status then ds:saveSetting("summary", { status = status }) end
        if pct then ds:saveSetting("percent_finished", pct) end
        ds:flush()
        return file
    end
    local history = {
        { file = book("finished-this-month", "complete", 1), time = now - 3 * 86400 },
        { file = book("reading-now", "reading", 0.72), time = now - 3600 },
        { file = book("started-no-status", nil, 0.1), time = now - 5 * 86400 },
        { file = book("only-sampled", "reading", 0.03), time = now - 4 * 86400 },
        { file = book("on-hold", "abandoned", 0.4), time = now - 2 * 86400 },
        { file = book("finished-in-march", "complete", 1), time = os.time{ year = 2026, month = 3, day = 10, hour = 12 } },
        { file = book("reading-in-june", "reading", 0.3), time = os.time{ year = 2026, month = 6, day = 2, hour = 12 } },
        { file = book("finished-last-year", "complete", 1), time = os.time{ year = 2025, month = 12, day = 20, hour = 12 } },
        { file = book("never-read", nil, nil), time = now - 86400 },
    }
    local bc = Data.bookCounts(now, history)
    check(bc.month.finished == 1 and bc.year.finished == 2, "only finished books count toward the goals",
        bc.month.finished .. "/" .. bc.year.finished)
    check(bc.month.reading == 2 and bc.year.reading == 3, "books still being read are counted apart, not ones only sampled",
        bc.month.reading .. "/" .. bc.year.reading)
    local own = DataStorage:getDataDir() .. "/help"
    lfs.mkdir(own)
    local guide = own .. "/quickstart.html"
    local f = io.open(guide, "w"); f:write("x"); f:close()
    local ds = DocSettings:open(guide); ds:saveSetting("summary", { status = "reading" }); ds:saveSetting("percent_finished", 0.62); ds:flush()
    local with_guide = Data.bookCounts(now, { { file = guide, time = now - 60 } })
    check(with_guide.month.reading == 0, "KOReader's own guide isn't a book being read")
end
local pages = Data.pagesSince(db_path, C.startOfDay(now))
check(pages == 5, "sql pages today, each page once", pages)
check(Data.pagesSince(db_path, now + 86400) == 0, "sql no pages tomorrow")
local spent = Data.bookTime(db_path, "aaa")
check(spent and spent.seconds == 30 * 60 + 50, "sql time in one book", spent and spent.seconds)
check(spent and spent.first == at(6, 23) + 30 * 60, "sql the book's first page", spent and spent.first)
check(spent and require("coverlet/format").bookSoFar(spent.seconds, spent.first, now) == "30 min in, since 19 Sep",
    "sql time in the book reads right", spent and require("coverlet/format").bookSoFar(spent.seconds, spent.first, now))
check(Data.bookTime(db_path, "zzz") == nil, "sql unknown book has no time")
local pace = Data.bookPace(db_path, "aaa")
-- 30 pages at 60 s plus the late-night page at 50 s
check(pace and pace.pages == 100 and math.abs((pace.avg or 0) - (30 * 60 + 50) / 31) < 0.01, "sql book pace", pace and pace.avg)
check(Data.bookPace(db_path, "zzz") == nil, "sql unknown book has no pace")
check(Data.readDays("/nonexistent/dir/statistics.sqlite3") == nil, "sql missing database is handled")

-- ------------------------------------------- goals from Bookshelf's file ---
lfs.mkdir(DataStorage:getSettingsDir())
local mm_path = DataStorage:getSettingsDir() .. "/bookshelf_micromodules.lua"
local function writeGoals(tbl)
    local LuaSettings = require("luasettings")
    os.remove(mm_path)
    local ls = LuaSettings:open(mm_path)
    for k, v in pairs(tbl) do ls:saveSetting(k, v) end
    ls:flush()
end
check(next(Data.goals()) == nil, "no Bookshelf file means no goals")
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6, micromodule_reading_goal_weekly = 600 })
local goals = Data.goals()
check(goals.daily == 45 and goals.yearly == 6, "goals read from Bookshelf's file", goals.daily .. "/" .. tostring(goals.yearly))
check(goals.weekly == 600, "with no switches saved, every goal is on, as in Bookshelf", tostring(goals.weekly))
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6,
    micromodule_reading_goal_weekly = 600, micromodule_reading_goal_monthly = 2 })
goals = Data.goals()
check(goals.daily == 45 and goals.weekly == 600 and goals.monthly == 2 and goals.yearly == 6,
    "the device's own settings file shows all four goals",
    table.concat({ tostring(goals.daily), tostring(goals.weekly), tostring(goals.monthly), tostring(goals.yearly) }, "/"))
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6,
    micromodule_reading_goal_weekly = 600, micromodule_reading_goal_monthly = 2,
    micromodule_reading_goal_active = { daily = false, weekly = true, monthly = true, yearly = true } })
goals = Data.goals()
check(goals.daily == nil and goals.yearly == 6, "a goal switched off in Bookshelf is left out")
check(goals.weekly == 600 and goals.monthly == 2, "weekly and monthly goals read from Bookshelf's file",
    tostring(goals.weekly) .. "/" .. tostring(goals.monthly))
writeGoals({ micromodule_reading_goal_weekly = 600, micromodule_reading_goal_monthly = 2,
    micromodule_reading_goal_active = { daily = true, weekly = true, monthly = false, yearly = false } })
goals = Data.goals()
check(goals.weekly == 600 and goals.monthly == nil and goals.yearly == nil, "monthly and yearly switched off")
check(goals.daily == 30, "an unset daily goal takes Bookshelf's default", goals.daily)
writeGoals({ micromodule_reading_goal_active = { daily = false, weekly = true, monthly = true, yearly = false } })
goals = Data.goals()
check(goals.weekly == 300 and goals.monthly == 3, "weekly and monthly switched on but unset take Bookshelf's defaults",
    tostring(goals.weekly) .. "/" .. tostring(goals.monthly))
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6 })

-- ------------------------------ 3. sleep-screen hook through core, end to end ---
-- Put the synthetic database where KOReader looks for it, then suspend the
-- way core does: Screensaver:setup() followed by Screensaver:show().
lfs.mkdir(DataStorage:getSettingsDir())
local real_db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
os.remove(real_db)
local src, dst = io.open(db_path, "rb"), io.open(real_db, "wb")
dst:write(src:read("*a")); src:close(); dst:close()

-- Settings saved under the old name carry over when the plugin loads.
G_reader_settings:saveSetting("screensaver_type", "streakchain")
G_reader_settings:saveSetting("streakchain_previous_type", "readinginsights")
G_reader_settings:saveSetting("streakchain_quote", { order = { 2, 1 }, index = 1 })
G_reader_settings:saveSetting("streakchain_goal", 10)
local plugin_module = dofile(plugin_dir .. "/main.lua")
local registered = false
local fake_menu = { registerToMainMenu = function() registered = true end }
local fm = { menu = fake_menu, bookinfo = nil }
local plugin = plugin_module:new{ ui = fm }
check(registered, "plugin registers its menu")
check(G_reader_settings:readSetting("screensaver_type") == "coverlet", "the old sleep screen type becomes coverlet")
check(G_reader_settings:readSetting("coverlet_previous_type") == "readinginsights"
    and G_reader_settings:readSetting("streakchain_previous_type") == nil, "the previous screen type carries over")
check(type(G_reader_settings:readSetting("coverlet_quote")) == "table", "the quote rotation carries over")
check(G_reader_settings:readSetting("streakchain_goal") == nil, "the unused goal setting is cleared")

local menu_items = {}
plugin:addToMainMenu(menu_items)
check(menu_items.coverlet and #menu_items.coverlet.sub_item_table == 2, "menu has two entries, no goal setting")

G_reader_settings:saveSetting("screensaver_type", "random_image")
plugin:toggleSleepScreen()
check(G_reader_settings:readSetting("screensaver_type") == "coverlet", "toggle turns it on")
plugin:toggleSleepScreen()
check(G_reader_settings:readSetting("screensaver_type") == "random_image", "toggle restores the previous screen")
plugin:toggleSleepScreen()

local Screensaver = require("ui/screensaver")
local FileManager = require("apps/filemanager/filemanager")
FileManager.instance = fm
G_reader_settings:delSetting("lastfile")
Screensaver:setup()
check(Screensaver.screensaver_type == "coverlet", "core setup keeps our screen type")
local ok, err = pcall(Screensaver.show, Screensaver)
check(ok, "core show runs our hook", err)
local ssw = Screensaver.screensaver_widget
check(ssw ~= nil, "a sleep screen widget is shown")
local ours = ssw and ssw.widget
check(ours and ours.model and ours.model.stats ~= nil, "hook built a model with stats from the database")
check(ours and ours.model and ours.model.book == nil, "no last file means the no-book layout")
check(ours and ours.model.stats.today.fraction ~= nil and ours.model.stats.today.unit:match("goal") ~= nil,
    "hook uses Bookshelf's daily goal", ours and ours.model.stats.today.unit)
if ours then
    local W, H = require("device").screen:getWidth(), require("device").screen:getHeight()
    png(ours, "hook-end-to-end", W, H)
    check(true, "hook render saved (" .. W .. "x" .. H .. ")")
end
require("ui/uimanager"):close(ssw)
Screensaver:cleanup()

-- The flame: every variant draws from its SVG at every size, and the core
-- really is a hole in the solid flame.
local function inked(variant, w, h)
    local bb = Blitbuffer.new(w + 4, h + 4, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local ok = StreakScreen:paintFlame(bb, 2, 2, w, h, variant)
    local n = 0
    for y = 0, h + 3 do
        for x = 0, w + 3 do
            if bb:getPixel(x, y):getColor8().a < 0xE0 then n = n + 1 end
        end
    end
    bb:free()
    return ok, n
end
for _, size in ipairs({ "small", "medium", "large" }) do
    local dims = C.FLAME[size]
    local counts = {}
    for _, variant in ipairs({ "dashed", "outline", "solid", "core" }) do
        local ok_f, n = inked(variant, dims.w, dims.h)
        counts[variant] = n
        check(ok_f and n > dims.w, "flame " .. variant .. " draws at " .. size, n)
    end
    check(counts.core < counts.solid and counts.outline < counts.solid and counts.dashed < counts.outline,
        "flame " .. size .. ": core, outline and dashed are lighter than solid",
        counts.solid .. " " .. counts.core .. " " .. counts.outline .. " " .. counts.dashed)
end

-- The fallback: a model that makes drawing fail must still paint something.
local bad = StreakScreen:new{ model = { book = { title = "x", ticks = "not a table" }, header = {} }, width = 1264, height = 1680 }
local before = #warned
png(bad, "fallback", 1264, 1680)
check(#warned > before, "a drawing error falls back to a plain sleep screen")

print(failures == 0 and "all KOReader checks passed" or (failures .. " KOReader checks failed"))
os.exit(failures == 0 and 0 or 1)
