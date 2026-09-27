--[[
Draws the model from streakchain/data.lua as design 7b ("Two-column ledger"):
the book on top (cover, title, the next step, time to the end, time in the
book so far) over its chapter bar; then the ledger, Today and Goals side by
side; then the habit: the day streak with its flame, and a three-month
calendar of reading days.

Layout is in the design's own units (a 1264x1680 portrait canvas, 1680x1264
in landscape) scaled to the real screen, except the cover: it is drawn at
its own pixel size and only ever shrunk to fit, never enlarged or reshaped.
Text sits in CSS-style line boxes so rows share baselines as they do in the
design. Anything that fails to draw falls back to a plain "Sleeping" screen.
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

local Chain = require("streakchain/chain")
local Format = require("streakchain/format")

local Screen = Device.screen

local function gray(v) return Blitbuffer.Color8(v) end
local PAPER = Blitbuffer.COLOR_WHITE
local INK = gray(0x11)
local G44, G55, G77 = gray(0x44), gray(0x55), gray(0x77)
local G99, GBB = gray(0x99), gray(0xBB)
local COVER_PAPER = gray(0xF7)

-- The flame's SVGs ship beside this file.
local FLAME_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./") .. "flame/"

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

-- What the paint in progress put where, for tools/render.lua to check that
-- nothing overlaps, spills off the screen, or runs into its neighbour.
local log

local function mark(name, x, y, w, h)
    if log then table.insert(log.boxes, { name = name, x = x, y = y, w = w, h = h }) end
end

local function clash(what)
    if log then table.insert(log.clashes, what) end
end

local function text(str, fc, color, max_w)
    return TextWidget:new{ text = str, face = fc, fgcolor = color or INK, padding = 0, max_width = max_w }
end

-- Wrapped text with lines lh px apart (a CSS line-height), at most max_lines.
local function textbox(str, fc, width, align, color, lh, bg, max_lines)
    local line_height = lh and (lh / fc.size - 1) or 0.1
    local tb = TextBoxWidget:new{
        text = str, face = fc, width = width, alignment = align or "left",
        fgcolor = color or INK, line_height = line_height, bgcolor = bg or PAPER,
    }
    if max_lines then
        local h = tb:getLineHeight()
        if tb:getSize().h > h * max_lines + 2 then
            tb:free()
            tb = TextBoxWidget:new{
                text = str, face = fc, width = width, alignment = align or "left",
                fgcolor = color or INK, line_height = line_height, bgcolor = bg or PAPER,
                height = h * max_lines, height_overflow_show_ellipsis = true,
            }
        end
    end
    return tb
end

-- One line of text in a line box lh px tall, its glyphs centred in the box
-- the way a browser centres them. base is the baseline's offset in the box.
local function line(str, role, size, color, lh, max_w)
    local t = text(str, face(role, size), color, max_w)
    local s = t:getSize()
    return { t = t, w = s.w, lh = lh, base = math.floor((lh - s.h) / 2) + t:getBaseline() }
end

local function put(bb, l, x, baseline)
    if bb then l.t:paintTo(bb, math.floor(x), math.floor(baseline) - l.t:getBaseline()) end
end

local function free(...)
    for _, l in ipairs({ ... }) do
        if l then (l.t or l):free() end
    end
end

local function rect(bb, x, y, w, h, c)
    if bb and w > 0 and h > 0 then bb:paintRect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), c) end
end

local function frame(bb, x, y, w, h, t, c)
    if bb and w > 0 and h > 0 then bb:paintBorder(math.floor(x), math.floor(y), math.floor(w), math.floor(h), t, c) end
end

