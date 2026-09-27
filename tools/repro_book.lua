--[[
Opens a real book in a headless KOReader reader session (with its .sdr
sidecar beside it, so the saved position and font settings apply), runs the
plugin's data step on it, prints what the plugin sees, and renders the
sleep screen.

    ./luajit /plugin/tools/repro_book.lua /books/book.epub /out
]]

local book_path = assert(arg[1], "usage: repro_book.lua <book> [out-dir]")
local out_dir = arg[2] or "/out"
local plugin_dir = os.getenv("PLUGIN_DIR") or "/plugin"

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen = Device.screen

local Blitbuffer = require("ffi/blitbuffer")
local DocumentRegistry = require("document/documentregistry")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")

local document = assert(DocumentRegistry:openDocument(book_path), "could not open " .. book_path)
local reader = ReaderUI:new{
    dimen = Screen:getSize(),
    covers_fullscreen = true,
    document = document,
}
-- Let scheduled work (rendering, position restore) run.
for _ = 1, 20 do UIManager:handleInput() end

local toc = reader.toc
local page = reader:getCurrentPage()
local total = document:getPageCount()
print("page", page, "of", total)
print("toc entries", toc and toc.toc and #toc.toc)
if toc and toc.toc then
    for i = 1, math.min(#toc.toc, 60) do
        local e = toc.toc[i]
        print(string.format("  depth %d  page %4s  %s", e.depth or 0, tostring(e.page), e.title))
    end
end
print("max depth", toc and toc:getMaxDepth())
local ok_t, level1 = pcall(toc.getTocTicks, toc, 1)
print("level-1 ticks", ok_t and level1 and #level1, ok_t and "" or level1)
print("flattened ticks", #toc:getTocTicksFlattened(true))
print("next chapter after", page, "->", toc:getNextChapter(page))
print("title at page", toc:getTocTitleByPage(page))
print("statistics", reader.statistics ~= nil, reader.statistics and reader.statistics.avg_time)

-- Two earlier sessions in this book, written under the id the statistics
-- plugin gave it, so the time-in-the-book line is found through the book's
-- md5 the way it is on the device.
local st = reader.statistics
local seeded = st and st.id_curr_book
if seeded then
    reader.statistics:insertDB()
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
    local t0 = os.time() - 3 * 86400
    conn:exec(string.format("INSERT INTO page_stat_data VALUES (%d, 300, %d, 1800, %d), (%d, 301, %d, 600, %d);",
        st.id_curr_book, t0, total, st.id_curr_book, t0 + 1800, total))
    conn:close()
end
print("statistics book id", seeded)

local Data = require("coverlet/data")
local model = Data.build(reader)
print("model.book.step", model.book and model.book.step)
print("model.book.hero", model.book and model.book.hero and table.concat(model.book.hero, " "))
print("model.book.so_far", model.book and model.book.so_far)
print("model.book.ticks", model.book and #model.book.ticks)

local StreakScreen = require("coverlet/screen")
local W, H = Screen:getWidth(), Screen:getHeight()
local function render(m, name)
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    StreakScreen:new{ model = m, width = W, height = H }:paintTo(bb, 0, 0)
    bb:writePNG(out_dir .. "/" .. name .. ".png")
    bb:free()
    print("wrote", out_dir .. "/" .. name .. ".png")
end
render(model, "repro")

-- Now sleep from the file browser: no open document, only the last file and
-- the snapshot the reader just saved.
local reader_step = model.book.step
reader:handleEvent(require("ui/event"):new("CloseDocument"))
G_reader_settings:saveSetting("lastfile", book_path)
local fm = { bookinfo = require("apps/filemanager/filemanagerbookinfo") }
local fm_model = Data.build(fm)
print("file browser step:", fm_model.book and fm_model.book.step)
print("file browser ticks:", fm_model.book and #fm_model.book.ticks)
render(fm_model, "repro-filebrowser")
print("file browser so far:", fm_model.book and fm_model.book.so_far)
local same = fm_model.book and fm_model.book.step == reader_step and #fm_model.book.ticks == #model.book.ticks
    and fm_model.book.so_far == model.book.so_far
local so_far_ok = not seeded or (model.book.so_far or ""):match("^40 min in, since ") ~= nil
print(so_far_ok and "ok   time in the book found through its md5" or "FAIL time in the book: " .. tostring(model.book.so_far))
print(same and "ok   file browser matches the reader" or "FAIL file browser differs from the reader")

-- A different last file must not borrow this book's snapshot.
G_reader_settings:saveSetting("lastfile", "/books/does-not-exist.epub")
local none = Data.build(fm)
print(none.book == nil and "ok   missing last file shows no book" or "FAIL missing last file")
os.exit((same and so_far_ok and none.book == nil) and 0 or 1)
