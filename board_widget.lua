local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local gwb            = lrequire_common("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local Screen = Device.screen

local C_BG       = Blitbuffer.COLOR_WHITE
local C_GIVEN_BG = Blitbuffer.COLOR_GRAY_D     -- cells holding a given number
local C_GRID     = Blitbuffer.COLOR_GRAY_6
local C_INK      = Blitbuffer.COLOR_BLACK
-- An arrow whose cell already has its successor: still easy to read, but
-- it steps back so the cells left to link stand out.
local C_DONE     = Blitbuffer.COLOR_GRAY_9
local C_TARGET   = Blitbuffer.COLOR_GRAY_5     -- frame of cells along the selected arrow

-- ---------------------------------------------------------------------------
-- Arrow geometry: one arrow pointing east in a unit box centred on 0,0,
-- as two convex pieces (shaft, head), rotated per direction.
-- ---------------------------------------------------------------------------

local SHAFT = { { -0.92, -0.17 }, { 0.10, -0.17 }, { 0.10, 0.17 }, { -0.92, 0.17 } }
local HEAD  = { { -0.08, -0.62 }, { 0.95, 0 }, { -0.08, 0.62 } }

-- Fills a convex polygon of {x, y} points with horizontal spans: the
-- blitbuffer has rectangles and circles, no polygons.
local function fillConvex(bb, pts, color)
    local ymin, ymax = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < ymin then ymin = p[2] end
        if p[2] > ymax then ymax = p[2] end
    end
    for y = math.floor(ymin), math.ceil(ymax) do
        local yc = y + 0.5
        local xl, xr = math.huge, -math.huge
        for i = 1, #pts do
            local p, q = pts[i], pts[i % #pts + 1]
            if (p[2] <= yc and q[2] > yc) or (q[2] <= yc and p[2] > yc) then
                local x = p[1] + (yc - p[2]) * (q[1] - p[1]) / (q[2] - p[2])
                if x < xl then xl = x end
                if x > xr then xr = x end
            end
        end
        if xl <= xr then
            local x0 = math.floor(xl + 0.5)
            local x1 = math.floor(xr + 0.5)
            if x1 > x0 then bb:paintRect(x0, y, x1 - x0, 1, color) end
        end
    end
end

-- Direction 1..8 clockwise from north; east is 3. Screen y grows downward,
-- so a positive angle turns clockwise.
local function drawArrow(bb, dir, cx, cy, half, color)
    local a = (dir - 3) * math.pi / 4
    local ca, sa = math.cos(a), math.sin(a)
    for _, shape in ipairs({ SHAFT, HEAD }) do
        local pts = {}
        for i, p in ipairs(shape) do
            local x, y = p[1] * half, p[2] * half
            pts[i] = { cx + x * ca - y * sa, cy + x * sa + y * ca }
        end
        fillConvex(bb, pts, color)
    end
end

-- ---------------------------------------------------------------------------
-- SignpostBoardWidget
--
-- Each cell: the arrow large in its upper part, the label (number, or chain
-- letter such as "b+2") in a band along the bottom.
-- ---------------------------------------------------------------------------

local SignpostBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function SignpostBoardWidget:init()
    local n = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
    local u = self.cell_w
    self.label_face = self:_fitFace("a+88", u * 0.80, u * 0.27)
end

function SignpostBoardWidget:_fitFace(sample, max_w, max_h)
    local lo, hi, best = 8, math.max(8, math.floor(max_h * 1.5)), 8
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace("cfont", mid)
        local m    = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return Font:getFace("cfont", best)
end

function SignpostBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function SignpostBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

local function drawText(bb, face, text, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, false)
    local bx = math.floor(cx - m.x / 2)
    local by = math.floor(cy + (m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, bx, by, face, text, true, false, color)
end

local function frame(bb, x, y, w, h, t, color)
    drawLine(bb, x, y, w, t, color)
    drawLine(bb, x, y + h - t, w, t, color)
    drawLine(bb, x, y, t, h, color)
    drawLine(bb, x + w - t, y, t, h, color)
end

function SignpostBoardWidget:paintTo(bb, x, y)
    local board = self.board
    if not board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local n    = board.n
    local u    = self.dimen.w / n
    local show = board:isShowingSolution()

    local function left(c) return x + math.floor((c - 1) * u) end
    local function top(r) return y + math.floor((r - 1) * u) end

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    local labels
    if show then
        labels = {}
        for cell = 1, board.N do
            labels[cell] = { text = tostring(board.number[cell]), given = board.givens[cell] > 0 }
        end
    else
        labels = board:labels()
    end

    local sel = (not show) and board.selected
    local targets = sel and board:targetsOf(board:cellOf(sel.r, sel.c)) or {}

    for r = 1, n do
        for c = 1, n do
            local cell = board:cellOf(r, c)
            local x0, y0 = left(c), top(r)
            local w, h = left(c + 1) - x0, top(r + 1) - y0
            if board.givens[cell] > 0 then bb:paintRect(x0, y0, w, h, C_GIVEN_BG) end

            -- The arrow, or a ring for the last cell.
            local acx = x0 + math.floor(w / 2)
            local acy = y0 + math.floor(u * 0.35)
            local half = u * 0.28
            local dir = board.arrows[cell]
            if dir == 0 then
                local rad = math.floor(u * 0.21)
                bb:paintCircle(acx, acy, rad, C_INK)
                bb:paintCircle(acx, acy, math.floor(rad * 0.62), C_BG)
                bb:paintCircle(acx, acy, math.floor(rad * 0.30), C_INK)
            else
                local linked = show or board.succ[cell] ~= 0
                drawArrow(bb, dir, acx, acy, half, linked and C_DONE or C_INK)
            end

            local lab = labels[cell]
            if lab.text ~= "" then
                drawText(bb, self.label_face, lab.text, acx, y0 + math.floor(u * 0.78), C_INK)
            end
        end
    end

    -- Grid.
    local thin  = Size.line.thin or 1
    local thick = math.max(2, Size.line.thick or 2)
    for i = 1, n - 1 do
        local pos = math.floor(i * u)
        drawLine(bb, x + pos, y, thin, self.dimen.h, C_GRID)
        drawLine(bb, x, y + pos, self.dimen.w, thin, C_GRID)
    end
    frame(bb, x, y, self.dimen.w, self.dimen.h, thick, C_INK)

    -- Cells along the selected arrow get a light frame, the selection a
    -- heavy one.
    if sel then
        local tw = math.max(2, math.floor(u * 0.035))
        for cell in pairs(targets) do
            local r, c = board:rcOf(cell)
            local x0, y0 = left(c), top(r)
            frame(bb, x0 + tw, y0 + tw, left(c + 1) - x0 - 2 * tw, top(r + 1) - y0 - 2 * tw, tw, C_TARGET)
        end
        local sw = math.max(3, math.floor(u * 0.06))
        local x0, y0 = left(sel.c), top(sel.r)
        frame(bb, x0, y0, left(sel.c + 1) - x0, top(sel.r + 1) - y0, sw, C_INK)
    end
end

return SignpostBoardWidget
