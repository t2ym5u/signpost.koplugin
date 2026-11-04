local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local Solver = require("solver")
local Board  = require("board")

local function newBoard(n, diff, seed)
    math.randomseed(seed or 42)
    local b = Board:new{ n = n or 5, difficulty = diff or "easy" }
    b:generate()
    return b
end

-- Links the whole answer through the player's own move API.
local function playSolution(b)
    for a = 1, b.N do
        if b.sol_succ[a] ~= 0 then assert(b:linkCells(a, b.sol_succ[a])) end
    end
end

-- A tiny hand-made 3×3 board: the answer snakes 1..9 along the rows.
--   1 → 2 → 3
--   6 ← 5 ← 4     (3 points down-left... see arrows below)
--   7 → 8 → 9
local function snakeBoard()
    local b = Board:new{ n = 3 }
    local order = { 1, 2, 3, 6, 5, 4, 7, 8, 9 }   -- cells in path order
    local path = {}
    for i, cell in ipairs(order) do path[i] = cell end
    local puz = Solver.puzzleFromPath(3, path)
    for cell = 1, 9 do
        b.arrows[cell] = puz.arrows[cell]
        b.number[cell] = puz.number[cell]
        b.givens[cell] = puz.givens[cell] or 0
    end
    for i = 1, 8 do b.sol_succ[path[i]] = path[i + 1] end
    return b
end

