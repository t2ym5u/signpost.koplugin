-- ---------------------------------------------------------------------------
-- Signpost — solver and generator (pure Lua, no KOReader dependency).
--
-- An n×n grid; every cell but the last carries an arrow in one of eight
-- directions. The answer numbers the cells 1..N (N = n²) so that each cell's
-- successor lies somewhere along its arrow, at any distance. The first and
-- last numbers are always given, a few others may be.
--
-- The solver links cells (a → b: b follows a). Links build chains; a chain
-- holding a given number has all its numbers known. It reasons in tiers,
-- which is what the difficulty levels are measured with:
--
--   tier 1  a cell with only one possible successor, or only one possible
--           predecessor, is linked. A link is possible when b lies on a's
--           arrow, neither end is taken, it would not close a loop, and the
--           numbers on both chains (if known) line up and stay within 1..N;
--   tier 2  numbers are a resource: a link is also impossible when the
--           numbers the joined chain would take are already held by another
--           chain, or when an unnumbered chain would be too long for any gap
--           still free between the numbers already placed.
--
-- There is no trial tier: no level ever needs "assume a link and see if it
-- breaks" (1.3.0; before, Hard needed exactly that). Hard is tier 2 like
-- Medium, but with many more tier-2 steps: each one is a link that tier 1
-- alone could not find at that point (see run()).
--
-- Every rule is sound, so a grid the solver finishes has exactly one
-- solution. The generator checks that independently with countSolutions().
-- ---------------------------------------------------------------------------

local S = {}

-- Directions 1..8, clockwise from north.
S.DIRS = {
    { dr = -1, dc =  0 }, { dr = -1, dc =  1 }, { dr = 0, dc =  1 }, { dr =  1, dc =  1 },
    { dr =  1, dc =  0 }, { dr =  1, dc = -1 }, { dr = 0, dc = -1 }, { dr = -1, dc = -1 },
}

-- The direction index from cell (r1,c1) to (r2,c2) if they share a line.
function S.dirBetween(r1, c1, r2, c2)
    local dr, dc = r2 - r1, c2 - c1
    if dr == 0 and dc == 0 then return nil end
    if dr ~= 0 and dc ~= 0 and math.abs(dr) ~= math.abs(dc) then return nil end
    local sr = dr == 0 and 0 or (dr > 0 and 1 or -1)
    local sc = dc == 0 and 0 or (dc > 0 and 1 or -1)
    for i, d in ipairs(S.DIRS) do
        if d.dr == sr and d.dc == sc then return i end
    end
end

-- ---------------------------------------------------------------------------
-- Puzzle context: rays along each arrow and their inverse.
-- ---------------------------------------------------------------------------

