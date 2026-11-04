-- ---------------------------------------------------------------------------
-- SignpostBoard — game state for Signpost.
--
-- Cells are numbered (r-1)*n + c. The player's answer is a set of links:
-- succ[a] = b means "b comes right after a" (0 = no link yet), with pred as
-- its mirror. Links form chains; a chain holding a given number has all its
-- numbers known, any other chain of two or more cells is labelled with a
-- letter (a, a+1, a+2, ...) the way Simon Tatham's original does.
--
-- A link is refused when it would close a loop, or when it would put two
-- given numbers in a chain at the wrong distance (3 → … → 7 in two steps):
-- those can never be part of the answer and the original refuses them too.
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack = require("undo_stack")
local Timer     = require("timer")
local Hint      = require("hint")

local Solver = lrequire("solver")

local SignpostBoard = {}
SignpostBoard.__index = SignpostBoard

SignpostBoard.SIZES     = { 4, 5, 6, 7 }
SignpostBoard.DEFAULT_N = 5

-- Refusal reasons, as ids: the screen words them.
SignpostBoard.ERR_NOT_ON_ARROW = "not_on_arrow"
SignpostBoard.ERR_LOOP         = "loop"
SignpostBoard.ERR_NUMBERS      = "numbers"
SignpostBoard.ERR_LAST         = "last"
SignpostBoard.ERR_SOLVED       = "solved"

function SignpostBoard:new(opts)
    opts = opts or {}
    local o = setmetatable({
        n          = opts.n or SignpostBoard.DEFAULT_N,
        difficulty = opts.difficulty or "easy",
        undo       = UndoStack:new(),
        timer      = Timer:new(),
    }, self)
    o:_reset()
    return o
end

function SignpostBoard:_reset()
    local N = self.n * self.n
    self.N = N
    self.arrows, self.givens, self.number, self.sol_succ = {}, {}, {}, {}
    self.succ, self.pred = {}, {}
    for cell = 1, N do
        self.arrows[cell] = 0
        self.givens[cell] = 0
        self.number[cell] = 0
        self.sol_succ[cell] = 0
        self.succ[cell], self.pred[cell] = 0, 0
    end
    self.selected = nil
    self.solved = false
    self.showing_solution = false
    self.hints_used = 0
end

function SignpostBoard:cellOf(r, c) return (r - 1) * self.n + c end
function SignpostBoard:rcOf(cell)
    return math.floor((cell - 1) / self.n) + 1, (cell - 1) % self.n + 1
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

-- on_progress (optional): called with a 0..1 fraction as it goes.
function SignpostBoard:generate(n, difficulty, on_progress)
    self.n = n or self.n
    self.difficulty = difficulty or self.difficulty
    self:_reset()
    local puz, info = Solver.generate(self.n, self.difficulty, { on_progress = on_progress })
    self.gen_info = info
    for cell = 1, self.N do
        self.arrows[cell] = puz.arrows[cell] or 0
        self.givens[cell] = puz.givens[cell] or 0
        self.number[cell] = puz.number[cell]
    end
    for i = 1, self.N - 1 do self.sol_succ[puz.path[i]] = puz.path[i + 1] end
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- The solver's view of the grid.
function SignpostBoard:toPuzzle()
    local givens = {}
    for cell = 1, self.N do
        if self.givens[cell] > 0 then givens[cell] = self.givens[cell] end
    end
    return { n = self.n, arrows = self.arrows, givens = givens }
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- Is b somewhere along a's arrow?
function SignpostBoard:isOnArrow(a, b)
    local d = self.arrows[a]
    if d == 0 or a == b then return false end
    local r1, c1 = self:rcOf(a)
    local r2, c2 = self:rcOf(b)
    return Solver.dirBetween(r1, c1, r2, c2) == d
end

