--[[
The daily quote's rules, as pure Lua: which quote comes next, and whether a
laid-out quote fits the gap beside the cover.

Rotation: the quotes go round in a shuffled order, so none repeats until all
have shown. The order and the position in it are saved between sleeps
(state = { order = { indices }, pos = next position }).

Fit: a quote gets at most two lines at the column's width, and only as many
as the gap holds with 14 px clear above and below. One that doesn't fit is
skipped for the next one that does; it stays in the round for a roomier day.
Type never shrinks and nothing is cut short: if none fits, the gap stays empty.
]]

local Q = {}

-- Design px, scaled by the screen before use.
Q.METRICS = { line = 38, attribution_gap = 8, attribution = 28, clear = 14 }
Q.MAX_LINES = 2

-- Height of a quote of n lines with its attribution.
function Q.height(lines, m)
    m = m or Q.METRICS
    return lines * m.line + m.attribution_gap + m.attribution
end

-- Whether a quote laid out in `lines` lines fits a gap `gap` px tall.
function Q.fits(lines, gap, m)
    m = m or Q.METRICS
    return lines >= 1 and lines <= Q.MAX_LINES and Q.height(lines, m) + 2 * m.clear <= gap
end

-- A shuffled order of 1..n (Fisher-Yates). random(k) returns 1..k.
function Q.shuffle(n, random)
    random = random or math.random
    local order = {}
    for i = 1, n do order[i] = i end
    for i = n, 2, -1 do
        local j = random(i)
        order[i], order[j] = order[j], order[i]
    end
    return order
end

-- A saved order is usable when it holds each of 1..n exactly once.
local function valid(state, n)
    if type(state) ~= "table" or type(state.order) ~= "table" or #state.order ~= n then return false end
    if type(state.pos) ~= "number" or state.pos < 1 then return false end
    local seen = {}
    for _, i in ipairs(state.order) do
        if type(i) ~= "number" or i < 1 or i > n or seen[i] then return false end
        seen[i] = true
    end
    return true
end

--[[
The next quote that fits. fits(i) says whether quote i fits today's gap.
Returns the chosen index (nil when none fits) and the state to save. The
chosen quote takes the current position, so ones skipped for length wait
their turn later in the round. When nothing left in this round fits but
something would, a new round starts; when nothing fits at all, the state
stays as it was.
]]
function Q.pick(state, n, fits, random)
    if n < 1 then return nil, state end
    local order, pos
    if valid(state, n) then
        order, pos = {}, state.pos
        for i, v in ipairs(state.order) do order[i] = v end
    else
        order, pos = Q.shuffle(n, random), 1
    end
    local function take()
        for i = pos, #order do
            if fits(order[i]) then
                order[pos], order[i] = order[i], order[pos]
                pos = pos + 1
                return order[pos - 1]
            end
        end
    end
    local chosen = take()
    if not chosen then
        local any = false
        for i = 1, n do
            if fits(i) then any = true; break end
        end
        if not any then return nil, state end
        order, pos = Q.shuffle(n, random), 1
        chosen = take()
    end
    return chosen, { order = order, pos = pos }
end

return Q