--[[
An anti-aliased disc (r_in nil) or ring, blended over what is already
there. dash = { on, off } breaks the ring into dashes, evened out so they
meet cleanly all the way round.
]]
local function round(bb, cx, cy, r_out, r_in, color, dash)
    if not bb then return end
    local c8 = color:getColor8().a
    local bw, bh = bb:getWidth(), bb:getHeight()
    local x0, x1 = math.max(0, math.floor(cx - r_out)), math.min(bw - 1, math.ceil(cx + r_out))
    local y0, y1 = math.max(0, math.floor(cy - r_out)), math.min(bh - 1, math.ceil(cy + r_out))
    local period, on
    if dash then
        local n = math.max(1, math.floor(2 * math.pi * (r_out + r_in) / 2 / (dash[1] + dash[2]) + 0.5))
        period = 2 * math.pi / n
        on = period * dash[1] / (dash[1] + dash[2])
    end
    for yy = y0, y1 do
        local dy = yy + 0.5 - cy
        for xx = x0, x1 do
            local dx = xx + 0.5 - cx
            local d = math.sqrt(dx * dx + dy * dy)
            local a = r_out + 0.5 - d
            if r_in then a = math.min(a, d - r_in + 0.5) end
            if a > 0 and dash and (math.atan2(dy, dx) + math.pi) % period > on then a = 0 end
            if a >= 1 then
                bb:setPixel(xx, yy, color)
            elseif a > 0 then
                local old = bb:getPixel(xx, yy):getColor8().a
                bb:setPixel(xx, yy, Blitbuffer.Color8(math.floor(old + (c8 - old) * a + 0.5)))
            end
        end
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

StreakScreen.FLAME_DIR = FLAME_DIR

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
    log = { boxes = {}, clashes = {} }
    self.layout = log
    local ok, err = pcall(self.paintScreen, self, bb, x, y)
    log = nil
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
    if W > H then
        return self:paintLandscape(bb, x, y, W, H, m)
    end
    return self:paintPortrait(bb, x, y, W, H, m)
end

-- ---------------------------------------------------------------- header ---

function StreakScreen:header(bb, x, y, w, px, header)
    header = header or {}
    if bb then mark("header", x, y, w, px(32)) end
    local left = line(string.upper(header.date or ""), "sans", px(26), G44, px(32))
    local base = y + left.base
    put(bb, left, x, base)
    free(left)
    if header.battery then
        local t = text(string.upper(header.battery), face("sansBold", px(26)), PAPER)
        local s = t:getSize()
        local pw, ph = s.w + px(32), s.h + px(12)
        if bb then
            rect(bb, x + w - pw, base - t:getBaseline() - px(6), pw, ph, INK)
            t:paintTo(bb, x + w - pw + px(16), base - t:getBaseline())
        end
        t:free()
    else
        local right = line("SLEEPING", "sans", px(26), G44, px(32))
        put(bb, right, x + w - right.w, base)
        free(right)
    end
    return px(32)
end

-- ------------------------------------------------------------------ book ---

function StreakScreen:typesetCover(bb, x, y, w, h, book)
    local s = h / 840
    local function sp(v) return math.max(1, math.floor(v * s + 0.5)) end
    rect(bb, x, y, w, h, COVER_PAPER)
    local inset = sp(28)
    frame(bb, x + inset, y + inset, w - 2 * inset, h - 2 * inset, 1, INK)
    local inner = w - 2 * inset - sp(80)
    local tb = textbox(book.title or "", face("title", sp(76)), inner, "center", INK, sp(80), COVER_PAPER, 4)
    local at = book.author and textbox(string.upper(book.author), face("sans", sp(24)), inner, "center", G44, sp(26), COVER_PAPER, 2) or nil
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
        local t = text(Format.FINISHED, face("title", math.max(px(24), math.min(px(40), math.floor(cw / 8)))), PAPER)
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

-- Hero: the number and its unit on one baseline, or stacked when too wide.
function StreakScreen:hero(bb, x, y, w, px, hero)
    local size = px(110)
    local num = line(hero[1], "number", size, INK, px(110))
    while num.w > w and size > px(72) do
        free(num)
        size = size - px(8)
        num = line(hero[1], "number", size, INK, px(110))
    end
    local unit = line(hero[2], "sans", px(36), INK, px(44), w)
    if bb and num.w > w then clash("hero wider than its column: " .. hero[1]) end
    local h
    if num.w + px(16) + unit.w <= w then
        local base = math.max(num.base, unit.base)
        h = base + math.max(num.lh - num.base, unit.lh - unit.base)
        put(bb, num, x, y + base)
        put(bb, unit, x + num.w + px(16), y + base)
    else
        h = num.lh + unit.lh
        put(bb, num, x, y + num.base)
        put(bb, unit, x, y + num.lh + unit.base)
    end
    free(num, unit)
    return h
end

