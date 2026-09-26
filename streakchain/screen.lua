--[[
Draws the model from streakchain/data.lua. All layout is in the design's own
units (a 1264x1680 portrait canvas, 1680x1264 in landscape) and scaled to the
real screen, so it matches the design canvas on any Kindle.

Layouts: portrait, landscape, no book open, and statistics off (a hint in
place of the chain). Anything that fails to draw falls back to a plain
message instead of a blank or broken sleep screen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local logger = require("logger")

local Format = require("streakchain/format")

local Screen = Device.screen

local function gray(v) return Blitbuffer.Color8(v) end
local PAPER = Blitbuffer.COLOR_WHITE
local INK = gray(0x11)
local G44, G55, G66 = gray(0x44), gray(0x55), gray(0x66)
local G77, G99, GBB = gray(0x77), gray(0x99), gray(0xBB)
local COVER_PAPER = gray(0xF7)

local LEVEL = { l = GBB, m = G77, h = INK }

-- Vollkorn and Atkinson Hyperlegible when installed, KOReader's own fonts otherwise.
local FONTS = {
    title = { "Vollkorn-MediumItalic.ttf", "Vollkorn-Italic.ttf", "NotoSerif-Italic.ttf" },
    serif = { "Vollkorn-Regular.ttf", "NotoSerif-Regular.ttf" },
    number = { "Vollkorn-SemiBold.ttf", "Vollkorn-Bold.ttf", "NotoSerif-Bold.ttf" },
    sans = { "AtkinsonHyperlegible-Regular.ttf", "NotoSans-Regular.ttf" },
    sansBold = { "AtkinsonHyperlegible-Bold.ttf", "NotoSans-Bold.ttf" },
}
local resolved = {}

-- px is the wanted size in real screen pixels; Font:getFace scales by DPI itself.
local function face(role, px)
    local size = px / (Screen:scaleBySize(1000) / 1000)
    local names = resolved[role] and { resolved[role] } or FONTS[role]
    for _, name in ipairs(names) do
        local f = Font:getFace(name, size)
        if f then
            resolved[role] = name
            return f
        end
    end
    return Font:getFace("cfont", size)
end

local function text(str, fc, color, max_w)
    return TextWidget:new{ text = str, face = fc, fgcolor = color or INK, padding = 0, max_width = max_w }
end

local function textbox(str, fc, width, align, color, line_height, bg)
    return TextBoxWidget:new{
        text = str, face = fc, width = width, alignment = align or "left",
        fgcolor = color or INK, line_height = line_height or 0.1, bgcolor = bg or PAPER,
    }
end

local function rect(bb, x, y, w, h, c)
    if bb and w > 0 and h > 0 then bb:paintRect(x, y, w, h, c) end
end

local function frame(bb, x, y, w, h, t, c)
    if bb and w > 0 and h > 0 then bb:paintBorder(x, y, w, h, t, c) end
end

local function dashed(bb, x, y, w, h, t, c, dash, space)
    local i = 0
    while i < w do
        local l = math.min(dash, w - i)
        rect(bb, x + i, y, l, t, c)
        rect(bb, x + i, y + h - t, l, t, c)
        i = i + dash + space
    end
    i = 0
    while i < h do
        local l = math.min(dash, h - i)
        rect(bb, x, y + i, t, l, c)
        rect(bb, x + w - t, y + i, t, l, c)
        i = i + dash + space
    end
end

-- Scale design units to the screen, centred if the aspect ratio differs.
local function scaler(W, H, dw, dh)
    local f = math.min(W / dw, H / dh)
    local px = function(v) return math.floor(v * f + 0.5) end
    return px, math.floor((W - dw * f) / 2), math.floor((H - dh * f) / 2)
end

local StreakScreen = Widget:extend{
    model = nil,
    width = nil,
    height = nil,
}

function StreakScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width or Screen:getWidth(), h = self.height or Screen:getHeight() }
end

function StreakScreen:getSize()
    return self.dimen
end

function StreakScreen:free()
    local book = self.model and self.model.book
    if book and book.cover then
        book.cover:free()
        book.cover = nil
    end
end

function StreakScreen:onCloseWidget()
    self:free()
end

function StreakScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local ok, err = pcall(self.paintScreen, self, bb, x, y)
    if not ok then
        logger.warn("streakchain: could not draw the sleep screen:", err)
        rect(bb, x, y, self.dimen.w, self.dimen.h, PAPER)
        local t = text("Sleeping", face("title", Screen:scaleBySize(40)))
        local s = t:getSize()
        t:paintTo(bb, x + math.floor((self.dimen.w - s.w) / 2), y + math.floor((self.dimen.h - s.h) / 2))
        t:free()
    end
end

function StreakScreen:paintScreen(bb, x, y)
    local W, H = self.dimen.w, self.dimen.h
    rect(bb, x, y, W, H, PAPER)
    local m = self.model or {}
    if not m.book then
        return self:paintNoBook(bb, x, y, W, H, m)
    elseif W > H then
        return self:paintLandscape(bb, x, y, W, H, m)
    end
    return self:paintPortrait(bb, x, y, W, H, m)
end

-- ---------------------------------------------------------------- parts ---

function StreakScreen:header(bb, x, y, w, px, header)
    header = header or {}
    local fc = face("sans", px(22))
    local left = text(string.upper(header.date or ""), fc, G44)
    local h = left:getSize().h
    if bb then left:paintTo(bb, x, y) end
    left:free()
    if header.battery then
        local t = text(string.upper(header.battery), face("sansBold", px(22)), PAPER)
        local s = t:getSize()
        local pw, ph = s.w + px(32), s.h + px(12)
        if bb then
            rect(bb, x + w - pw, y - px(6), pw, ph, INK)
            t:paintTo(bb, x + w - pw + px(16), y)
        end
        t:free()
    else
        local t = text("SLEEPING", fc, G44)
        if bb then t:paintTo(bb, x + w - t:getSize().w, y) end
        t:free()
    end
    return h
end

-- Title (two lines at most, then an ellipsis) and the meta line under it.
function StreakScreen:titleBlock(bb, x, y, w, px, book, align)
    local fc = face("title", px(62))
    local tb = textbox(book.title or "", fc, w, align, INK, 0.05)
    local lh = tb:getLineHeight()
    local th = tb:getSize().h
    if th > lh * 2 + 2 then
        tb:free()
        tb = TextBoxWidget:new{
            text = book.title or "", face = fc, width = w, alignment = align, fgcolor = INK,
            line_height = 0.05, height = lh * 2, height_overflow_show_ellipsis = true,
        }
        th = tb:getSize().h
    end
    local mfc = face("sans", px(24))
    local meta
    local variants = book.meta or {}
    for i, v in ipairs(variants) do
        local t = text(v, mfc, G44)
        if t:getSize().w <= w or i == #variants then
            if t:getSize().w > w then
                t:free()
                t = text(v, mfc, G44, w)
            end
            meta = t
            break
        end
        t:free()
    end
    local mh = meta and meta:getSize().h or 0
    local total = px(8) + th + px(4) + mh
    if bb then
        tb:paintTo(bb, x, y + px(8))
        if meta then
            local mw = meta:getSize().w
            local mx = align == "center" and x + math.floor((w - mw) / 2) or x
            meta:paintTo(bb, mx, y + px(8) + th + px(4))
        end
    end
    tb:free()
    if meta then meta:free() end
    return total
end

function StreakScreen:progress(bb, x, y, w, px, book)
    local pct = book.finished and 1 or math.max(0, math.min(1, book.pct or 0))
    rect(bb, x, y + px(10), w, math.max(1, px(2)), G99)
    rect(bb, x, y + px(7), math.floor(w * pct), px(8), INK)
    for _, t in ipairs(book.ticks or {}) do
        rect(bb, x + math.floor(w * t), y, math.max(1, px(2)), px(22), G66)
    end
    local d = px(22)
    local mx = x + math.floor(w * pct) - math.floor(d / 2)
    mx = math.max(x, math.min(x + w - d, mx))
    bb:paintRoundedRect(mx, y, d, d, INK, math.floor(d / 2))
    return px(22)
end

function StreakScreen:typesetCover(bb, x, y, w, h, book)
    local s = h / 840
    local function sp(v) return math.max(1, math.floor(v * s + 0.5)) end
    rect(bb, x, y, w, h, COVER_PAPER)
    local inset = sp(28)
    frame(bb, x + inset, y + inset, w - 2 * inset, h - 2 * inset, 1, INK)
    local inner = w - 2 * inset - sp(80)
    local tb = textbox(book.title or "", face("title", sp(76)), inner, "center", INK, 0.05, COVER_PAPER)
    local at = book.author and textbox(string.upper(book.author), face("sans", sp(22)), inner, "center", G44, nil, COVER_PAPER) or nil
    local gap, rule_w, rule_h = sp(28), sp(80), sp(2)
    local total = (at and at:getSize().h + gap or 0) + rule_h + gap + tb:getSize().h
    local cy = y + math.floor((h - total) / 2)
    local cx = x + math.floor((w - inner) / 2)
    if at then
        at:paintTo(bb, cx, cy)
        cy = cy + at:getSize().h + gap
        at:free()
    end
    rect(bb, x + math.floor((w - rule_w) / 2), cy, rule_w, rule_h, INK)
    cy = cy + rule_h + gap
    tb:paintTo(bb, cx, cy)
    tb:free()
end

-- The cover, fitted whole into the box: never cropped, never stretched past
-- 1.5x its own pixels. Returns the rectangle it used.
function StreakScreen:cover(bb, x, y, w, h, px, book, align)
    local shadow = px(16)
    local maxw, maxh = w - 2 * shadow, h - shadow
    if maxw <= 0 or maxh <= 0 then return x, y, 0, 0 end
    local img = book.cover
    local iw, ih = 2, 3
    if img then
        -- Remember the cover's own size before the first scale replaces it.
        book.cover_w = book.cover_w or img:getWidth()
        book.cover_h = book.cover_h or img:getHeight()
        iw, ih = book.cover_w, book.cover_h
    end
    local ch = maxh
    local cw = math.floor(ch * iw / ih)
    if cw > maxw then
        cw = maxw
        ch = math.floor(cw * ih / iw)
    end
    if img and ch > ih * 1.5 then
        ch = math.floor(ih * 1.5)
        cw = math.floor(iw * 1.5)
    end
    local cx = align == "left" and x or x + math.floor((w - cw) / 2)
    local cy = y + math.floor((maxh - ch) / 2)
    rect(bb, cx + shadow, cy + shadow, cw, ch, GBB)
    if img then
        -- scaleBlitBuffer frees the buffer it is given, so scale once, keep
        -- the result as the model's cover, and reuse it on every repaint.
        if img:getWidth() ~= cw or img:getHeight() ~= ch then
            img = RenderImage:scaleBlitBuffer(img, cw, ch)
            book.cover = img
        end
        bb:blitFrom(img, cx, cy, 0, 0, cw, ch)
    else
        self:typesetCover(bb, cx, cy, cw, ch, book)
    end
    frame(bb, cx, cy, cw, ch, math.max(1, px(2)), INK)
    if book.finished then
        local t = text("Finished", face("title", px(44)), PAPER)
        local s = t:getSize()
        local bw, bh = s.w + px(80), s.h + px(20)
        local bx = cx + math.floor((cw - bw) / 2)
        local by = cy + ch - px(56) - bh
        rect(bb, bx, by, bw, bh, INK)
        t:paintTo(bb, bx + px(40), by + px(10))
        t:free()
    end
    return cx, cy, cw, ch
end

function StreakScreen:cell(bb, x, y, w, h, code, px)
    if code == "n" then
        local d = math.max(2, px(6))
        rect(bb, x + math.floor((w - d) / 2), y + math.floor((h - d) / 2), d, d, GBB)
    elseif code == "x" then
        frame(bb, x, y, w, h, math.max(1, px(2)), G99)
    elseif LEVEL[code] then
        rect(bb, x, y, w, h, LEVEL[code])
    elseif code == "te" then
        local t = math.max(1, px(2))
        dashed(bb, x, y, w, h, t, INK, math.max(2, px(6)), math.max(2, px(4)))
    elseif code == "tl" or code == "tm" or code == "th" then
        rect(bb, x, y, w, h, LEVEL[code:sub(2)])
        frame(bb, x, y, w, h, math.max(1, px(3)), INK)
    end
end

-- Four weeks of squares with day labels and a legend. Returns its height.
function StreakScreen:chain(bb, x, y, width, cell_h, gap, label_px, px, cells)
    local col = math.floor((width - 6 * gap) / 7)
    local lf = face("sans", label_px)
    local probe = text("M", lf)
    local lh = probe:getSize().h
    probe:free()
    local labels = { "M", "T", "W", "T", "F", "S", "S" }
    if bb then
        for i, l in ipairs(labels) do
            local t = text(l, lf, G55)
            local cx = x + (i - 1) * (col + gap)
            t:paintTo(bb, cx + math.floor((col - t:getSize().w) / 2), y)
            t:free()
        end
    end
    local gy = y + lh + px(8)
    if bb then
        for i, code in ipairs(cells or {}) do
            local r, c = math.floor((i - 1) / 7), (i - 1) % 7
            self:cell(bb, x + c * (col + gap), gy + r * (cell_h + gap), col, cell_h, code, px)
        end
    end
    local ly = gy + 4 * cell_h + 3 * gap + px(12)
    if bb then
        local less = text("less", lf, G55)
        less:paintTo(bb, x, ly)
        local sx = x + less:getSize().w + px(8)
        less:free()
        local sw = math.max(px(14), math.floor(label_px))
        local sy = ly + math.floor((lh - sw) / 2)
        self:cell(bb, sx, sy, sw, sw, "x", px)
        sx = sx + sw + px(8)
        for _, code in ipairs({ "l", "m", "h" }) do
            self:cell(bb, sx, sy, sw, sw, code, px)
            sx = sx + sw + px(8)
        end
        local more = text("more", lf, G55)
        more:paintTo(bb, sx, ly)
        more:free()
    end
    return (ly + lh) - y
end

-- Big streak number, its note, and the stats line. Returns its height.
function StreakScreen:streak(bb, x, y, w, px, stats, align)
    local nt = text(tostring(stats.streak or 0), face("number", px(120)), INK)
    local lt = text("day streak", face("sans", px(28)), INK)
    local ns, ls = nt:getSize(), lt:getSize()
    local talign = align == "center" and "center" or "left"
    local note = textbox(stats.note or "", face("serif", px(34)), w, talign, INK, 0.1)
    local line = textbox(stats.line or "", face("sans", px(22)), w, talign, G44, 0.15)
    local nh, lnh = note:getSize().h, line:getSize().h
    local total = ns.h + px(6) + nh + px(10) + lnh
    if bb then
        local row_w = ns.w + px(16) + ls.w
        local rx = align == "center" and x + math.floor((w - row_w) / 2) or x
        nt:paintTo(bb, rx, y)
        lt:paintTo(bb, rx + ns.w + px(16), y + nt:getBaseline() - lt:getBaseline())
        note:paintTo(bb, x, y + ns.h + px(6))
        line:paintTo(bb, x, y + ns.h + px(6) + nh + px(10))
    end
    nt:free(); lt:free(); note:free(); line:free()
    return total
end

-- Chain and streak side by side, vertically centred. Returns its height.
function StreakScreen:footer(bb, x, y, w, px, stats)
    local chain_w, gap = px(330), px(56)
    local sx, sw = x + chain_w + gap, w - chain_w - gap
    local ch = self:chain(nil, x, y, chain_w, px(36), px(8), px(18), px, stats.cells)
    local sh = self:streak(nil, sx, y, sw, px, stats, "left")
    local h = math.max(ch, sh)
    if bb then
        self:chain(bb, x, y + math.floor((h - ch) / 2), chain_w, px(36), px(8), px(18), px, stats.cells)
        self:streak(bb, sx, y + math.floor((h - sh) / 2), sw, px, stats, "left")
    end
    return h
end

-- Shown in place of the chain when Reading statistics is off.
function StreakScreen:hint(bb, x, y, w, px, align)
    local talign = align == "center" and "center" or "left"
    local note = textbox(Format.STATS_OFF_NOTE, face("serif", px(34)), w, talign, INK, 0.1)
    local sub = textbox(Format.STATS_OFF_HINT, face("sans", px(22)), w, talign, G44)
    local nh, sh = note:getSize().h, sub:getSize().h
    if bb then
        note:paintTo(bb, x, y)
        sub:paintTo(bb, x, y + nh + px(8))
    end
    note:free(); sub:free()
    return nh + px(8) + sh
end

-- -------------------------------------------------------------- layouts ---

function StreakScreen:paintPortrait(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1264, 1680)
    local left = x0 + ox + px(96)
    local cw = W - 2 * ox - 2 * px(96)
    local top, bottom = y0 + oy + px(80), y0 + H - oy - px(76)
    local gap = px(32)

    local y = top + self:header(bb, left, top, cw, px, m.header) + gap

    local fh, fy
    if m.stats then
        fh = self:footer(nil, left, 0, cw, px, m.stats)
        fy = bottom - fh
        self:footer(bb, left, fy, cw, px, m.stats)
    else
        fh = self:hint(nil, left, 0, cw, px, "center")
        fy = bottom - fh
        self:hint(bb, left, fy, cw, px, "center")
    end
    local rule_y = fy - px(30)
    rect(bb, left, rule_y, cw, math.max(1, px(1)), INK)

    local prog_y = rule_y - gap - px(22)
    self:progress(bb, left, prog_y, cw, px, m.book)

    local tb_h = self:titleBlock(nil, left, 0, cw, px, m.book, "center")
    local tb_y = prog_y - gap - tb_h
    self:titleBlock(bb, left, tb_y, cw, px, m.book, "center")

    self:cover(bb, left, y, cw, tb_y - gap - y, px, m.book, "center")
end

function StreakScreen:paintLandscape(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1680, 1264)
    local left = x0 + ox + px(88)
    local cw = W - 2 * ox - 2 * px(88)
    local top, bottom = y0 + oy + px(72), y0 + H - oy - px(64)
    local gap = px(32)

    local y = top + self:header(bb, left, top, cw, px, m.header) + px(36)
    local stage_h = bottom - y
    local _, _, cover_w = self:cover(bb, left, y, math.floor(cw * 0.46), stage_h, px, m.book, "left")
    local rx = left + cover_w + px(16) + px(72)
    local rw = left + cw - rx

    local tb_h = self:titleBlock(nil, rx, 0, rw, px, m.book, "left")
    local lower_h
    if m.stats then
        lower_h = self:chain(nil, rx, 0, px(330), px(36), px(8), px(18), px, m.stats.cells)
            + px(30) + self:streak(nil, rx, 0, rw, px, m.stats, "left")
    else
        lower_h = self:hint(nil, rx, 0, rw, px, "left")
    end
    local total = tb_h + gap + px(22) + gap + px(30) + lower_h
    local ry = y + math.max(0, math.floor((stage_h - total) / 2))

    self:titleBlock(bb, rx, ry, rw, px, m.book, "left")
    ry = ry + tb_h + gap
    self:progress(bb, rx, ry, rw, px, m.book)
    ry = ry + px(22) + gap
    rect(bb, rx, ry, rw, math.max(1, px(1)), INK)
    ry = ry + px(30)
    if m.stats then
        ry = ry + self:chain(bb, rx, ry, px(330), px(36), px(8), px(18), px, m.stats.cells) + px(30)
        self:streak(bb, rx, ry, rw, px, m.stats, "left")
    else
        self:hint(bb, rx, ry, rw, px, "left")
    end
end

-- Nothing to show a cover for: the chain takes the stage.
function StreakScreen:paintNoBook(bb, x0, y0, W, H, m)
    local landscape = W > H
    local px, ox, oy = scaler(W, H, landscape and 1680 or 1264, landscape and 1264 or 1680)
    local pad = landscape and 88 or 96
    local left = x0 + ox + px(pad)
    local cw = W - 2 * ox - 2 * px(pad)
    local top = y0 + oy + px(landscape and 72 or 80)
    local bottom = y0 + H - oy - px(landscape and 64 or 76)

    local y = top + self:header(bb, left, top, cw, px, m.header) + px(48)

    local title = textbox(Format.NO_BOOK_TITLE, face("title", px(62)), cw, "center", INK, 0.05)
    local sub = textbox(Format.NO_BOOK_SUB, face("sans", px(24)), cw, "center", G44)
    local th = title:getSize().h + px(8) + sub:getSize().h

    local chain_w = math.min(px(820), cw)
    local cell_h = landscape and px(64) or px(90)
    local chain_h, streak_h = 0, 0
    if m.stats then
        chain_h = self:chain(nil, left, 0, chain_w, cell_h, px(14), px(24), px, m.stats.cells)
        streak_h = self:streak(nil, left, 0, cw, px, m.stats, "center")
    else
        streak_h = self:hint(nil, left, 0, cw, px, "center")
    end
    local gap = px(56)
    local total = th + gap + (m.stats and (chain_h + gap) or 0) + streak_h
    local cy = y + math.max(0, math.floor((bottom - y - total) / 2))

    title:paintTo(bb, left, cy)
    sub:paintTo(bb, left, cy + title:getSize().h + px(8))
    title:free(); sub:free()
    cy = cy + th + gap
    if m.stats then
        self:chain(bb, left + math.floor((cw - chain_w) / 2), cy, chain_w, cell_h, px(14), px(24), px, m.stats.cells)
        cy = cy + chain_h + gap
        self:streak(bb, left, cy, cw, px, m.stats, "center")
    else
        self:hint(bb, left, cy, cw, px, "center")
    end
end

return StreakScreen