describe("Signpost solver", function()
    it("random paths visit every cell once along queen lines", function()
        for seed = 1, 30 do
            math.randomseed(seed)
            local n = 4 + seed % 4
            local path = Solver.randomPath(n)
            assert.are.equal(n * n, #path)
            local seen = {}
            for i, cell in ipairs(path) do
                assert.is_nil(seen[cell])
                seen[cell] = true
                if i > 1 then
                    local p = path[i - 1]
                    local r1, c1 = math.floor((p - 1) / n) + 1, (p - 1) % n + 1
                    local r2, c2 = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
                    assert.is_not_nil(Solver.dirBetween(r1, c1, r2, c2))
                end
            end
        end
    end)

    it("arrows point from each number towards the next", function()
        math.randomseed(5)
        local puz = Solver.generate(6, "medium")
        local n = 6
        local where = {}
        for cell, k in pairs(puz.number) do where[k] = cell end
        for k = 1, n * n - 1 do
            local a, b = where[k], where[k + 1]
            local r1, c1 = math.floor((a - 1) / n) + 1, (a - 1) % n + 1
            local r2, c2 = math.floor((b - 1) / n) + 1, (b - 1) % n + 1
            assert.are.equal(puz.arrows[a], Solver.dirBetween(r1, c1, r2, c2))
        end
        assert.are.equal(0, puz.arrows[where[n * n]])
    end)

    it("generates unique puzzles at the requested tier, every size and level", function()
        for _, n in ipairs({ 4, 5, 6, 7 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for seed = 1, 5 do
                    math.randomseed(seed * 17 + n)
                    local puz, info = Solver.generate(n, diff)
                    assert.are.equal(1, Solver.countSolutions(puz, 2))
                    assert.are.equal(Solver.TIER[diff], info.tier)
                    assert.is_true((Solver.solve(puz, info.tier)))
                    if info.tier > 1 then
                        assert.is_false((Solver.solve(puz, info.tier - 1)))
                    end
                    -- 1 and N are always given.
                    local has1, hasN = false, false
                    for _, v in pairs(puz.givens) do
                        if v == 1 then has1 = true end
                        if v == n * n then hasN = true end
                    end
                    assert.is_true(has1 and hasN)
                end
            end
        end
    end)

    -- 1.1.0: the tier-3 probe no longer re-tries two-choice cells in its
    -- three-choice round (same outcome; 7x7 Hard took up to ~0.26 s on a
    -- desktop). Keep a generous bound on it, and on the progress reports.
    it("builds 7x7 Hard quickly, reporting progress from 0 to 1", function()
        local worst = 0
        for seed = 1, 4 do
            math.randomseed(seed * 101)
            local last, monotone = -1, true
            local t0 = os.clock()
            Solver.generate(7, "hard", { on_progress = function(f)
                if f < last or f < 0 or f > 1 then monotone = false end
                last = f
            end })
            worst = math.max(worst, os.clock() - t0)
            assert.is_true(monotone)
        end
        -- generous: ~0.15 s on a desktop
        assert.is_true(worst < 3.0, ("took %.2f s"):format(worst))
    end)

    it("the deduction reproduces the stored answer (soundness)", function()
        for seed = 1, 20 do
            math.randomseed(seed)
            local n = 4 + seed % 4
            local puz = Solver.generate(n, ({ "easy", "medium", "hard" })[seed % 3 + 1])
            local ok, _, st = Solver.solve(puz, 3)
            assert.is_true(ok)
            for i = 1, n * n - 1 do
                assert.are.equal(puz.path[i + 1], st.succ[puz.path[i]])
            end
        end
    end)

    it("finds ambiguity when numbers are missing", function()
        local found = false
        for seed = 1, 40 do
            math.randomseed(seed)
            local path = Solver.randomPath(5)
            local puz = Solver.puzzleFromPath(5, path)
            if Solver.countSolutions(puz, 2) == 2 then found = true; break end
        end
        assert.is_true(found)
    end)
end)

describe("SignpostBoard", function()
    it("links only along the arrow", function()
        local b = snakeBoard()
        -- cell 1 points east: 2 and 3 are on its arrow, 4 is not.
        assert.is_true(b:isOnArrow(1, 2))
        assert.is_true(b:isOnArrow(1, 3))
        assert.is_false(b:isOnArrow(1, 4))
        local ok, err = b:linkCells(1, 4)
        assert.is_false(ok)
        assert.are.equal(Board.ERR_NOT_ON_ARROW, err)
    end)

    it("tap-select then tap a target links and moves the selection", function()
        local b = snakeBoard()
        assert.is_true(b:tapCell(1, 1))
        assert.is_true(b:tapCell(1, 2))
        assert.are.equal(2, b.succ[1])
        assert.are.same({ r = 1, c = 2 }, b.selected)
        -- Back on 1, tapping its successor again unlinks.
        b:tapCell(1, 1)
        b:tapCell(1, 2)
        assert.are.equal(0, b.succ[1])
    end)

    it("relinking replaces the old successor and predecessor", function()
        local b = snakeBoard()
        assert.is_true(b:linkCells(1, 3))
        assert.is_true(b:linkCells(1, 2))
        assert.are.equal(2, b.succ[1])
        assert.are.equal(0, b.pred[3])
    end)

    it("refuses loops", function()
        local b = Board:new{ n = 3 }
        -- 1 → 2 east, 2 → 5 south, 5 → 1 north-west.
        b.arrows[1], b.arrows[2], b.arrows[5] = 3, 5, 8
        b.givens[9] = 0
        assert.is_true(b:linkCells(1, 2))
        assert.is_true(b:linkCells(2, 5))
        local ok, err = b:linkCells(5, 1)
        assert.is_false(ok)
        assert.are.equal(Board.ERR_LOOP, err)
    end)

    it("refuses numbers that cannot follow each other", function()
        local b = snakeBoard()
        -- Give 2 the number 5 (wrong distance from the given 1).
        b.givens[2] = 5
        local ok, err = b:linkCells(1, 2)
        assert.is_false(ok)
        assert.are.equal(Board.ERR_NUMBERS, err)
    end)

    it("labels numbered chains with numbers, others with letters", function()
        local b = snakeBoard()
        b:linkCells(1, 2)          -- chain from given 1
        b:linkCells(5, 4)          -- loose chain
        b:linkCells(4, 7)
        local lab = b:labels()
        assert.are.equal("1", lab[1].text)
        assert.are.equal("2", lab[2].text)
        assert.are.equal("a", lab[5].text)
        assert.are.equal("a+1", lab[4].text)
        assert.are.equal("a+2", lab[7].text)
        assert.are.equal("9", lab[9].text)      -- the given end
        assert.are.equal("", lab[3].text)
    end)

    it("detects the win by the rules", function()
        for seed = 1, 6 do
            local b = newBoard(4 + seed % 4, "medium", seed)
            assert.is_false(b:isSolved())
            playSolution(b)
            assert.is_true(b:isSolved())
            assert.is_false(b.timer:isRunning())
            assert.are.equal(b.N - 1, b:countLinks())
        end
    end)

    it("undo restores links, including replaced ones", function()
        local b = snakeBoard()
        b:linkCells(1, 3)
        b:linkCells(1, 2)
        b:detach(2)
        assert.are.equal(0, b.succ[1])
        assert.is_true(b:undoLast())
        assert.are.equal(2, b.succ[1])
        assert.is_true(b:undoLast())
        assert.are.equal(3, b.succ[1])
        assert.are.equal(1, b.pred[3])
        assert.is_true(b:undoLast())
        assert.are.equal(0, b.succ[1])
        assert.is_false(b:undoLast())
    end)

    it("clear removes every link in one undoable step", function()
        local b = newBoard(5, "easy", 3)
        playSolution(b)
        b.solved = false
        assert.is_true(b:clearAll())
        assert.are.equal(0, b:countLinks())
        assert.is_true(b:undoLast())
        assert.are.equal(b.N - 1, b:countLinks())
    end)

    it("serialize / load round trip", function()
        local b = newBoard(6, "hard", 9)
        local start
        for cell = 1, b.N do if b.givens[cell] == 1 then start = cell end end
        b:linkCells(start, b.sol_succ[start])
        local data = b:serialize()
        local b2 = Board:new()
        assert.is_true(b2:load(data))
        assert.are.equal(6, b2.n)
        assert.are.same(b.arrows, b2.arrows)
        assert.are.same(b.givens, b2.givens)
        assert.are.same(b.succ, b2.succ)
        assert.are.same(b.pred, b2.pred)
        assert.are.same(b.sol_succ, b2.sol_succ)
        assert.is_true(b2:canUndo())
        assert.is_true(b.timer:isRunning())
        assert.is_false(Board:new():load(nil))
        assert.is_false(Board:new():load({ n = 4 }))
    end)
end)

describe("Signpost hint", function()
    it("successive hints finish the grid", function()
        for seed = 1, 6 do
            local b = newBoard(4 + seed % 4, "hard", seed)
            local guard = 0
            while not b:isSolved() and guard < 100 do
                guard = guard + 1
                local step = b:findHint()
                assert.is_not_nil(step)
                assert.are.equal("fill", step.kind)
                assert.is_true(b:applyHint(step))
            end
            assert.is_true(b:isSolved())
        end
    end)

    it("reports a wrong link first and cuts it", function()
        local b = newBoard(5, "easy", 2)
        for a = 1, b.N do
            for _, t in ipairs(b:rayOf(a)) do
                if t ~= b.sol_succ[a] and b:linkCells(a, t) then
                    local step = b:findHint()
                    assert.are.equal("mistake", step.kind)
                    assert.are.equal(a, b:cellOf(step.r, step.c))
                    assert.is_true(b:applyHint(step))
                    assert.are.equal(0, b.succ[a])
                    return
                end
            end
        end
        error("no wrong link could be made")
    end)
end)
