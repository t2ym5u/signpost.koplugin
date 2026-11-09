-- Difficulty guarantees for Signpost: every size x level builds a unique
-- puzzle quickly, the game's solver finishes it at the level's tier with no
-- trial, Easy needs tier 1 only, Easy < Medium < Hard in tier-2 steps, and
-- a seed gives the same puzzle without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local Solver = require("solver")
local Board  = require("board")

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Signpost difficulty", function()
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

    -- 1.3.0: Hard used to need one-step trials ("assume a link, see it
    -- break"), which is guessing. No level may need more than tier 2 now.
    it("no level needs trial and error (30 seeds per size and level)", function()
        for _, n in ipairs({ 4, 5, 6, 7 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for seed = 1, 30 do
                    math.randomseed(seed * 7919 + n)
                    local puz, info = Solver.generate(n, diff)
                    assert.is_true(info.tier <= 2)
                    local ok, _, st = Solver.solve(puz, 2)
                    assert.is_true(ok, ("%dx%d %s seed %d"):format(n, n, diff, seed))
                    assert.are.equal(info.t2, st.t2)
                end
            end
        end
    end)

    -- 1.3.0: Hard is tier 2 like Medium but with clearly more tier-2 steps.
    it("Easy < Medium < Hard in tier-2 steps, every size", function()
        for _, n in ipairs({ 5, 6, 7 }) do
            local sum, fit = { easy = 0, medium = 0, hard = 0 }, { medium = 0, hard = 0 }
            local hard_min, med_max = math.huge, 0
            local K = 20
            for seed = 1, K do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    math.randomseed(seed * 31 + n)
                    local _, info = Solver.generate(n, diff)
                    sum[diff] = sum[diff] + info.t2
                    if fit[diff] and info.miss == 0 then fit[diff] = fit[diff] + 1 end
                    if diff == "hard" then hard_min = math.min(hard_min, info.t2) end
                    if diff == "medium" then med_max = math.max(med_max, info.t2) end
                end
            end
            assert.are.equal(0, sum.easy)
            assert.is_true(sum.medium >= K, n .. ": medium needs tier 2")
            -- Hard averages at least one and a half times Medium's tier-2 steps
            assert.is_true(2 * sum.hard >= 3 * sum.medium, ("%d: %d vs %d"):format(n, sum.hard, sum.medium))
            -- nearly every grid lands in its level's window
            assert.is_true(fit.hard >= K - 2 and fit.medium >= K - 2, n .. ": windows")
            assert.is_true(hard_min >= med_max - 1, n .. ": overlap")
        end
        -- 4x4: two tier-2 steps are rare on so small a grid; Hard still
        -- never needs fewer than Medium.
        local s = { medium = 0, hard = 0 }
        for seed = 1, 20 do
            for _, diff in ipairs({ "medium", "hard" }) do
                math.randomseed(seed * 31 + 4)
                local _, info = Solver.generate(4, diff)
                s[diff] = s[diff] + info.t2
            end
        end
        assert.is_true(s.hard >= s.medium)
    end)

    it("same seed, same puzzle (the Daily Challenge relies on it)", function()
        for _, n in ipairs({ 5, 7 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(1234 + n)
                local a = Solver.generate(n, diff)
                math.randomseed(1234 + n)
                local b = Solver.generate(n, diff)
                assert.are.same(a.path, b.path)
                assert.are.same(a.givens, b.givens)
            end
        end
    end)

    -- 1.3.0: no trial tier any more; Hard picks paths by tier-2 steps.
    -- Generous bound (worst about 45 ms on a desktop at 7x7, 100 seeds).
    it("builds 7x7 Hard quickly, reporting progress from 0 to 1", function()
        local worst = 0
        for seed = 1, 10 do
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
        assert.is_true(worst < 1.0, ("took %.2f s"):format(worst))
    end)

    it("every size and level builds within a generous time bound", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local worst = 0
                for seed = 1, 5 do
                    math.randomseed(seed * 211 + n)
                    local t0 = os.clock()
                    Solver.generate(n, diff)
                    worst = math.max(worst, os.clock() - t0)
                end
                assert.is_true(worst < 1.5, ("%dx%d %s took %.2f s"):format(n, n, diff, worst))
            end
        end
    end)

    -- Solver.generate is the whole generator; Board:generate only adds the
    -- play timer, which reads the clock on purpose.
    it("generation never reads the clock", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(n * 13)
                withoutClock(function() Solver.generate(n, diff) end)
            end
        end
    end)
end)