--[[
The text beside the cover: title, author and next step at the top; time to
the end and time in the book so far at the bottom, as far down as h allows.
Returns the height of the top part and of the bottom part.
]]
function StreakScreen:bookText(bb, x, y, w, h, px, book)
    local title = textbox(book.title or "", face("title", px(64)), w, "left", INK, px(90), PAPER, 2)
    local author = book.author and line(book.author, "sans", px(30), G44, px(36), w) or nil
    local step = book.step and textbox(book.step, face("sans", px(30)), w, "left", G44, px(36), PAPER, 2) or nil
    local top_h = title:getSize().h
    if author then top_h = top_h + px(8) + author.lh end
    if step then top_h = top_h + (author and px(4) or px(8)) + step:getSize().h end

    local so_far = book.so_far and line(book.so_far, "sans", px(30), G44, px(36), w) or nil
    if bb and so_far and so_far.t:isTruncated() then clash("time in the book cut short") end
    local hero_h = book.hero and self:hero(nil, x, 0, w, px, book.hero) or 0
    local bottom_h = hero_h
    if so_far then bottom_h = bottom_h + (book.hero and px(24) or 0) + so_far.lh end

    if bb then
        local cy = y
        title:paintTo(bb, x, cy)
        cy = cy + title:getSize().h
        if author then
            cy = cy + px(8)
            put(bb, author, x, cy + author.base)
            cy = cy + author.lh
        end
        if step then
            cy = cy + (author and px(4) or px(8))
            step:paintTo(bb, x, cy)
        end
        local by = y + math.max(top_h + px(32), h - bottom_h)
        if book.hero then
            by = by + self:hero(bb, x, by, w, px, book.hero) + px(24)
        end
        if so_far then put(bb, so_far, x, by + so_far.base) end
    end
    title:free()
    if step then step:free() end
    free(author, so_far)
    return top_h, bottom_h
end

-- Cover on the left, text on the right. Returns its height.
function StreakScreen:bookBand(bb, x, y, w, max_cover_h, px, book)
    local shadow = px(14)
    local cw, ch = self:coverSize(book, math.floor(w * 0.42) - shadow, max_cover_h, px)
    local tx = x + cw + shadow + px(48)
    local tw = x + w - tx
    local top_h, bottom_h = self:bookText(nil, tx, y, tw, ch, px, book)
    local text_h = math.max(ch, top_h + px(32) + bottom_h)
    if bb then
        self:cover(bb, x, y, cw, ch, px, book)
        self:bookText(bb, tx, y, tw, text_h, px, book)
        mark("cover", x, y, cw + shadow, ch + shadow)
        mark("book text", tx, y, tw, text_h)
    end
    return math.max(ch + shadow, text_h)
end

-- The book's bar: its chapters as marks, the current chapter's two marks
-- full height, and the reading position.
function StreakScreen:chapterBar(bb, x, y, w, px, book)
    local H = px(40)
    if not bb then return H end
    mark("chapter bar", x, y, w, H)
    local pct = book.finished and 1 or math.max(0, math.min(1, book.pct or 0))
    local function at(p) return x + math.floor(w * p + 0.5) end
    rect(bb, x, y + px(18), w, px(4), G99)
    rect(bb, x, y + px(13), at(pct) - x, px(14), INK)
    local from, to = Chain.chapterBounds(book.ticks, pct)
    for _, t in ipairs(book.ticks or {}) do
        if t == from or t == to then
            rect(bb, at(t) - px(2), y, px(4), H, G55)
        else
            rect(bb, at(t) - px(2), y + px(8), px(4), px(24), G55)
        end
    end
    rect(bb, x + w - px(4), y, px(4), H, INK)
    if not book.finished then
        local r = px(18)
        round(bb, math.max(x + r, math.min(x + w - r, x + w * pct)), y + H / 2, r, nil, INK)
    end
    return H
end

-- The whole book block: band, then the bar. Returns its height.
function StreakScreen:bookBlock(bb, x, y, w, max_cover_h, px, book)
    local band = self:bookBand(bb, x, y, w, max_cover_h, px, book)
    self:chapterBar(bb, x, y + band + px(36), w, px, book)
    return band + px(36) + px(40)
end

