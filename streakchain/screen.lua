--[[
Draws the model from streakchain/data.lua as design 6.4a ("Big book"): the
book on top (cover, title, time to the end, finish forecast), a full-width
timeline of the book, and the reader underneath (streak strip, note, this
week and books this year).

Layout is in the design's own units (a 1264x1680 portrait canvas, 1680x1264
in landscape) scaled to the real screen, except the cover: it is drawn at
its own pixel size and only ever shrunk to fit, never enlarged or reshaped.
Anything that fails to draw falls back to a plain "Sleeping" screen.
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
local G44, G55, G77 = gray(0x44), gray(0x55), gray(0x77)
local G99, GBB, GCC = gray(0x99), gray(0xBB), gray(0xCC)
local COVER_PAPER = gray(0xF7)

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

local function textbox(str, fc, width, align, color, line_height, bg, max_lines)
    local tb = TextBoxWidget:new{
        text = str, face = fc, width = width, alignment = align or "left",
        fgcolor = color or INK, line_height = line_height or 0.1, bgcolor = bg or PAPER,
    }
    if max_lines then
        local lh = tb:getLineHeight()
        if tb:getSize().h > lh * max_lines + 2 then
            tb:free()
            tb = TextBoxWidget:new{
                text = str, face = fc, width = width, alignment = align or "left",
                fgcolor = color or INK, line_height = line_height or 0.1, bgcolor = bg or PAPER,
                height = lh * max_lines, height_overflow_show_ellipsis = true,
            }
        end
    end
    return tb
end

local function rect(bb, x, y, w, h, c)
    if bb and w > 0 and h > 0 then bb:paintRect(x, y, w, h, c) end
end

local function frame(bb, x, y, w, h, t, c)
    if bb and w > 0 and h > 0 then bb:paintBorder(x, y, w, h, t, c) end
end

local function dashed(bb, x, y, w, h, t, c, dash, space)
    if not bb then return end
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
    local fc = face("sans", px(26))
    local left = text(string.upper(header.date or ""), fc, G44)
    local h = left:getSize().h
    if bb then left:paintTo(bb, x, y) end
    left:free()
    if header.battery then
        local t = text(string.upper(header.battery), face("sansBold", px(26)), PAPER)
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

function StreakScreen:typesetCover(bb, x, y, w, h, book)
    local s = h / 840
    local function sp(v) return math.max(1, math.floor(v * s + 0.5)) end
    rect(bb, x, y, w, h, COVER_PAPER)
    local inset = sp(28)
    frame(bb, x + inset, y + inset, w - 2 * inset, h - 2 * inset, 1, INK)
    local inner = w - 2 * inset - sp(80)
    local tb = textbox(book.title or "", face("title", sp(76)), inner, "center", INK, 0.05, COVER_PAPER, 4)
    local at = book.author and textbox(string.upper(book.author), face("sans", sp(24)), inner, "center", G44, nil, COVER_PAPER, 2) or nil
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

-- The size the cover will be drawn at: its own pixels, shrunk only to fit.
function StreakScreen:coverSize(book, maxw, maxh, px)
    local img = book.cover
    if img then
        book.cover_w = book.cover_w or img:getWidth()
        book.cover_h = book.cover_h or img:getHeight()
        local scale = math.min(1, maxw / book.cover_w, maxh / book.cover_h)
        return math.floor(book.cover_w * scale), math.floor(book.cover_h * scale)
    end
    local h = math.min(maxh, px(640))
    local w = math.floor(h * 2 / 3)
    if w > maxw then
        w = maxw
        h = math.floor(w * 3 / 2)
    end
    return w, h
end

function StreakScreen:cover(bb, x, y, cw, ch, px, book)
    local shadow = px(14)
    rect(bb, x + shadow, y + shadow, cw, ch, GBB)
    local img = book.cover
    if img then
        -- scaleBlitBuffer frees the buffer it is given, so scale once, keep
        -- the result as the model's cover, and reuse it on every repaint.
        if img:getWidth() ~= cw or img:getHeight() ~= ch then
            img = RenderImage:scaleBlitBuffer(img, cw, ch)
            book.cover = img
        end
        bb:blitFrom(img, x, y, 0, 0, cw, ch)
    else
        self:typesetCover(bb, x, y, cw, ch, book)
    end
    frame(bb, x, y, cw, ch, math.max(1, px(2)), INK)
    if book.finished then
        local t = text("Finished", face("title", math.max(px(24), math.min(px(40), math.floor(cw / 8)))), PAPER)
        local s = t:getSize()
        local pad = math.floor(s.h / 3)
        local bw, bh = s.w + 4 * pad, s.h + pad
        local bx = x + math.floor((cw - bw) / 2)
        local by = y + ch - math.floor(ch / 12) - bh
        rect(bb, bx, by, bw, bh, INK)
        t:paintTo(bb, bx + 2 * pad, by + math.floor(pad / 2))
        t:free()
    end
end

-- Hero: the number and its unit side by side, or stacked when that's too wide.
function StreakScreen:hero(bb, x, y, w, px, hero, compact)
    local size = compact and px(112) or px(150)
    local nt = text(hero[1], face("number", size))
    while nt:getSize().w > w and size > px(80) do
        nt:free()
        size = size - px(10)
        nt = text(hero[1], face("number", size))
    end
    local ut = text(hero[2], face("sans", px(36)))
    local ns, us = nt:getSize(), ut:getSize()
    local h
    if ns.w + px(16) + us.w <= w then
        h = ns.h
        if bb then
            nt:paintTo(bb, x, y)
            ut:paintTo(bb, x + ns.w + px(16), y + nt:getBaseline() - ut:getBaseline())
        end
    else
        h = ns.h + px(4) + us.h
        if bb then
            nt:paintTo(bb, x, y)
            ut:paintTo(bb, x, y + ns.h + px(4))
        end
    end
    nt:free(); ut:free()
    return h
end

-- The right-hand side of the book band: title and meta at the top, hero and
-- forecast at the bottom. Returns top height and bottom height.
function StreakScreen:bookText(bb, x, y, w, h, px, book, compact)
    local tb = textbox(book.title or "", face("title", px(64)), w, "left", INK, 0.05, PAPER, 2)
    local th = tb:getSize().h
    -- The author on its own line, then the progress line, which wraps rather
    -- than dropping the chapter's name.
    local mfc = face("sans", px(30))
    local author = book.author and text(book.author, mfc, G44, w) or nil
    local progress_text = book.progress or (book.meta and book.meta[1]) or ""
    local progress = textbox(progress_text, mfc, w, "left", G44, 0.1, PAPER, 2)
    local meta = {
        getSize = function()
            return { h = (author and author:getSize().h + px(4) or 0) + progress:getSize().h }
        end,
        paintTo = function(_, target, mx, my)
            if author then
                author:paintTo(target, mx, my)
                my = my + author:getSize().h + px(4)
            end
            progress:paintTo(target, mx, my)
        end,
        free = function()
            if author then author:free() end
            progress:free()
        end,
    }
    local mh = meta and meta:getSize().h or 0
    local top_h = th + px(8) + mh

    local bottom_h = 0
    local fc
    if book.hero then
        bottom_h = self:hero(nil, x, 0, w, px, book.hero, compact)
    end
    if book.forecast then
        fc = textbox(book.forecast.line, face("serif", compact and px(34) or px(40)), w, "left", INK, 0.1, PAPER, 2)
        bottom_h = bottom_h + px(14) + fc:getSize().h
    end

    if bb then
        tb:paintTo(bb, x, y)
        if meta then meta:paintTo(bb, x, y + th + px(8)) end
        local by = y + math.max(top_h + px(32), h - bottom_h)
        if book.hero then
            by = by + self:hero(bb, x, by, w, px, book.hero, compact)
        end
        if fc then fc:paintTo(bb, x, by + px(14)) end
    end
    tb:free()
    if meta then meta:free() end
    if fc then fc:free() end
    return top_h, bottom_h
end

-- Cover on the left, text on the right. Returns its height.
function StreakScreen:bookBand(bb, x, y, w, maxh, px, book)
    local shadow = px(14)
    local cw, ch = self:coverSize(book, math.floor(w * 0.52) - shadow, maxh - shadow, px)
    local tx = x + cw + shadow + px(48)
    local tw = x + w - tx
    local top_h, bottom_h = self:bookText(nil, tx, y, tw, ch, px, book)
    local h = math.max(ch + shadow, top_h + px(32) + bottom_h)
    if bb then
        self:cover(bb, x, y, cw, ch, px, book)
        self:bookText(bb, tx, y, tw, math.max(ch, h - shadow), px, book)
    end
    return h
end

-- Chapter names over the timeline: all of them when they fit, otherwise just
-- the current chapter's.
function StreakScreen:chapterLabels(x, w, px, book)
    local chapters = book.chapters or {}
    if #chapters == 0 then return {} end
    local fc = face("sans", px(24))
    local labels = {}
    local fits = true
    for i, c in ipairs(chapters) do
        local t = text(string.upper(c.title or ""), fc, G55)
        local lx = c.pos <= 0.001 and x or x + math.floor(w * c.pos) + px(12)
        labels[i] = { t = t, x = lx, w = t:getSize().w, pos = c.pos }
    end
    for i, l in ipairs(labels) do
        local limit = labels[i + 1] and (labels[i + 1].x - px(16)) or (x + w)
        if l.x + l.w > limit then fits = false end
    end
    if fits then return labels end
    local current
    for _, l in ipairs(labels) do
        if l.pos <= (book.pct or 0) + 1e-6 then current = l end
    end
    for _, l in ipairs(labels) do
        if l ~= current then l.t:free() end
    end
    if not current then return {} end
    current.x = math.max(x, math.min(current.x, x + w - current.w))
    return { current }
end

function StreakScreen:timeline(bb, x, y, w, px, book)
    local labels = self:chapterLabels(x, w, px, book)
    local lh = px(34)
    local top_h = #labels > 0 and (lh + px(10)) or 0
    local bar_h = px(40)
    local total = top_h + bar_h + px(10) + lh
    if not bb then
        for _, l in ipairs(labels) do l.t:free() end
        return total
    end
    for _, l in ipairs(labels) do
        l.t:paintTo(bb, l.x, y)
        l.t:free()
    end

    local by = y + top_h
    local pct = book.finished and 1 or math.max(0, math.min(1, book.pct or 0))
    local px_at = function(p) return x + math.floor(w * p) end
    local fh = px(14)
    local fy = by + math.floor((bar_h - fh) / 2)
    rect(bb, x, by + math.floor(bar_h / 2) - px(2), w, px(4), G99)

    local fc = book.forecast
    local today_end = pct
    if fc and not book.finished then
        today_end = pct + (1 - pct) * math.max(0, math.min(1, fc.today_share or 0))
        rect(bb, px_at(pct), fy, px_at(today_end) - px_at(pct), fh, GBB)
        if today_end < 1 then
            dashed(bb, px_at(today_end), fy, x + w - px_at(today_end), fh, math.max(1, px(2)), G77, px(8), px(6))
        end
    end
    rect(bb, x, fy, px_at(pct) - x, fh, INK)
    for _, t in ipairs(book.ticks or {}) do
        rect(bb, px_at(t) - math.floor(px(4) / 2), by, px(4), bar_h, G55)
    end
    rect(bb, x + w - px(4), by, px(4), bar_h, INK)
    local d = px(36)
    if not book.finished then
        local mx = math.max(x, math.min(x + w - d, px_at(pct) - math.floor(d / 2)))
        bb:paintRoundedRect(mx, by + math.floor((bar_h - d) / 2), d, d, INK, math.floor(d / 2))
    end

    -- Labels under the bar: position, TODAY, finish day. A label that doesn't
    -- fit its segment, or would touch another, is left out.
    local ly = by + bar_h + px(10)
    local taken = {}
    local function place(t, cx, lo, hi)
        local tw = t:getSize().w
        local lx = math.floor(cx - tw / 2)
        lx = math.max(lo, math.min(lx, hi - tw))
        if lx < lo or lx + tw > hi then t:free(); return end
        for _, r in ipairs(taken) do
            if lx < r[2] + px(12) and lx + tw + px(12) > r[1] then t:free(); return end
        end
        t:paintTo(bb, lx, ly)
        table.insert(taken, { lx, lx + tw })
        t:free()
    end
    if book.finished then
        place(text("FINISHED", face("sansBold", px(28))), x + w, x, x + w)
        return total
    end
    place(text(Format.percent(pct), face("sansBold", px(28))), px_at(pct), x, x + w)
    if fc then
        local lf = face("sans", px(24))
        if today_end > pct then
            place(text("TODAY", lf, G55), (px_at(pct) + px_at(today_end)) / 2, px_at(pct), px_at(today_end))
        end
        if fc.label and today_end < 1 then
            place(text(fc.label, lf, G55), (px_at(today_end) + x + w) / 2, px_at(today_end), x + w)
        end
    end
    return total
end

function StreakScreen:strip(bb, x, y, w, h, px, strip)
    local t = math.max(1, px(2))
    if strip.bar then
        local unit = w / strip.n
        rect(bb, x, y, math.floor(unit * strip.filled), h, INK)
        frame(bb, x, y, w, h, t, G99)
        if strip.pending then
            dashed(bb, x + math.floor(unit * strip.filled), y, math.max(px(8), math.floor(unit)), h, t, INK, px(8), px(6))
        end
        if strip.best > strip.filled then
            rect(bb, x + math.floor(unit * strip.best) - px(2), y - px(6), px(4), h + px(12), INK)
        end
        return
    end
    local gap = px(8)
    local cell = (w - gap * (strip.n - 1)) / strip.n
    for i = 1, strip.n do
        local cx = x + math.floor((i - 1) * (cell + gap))
        local cw = math.floor(cell)
        if i <= strip.filled then
            rect(bb, cx, y, cw, h, INK)
        elseif i == strip.filled + 1 and strip.pending then
            dashed(bb, cx, y, cw, h, t, INK, px(8), px(6))
        elseif i <= strip.best then
            frame(bb, cx, y, cw, h, t, G99)
        else
            frame(bb, cx, y, cw, h, t, GCC)
        end
    end
end

function StreakScreen:tile(bb, x, y, w, px, label, value, sub)
    local lt = text(string.upper(label), face("sans", px(24)), G55)
    local vt = text(value, face("number", px(64)), INK, w)
    local st = textbox(sub, face("sans", px(30)), w, "left", G44, 0.1, PAPER, 2)
    local h = px(2) + px(20) + lt:getSize().h + px(8) + vt:getSize().h + px(8) + st:getSize().h
    if bb then
        rect(bb, x, y, w, px(2), INK)
        local cy = y + px(22)
        lt:paintTo(bb, x, cy); cy = cy + lt:getSize().h + px(8)
        vt:paintTo(bb, x, cy); cy = cy + vt:getSize().h + px(8)
        st:paintTo(bb, x, cy)
    end
    lt:free(); vt:free(); st:free()
    return h
end

-- A number with its unit on the same baseline, and optional text flush right.
function StreakScreen:numberRow(bb, x, y, w, px, num, unit, right, num_px, unit_px, right_bold)
    local nt = text(num, face("number", num_px))
    local ut = text(unit, face("sans", unit_px))
    local rt = right and text(right, face(right_bold and "sansBold" or "sans", px(32)), right_bold and INK or G44) or nil
    local h = nt:getSize().h
    if bb then
        nt:paintTo(bb, x, y)
        local base = y + nt:getBaseline()
        ut:paintTo(bb, x + nt:getSize().w + px(12), base - ut:getBaseline())
        if rt then rt:paintTo(bb, x + w - rt:getSize().w, base - rt:getBaseline()) end
    end
    nt:free(); ut:free()
    if rt then rt:free() end
    return h
end

function StreakScreen:goalBar(bb, x, y, w, h, px, fraction)
    local t = math.max(1, px(2))
    rect(bb, x, y, math.floor(w * math.max(0, math.min(1, fraction or 0))), h, INK)
    frame(bb, x, y, w, h, t, G99)
end

-- The reader: today's goal (when one is set in Bookshelf), the streak and
-- its strip, the note, then this week and books this year.
function StreakScreen:readerBand(bb, x, y, w, px, stats)
    local daily = stats.daily
    local note = textbox(stats.note or "", face("serif", daily and px(36) or px(40)), w, "left", INK, 0.1, PAPER, 2)
    local tile_w = math.floor((w - px(40)) / 2)
    local tile_h = math.max(
        self:tile(nil, x, 0, tile_w, px, "This week", stats.week.value, stats.week.sub),
        self:tile(nil, x, 0, tile_w, px, "Books this year", stats.books.value, stats.books.sub))

    local goal_h, goal_bar = 0, px(24)
    if daily then
        goal_h = self:numberRow(nil, x, 0, w, px, daily.num, daily.unit, daily.right, px(96), px(34)) + px(12) + goal_bar + px(22)
    end
    local streak_num = daily and px(56) or px(96)
    local streak_unit = daily and px(30) or px(34)
    local streak_h = self:numberRow(nil, x, 0, w, px, tostring(stats.streak or 0), "day streak", stats.best_line, streak_num, streak_unit)
    local strip_h = daily and px(44) or px(56)
    local h = px(2) + px(30) + goal_h + streak_h + px(12) + strip_h + px(12) + note:getSize().h + px(26) + tile_h

    if bb then
        rect(bb, x, y, w, px(2), INK)
        local cy = y + px(32)
        if daily then
            cy = cy + self:numberRow(bb, x, cy, w, px, daily.num, daily.unit, daily.right, px(96), px(34), daily.done) + px(12)
            self:goalBar(bb, x, cy, w, goal_bar, px, daily.fraction)
            cy = cy + goal_bar + px(22)
        end
        cy = cy + self:numberRow(bb, x, cy, w, px, tostring(stats.streak or 0), "day streak", stats.best_line, streak_num, streak_unit) + px(12)
        self:strip(bb, x, cy, w, strip_h, px, stats.strip)
        cy = cy + strip_h + px(12)
        note:paintTo(bb, x, cy)
        cy = cy + note:getSize().h + px(26)
        self:tile(bb, x, cy, tile_w, px, "This week", stats.week.value, stats.week.sub)
        self:tile(bb, x + tile_w + px(40), cy, tile_w, px, "Books this year", stats.books.value, stats.books.sub)
    end
    note:free()
    return h
end

-- Shown in place of the reader band when Reading statistics is off.
function StreakScreen:hint(bb, x, y, w, px, align)
    local talign = align == "center" and "center" or "left"
    local note = textbox(Format.STATS_OFF_NOTE, face("serif", px(40)), w, talign, INK, 0.1)
    local sub = textbox(Format.STATS_OFF_HINT, face("sans", px(30)), w, talign, G44)
    local nh, sh = note:getSize().h, sub:getSize().h
    if bb then
        rect(bb, x, y, w, px(2), INK)
        note:paintTo(bb, x, y + px(38))
        sub:paintTo(bb, x, y + px(38) + nh + px(10))
    end
    note:free(); sub:free()
    return px(38) + nh + px(10) + sh
end

local function lower(self, bb, x, y, w, px, m)
    if m.stats then return self:readerBand(bb, x, y, w, px, m.stats) end
    return self:hint(bb, x, y, w, px, "left")
end

-- -------------------------------------------------------------- layouts ---

local MARGIN = { top = 56, side = 56, bottom = 52 }

function StreakScreen:paintPortrait(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1264, 1680)
    local left = x0 + ox + px(MARGIN.side)
    local cw = W - 2 * ox - 2 * px(MARGIN.side)
    local top, bottom = y0 + oy + px(MARGIN.top), y0 + H - oy - px(MARGIN.bottom)
    local min_gap = px(24)

    local hh = self:header(nil, left, 0, cw, px, m.header)
    local tl_h = self:timeline(nil, left, 0, cw, px, m.book)
    local lo_h = lower(self, nil, left, 0, cw, px, m)
    local band_max = (bottom - top) - hh - tl_h - lo_h - 3 * min_gap
    local band_h = self:bookBand(nil, left, 0, cw, band_max, px, m.book)
    local gap = math.max(min_gap, math.floor(((bottom - top) - hh - band_h - tl_h - lo_h) / 3))

    local y = top
    self:header(bb, left, y, cw, px, m.header)
    y = y + hh + gap
    self:bookBand(bb, left, y, cw, band_max, px, m.book)
    y = y + band_h + gap
    self:timeline(bb, left, y, cw, px, m.book)
    lower(self, bb, left, bottom - lo_h, cw, px, m)
end

-- Landscape: the cover full height on the left; the book's text, the
-- timeline and the reader stacked on the right.
function StreakScreen:paintLandscape(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1680, 1264)
    local left = x0 + ox + px(MARGIN.side)
    local cw = W - 2 * ox - 2 * px(MARGIN.side)
    local top, bottom = y0 + oy + px(MARGIN.top), y0 + H - oy - px(MARGIN.bottom)
    local min_gap = px(28)

    local hh = self:header(bb, left, top, cw, px, m.header)
    local y = top + hh + px(36)
    local stage_h = bottom - y
    local shadow = px(14)
    local cvw, cvh = self:coverSize(m.book, math.floor(cw * 0.42) - shadow, stage_h - shadow, px)
    self:cover(bb, left, y + math.floor((stage_h - shadow - cvh) / 2), cvw, cvh, px, m.book)

    local rx = left + cvw + shadow + px(56)
    local rw = left + cw - rx
    local top_h, bottom_h = self:bookText(nil, rx, 0, rw, 0, px, m.book, true)
    local text_h = top_h + px(32) + bottom_h
    local tl_h = self:timeline(nil, rx, 0, rw, px, m.book)
    local lo_h = lower(self, nil, rx, 0, rw, px, m)
    local gap = math.max(min_gap, math.floor((stage_h - text_h - tl_h - lo_h) / 2))

    self:bookText(bb, rx, y, rw, text_h, px, m.book, true)
    local tl_y = y + text_h + gap
    self:timeline(bb, rx, tl_y, rw, px, m.book)
    -- Never let the reader band ride up into the timeline.
    lower(self, bb, rx, math.max(bottom - lo_h, tl_y + tl_h + min_gap), rw, px, m)
end

-- Nothing to show a cover for: a short line, then the reader band.
function StreakScreen:paintNoBook(bb, x0, y0, W, H, m)
    local landscape = W > H
    local px, ox, oy = scaler(W, H, landscape and 1680 or 1264, landscape and 1264 or 1680)
    local left = x0 + ox + px(MARGIN.side)
    local cw = W - 2 * ox - 2 * px(MARGIN.side)
    local top, bottom = y0 + oy + px(MARGIN.top), y0 + H - oy - px(MARGIN.bottom)

    local hh = self:header(bb, left, top, cw, px, m.header)
    local lo_h = lower(self, nil, left, 0, cw, px, m)
    local lo_y = bottom - lo_h
    lower(self, bb, left, lo_y, cw, px, m)

    local title = textbox(Format.NO_BOOK_TITLE, face("title", px(72)), cw, "center", INK, 0.05)
    local sub = textbox(Format.NO_BOOK_SUB, face("sans", px(30)), cw, "center", G44)
    local th = title:getSize().h + px(12) + sub:getSize().h
    local area_top = top + hh
    local ty = area_top + math.max(0, math.floor((lo_y - area_top - th) / 2))
    title:paintTo(bb, left, ty)
    sub:paintTo(bb, left, ty + title:getSize().h + px(12))
    title:free(); sub:free()
end

return StreakScreen
