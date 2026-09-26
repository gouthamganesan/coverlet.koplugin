--[[
Streak chain: a sleep screen with the book you're reading, the time left in
the chapter, and a four-week reading chain.

Hooks into KOReader's own sleep screen rather than drawing beside it: once
"Use as sleep screen" is on, screensaver_type is "streakchain", core's
Screensaver:setup() passes that value through untouched, and the patched
Screensaver:show() below builds our widget and hands it to core's
ScreenSaverWidget. Core then closes it on wake exactly as it closes its own.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- KOReader only puts this folder on the module path while main.lua loads,
-- so every module is required here, up front.
local Data = require("streakchain/data")
local StreakScreen = require("streakchain/screen")

local TYPE = "streakchain"

local function isActive()
    return G_reader_settings:readSetting("screensaver_type") == TYPE
end

local function patchScreensaver()
    local Screensaver = require("ui/screensaver")
    if Screensaver._streakchain_patched then return end
    Screensaver._streakchain_patched = true

    local orig_show = Screensaver.show
    Screensaver.show = function(self, ...)
        if not (self.ui and self.screensaver_type == TYPE) then
            return orig_show(self, ...)
        end
        local ok, widget = pcall(function()
            return StreakScreen:new{ model = Data.build(self.ui) }
        end)
        if not ok or not widget then
            logger.warn("streakchain: falling back to leaving the screen as is:", widget)
            self.screensaver_type = "disable"
            return orig_show(self, ...)
        end
        Device.screen_saver_mode = true
        Device.orig_rotation_mode = nil
        UIManager:setIgnoreTouchInput(false)
        if Device:isTouchDevice() and G_reader_settings:readSetting("screensaver_delay") == "gesture" then
            local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
            self.screensaver_lock_widget = ScreenSaverLockWidget:new{ ui = self.ui }
        end
        local ScreenSaverWidget = require("ui/widget/screensaverwidget")
        self.screensaver_widget = ScreenSaverWidget:new{
            widget = widget,
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
        if self.screensaver_lock_widget then
            UIManager:show(self.screensaver_lock_widget)
        end
    end
end

local StreakChain = WidgetContainer:extend{
    name = "streakchain",
    is_doc_only = false,
}

function StreakChain:init()
    patchScreensaver()
    self.ui.menu:registerToMainMenu(self)
end

-- The snapshot of the open book (chapter, time left, marks) that a sleep
-- screen shown from the file browser or Bookshelf falls back on. Bookshelf
-- keeps a book "parked" open behind the shelf and only really closes it
-- later, so saving on close alone isn't enough: save when the book opens,
-- as pages turn (at most every 30 s), and on close.
function StreakChain:saveSnapshot(why)
    if not (self.ui and self.ui.document) then return end
    local ok, state = pcall(Data.saveSnapshot, self.ui)
    if ok then
        logger.dbg("streakchain: snapshot saved on", why, state.step and state.step.chapter_title)
    else
        logger.warn("streakchain: could not save the snapshot:", state)
    end
end

function StreakChain:onReaderReady()
    UIManager:scheduleIn(2, function() self:saveSnapshot("open") end)
end

function StreakChain:onPageUpdate()
    local now = os.time()
    if self._snapshot_at and now - self._snapshot_at < 30 then return end
    self._snapshot_at = now
    self:saveSnapshot("page")
end

function StreakChain:onCloseDocument()
    self:saveSnapshot("close")
end

function StreakChain:toggleSleepScreen()
    if isActive() then
        local previous = G_reader_settings:readSetting("streakchain_previous_type")
        if not previous or previous == TYPE then previous = "cover" end
        G_reader_settings:saveSetting("screensaver_type", previous)
    else
        G_reader_settings:saveSetting("streakchain_previous_type", G_reader_settings:readSetting("screensaver_type"))
        G_reader_settings:saveSetting("screensaver_type", TYPE)
    end
end

-- Shows the sleep screen now; a tap closes it.
function StreakChain:preview()
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local ok, widget = pcall(function()
        return StreakScreen:new{ model = Data.build(self.ui) }
    end)
    if not ok then
        logger.warn("streakchain: preview failed:", widget)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Streak chain could not build the screen.") })
        return
    end
    local preview = ScreenSaverWidget:new{
        widget = widget,
        background = Blitbuffer.COLOR_WHITE,
        covers_fullscreen = true,
    }
    preview.dithered = true
    UIManager:show(preview, "full")
end

function StreakChain:addToMainMenu(menu_items)
    menu_items.streakchain = {
        text = _("Streak chain"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Use as sleep screen"),
                checked_func = isActive,
                callback = function() self:toggleSleepScreen() end,
            },
            {
                text = _("Preview"),
                keep_menu_open = false,
                callback = function() self:preview() end,
            },
        },
    }
end

return StreakChain
