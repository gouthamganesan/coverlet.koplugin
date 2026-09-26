--[[
Renders every state with the real KOReader engine, headless, and runs the
KOReader-side checks: statistics SQL against a synthetic database, and the
sleep-screen hook end to end through core's Screensaver.

Run from KOReader's install directory (the one holding reader.lua):

    SDL_VIDEO_DRIVER=offscreen ./luajit /plugin/tools/render.lua /out /covers

tools/test.sh does this inside a Debian container.
]]

local out_dir = arg[1] or "/tmp/streakchain-out"
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
local StreakScreen = require("streakchain/screen")
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

local states = require("tools/fixtures")(loadCover)
for _, s in ipairs(states) do
    local name, model, w, h = s[1], s[2], s[3] or 1264, s[4] or 1680
    local before = #warned
    local ok, err = pcall(function()
        png(StreakScreen:new{ model = model, width = w, height = h }, name, w, h)
    end)
    check(ok and #warned == before, "render " .. name, err or warned[#warned])
    -- The cover must keep its own pixels whenever it fits: never enlarged,
    -- never reshaped, only shrunk when the screen has no room.
    local b = model.book
    if b and b.cover and b.cover_w then
        local dw, dh = b.cover:getWidth(), b.cover:getHeight()
        check(dw <= b.cover_w and dh <= b.cover_h, name .. ": cover never enlarged", dw .. "x" .. dh)
        check(math.abs(dw / dh - b.cover_w / b.cover_h) < 0.01, name .. ": cover keeps its proportions", dw .. "x" .. dh)
        if name == "18-many-chapters" then
            check(dw == b.cover_w and dh == b.cover_h, name .. ": Sharp Objects cover drawn at its own 500x667",
                dw .. "x" .. dh)
        end
    end
end

-- --------------------------------------------- 2. statistics SQL, synthetic ---
local SQ3 = require("lua-ljsqlite3/init")
local Data = require("streakchain/data")
local C = require("streakchain/chain")

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
    INSERT INTO book (id, title, pages, md5) VALUES (1, 'Kafka', 100, 'aaa'), (2, 'Short', 10, 'bbb');
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
stmt:close()
conn:close()

local days = Data.readDays(db_path)
check(days ~= nil, "sql readDays returns data")
local function secs(ago) return days[C.key(now - ago * 86400)] end
check(secs(1) == 8 * 60, "sql day total yesterday", secs(1))
check(secs(4) == 6 * 60, "sql day total four days ago", secs(4))
check(secs(5) == 10 * 45, "sql second book's day", secs(5))
check(secs(6) == 50, "sql late-night page lands on its own day", secs(6))
local chain = C.compute(days, now)
check(chain.streak == 6, "sql-fed streak", chain.streak)
local year_start = os.time{ year = 2026, month = 1, day = 1, hour = 0 }
check(Data.booksFinishedSince(db_path, year_start) == 1, "sql finished this year", Data.booksFinishedSince(db_path, year_start))
check(Data.booksFinishedSince(db_path, now) == 0, "sql finished since now is none")
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
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6,
    micromodule_reading_goal_active = { daily = false, weekly = true, monthly = true, yearly = true } })
goals = Data.goals()
check(goals.daily == nil and goals.yearly == 6, "a goal switched off in Bookshelf is left out")
writeGoals({ micromodule_reading_goal_daily = 45, micromodule_reading_goal_yearly = 6 })

-- ------------------------------ 3. sleep-screen hook through core, end to end ---
-- Put the synthetic database where KOReader looks for it, then suspend the
-- way core does: Screensaver:setup() followed by Screensaver:show().
lfs.mkdir(DataStorage:getSettingsDir())
local real_db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
os.remove(real_db)
local src, dst = io.open(db_path, "rb"), io.open(real_db, "wb")
dst:write(src:read("*a")); src:close(); dst:close()

local plugin_module = dofile(plugin_dir .. "/main.lua")
local registered = false
local fake_menu = { registerToMainMenu = function() registered = true end }
local fm = { menu = fake_menu, bookinfo = nil }
local plugin = plugin_module:new{ ui = fm }
check(registered, "plugin registers its menu")

local menu_items = {}
plugin:addToMainMenu(menu_items)
check(menu_items.streakchain and #menu_items.streakchain.sub_item_table == 2, "menu has two entries, no goal setting")

G_reader_settings:saveSetting("screensaver_type", "random_image")
plugin:toggleSleepScreen()
check(G_reader_settings:readSetting("screensaver_type") == "streakchain", "toggle turns it on")
plugin:toggleSleepScreen()
check(G_reader_settings:readSetting("screensaver_type") == "random_image", "toggle restores the previous screen")
plugin:toggleSleepScreen()

local Screensaver = require("ui/screensaver")
local FileManager = require("apps/filemanager/filemanager")
FileManager.instance = fm
G_reader_settings:delSetting("lastfile")
Screensaver:setup()
check(Screensaver.screensaver_type == "streakchain", "core setup keeps our screen type")
local ok, err = pcall(Screensaver.show, Screensaver)
check(ok, "core show runs our hook", err)
local ssw = Screensaver.screensaver_widget
check(ssw ~= nil, "a sleep screen widget is shown")
local ours = ssw and ssw.widget
check(ours and ours.model and ours.model.stats ~= nil, "hook built a model with stats from the database")
check(ours and ours.model and ours.model.book == nil, "no last file means the no-book layout")
check(ours and ours.model.stats.goal_minutes == 45, "hook uses Bookshelf's daily goal")
if ours then
    local W, H = require("device").screen:getWidth(), require("device").screen:getHeight()
    png(ours, "hook-end-to-end", W, H)
    check(true, "hook render saved (" .. W .. "x" .. H .. ")")
end
require("ui/uimanager"):close(ssw)
Screensaver:cleanup()

-- The fallback: a model that makes drawing fail must still paint something.
local bad = StreakScreen:new{ model = { book = { title = "x", ticks = "not a table" }, header = {} }, width = 1264, height = 1680 }
local before = #warned
png(bad, "fallback", 1264, 1680)
check(#warned > before, "a drawing error falls back to a plain sleep screen")

print(failures == 0 and "all KOReader checks passed" or (failures .. " KOReader checks failed"))
os.exit(failures == 0 and 0 or 1)