-- The cells along a's arrow, nearest first.
function SignpostBoard:rayOf(a)
    local list = {}
    local d = Solver.DIRS[self.arrows[a]]
    if not d then return list end
    local r, c = self:rcOf(a)
    r, c = r + d.dr, c + d.dc
    while r >= 1 and r <= self.n and c >= 1 and c <= self.n do
        list[#list + 1] = self:cellOf(r, c)
        r, c = r + d.dr, c + d.dc
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Chains
-- ---------------------------------------------------------------------------

function SignpostBoard:headOf(cell)
    local guard = 0
    while self.pred[cell] ~= 0 and guard <= self.N do
        cell = self.pred[cell]
        guard = guard + 1
    end
    return cell
end

-- The chain through `cell`, head first.
function SignpostBoard:chainOf(cell)
    local list, x = {}, self:headOf(cell)
    while x ~= 0 and #list <= self.N do
        list[#list + 1] = x
        x = self.succ[x]
    end
    return list
end

-- Would linking a → b give a chain whose given numbers disagree, or run
-- outside 1..N? Checked on the chain the link would create: a's chain up to
-- a, then b's chain from b.
function SignpostBoard:_numbersFit(a, b)
    local list = {}
    local back, x = {}, a
    while x ~= 0 and #back <= self.N do
        back[#back + 1] = x
        x = self.pred[x]
    end
    for i = #back, 1, -1 do list[#list + 1] = back[i] end
    x = b
    while x ~= 0 and #list <= 2 * self.N do
        list[#list + 1] = x
        x = self.succ[x]
    end
    local offset
    for i, cell in ipairs(list) do
        local g = self.givens[cell]
        if g > 0 then
            if offset and g - i ~= offset then return false end
            offset = g - i
        end
    end
    if offset and (offset + 1 < 1 or offset + #list > self.N) then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Moves (all undoable). An undo entry is a list of { a, b, add } link ops.
-- ---------------------------------------------------------------------------

function SignpostBoard:_apply(ops)
    for _, op in ipairs(ops) do
        if op.add then
            self.succ[op.a], self.pred[op.b] = op.b, op.a
        else
            self.succ[op.a], self.pred[op.b] = 0, 0
        end
    end
end

function SignpostBoard:_commit(ops)
    if #ops == 0 then return end
    self:_apply(ops)
    self.undo:push(ops)
    self.solved = self:checkWin()
    if self.solved then
        self.selected = nil
        self.timer:stop()
    end
end

-- Links a → b, replacing a's old successor and b's old predecessor.
-- Returns ok, err.
function SignpostBoard:linkCells(a, b)
    if self.solved then return false, SignpostBoard.ERR_SOLVED end
    if self.arrows[a] == 0 then return false, SignpostBoard.ERR_LAST end
    if not self:isOnArrow(a, b) then return false, SignpostBoard.ERR_NOT_ON_ARROW end
    if self.succ[a] == b then return true end
    -- Following b's chain forward reaching a means a loop.
    local x, guard = b, 0
    while x ~= 0 and guard <= self.N do
        if x == a then return false, SignpostBoard.ERR_LOOP end
        x = self.succ[x]
        guard = guard + 1
    end
    local ops = {}
    if self.succ[a] ~= 0 then ops[#ops + 1] = { a = a, b = self.succ[a], add = false } end
    if self.pred[b] ~= 0 then ops[#ops + 1] = { a = self.pred[b], b = b, add = false } end
    -- Check the numbers on the chain as it would be after the cuts.
    local saved_s, saved_p = self.succ[a], self.pred[b]
    self:_apply(ops)
    local fits = self:_numbersFit(a, b)
    -- Put the cuts back; _commit applies everything in one go.
    if saved_p ~= 0 then self.succ[saved_p], self.pred[b] = b, saved_p end
    if saved_s ~= 0 then self.succ[a], self.pred[saved_s] = saved_s, a end
    if not fits then return false, SignpostBoard.ERR_NUMBERS end
    ops[#ops + 1] = { a = a, b = b, add = true }
    self:_commit(ops)
    return true
end

function SignpostBoard:unlinkSucc(a)
    if self.solved then return false end
    if self.succ[a] == 0 then return true end
    self:_commit({ { a = a, b = self.succ[a], add = false } })
    return true
end

-- Cuts both links of a cell (hold).
function SignpostBoard:detach(cell)
    if self.solved then return false, SignpostBoard.ERR_SOLVED end
    local ops = {}
    if self.succ[cell] ~= 0 then ops[#ops + 1] = { a = cell, b = self.succ[cell], add = false } end
    if self.pred[cell] ~= 0 then ops[#ops + 1] = { a = self.pred[cell], b = cell, add = false } end
    self:_commit(ops)
    return true
end

function SignpostBoard:clearAll()
    if self.solved then return false end
    local ops = {}
    for a = 1, self.N do
        if self.succ[a] ~= 0 then ops[#ops + 1] = { a = a, b = self.succ[a], add = false } end
    end
    if #ops == 0 then return false end
    self:_commit(ops)
    self.selected = nil
    return true
end

function SignpostBoard:canUndo()
    return self.undo:canUndo()
end

function SignpostBoard:undoLast()
    local ops = self.undo:pop()
    if not ops then return false end
    for i = #ops, 1, -1 do
        local op = ops[i]
        self:_apply({ { a = op.a, b = op.b, add = not op.add } })
    end
    self.solved = false
    self.timer:start()
    return true
end

-- ---------------------------------------------------------------------------
-- Taps: tap a cell to select it; tap a cell along its arrow to link the two
-- (tapping its current successor again unlinks it). The new successor becomes
-- the selection, so a chain is built by tapping its cells in order.
-- Returns ok, err.
-- ---------------------------------------------------------------------------

function SignpostBoard:tapCell(r, c)
    if self.solved then return false, SignpostBoard.ERR_SOLVED end
    local cell = self:cellOf(r, c)
    local sel = self.selected and self:cellOf(self.selected.r, self.selected.c)
    if sel == cell then
        self.selected = nil
        return true
    end
    if sel and self:isOnArrow(sel, cell) then
        if self.succ[sel] == cell then
            return self:unlinkSucc(sel)
        end
        local ok, err = self:linkCells(sel, cell)
        if ok and not self.solved then
            self.selected = (self.arrows[cell] ~= 0) and { r = r, c = c } or nil
        end
        return ok, err
    end
    self.selected = { r = r, c = c }
    return true
end

function SignpostBoard:holdCell(r, c)
    return self:detach(self:cellOf(r, c))
end

function SignpostBoard:setSelection(r, c)
    self.selected = { r = r, c = c }
end

-- The cells along a's arrow, as a set: what the widget marks as reachable
-- from the selection. linkCells may still refuse one (loop, number clash).
function SignpostBoard:targetsOf(a)
    local set = {}
    for _, b in ipairs(self:rayOf(a)) do
        set[b] = true
    end
    return set
end

-- ---------------------------------------------------------------------------
-- Labels: { text = "12" | "b+2" | "", given = bool } per cell.
-- ---------------------------------------------------------------------------

local LETTERS = "abcdefghijklmnopqrstuvwxyz"

function SignpostBoard:labels()
    local out, letter = {}, 0
    for cell = 1, self.N do out[cell] = { text = "", given = self.givens[cell] > 0 } end
    for head = 1, self.N do
        if self.pred[head] == 0 then
            local chain = self:chainOf(head)
            local offset
            for i, cell in ipairs(chain) do
                local g = self.givens[cell]
                if g > 0 then offset = g - i; break end
            end
            if offset then
                for i, cell in ipairs(chain) do
                    out[cell].text = tostring(offset + i)
                end
            elseif #chain >= 2 then
                letter = letter + 1
                local idx = (letter - 1) % #LETTERS + 1
                local ch = LETTERS:sub(idx, idx)
                for i, cell in ipairs(chain) do
                    out[cell].text = (i == 1) and ch or (ch .. "+" .. (i - 1))
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Win check, by the rules: one chain covers every cell, starts at the cell
-- given 1, and agrees with every given number.
-- ---------------------------------------------------------------------------

function SignpostBoard:checkWin()
    local start
    for cell = 1, self.N do
        if self.givens[cell] == 1 then start = cell end
    end
    if not start or self.pred[start] ~= 0 then return false end
    local k, x = 0, start
    while x ~= 0 do
        k = k + 1
        if k > self.N then return false end
        if self.givens[x] > 0 and self.givens[x] ~= k then return false end
        local nx = self.succ[x]
        if nx ~= 0 and not self:isOnArrow(x, nx) then return false end
        x = nx
    end
    return k == self.N
end

function SignpostBoard:isSolved()
    return self.solved
end

function SignpostBoard:countLinks()
    local k = 0
    for a = 1, self.N do
        if self.succ[a] ~= 0 then k = k + 1 end
    end
    return k
end

function SignpostBoard:toggleSolution()
    self.showing_solution = not self.showing_solution
end

function SignpostBoard:isShowingSolution()
    return self.showing_solution
end

-- ---------------------------------------------------------------------------
-- Hint. The unit is a cell's outgoing link: a wrong one is cut, a missing
-- one is drawn. Wording lives in the screen (describeHintStep).
-- ---------------------------------------------------------------------------

Hint.install(SignpostBoard, {
    isEmpty     = function(v) return v == nil or v == 0 end,
    getUser     = function(b, r, c) return b.succ[b:cellOf(r, c)] end,
    getSolution = function(b, r, c) return b.sol_succ[b:cellOf(r, c)] end,
    setCell     = function(b, r, c, v) return (b:linkCells(b:cellOf(r, c), v)) end,
    clearCell   = function(b, r, c) return b:unlinkSucc(b:cellOf(r, c)) end,
})

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function SignpostBoard:serialize()
    -- Timer:serialize() stops the clock to bank the elapsed time; the game is
    -- saved after every move, so restart it or it would freeze at the first
    -- save.
    local timer = self.timer:serialize()
    if timer.was_running then self.timer:start() end
    return {
        n          = self.n,
        difficulty = self.difficulty,
        arrows     = self.arrows,
        givens     = self.givens,
        number     = self.number,
        sol_succ   = self.sol_succ,
        succ       = self.succ,
        solved     = self.solved,
        hints_used = self.hints_used,
        timer      = timer,
        undo       = self.undo:serialize(),
    }
end

function SignpostBoard:load(data)
    if type(data) ~= "table" or type(data.n) ~= "number" or type(data.arrows) ~= "table"
       or type(data.sol_succ) ~= "table" or type(data.succ) ~= "table" then
        return false
    end
    self.n = data.n
    self:_reset()
    self.difficulty = data.difficulty or "easy"
    for cell = 1, self.N do
        self.arrows[cell]   = data.arrows[cell] or 0
        self.givens[cell]   = (data.givens or {})[cell] or 0
        self.number[cell]   = (data.number or {})[cell] or 0
        self.sol_succ[cell] = data.sol_succ[cell] or 0
    end
    for a = 1, self.N do
        local b = data.succ[a] or 0
        if b ~= 0 then self.succ[a], self.pred[b] = b, a end
    end
    self.solved     = data.solved and true or false
    self.hints_used = data.hints_used or 0
    self.timer:load(data.timer)
    self.undo:load(data.undo)
    return true
end

return SignpostBoard