-- Nothing to show a cover for: a short line in the book's place.
function StreakScreen:noBook(bb, x, y, w, px)
    local title = textbox(Format.NO_BOOK_TITLE, face("title", px(72)), w, "center", INK, px(90))
    local sub = textbox(Format.NO_BOOK_SUB, face("sans", px(30)), w, "center", G44, px(36))
    local h = title:getSize().h + px(12) + sub:getSize().h
    if bb then
        mark("no book", x, y, w, h)
        title:paintTo(bb, x, y)
        sub:paintTo(bb, x, y + title:getSize().h + px(12))
    end
    title:free(); sub:free()
    return h
end

-- ---------------------------------------------------------------- ledger ---

local function heading(bb, x, y, px, label)
    local l = line(string.upper(label), "sans", px(24), G55, px(30))
    put(bb, l, x, y + l.base)
    free(l)
    return px(30)
end

-- A left label and a right value on one baseline. Returns the line's height.
local function pair(bb, x, y, w, left, right, min_gap)
    if bb and left.w + min_gap + right.w > w then clash("row runs into its value: " .. left.t.text) end
    local base = math.max(left.base, right.base)
    put(bb, left, x, y + base)
    put(bb, right, x + w - right.w, y + base)
    return base + math.max(left.lh - left.base, right.lh - right.base)
end

local function meter(bb, x, y, w, h, px, fraction)
    rect(bb, x, y, math.floor(w * math.max(0, math.min(1, fraction or 0))), h, INK)
    frame(bb, x, y, w, h, math.max(1, px(2)), G99)
end

-- One cell per book, filled for each one finished.
local function segments(bb, x, y, w, h, px, n, filled)
    local gap = px(6)
    local cell = (w - gap * (n - 1)) / n
    for i = 1, n do
        local cx = x + math.floor((i - 1) * (cell + gap))
        local cw = math.floor(x + (i - 1) * (cell + gap) + cell) - cx
        if i <= filled then
            rect(bb, cx, y, cw, h, INK)
        else
            frame(bb, cx, y, cw, h, math.max(1, px(2)), G99)
        end
    end
end

-- Today: minutes against the daily goal, its bar, then the rows.
function StreakScreen:todayColumn(bb, x, y, w, px, today)
    local cy = y + heading(bb, x, y, px, "Today") + px(8)
    local num = line(today.num, "number", px(96), INK, px(96))
    local unit = line(today.unit, "sans", px(32), INK, px(40), w - num.w - px(12))
    if bb and unit.t:isTruncated() then clash("today's unit cut short") end
    local base = math.max(num.base, unit.base)
    put(bb, num, x, cy + base)
    put(bb, unit, x + num.w + px(12), cy + base)
    cy = cy + base + math.max(num.lh - num.base, unit.lh - unit.base)
    free(num, unit)
    if today.fraction then
        cy = cy + px(16)
        if bb then meter(bb, x, cy, w, px(24), px, today.fraction) end
        cy = cy + px(24)
    end
    cy = cy + px(14)
    for i, row in ipairs(today.rows) do
        local l = line(row[1], "sans", px(30), INK, px(40))
        local r = line(row[2], "number", px(36), INK, px(40))
        cy = cy + px(10) + pair(bb, x, cy + px(10), w, l, r, px(16)) + px(10)
        free(l, r)
        if i < #today.rows then
            rect(bb, x, cy, w, px(2), GBB)
            cy = cy + px(2)
        end
    end
    if bb then mark("today", x, y, w, cy - y) end
    return cy - y
end

