-- Skill: skill-up chances and the cheapest route to a target skill. Pure logic (no WoW calls).
--
-- Every recipe has four thresholds: it is orange from the skill you learn it at, yellow from Y, green from G
-- and grey from R. The classic skill-up chance is 100% below yellow and falls linearly to 0% at grey:
--     chance(s) = (R - s) / (R - Y)   for Y <= s < R
-- The game doesn't expose Y/G/R, so we estimate them:
--   * defaults from the learn skill L:  Y = L + 25, R = Y + 25, G halfway between (typical of classic recipes)
--   * narrowed by observations: every time the profession is scanned we note each recipe's colour at the
--     current skill, which bounds the thresholds (e.g. yellow at 63 means Y <= 63 < G)
local _, ns = ...

local Skill = {}
ns.Skill = Skill

Skill.YELLOW_AFTER_LEARN = 25
Skill.GREY_AFTER_YELLOW = 25
-- "No upper limit". Not math.huge: WoW can't save infinity in SavedVariables (it comes back as nil).
Skill.UNBOUNDED = 100000
local INF = Skill.UNBOUNDED
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

-- A { lo, hi } range with missing or broken parts read as unbounded (older saves hold { 79 } or { 0, nil })
local function range(v)
    if type(v) ~= "table" then
        return { 0, INF }
    end
    local lo = type(v[1]) == "number" and v[1] or 0
    local hi = type(v[2]) == "number" and v[2] < INF and v[2] or INF
    return { lo, hi }
end

-- bounds = { y = { lo, hi }, g = { lo, hi }, r = { lo, hi } } (inclusive). Missing parts mean unbounded.
local function bound(b, key)
    local v = range(b[key])
    b[key] = v
    return v
end

-- Records that the recipe has `difficulty` (0 orange, 1 yellow, 2 green, 3 grey) at skill `s`.
-- Mutates and returns `bounds`. Contradicting old data (e.g. after a patch) is reset.
function Skill.Observe(bounds, s, difficulty, retried)
    bounds = bounds or {}
    local y, g, r = bound(bounds, "y"), bound(bounds, "g"), bound(bounds, "r")
    local function raise(v, lo) v[1] = max(v[1], lo) end
    local function lower(v, hi) v[2] = min(v[2], hi) end
    if difficulty == 0 then
        raise(y, s + 1)
    elseif difficulty == 1 then
        lower(y, s); raise(g, s + 1)
    elseif difficulty == 2 then
        lower(g, s); raise(r, s + 1)
    elseif difficulty == 3 then
        lower(r, s)
    end
    -- Each range must be non-empty and the order Y < G < R must stay possible
    local conflict = y[1] > y[2] or g[1] > g[2] or r[1] > r[2]
        or y[1] >= g[2] or g[1] >= r[2] or y[1] + 1 >= r[2]
    if conflict and not retried then
        bounds.y, bounds.g, bounds.r = nil, nil, nil
        return Skill.Observe(bounds, s, difficulty, true)
    end
    return bounds
end

local function clamp(v, lo, hi)
    if v < lo then v = lo end
    if v > hi then v = hi end
    return v
end

-- Estimated thresholds { y, g, r } from the learn skill (may be nil) and observed bounds (may be nil).
-- Returns nil when there's nothing to go on.
function Skill.Thresholds(learn, bounds)
    bounds = bounds or {}
    local yb, gb, rb = range(bounds.y), range(bounds.g), range(bounds.r)
    local base
    if learn then
        base = learn + Skill.YELLOW_AFTER_LEARN
    elseif yb[2] < INF then
        base = yb[2]
    elseif yb[1] > 0 then
        base = yb[1]
    else
        return nil
    end
    local y = clamp(base, max(yb[1], (learn or 0) + 1), yb[2])
    -- grey/green must leave room above yellow; their own lower bounds can also push yellow down
    y = min(y, max(rb[2], 2) - 2, max(gb[2], 1) - 1)
    local r = clamp(y + Skill.GREY_AFTER_YELLOW, max(rb[1], y + 2), rb[2])
    local g = clamp(y + floor((r - y) / 2), max(gb[1], y + 1), min(gb[2], r - 1))
    return { y = y, g = g, r = r }
