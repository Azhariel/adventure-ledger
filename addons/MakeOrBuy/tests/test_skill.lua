-- Unit tests for Skill.lua: threshold estimates, skill-up chance and the route planner.
-- Techniques (ISTQB): equivalence partitioning over the four colours, boundary value analysis at each
-- threshold, state-based testing of accumulated observations, and use-case tests for the route.
return function(H)
    local ns = H.load({ "Skill.lua" })
    local Skill = ns.Skill

    H.test("default thresholds from the learn skill: yellow +25, grey +25 more, green halfway", function()
        local t = Skill.Thresholds(1, nil)
        H.eq(t.y, 26); H.eq(t.g, 38); H.eq(t.r, 51)
    end)

    H.test("no learn skill and no observations: no estimate", function()
        H.eq(Skill.Thresholds(nil, nil), nil)
        H.eq(Skill.Thresholds(nil, {}), nil)
    end)

    H.test("Observe bounds each threshold by colour (one test per equivalence class)", function()
        local b = Skill.Observe(nil, 10, 0) -- orange at 10: yellow starts above 10
        H.eq(b.y[1], 11)
        b = Skill.Observe({}, 30, 1) -- yellow at 30: Y <= 30 < G
        H.eq(b.y[2], 30); H.eq(b.g[1], 31)
        b = Skill.Observe({}, 40, 2) -- green at 40: G <= 40 < R
        H.eq(b.g[2], 40); H.eq(b.r[1], 41)
        b = Skill.Observe({}, 55, 3) -- grey at 55: R <= 55
        H.eq(b.r[2], 55)
    end)

    H.test("observations override the default guess (state accumulates across scans)", function()
        -- Learned at 1; still orange at 40, so yellow must be 41 or later, not the default 26
        local b = Skill.Observe(nil, 40, 0)
        local t = Skill.Thresholds(1, b)
        H.eq(t.y, 41); H.eq(t.r, 66)
        -- Later seen yellow at 45 and green at 52: Y <= 45, G in (45, 52], R > 52
        b = Skill.Observe(b, 45, 1)
        b = Skill.Observe(b, 52, 2)
        t = Skill.Thresholds(1, b)
        H.eq(t.y, 41); H.truthy(t.g > 45 and t.g <= 52, "green " .. t.g); H.truthy(t.r > 52)
        H.eq(Skill.DifficultyAt(t, 45), 1)
        H.eq(Skill.DifficultyAt(t, 52), 2)
    end)

    H.test("an early grey sighting pulls the estimate down so the colours still fit", function()
        local t = Skill.Thresholds(1, Skill.Observe(nil, 30, 3)) -- grey at 30
        H.truthy(t.r <= 30, "grey " .. t.r)
        H.truthy(t.y < t.g and t.g < t.r)
        H.eq(Skill.DifficultyAt(t, 30), 3)
    end)

    H.test("contradicting observations (e.g. after a patch) reset the bounds", function()
        local b = Skill.Observe(nil, 50, 3) -- grey at 50
        b = Skill.Observe(b, 60, 0) -- orange at 60 contradicts it
        H.eq(b.r[2], Skill.UNBOUNDED, "old grey bound dropped")
        H.eq(b.y[1], 61)
    end)

    -- Regression: math.huge was saved by WoW as nil, so bounds came back as { 79 } and comparisons errored
    H.test("bounds as saved by an older version ({ 79 }, { 0, nil }) read as unbounded, no error", function()
        local saved = { y = { 79 }, g = { 0 }, r = { 0, 78 } }
        local t = Skill.Thresholds(50, saved)
        H.truthy(t and t.y < t.g and t.g < t.r, "valid estimate")
        local b = Skill.Observe({ y = { 79 }, g = { 0 }, r = { 0 } }, 80, 1)
        H.eq(b.y[2], 80); H.eq(b.g[1], 81); H.eq(b.r[2], Skill.UNBOUNDED)
        H.eq(Skill.Thresholds(nil, { y = { 79 } }).y, 79)
    end)

    H.test("bounds survive a save/load round trip (no infinity stored)", function()
        local b = Skill.Observe(nil, 10, 0)
        for _, k in ipairs({ "y", "g", "r" }) do
            for i = 1, 2 do
                H.truthy(b[k][i] ~= math.huge and b[k][i] ~= nil, k .. i)
            end
        end
    end)

    H.test("a single impossible sighting (grey at skill 1) terminates instead of looping", function()
        local b = Skill.Observe(nil, 1, 3)
        H.eq(b.r[2], 1)
    end)

    H.test("Chance boundaries: 100% below yellow, linear to 0% at grey", function()
        local t = { y = 26, g = 38, r = 51 }
        H.eq(Skill.Chance(t, 25), 1, "last orange point")
        H.eq(Skill.Chance(t, 26), 1, "first yellow point")
        H.near(Skill.Chance(t, 27), 24 / 25)
        H.near(Skill.Chance(t, 50), 1 / 25, "last green point")
        H.eq(Skill.Chance(t, 51), 0, "grey")
    end)

    local function cand(key, learn, t, net, extra)
        local c = { key = key, name = "R" .. key, learn = learn, thresholds = t, net = net, cost = net }
        for k, v in pairs(extra or {}) do c[k] = v end
        return c
    end

    H.test("route with one orange recipe: one craft per point", function()
        local r = Skill.Route({ cand(1, 1, { y = 26, g = 38, r = 51 }, 10) }, 1, 5)
        H.eq(#r.segments, 1)
        H.eq(r.segments[1].from, 1); H.eq(r.segments[1].to, 5)
        H.eq(r.crafts, 4); H.eq(r.net, 40)
        H.eq(r.stuckAt, nil)
    end)

    H.test("route switches to a newly orange recipe once the old one turns yellow", function()
        local cheap = cand(1, 1, { y = 10, g = 15, r = 20 }, 10)
        local next = cand(2, 10, { y = 30, g = 40, r = 50 }, 12)
        local r = Skill.Route({ cheap, next }, 1, 14)
        H.eq(#r.segments, 2)
        H.eq(r.segments[1].candidate, cheap); H.eq(r.segments[1].to, 12)
        -- At 10 the cheap one is yellow (chance 1) at 10c; the other is orange at 12c, so cheap still wins at 10,
        -- then at 11 cheap costs 10/(9/10) = 11.1c < 12c, at 12 it's 12.5c > 12c
        H.eq(r.segments[1].candidate.key, 1)
        H.eq(r.segments[2].candidate, next)
        H.eq(r.segments[2].from, 12)
    end)

    H.test("a learn cost is spread over the points a recipe can still give", function()
        local known = cand(1, 1, { y = 30, g = 40, r = 50 }, 20)
        -- 1c cheaper per craft, but 100c to learn spread over 10 points = +10c per point: not worth it
        local pricey = cand(2, 1, { y = 30, g = 40, r = 50 }, 19, { learnCost = 100 })
        local r = Skill.Route({ known, pricey }, 1, 11)
        H.eq(r.segments[1].candidate, known)
        H.eq(r.learnCost, 0)
        -- Free-ish to learn (5c over 10 points = 0.5c/point) and 1c cheaper: learn it
        pricey.learnCost = 5
        r = Skill.Route({ known, pricey }, 1, 11)
        H.eq(r.segments[1].candidate, pricey)
        H.eq(r.learnCost, 5); H.eq(#r.learned, 1)
        H.eq(r.cost, 10 * 19 + 5)
    end)

    H.test("route reports where it gets stuck (no recipe gives points)", function()
        local r = Skill.Route({ cand(1, 1, { y = 3, g = 4, r = 5 }, 10) }, 1, 10)
        H.eq(r.stuckAt, 5)
        H.eq(r.segments[1].to, 5)
    end)

    H.test("recipes above your skill wait until you reach their learn level", function()
        local r = Skill.Route({ cand(1, 5, { y = 30, g = 40, r = 50 }, 10) }, 1, 10)
        H.eq(r.stuckAt, 1)
        r = Skill.Route({ cand(1, 5, { y = 30, g = 40, r = 50 }, 10) }, 5, 10)
        H.eq(r.stuckAt, nil); H.eq(r.crafts, 5)
    end)

    H.test("orange recipes that give several points need fewer crafts", function()
        local r = Skill.Route({ cand(1, 1, { y = 30, g = 40, r = 50 }, 10, { ups = 2 }) }, 1, 5)
        H.eq(r.crafts, 2)
    end)

    H.test("expected crafts on yellow sum 1/chance and round up per segment", function()
        local r = Skill.Route({ cand(1, 1, { y = 1, g = 3, r = 5 }, 10) }, 1, 3)
        -- chances 4/4 then 3/4: 1 + 1.333 = 2.33 -> 3 whole crafts
        H.near(r.segments[1].crafts, 1 + 4 / 3)
        H.eq(r.crafts, 3)
    end)

    H.test("earning crafts count as free: the route takes fewer crafts, not more money", function()
        -- Green-ish recipe earns 100c a craft at 10% chance (10 crafts per point = 1000c "earned");
        -- an orange one earns 5c (1 craft). Both points are free; the orange one needs fewer crafts.
        local green = cand(1, 1, { y = 1, g = 2, r = 12 }, -100)
        local orange = cand(2, 1, { y = 30, g = 40, r = 50 }, -5)
        local r = Skill.Route({ green, orange }, 11, 12)
        H.eq(r.segments[1].candidate, orange)
        -- Equal crafts: the bigger earner wins
        local orange2 = cand(3, 1, { y = 30, g = 40, r = 50 }, -50)
        r = Skill.Route({ orange, orange2 }, 11, 12)
        H.eq(r.segments[1].candidate, orange2)
    end)

    H.test("a free-to-learn trainer recipe is still listed as learned on the way", function()
        local c = cand(1, 1, { y = 30, g = 40, r = 50 }, 10, { toLearn = true, learnCost = 0 })
        local r = Skill.Route({ c }, 1, 3)
        H.eq(#r.learned, 1); H.eq(r.learnCost, 0)
    end)
end