-- Goals: a row and a bar for each of Bookshelf's goals that is on, then the
-- year's reading time.
function StreakScreen:goalsColumn(bb, x, y, w, px, goals, year)
    local cy = y + heading(bb, x, y, px, #goals > 0 and "Goals" or "This year") + px(8)
    for _, g in ipairs(goals) do
        local l = line(g.label, "number", px(36), INK, px(44))
        local r = line(g.value, "sans", px(30), G44, px(44))
        cy = cy + px(12) + pair(bb, x, cy + px(12), w, l, r, px(16)) + px(8)
        free(l, r)
        if bb then
            if g.segments then
                segments(bb, x, cy, w, px(14), px, g.segments, g.filled)
            else
                meter(bb, x, cy, w, px(14), px, g.fraction)
            end
        end
        cy = cy + px(14) + px(16)
        rect(bb, x, cy, w, px(2), GBB)
        cy = cy + px(2)
    end
    local l = line(year.label, "sans", px(30), INK, px(40))
    local r = line(year.value, "number", px(36), INK, px(40))
    cy = cy + px(10) + pair(bb, x, cy + px(10), w, l, r, px(16)) + px(10)
    free(l, r)
    if bb then mark("goals", x, y, w, cy - y) end
    return cy - y
end

-- ----------------------------------------------------------------- habit ---

-- Draws one flame from its SVG at w x h. Returns false if it couldn't.
function StreakScreen:paintFlame(bb, x, y, w, h, variant)
    local img, straight = RenderImage:renderSVGImageFile(FLAME_DIR .. variant .. ".svg", w, h)
    if not img then return false end
    if straight then
        bb:alphablitFrom(img, x, y, 0, 0, img:getWidth(), img:getHeight())
    else
        bb:pmulalphablitFrom(img, x, y, 0, 0, img:getWidth(), img:getHeight())
    end
    img:free()
    return true
end

-- The flame, the day streak and the best run on one row, then the note.
function StreakScreen:streakRow(bb, x, y, w, px, stats)
    local flame = stats.flame
    local color = flame.muted and G77 or INK
    local row_h = px(64)
    local num = line(tostring(stats.streak or 0), "number", px(56), color, px(60))
    local unit = line("day streak", "sans", px(30), color, px(36))
    local best = stats.best_line and line(stats.best_line, "sans", px(30), G44, px(36)) or nil
    local note = line(stats.note or "", "sans", px(26), G44, px(34), w)
    if bb and note.t:isTruncated() then clash("streak note cut short") end
    local box_top = y + row_h - num.lh
    local base = box_top + num.base
    if bb then
        mark("streak", x, y, w, row_h + px(10) + px(34))
        if px(flame.w) + px(14) + num.w + px(12) + unit.w + (best and px(24) + best.w or 0) > w then
            clash("streak row runs into the best run")
        end
        local fw, fh = px(flame.w), px(flame.h)
        self:paintFlame(bb, x, y + row_h - px(flame.drop) - fh, fw, fh, flame.variant)
        local nx = x + fw + px(14)
        put(bb, num, nx, base)
        put(bb, unit, nx + num.w + px(12), base)
        if best then put(bb, best, x + w - best.w, base) end
        put(bb, note, x, y + row_h + px(10) + note.base)
    end
    free(num, unit, best, note)
    return row_h + px(10) + px(34)
end

-- Three months of reading days, Monday-first, with the current run joined up.
function StreakScreen:calendar(bb, x, y, w, px, months, col_gap)
    local n = #months
    local mw = (w - col_gap * (n - 1)) / n
    local gap = px(6)
    local cell = (mw - gap * 6) / 7
    local pitch = px(40) + px(12)
    local rows = 0
    for _, month in ipairs(months) do
        rows = math.max(rows, math.ceil((month.offset + #month.days) / 7))
    end
    local grid_top = px(40) + px(10) + px(26) + px(8)
    local h = grid_top + rows * px(40) + (rows - 1) * px(12)
    if not bb then return h end
    mark("calendar", x, y, w, h)
    if cell < px(36) then clash("calendar days narrower than their circles") end

    local r = px(18)
    local ring = math.max(1, px(2))
    local link_h = px(6)
    local dash = { px(6), px(4) }
    for i, month in ipairs(months) do
        local mx = x + (i - 1) * (mw + col_gap)
        local name = line(month.name or "", "number", px(34), INK, px(40), mw)
        put(bb, name, mx, y + name.base)
        free(name)
        for c, letter in ipairs(Format.WEEKDAYS) do
            local l = line(letter, "sans", px(20), G55, px(26))
            put(bb, l, mx + (c - 1) * (cell + gap) + (cell - l.w) / 2, y + px(50) + l.base)
            free(l)
        end
        local function centre(day)
            local idx = month.offset + day - 1
            local col, row = idx % 7, math.floor(idx / 7)
            return mx + col * (cell + gap) + cell / 2, y + grid_top + row * pitch + px(20), col
        end
        -- The run's links go under the circles: centre to centre within a
        -- week, and out to the cell's edge where the run wraps or changes month.
        for day, d in ipairs(month.days) do
            local cx, cy, col = centre(day)
            local ly = math.floor(cy - link_h / 2)
            if d.joins_next then
                if col < 6 and day < #month.days then
                    rect(bb, cx, ly, cell + gap, link_h, INK)
                else
                    rect(bb, cx, ly, cell / 2, link_h, INK)
                end
            end
            if d.joins_prev and (col == 0 or day == 1) then
                rect(bb, cx - cell / 2, ly, cell / 2, link_h, INK)
            end
        end
        for day, d in ipairs(month.days) do
            local cx, cy = centre(day)
            if d.level == "f" then
                round(bb, cx, cy, r, r - ring, GBB, dash)
            elseif d.level == "o" then
                round(bb, cx, cy, r, r - ring, GBB)
            else
                round(bb, cx, cy, r, nil, d.level == "h" and INK or d.level == "m" and G77 or GBB)
            end
            if d.today then round(bb, cx, cy, r + px(6), r + px(3), INK) end
        end
    end
    return h
end

function StreakScreen:habitBlock(bb, x, y, w, px, stats, col_gap)
    local sh = self:streakRow(bb, x, y, w, px, stats)
    local ch = self:calendar(bb, x, y + sh + px(16), w, px, stats.calendar, col_gap)
    return sh + px(16) + ch
end

-- Shown in place of the ledger and the calendar when Reading statistics is off.
function StreakScreen:hint(bb, x, y, w, px)
    local note = textbox(Format.STATS_OFF_NOTE, face("serif", px(40)), w, "left", INK, px(52))
    local sub = textbox(Format.STATS_OFF_HINT, face("sans", px(30)), w, "left", G44, px(36))
    local nh, sh = note:getSize().h, sub:getSize().h
    if bb then
        mark("hint", x, y, w, px(26) + nh + px(8) + sh)
        rect(bb, x, y, w, px(2), INK)
        note:paintTo(bb, x, y + px(26))
        sub:paintTo(bb, x, y + px(26) + nh + px(8))
    end
    note:free(); sub:free()
    return px(26) + nh + px(8) + sh
end

-- -------------------------------------------------------------- layouts ---

local MARGIN = { top = 56, side = 56, bottom = 52 }
local COVER_H = 420        -- the design's cover height beside the ledger
local COVER_H_ALONE = 640  -- with no ledger under it (statistics off)

--[[
Stacks blocks from top to bottom with the free space shared out evenly
between them, like the design's space-between column. Each block is
{ h = height, paint = function(y) }.
]]
local function stack(bb, top, bottom, blocks, min_gap)
    local used = 0
    for _, b in ipairs(blocks) do used = used + b.h end
    local gap = math.max(min_gap, math.floor((bottom - top - used) / math.max(1, #blocks - 1)))
    local y = top
    for _, b in ipairs(blocks) do
        if bb then b.paint(y) end
        y = y + b.h + gap
    end
end

-- The tallest cover that still leaves room for everything else: the design's
-- height when it fits, shorter on a crowded screen.
local function coverRoom(px, avail, others, n_gaps, want)
    local room = avail - others - n_gaps * px(24) - px(36) - px(40) - px(14)
    return math.max(px(160), math.min(px(want), room))
end

function StreakScreen:paintPortrait(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1264, 1680)
    local left = x0 + ox + px(MARGIN.side)
    local cw = W - 2 * ox - 2 * px(MARGIN.side)
    local top, bottom = y0 + oy + px(MARGIN.top), y0 + H - oy - px(MARGIN.bottom)
    local col_gap = px(56)
    local col_w = math.floor((cw - col_gap) / 2)

    local blocks = { { h = px(32), paint = function(y) self:header(bb, left, y, cw, px, m.header) end } }
    local lower = {}
    if m.stats then
        local s = m.stats
        local ledger_h = px(2) + px(24) + math.max(
            self:todayColumn(nil, left, 0, col_w, px, s.today),
            self:goalsColumn(nil, left, 0, col_w, px, s.goals, s.year))
        table.insert(lower, { h = ledger_h, paint = function(y)
            rect(bb, left, y, cw, px(2), INK)
            self:todayColumn(bb, left, y + px(26), col_w, px, s.today)
            self:goalsColumn(bb, left + col_w + col_gap, y + px(26), cw - col_w - col_gap, px, s.goals, s.year)
        end })
        table.insert(lower, { h = self:habitBlock(nil, left, 0, cw, px, s, px(48)), paint = function(y)
            self:habitBlock(bb, left, y, cw, px, s, px(48))
        end })
    else
        table.insert(lower, { h = self:hint(nil, left, 0, cw, px), paint = function(y) self:hint(bb, left, y, cw, px) end })
    end
    local lower_h = 0
    for _, b in ipairs(lower) do lower_h = lower_h + b.h end

    if m.book then
        local cover_h = coverRoom(px, bottom - top, px(32) + lower_h, #lower + 1,
            m.stats and COVER_H or COVER_H_ALONE)
        table.insert(blocks, { h = self:bookBlock(nil, left, 0, cw, cover_h, px, m.book), paint = function(y)
            self:bookBlock(bb, left, y, cw, cover_h, px, m.book)
        end })
    else
        table.insert(blocks, { h = self:noBook(nil, left, 0, cw, px), paint = function(y) self:noBook(bb, left, y, cw, px) end })
    end
    for _, b in ipairs(lower) do table.insert(blocks, b) end
    stack(bb, top, bottom, blocks, px(24))
end

--[[
Landscape: the book and the habit on the left, the ledger on the right,
Today level with the book and Goals level with the streak. Without
statistics it's the portrait order across the full width.
]]
function StreakScreen:paintLandscape(bb, x0, y0, W, H, m)
    local px, ox, oy = scaler(W, H, 1680, 1264)
    local left = x0 + ox + px(MARGIN.side)
    local cw = W - 2 * ox - 2 * px(MARGIN.side)
    local top, bottom = y0 + oy + px(MARGIN.top), y0 + H - oy - px(MARGIN.bottom)
    if not m.stats then
        return self:paintPortraitOrder(bb, left, top, bottom, cw, px, m)
    end
    local s = m.stats
    local rw = px(500)
    local lw = cw - rw - px(56)
    local rx = left + lw + px(56)

    self:header(bb, left, top, cw, px, m.header)
    local habit_h = self:habitBlock(nil, left, 0, lw, px, s, px(32))
    local habit_y = bottom - habit_h
    local body
    if m.book then
        local cover_h = coverRoom(px, bottom - top, px(32) + habit_h, 2, COVER_H)
        local book_h = self:bookBlock(nil, left, 0, lw, cover_h, px, m.book)
        body = top + px(32) + math.max(px(24), math.floor((habit_y - top - px(32) - book_h) / 2))
        self:bookBlock(bb, left, body, lw, cover_h, px, m.book)
    else
        body = top + px(32) + px(24)
        local book_h = self:noBook(nil, left, 0, lw, px)
        self:noBook(bb, left, body + math.floor((habit_y - body - book_h) / 2), lw, px)
    end
    self:habitBlock(bb, left, habit_y, lw, px, s, px(32))

    local today_h = px(26) + self:todayColumn(nil, rx, 0, rw, px, s.today)
    local goals_h = px(26) + self:goalsColumn(nil, rx, 0, rw, px, s.goals, s.year)
    local today_y = body
    -- Goals level with the streak when there is room, else under Today.
    local goals_y = math.min(math.max(habit_y, today_y + today_h + px(40)), bottom - goals_h)
    rect(bb, rx, today_y, rw, px(2), INK)
    self:todayColumn(bb, rx, today_y + px(26), rw, px, s.today)
    rect(bb, rx, goals_y, rw, px(2), INK)
    self:goalsColumn(bb, rx, goals_y + px(26), rw, px, s.goals, s.year)
end

-- Statistics off in landscape: header, book (or its absence), then the hint.
function StreakScreen:paintPortraitOrder(bb, left, top, bottom, cw, px, m)
    local hint_h = self:hint(nil, left, 0, cw, px)
    local blocks = { { h = px(32), paint = function(y) self:header(bb, left, y, cw, px, m.header) end } }
    if m.book then
        local cover_h = coverRoom(px, bottom - top, px(32) + hint_h, 2, COVER_H_ALONE)
        table.insert(blocks, { h = self:bookBlock(nil, left, 0, cw, cover_h, px, m.book), paint = function(y)
            self:bookBlock(bb, left, y, cw, cover_h, px, m.book)
        end })
    else
        table.insert(blocks, { h = self:noBook(nil, left, 0, cw, px), paint = function(y) self:noBook(bb, left, y, cw, px) end })
    end
    table.insert(blocks, { h = hint_h, paint = function(y) self:hint(bb, left, y, cw, px) end })
    stack(bb, top, bottom, blocks, px(24))
end

return StreakScreen