local function context(puz)
    local n = puz.n
    local N = n * n
    local ctx = { n = n, N = N, ray = {}, rayIn = {}, arrows = puz.arrows, givens = puz.givens }
    for cell = 1, N do ctx.rayIn[cell] = {} end
    for cell = 1, N do
        local list = {}
        local d = S.DIRS[puz.arrows[cell] or 0]
        if d then
            local r, c = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
            r, c = r + d.dr, c + d.dc
            while r >= 1 and r <= n and c >= 1 and c <= n do
                local b = (r - 1) * n + c
                list[#list + 1] = b
                local inl = ctx.rayIn[b]
                inl[#inl + 1] = cell
                r, c = r + d.dr, c + d.dc
            end
        end
        ctx.ray[cell] = list
    end
    return ctx
end

-- ---------------------------------------------------------------------------
-- State: succ/pred links (0 = none), and per chain head its tail, length and
-- head number (0 = unknown). head[cell] names the chain a cell belongs to.
-- ---------------------------------------------------------------------------

local function initState(ctx)
    local st = { succ = {}, pred = {}, head = {}, tail = {}, len = {}, num = {}, forbid = {} }
    for cell = 1, ctx.N do
        st.succ[cell], st.pred[cell] = 0, 0
        st.head[cell], st.tail[cell], st.len[cell] = cell, cell, 1
        st.num[cell] = ctx.givens[cell] or 0
    end
    return st
end

local function clone(st)
    local o = { succ = {}, pred = {}, head = {}, tail = {}, len = {}, num = {}, forbid = {} }
    for i = 1, #st.succ do
        o.succ[i], o.pred[i], o.head[i] = st.succ[i], st.pred[i], st.head[i]
        o.tail[i], o.len[i], o.num[i] = st.tail[i], st.len[i], st.num[i]
    end
    for k, v in pairs(st.forbid) do o.forbid[k] = v end
    o.occ, o.maxgap, o.t2 = st.occ, st.maxgap, st.t2
    return o
end

-- How many numbers up to k chains hold (pre[k]), for tier 2, and the
-- longest run of free numbers. Cached until the next link. Numbered chains
-- never overlap (a link is only made if its numbers are free), so the count
-- of held numbers in a range tells whether a chain other than the two being
-- joined holds one of them -- a prefix sum instead of a scan of the range,
-- which also keeps LuaJIT from tracing a tiny inner loop over and over.
local function occupancy(st, ctx)
    local pre = st.occ
    if pre then return pre, st.maxgap end
    local N = ctx.N
    local held = {}
    for cell = 1, N do
        local v = st.num[cell]
        if v > 0 and st.head[cell] == cell then
            for k = v, v + st.len[cell] - 1 do held[k] = true end
        end
    end
    pre = { [0] = 0 }
    local maxgap, run, cnt = 0, 0, 0
    for k = 1, N do
        if held[k] then
            cnt = cnt + 1; run = 0
        else
            run = run + 1; if run > maxgap then maxgap = run end
        end
        pre[k] = cnt
    end
    st.occ, st.maxgap = pre, maxgap
    return pre, maxgap
end

-- Could a → b be part of the answer, as far as tier `tier` can tell?
-- Assumes b lies on a's arrow (callers walk the rays).
local function canLink(st, ctx, a, b, tier)
    if st.succ[a] ~= 0 or st.pred[b] ~= 0 then return false end
    if st.forbid[a * 4096 + b] then return false end
    local ha = st.head[a]
    if ha == b then return false end              -- would close a loop
    local la, lb = st.len[ha], st.len[b]
    local na, nb = st.num[ha], st.num[b]
    local N = ctx.N
    local h
    if na > 0 then
        h = na
        if nb > 0 and nb ~= na + la then return false end
    elseif nb > 0 then
        h = nb - la
        if h < 1 then return false end
    end
    local L = la + lb
    if h then
        if h + L - 1 > N then return false end
    elseif L > N then
        return false
    end
    if tier >= 2 then
        local pre, maxgap = occupancy(st, ctx)
        if h then
            -- numbers h .. h+L-1 held by some chain other than ha's and b's
            local other = pre[h + L - 1] - pre[h - 1]
            if na > 0 then other = other - la end
            if nb > 0 then other = other - lb end
            if other > 0 then return false end
        elseif L > maxgap then
            return false
        end
    end
    return true
end

local function link(st, a, b)
    local ha = st.head[a]
    if (st.num[ha] > 0) ~= (st.num[b] > 0) then st.occ = nil end
    if st.num[ha] == 0 and st.num[b] > 0 then st.num[ha] = st.num[b] - st.len[ha] end
    st.succ[a], st.pred[b] = b, a
    local x = b
    while x ~= 0 do
        st.head[x] = ha
        x = st.succ[x]
    end
    st.tail[ha] = st.tail[b]
    st.len[ha] = st.len[ha] + st.len[b]
end

-- Does this cell still need a successor / a predecessor?
local function needsSucc(st, ctx, a)
    if st.succ[a] ~= 0 or (ctx.arrows[a] or 0) == 0 then return false end
    return true
end

local function needsPred(st, b)
    return st.pred[b] == 0 and st.num[b] ~= 1
end

-- One sweep of the single-successor / single-predecessor rules.
-- Returns ok, changed.
-- first_only: stop at the first link (tier-2 steps are counted one by one).
local function pass(st, ctx, tier, first_only)
    local changed = false
    for a = 1, ctx.N do
        if needsSucc(st, ctx, a) then
            local only, count = nil, 0
            for _, b in ipairs(ctx.ray[a]) do
                if canLink(st, ctx, a, b, tier) then
                    count = count + 1; only = b
                    if count > 1 then break end
                end
            end
            if count == 0 then return false, changed end
            if count == 1 then
                link(st, a, only); changed = true
                if first_only then return true, true end
            end
        end
    end
    for b = 1, ctx.N do
        if needsPred(st, b) then
            local only, count = nil, 0
            for _, a in ipairs(ctx.rayIn[b]) do
                if canLink(st, ctx, a, b, tier) then
                    count = count + 1; only = a
                    if count > 1 then break end
                end
            end
            if count == 0 then return false, changed end
            if count == 1 then
                link(st, only, b); changed = true
                if first_only then return true, true end
            end
        end
    end
    return true, changed
end

local function propagate(st, ctx, tier)
    while true do
        local ok, changed = pass(st, ctx, tier)
        if not ok then return false end
        if not changed then return true end
    end
end

local function isComplete(st, ctx)
    for a = 1, ctx.N do
        if needsSucc(st, ctx, a) then return false end
    end
    return true
end

-- A complete state is the answer when one chain, numbered from 1, covers
-- every cell and agrees with every given.
local function isValid(st, ctx)
    local start
    for cell = 1, ctx.N do
        if st.pred[cell] == 0 then
            if start then return false end
            start = cell
        end
    end
    if not start then return false end
    local k, x = 0, start
    while x ~= 0 do
        k = k + 1
        if ctx.givens[x] and ctx.givens[x] ~= k then return false end
        x = st.succ[x]
        if k > ctx.N then return false end
    end
    return k == ctx.N
end

-- ---------------------------------------------------------------------------
-- Public solver API
-- ---------------------------------------------------------------------------

-- Runs the tiers from state st until the grid is done or stuck.
-- Returns solved, the highest tier needed (at least `used`), and stuck:
-- true when no rule applies any more (as opposed to a contradiction).
-- st.t2 counts the tier-2 steps: tier 2 makes one link at a time, then
-- tier 1 runs dry again, so each step is a link tier 1 could not find.
-- The links found are the same whatever the order (every rule is sound
-- and only narrows the grid), only the count is new.
local function run(st, ctx, max_tier, used)
    st.t2 = st.t2 or 0
    while true do
        if not propagate(st, ctx, 1) then return false, used, false end
        if isComplete(st, ctx) then return isValid(st, ctx), used, false end
        local progressed = false
        if max_tier >= 2 then
            local ok, changed = pass(st, ctx, 2, true)
            if not ok then return false, used, false end
            if changed then
                progressed = true; st.t2 = st.t2 + 1
                if used < 2 then used = 2 end
            end
        end
        if not progressed then return false, used, true end
    end
end

-- Solves by deduction only, using tiers up to max_tier (at most 2).
-- Returns solved (bool), the highest tier actually needed, the state (its
-- t2 field: how many tier-2 steps), and whether it stopped stuck (rather
-- than on a contradiction).
function S.solve(puz, max_tier)
    max_tier = max_tier or 2
    local ctx = context(puz)
    local st = initState(ctx)
    local solved, used, stuck = run(st, ctx, max_tier, 1)
    return solved, used, st, stuck
end

-- Gives one more number to a grid the solver got stuck on, and carries on
-- from where it stopped instead of starting over. Every rule only ever
-- adds links and rules links out, and a new number only removes options,
-- so whatever was deduced before still holds: the solver reaches the same
-- end state as a fresh solve() of the grid with the number added (checked
-- against fresh solves in the generator spec). Givens are puz.givens,
-- which the context shares, so the new number is part of the puzzle too.
local function addGiven(st, ctx, cell, v)
    ctx.givens[cell] = v
    local h = st.head[cell]
    if st.num[h] == 0 then
        local k, x = 0, h
        while x ~= cell do k = k + 1; x = st.succ[x] end
        st.num[h] = v - k
        st.occ = nil
    end
end

-- For the specs: solves puz, then gives the numbers of `cells` one at a
-- time the way the generator does, carrying on from the stuck state.
-- Returns, after each step, whether it is solved and the links found.
function S._incremental(puz, max_tier, cells)
    local ctx = context(puz)
    local st = initState(ctx)
    local out = {}
    local solved, _, stuck = run(st, ctx, max_tier, 1)
    for i, cell in ipairs(cells) do
        if solved or not stuck then break end
        addGiven(st, ctx, cell, puz.number[cell])
        solved, _, stuck = run(st, ctx, max_tier, 1)
        local succ = {}
        for x = 1, ctx.N do succ[x] = st.succ[x] end
        out[i] = { solved = solved, succ = succ }
    end
    return out
end

-- Exhaustive count, stopping at `limit` (default 2).
function S.countSolutions(puz, limit)
    limit = limit or 2
    local ctx = context(puz)
    local count = 0
    local function dfs(st)
        if not propagate(st, ctx, 2) then return end
        if isComplete(st, ctx) then
            if isValid(st, ctx) then count = count + 1 end
            return
        end
        -- Branch on the cell with the fewest possible successors: it takes
        -- exactly one, so the branches are disjoint and exhaustive.
        local best, best_c
        for a = 1, ctx.N do
            if needsSucc(st, ctx, a) then
                local cands = {}
                for _, b in ipairs(ctx.ray[a]) do
                    if canLink(st, ctx, a, b, 2) then cands[#cands + 1] = b end
                end
                if not best or #cands < #best_c then best, best_c = a, cands end
                if #cands <= 1 then break end
            end
        end
        for _, b in ipairs(best_c) do
            local c = clone(st)
            link(c, best, b)
            dfs(c)
            if count >= limit then return end
        end
    end
    dfs(initState(ctx))
    return count
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

local function rand(a, b) return math.random(a, b) end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = rand(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- A random Hamiltonian path over queen moves, as a list of cells. Depth-
-- first with Warnsdorff ordering (fewest onward moves first, noisy ties) so
-- dead ends are rare; restarts if the node budget runs out.
function S.randomPath(n)
    local N = n * n
    local function moves(cell, visited)
        local r, c = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
        local list = {}
        for _, d in ipairs(S.DIRS) do
            local rr, cc = r + d.dr, c + d.dc
            while rr >= 1 and rr <= n and cc >= 1 and cc <= n do
                local b = (rr - 1) * n + cc
                if not visited[b] then list[#list + 1] = b end
                rr, cc = rr + d.dr, cc + d.dc
            end
        end
        return list
    end
    -- how many unvisited cells a queen move from cell reaches
    local function countMoves(cell, visited)
        local r, c = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
        local k = 0
        for _, d in ipairs(S.DIRS) do
            local rr, cc = r + d.dr, c + d.dc
            while rr >= 1 and rr <= n and cc >= 1 and cc <= n do
                if not visited[(rr - 1) * n + cc] then k = k + 1 end
                rr, cc = rr + d.dr, cc + d.dc
            end
        end
        return k
    end
    for _ = 1, 100 do
        local visited, path = {}, {}
        local budget = 20 * N
        local function dfs(cell)
            visited[cell] = true
            path[#path + 1] = cell
            if #path == N then return true end
            budget = budget - 1
            if budget < 0 then return false end
            local cands = moves(cell, visited)
            local scored = {}
            for _, b in ipairs(cands) do
                visited[b] = true
                scored[#scored + 1] = { b = b, s = countMoves(b, visited) + math.random() * 1.5 }
                visited[b] = nil
            end
            table.sort(scored, function(x, y) return x.s < y.s end)
            for _, it in ipairs(scored) do
                if dfs(it.b) then return true end
                if budget < 0 then break end
            end
            visited[cell] = nil
            path[#path] = nil
            return false
        end
        if dfs(rand(1, N)) then return path end
    end
end

-- Arrows (and full numbering) from a path.
function S.puzzleFromPath(n, path)
    local N = n * n
    local arrows, number = {}, {}
    for i, cell in ipairs(path) do
        number[cell] = i
        if i < N then
            local nx = path[i + 1]
            local r1, c1 = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
            local r2, c2 = math.floor((nx - 1) / n) + 1, (nx - 1) % n + 1
            arrows[cell] = S.dirBetween(r1, c1, r2, c2)
        else
            arrows[cell] = 0
        end
    end
    return {
        n = n, arrows = arrows, number = number, path = path,
        givens = { [path[1]] = 1, [path[N]] = N },
    }
end

S.TIER = { easy = 1, medium = 2, hard = 2 }

-- What each level asks for (1.3.0):
--   tier            the highest solver tier the grid needs
--   min_t2, max_t2  how many tier-2 steps it needs (see run())
--   attempts        how many paths to try for that; past it, the grid
--                   closest to the window found so far is used
-- Hard used to need one-step trials (a third tier), which is guessing. It
-- is now tier 2 like Medium, with clearly more tier-2 steps; Medium gets a
-- ceiling so the two never overlap. A 4x4 grid seldom needs tier 2 at all
-- (two tier-2 steps: about 1 path in 100), so its tries are many but
-- cheap, and Hard there is the best of them when none gets to two. The attempt counts keep the slowest
-- grid around 40 ms on a desktop (about 1 s on a Kobo).
local MED_MAX   = { [4] = 1, [5] = 1, [6] = 3, [7] = 7 }
local MED_TRIES = { [4] = 80, [5] = 15, [6] = 10, [7] = 6 }
local HARD_MIN  = { [4] = 2, [5] = 3, [6] = 5, [7] = 9 }
local HARD_TRIES = { [4] = 70, [5] = 22, [6] = 10, [7] = 6 }
S.LEVELS = {
    easy   = function(n) return { tier = 1, min_t2 = 0, max_t2 = 0,
                                  attempts = n <= 4 and 80 or 15 } end,
    medium = function(n) return { tier = 2, min_t2 = 1, max_t2 = MED_MAX[n] or 7,
                                  attempts = MED_TRIES[n] or 6 } end,
    hard   = function(n) return { tier = 2, min_t2 = HARD_MIN[n] or 9, max_t2 = math.huge,
                                  attempts = HARD_TRIES[n] or 6 } end,
}

-- How far a solved grid is from what the level asks for (0 = fits).
local function miss(level, tier, t2)
    if tier ~= level.tier then return 1000 + math.abs(tier - level.tier) end
    if t2 < level.min_t2 then return level.min_t2 - t2 end
    if t2 > level.max_t2 then return t2 - level.max_t2 end
    return 0
end

-- Builds a puzzle that fits the difficulty's level (S.LEVELS) where it can.
-- Returns the puzzle and an info table { tier, t2, givens, attempts, miss }
-- (miss > 0: no try fitted, this is the closest one).
--
-- Same scheme as Train Tracks: add numbers the stuck solver could not place
-- until the grid is solvable within the tier, take back the ones it can do
-- without, and retry from a new path if the grid ends up easier than asked.
-- 1 and N always stay. Every returned grid has passed countSolutions() == 1.
-- opts.on_progress (optional): called with a 0..1 fraction as it goes.
function S.generate(n, difficulty, opts)
    opts = opts or {}
    local on_progress = opts.on_progress
    local level = (S.LEVELS[difficulty] or S.LEVELS.easy)(n)
    if opts.min_t2 then level.min_t2 = opts.min_t2 end
    if opts.max_t2 then level.max_t2 = opts.max_t2 end
    local target = level.tier
    local max_attempts = opts.max_attempts or level.attempts
    local N = n * n
    local best, best_info
    for attempt = 1, max_attempts do
        -- each attempt fills half of what is left of the bar
        local function report(phase)
            if on_progress then on_progress(1 - 0.5 ^ (attempt - 1) * (1 - 0.5 * phase)) end
        end
        report(0)
        local path = S.randomPath(n)
        local puz = S.puzzleFromPath(n, path)
        -- Each number added only narrows the grid, so the solver resumes
        -- from its stuck state rather than solving the whole grid again.
        local ctx = context(puz)
        local st = initState(ctx)
        local solved, _, stuck = run(st, ctx, target, 1)
        -- snaps[j]: where the solver got stuck with the first j numbers
        -- added (order[j] the j-th one), kept for the removal pass below
        local snaps, order, added_at = {}, {}, {}
        if stuck then snaps[0] = clone(st) end
        local guard = 0
        while not solved and guard < N do
            guard = guard + 1
            report(0.5 * guard / N)
            local cands = {}
            for cell = 1, N do
                if not puz.givens[cell] and (st.succ[cell] == 0 or st.pred[cell] == 0) then
                    cands[#cands + 1] = cell
                end
            end
            if #cands == 0 then break end
            local cell = cands[rand(1, #cands)]
            order[guard], added_at[cell] = cell, guard
            if stuck then
                addGiven(st, ctx, cell, puz.number[cell])
                solved, _, stuck = run(st, ctx, target, 1)
                if stuck and not solved and snaps[guard - 1] then snaps[guard] = clone(st) end
            else
                -- a contradiction (never seen: the rules are sound) leaves
                -- st unusable, so solve afresh in that case
                puz.givens[cell] = puz.number[cell]
                solved, _, st, stuck = S.solve(puz, target)
                ctx = context(puz)
            end
        end
        if solved then
            local cells = {}
            for cell, v in pairs(puz.givens) do
                if v ~= 1 and v ~= N then cells[#cells + 1] = cell end
            end
            table.sort(cells)
            shuffle(cells)
            -- Taking a number out: the solver starts from where it got stuck
            -- with the longest run of first-added numbers still all there
            -- (saved above) and is handed the rest at once. Same outcome
            -- as solving from scratch: numbers only narrow the grid.
            for i, cell in ipairs(cells) do
                report(0.5 + 0.5 * i / #cells)
                local v = puz.givens[cell]
                puz.givens[cell] = nil
                local j = 0
                while snaps[j + 1] and puz.givens[order[j + 1]] do j = j + 1 end
                local ok
                if snaps[j] then
                    local t = clone(snaps[j])
                    for c2, w in pairs(puz.givens) do
                        if (added_at[c2] or 0) > j then addGiven(t, ctx, c2, w) end
                    end
                    ok = run(t, ctx, target, 1)
                else
                    ok = S.solve(puz, target)
                end
                if not ok then puz.givens[cell] = v end
            end
            local _, tier, fst = S.solve(puz, target)
            local t2 = fst.t2
            -- the level is checked first: countSolutions is the dear part
            local m = miss(level, tier, t2)
            if (not best or m < best_info.miss) and S.countSolutions(puz, 2) == 1 then
                local k = 0
                for _ in pairs(puz.givens) do k = k + 1 end
                local info = { tier = tier, t2 = t2, givens = k, attempts = attempt, miss = m }
                if m == 0 then return puz, info end
                best, best_info = puz, info
            end
        end
    end
    if best then return best, best_info end
    -- Unreachable in practice: every number given is always unique.
    local path = S.randomPath(n)
    local puz = S.puzzleFromPath(n, path)
    for i, cell in ipairs(path) do puz.givens[cell] = i end
    return puz, { tier = 1, t2 = 0, givens = N, attempts = max_attempts, miss = 0 }
end

return S
