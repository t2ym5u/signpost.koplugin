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
--           still free between the numbers already placed;
--   tier 3  one-step trial: assume a link for a cell with few choices, push
--           tiers 1-2, and rule it out if that runs into a contradiction.
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
    return o
end

-- Which chain holds each number, for tier 2. Cached until the next link.
local function occupancy(st, ctx)
    if st.occ then return st.occ, st.maxgap end
    local occ = {}
    for cell = 1, ctx.N do
        if st.head[cell] == cell and st.num[cell] > 0 then
            for k = st.num[cell], st.num[cell] + st.len[cell] - 1 do occ[k] = cell end
        end
    end
    local maxgap, run = 0, 0
    for k = 1, ctx.N do
        if occ[k] then run = 0 else run = run + 1; if run > maxgap then maxgap = run end end
    end
    st.occ, st.maxgap = occ, maxgap
    return occ, maxgap
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
        local occ, maxgap = occupancy(st, ctx)
        if h then
            for k = h, h + L - 1 do
                local owner = occ[k]
                if owner and owner ~= ha and owner ~= b then return false end
            end
        elseif L > maxgap then
            return false
        end
    end
    return true
end

local function link(st, a, b)
    local ha = st.head[a]
    if st.num[ha] == 0 and st.num[b] > 0 then st.num[ha] = st.num[b] - st.len[ha] end
    st.succ[a], st.pred[b] = b, a
    local x = b
    while x ~= 0 do
        st.head[x] = ha
        x = st.succ[x]
    end
    st.tail[ha] = st.tail[b]
    st.len[ha] = st.len[ha] + st.len[b]
    st.occ = nil
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
local function pass(st, ctx, tier)
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
            if count == 1 then link(st, a, only); changed = true end
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
            if count == 1 then link(st, only, b); changed = true end
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

-- Tier 3: try each link of a cell with two or three choices: first every
-- cell with two, then every cell with three. st doesn't change during the
-- scan (each try works on a copy), so the candidate lists are worked out
-- once, and the second round skips the two-choice cells the first round
-- already tried in vain -- the old scan tried them all again, which was
-- most of the time a 7x7 Hard grid took. Same links tried in the same
-- order, so the same outcome.
local function probe(st, ctx)
    local cands_of = {}
    for a = 1, ctx.N do
        if needsSucc(st, ctx, a) then
            local cands = {}
            for _, b in ipairs(ctx.ray[a]) do
                if canLink(st, ctx, a, b, 2) then cands[#cands + 1] = b end
            end
            cands_of[a] = cands
        end
    end
    for count = 2, 3 do
        for a = 1, ctx.N do
            local cands = cands_of[a]
            if cands and #cands == count then
                for _, b in ipairs(cands) do
                    local c = clone(st)
                    link(c, a, b)
                    if not propagate(c, ctx, 2) or (isComplete(c, ctx) and not isValid(c, ctx)) then
                        st.forbid[a * 4096 + b] = true
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Public solver API
-- ---------------------------------------------------------------------------

-- Solves by deduction only, using tiers up to max_tier.
-- Returns solved (bool), the highest tier actually needed, and the state.
function S.solve(puz, max_tier)
    max_tier = max_tier or 3
    local ctx = context(puz)
    local st = initState(ctx)
    local used = 1
    while true do
        if not propagate(st, ctx, 1) then return false, used, st end
        if isComplete(st, ctx) then return isValid(st, ctx), used, st end
        local progressed = false
        if max_tier >= 2 then
            local ok, changed = pass(st, ctx, 2)
            if not ok then return false, used, st end
            if changed then progressed = true; if used < 2 then used = 2 end end
        end
        if not progressed and max_tier >= 3 then
            if probe(st, ctx) then progressed = true; used = 3 end
        end
        if not progressed then return false, used, st end
    end
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
                scored[#scored + 1] = { b = b, s = #moves(b, visited) + math.random() * 1.5 }
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

S.TIER = { easy = 1, medium = 2, hard = 3 }

-- Builds a puzzle needing exactly the difficulty's tier where it can.
-- Returns the puzzle and an info table { tier, givens, attempts }.
--
-- Same scheme as Train Tracks: add numbers the stuck solver could not place
-- until the grid is solvable within the tier, take back the ones it can do
-- without, and retry from a new path if the grid ends up easier than asked.
-- 1 and N always stay. Every returned grid has passed countSolutions() == 1.
-- opts.on_progress (optional): called with a 0..1 fraction as it goes.
function S.generate(n, difficulty, opts)
    opts = opts or {}
    local on_progress = opts.on_progress
    local target = S.TIER[difficulty] or 1
    -- A 4×4 grid seldom needs more than tier 1, but tries are cheap there.
    local max_attempts = opts.max_attempts or (n <= 4 and 80 or 15)
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
        local solved, _, st = S.solve(puz, target)
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
            puz.givens[cell] = puz.number[cell]
            solved, _, st = S.solve(puz, target)
        end
        if solved then
            local cells = {}
            for cell, v in pairs(puz.givens) do
                if v ~= 1 and v ~= N then cells[#cells + 1] = cell end
            end
            table.sort(cells)
            shuffle(cells)
            for i, cell in ipairs(cells) do
                report(0.5 + 0.5 * i / #cells)
                local v = puz.givens[cell]
                puz.givens[cell] = nil
                if not S.solve(puz, target) then puz.givens[cell] = v end
            end
            local _, tier = S.solve(puz, target)
            if S.countSolutions(puz, 2) == 1 then
                local k = 0
                for _ in pairs(puz.givens) do k = k + 1 end
                local info = { tier = tier, givens = k, attempts = attempt }
                if tier == target then return puz, info end
                if not best or tier > best_info.tier then best, best_info = puz, info end
            end
        end
    end
    if best then return best, best_info end
    -- Unreachable in practice: every number given is always unique.
    local path = S.randomPath(n)
    local puz = S.puzzleFromPath(n, path)
    for i, cell in ipairs(path) do puz.givens[cell] = i end
    return puz, { tier = 1, givens = N, attempts = max_attempts }
end

return S