end

-- Difficulty (0..3) the thresholds predict at skill s
function Skill.DifficultyAt(t, s)
    if s < t.y then return 0 end
    if s < t.g then return 1 end
    if s < t.r then return 2 end
    return 3
end

-- Chance one craft gives a point at skill s
function Skill.Chance(t, s)
    if s < t.y then return 1 end
    if s >= t.r then return 0 end
    return (t.r - s) / (t.r - t.y)
end

local EPS = 1e-9

-- Ordering of two options for one skill point: cost, then crafts, then net (more earned first), then key
function Skill.Better(value, crafts, c, bestValue, bestCrafts, best)
    if not bestValue then return true end
    if value < bestValue - EPS then return true end
    if value > bestValue + EPS then return false end
    if crafts < bestCrafts - EPS then return true end
    if crafts > bestCrafts + EPS then return false end
    if c.net ~= best.net then return c.net < best.net end
    return (c.key or 0) < (best.key or 0)
end

-- Cheapest expected route from skill `from` to `to`.
-- candidates: { { key, name, learn, thresholds, net (copper per craft after selling), cost (per craft),
--                 toLearn (true if not known yet), learnCost, ups (points per orange craft, default 1) }, ... }
-- At each skill level the candidate with the lowest expected cost for that point wins. A craft that earns
-- money counts as free (not as "the more crafts the better", which would favour 25 green crafts per point);
-- among equally cheap points the one needing fewest crafts wins, then the one earning most.
-- An unlearned recipe (toLearn) has its learn cost spread over the points it can still give (until grey or
-- the target).
-- Returns { segments = { { candidate, from, to, crafts (expected, fractional), net, cost } },
--           crafts, net, cost, learnCost, learned = { candidate, ... }, stuckAt = skill or nil }
function Skill.Route(candidates, from, to)
    local route = { segments = {}, crafts = 0, net = 0, cost = 0, learnCost = 0, learned = {} }
    local paid = {}
    local current
    for s = from, to - 1 do
        local best, bestValue, bestCrafts
        for _, c in ipairs(candidates) do
            if c.thresholds and (c.learn or 0) <= s then
                local chance = Skill.Chance(c.thresholds, s)
                if chance > 0 then
                    local ups = (s < c.thresholds.y and c.ups and c.ups > 1) and c.ups or 1
                    local crafts = 1 / (chance * ups)
                    local value = crafts * max(c.net, 0)
                    if (c.learnCost or 0) > 0 and not paid[c] then
                        local span = max(1, min(c.thresholds.r, to) - s)
                        value = value + c.learnCost / span
                    end
                    if Skill.Better(value, crafts, c, bestValue, bestCrafts, best) then
                        best, bestValue, bestCrafts = c, value, crafts
                    end
                end
            end
        end
        if not best then
            route.stuckAt = s
            break
        end
        if (best.toLearn or (best.learnCost or 0) > 0) and not paid[best] then
            paid[best] = true
            route.learnCost = route.learnCost + best.learnCost
            route.learned[#route.learned + 1] = best
        end
        if not current or current.candidate ~= best then
            current = { candidate = best, from = s, to = s, crafts = 0, net = 0, cost = 0 }
            route.segments[#route.segments + 1] = current
        end
        current.to = s + 1
        current.crafts = current.crafts + bestCrafts
        current.net = current.net + bestCrafts * best.net
        current.cost = current.cost + bestCrafts * (best.cost or 0)
    end
    for _, seg in ipairs(route.segments) do
        seg.wholeCrafts = ceil(seg.crafts - 1e-9)
        route.crafts = route.crafts + seg.wholeCrafts
        route.net = route.net + seg.wholeCrafts * seg.candidate.net
        route.cost = route.cost + seg.wholeCrafts * (seg.candidate.cost or 0)
    end
    route.net = route.net + route.learnCost
    route.cost = route.cost + route.learnCost
    return route
end
