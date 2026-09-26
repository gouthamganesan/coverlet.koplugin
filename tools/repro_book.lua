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

local Data = require("streakchain/data")
local model = Data.build(reader)
print("model.book.meta:")
for _, v in ipairs(model.book and model.book.meta or {}) do print("  " .. v) end
print("model.book.ticks", model.book and #model.book.ticks)

local StreakScreen = require("streakchain/screen")
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
local reader_meta = model.book.meta[1]
reader:handleEvent(require("ui/event"):new("CloseDocument"))
G_reader_settings:saveSetting("lastfile", book_path)
local fm = { bookinfo = require("apps/filemanager/filemanagerbookinfo") }
local fm_model = Data.build(fm)
print("file browser meta:", fm_model.book and fm_model.book.meta[1])
print("file browser ticks:", fm_model.book and #fm_model.book.ticks)
render(fm_model, "repro-filebrowser")
local same = fm_model.book and fm_model.book.meta[1] == reader_meta and #fm_model.book.ticks == #model.book.ticks
print(same and "ok   file browser matches the reader" or "FAIL file browser differs from the reader")

-- A different last file must not borrow this book's snapshot.
G_reader_settings:saveSetting("lastfile", "/books/does-not-exist.epub")
local none = Data.build(fm)
print(none.book == nil and "ok   missing last file shows no book" or "FAIL missing last file")
os.exit(same and 0 or 1)
