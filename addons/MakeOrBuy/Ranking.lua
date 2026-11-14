-- Ranking: plans every known recipe of a profession and ranks them, by profit or by the cost of each skill
-- point. Also ranks unlearned recipes by how quickly they pay back. Pure logic (no WoW calls).
local _, ns = ...

local Ranking = {}
ns.Ranking = Ranking

-- Fallback chance that one craft gives a skill point, by recipe difficulty (Enum.TradeskillRelativeDifficulty:
-- 0 orange/optimal, 1 yellow/medium, 2 green/easy, 3 grey/trivial), used when Skill can't estimate the
-- recipe's thresholds. Yellow and green are the averages over each band.
Ranking.SKILL_CHANCE = { [0] = 1, [1] = 0.75, [2] = 0.25, [3] = 0 }

-- A row is "worth crafting" only if its profit is strictly positive and every reagent has a price.
-- Missing prices count as 0 in the plan, which would overstate profit.
function Ranking.IsWorthCrafting(row)
    return row.profit ~= nil and row.profit > 0 and row.complete
end

-- A row "levels" the profession if a craft can still give a skill point.
function Ranking.Levels(row)
    return (row.points or 0) > 0
end

-- Common part of a row: plan, cost, sale value and profit
local function baseRow(recipe, recipesByOutput, price, saleValue, opts)
    local plan = ns.Planner.PlanRecipe(recipe, recipesByOutput, price, opts)
    local saleUnit, saleSource = saleValue(recipe.outputItemID)
    local row = {
        recipe = recipe,
        plan = plan,
        cost = plan.total,
        naiveCost = plan.naiveTotal,
        complete = plan.complete,
        subCrafts = ns.Planner.UsesSubCrafts(plan),
        saleUnit = saleUnit,
        saleSource = saleSource,
        saleTotal = saleUnit and saleUnit * plan.outputQty or nil,
    }
    if saleUnit then
        row.profit = ns.Planner.ProfitFromValue(saleUnit, plan.outputQty, plan.total)
        if plan.total > 0 then
            row.margin = row.profit / plan.total
        end
    end
    row.net = math.ceil(plan.total - (row.saleTotal or 0))
    if opts.market and saleSource == "ah" then
        row.market = opts.market(recipe.outputItemID)
        row.risky = ns.Market.Risky(row.market)
    end
    return row
end

-- recipes:              { [recipeID] = recipe } (saved scanner data)
-- price(itemID):        cheapest purchase price for reagents
-- saleValue(itemID):    net value of one crafted item -> netUnit, "ah"|"vendor" (see Planner.SaleValue)
-- opts.profession:      only recipes with this profession key (nil = all)
-- opts.recipeInfo(id):  -> { relativeDifficulty, numSkillUps } for skill-up figures (optional)
-- opts.skillChance(id, difficulty): -> chance (0..1) or nil (then SKILL_CHANCE is used); see Skill.Chance
-- opts.market(itemID):  -> Market.Assess result for the crafted item's AH price (optional)
-- Returns every matching row, plus counts { worth = n, levels = n }.
-- Row: recipe, plan, cost, naiveCost, complete, subCrafts, saleUnit, saleSource, saleTotal, profit, margin,
--      net (cost minus sale value; negative = you earn), difficulty, chance, estimated, points (expected skill
--      points per craft), perPoint (net / points), market, risky, worth, levels
function Ranking.Build(recipes, recipesByOutput, price, saleValue, opts)
    opts = opts or {}
    local rows, counts = {}, { worth = 0, levels = 0 }
    for _, recipe in pairs(recipes or {}) do
        if opts.profession == nil or recipe.profession == opts.profession then
            local row = baseRow(recipe, recipesByOutput, price, saleValue, opts)

            local info = opts.recipeInfo and opts.recipeInfo(recipe.recipeID)
            if info and info.relativeDifficulty ~= nil then
                local d = info.relativeDifficulty
                row.difficulty = d
                local chance = opts.skillChance and opts.skillChance(recipe.recipeID, d)
                if chance == nil then
                    chance = Ranking.SKILL_CHANCE[d] or 0
                end
                row.chance = chance
                row.estimated = (d == 1 or d == 2)
                local ups = (d == 0 and info.numSkillUps and info.numSkillUps > 1) and info.numSkillUps or 1
                row.points = chance * ups
                if row.points > 0 and row.complete then
                    row.perPoint = row.net / row.points
                end
            end

            row.worth = Ranking.IsWorthCrafting(row)
            row.levels = Ranking.Levels(row)
            if row.worth then
                counts.worth = counts.worth + 1
            end
            if row.levels then
                counts.levels = counts.levels + 1
            end
            rows[#rows + 1] = row
        end
    end
    return rows, counts
end

-- Unlearned recipes and whether they pay for themselves.
-- unlearned:            { [recipeID] = recipe } (recipes you could learn, with reagents)
-- opts.learnInfo(id):   -> { learn = skill, cost = trainer copper, sources = "tvdq...", teach = itemID } or nil
-- price:                also prices the recipe item (teach) for vendor/AH recipes
-- opts.skill:           current skill, for "can learn now"
-- Row adds: learn, sources, teach (recipe item ID or nil), learnCost (nil if unknown), learnSource ("trainer"|"vendor"|"ah"), canLearn,
--           payback (crafts until profit covers the learn cost; nil if it never does)
function Ranking.BuildLearn(unlearned, recipesByOutput, price, saleValue, opts)
    opts = opts or {}
    local rows, counts = {}, { worth = 0 }
    for _, recipe in pairs(unlearned or {}) do
        if opts.profession == nil or recipe.profession == opts.profession then
            local row = baseRow(recipe, recipesByOutput, price, saleValue, opts)
            local li = opts.learnInfo and opts.learnInfo(recipe.recipeID) or {}
            row.learn = li.learn
            row.sources = li.sources or ""
            row.teach = li.teach
            if row.sources:find("t") and (li.cost or 0) > 0 then
                row.learnCost, row.learnSource = li.cost, "trainer"
            elseif li.teach then
                local p, src = price(li.teach)
                if p then
                    row.learnCost, row.learnSource = p, src
                end
            elseif row.sources:find("t") then
                row.learnCost, row.learnSource = 0, "trainer"
            end
            row.canLearn = row.learn ~= nil and opts.skill ~= nil and row.learn <= opts.skill
            if row.profit and row.profit > 0 and row.complete and row.learnCost then
                row.payback = math.max(1, math.ceil(row.learnCost / row.profit))
            end
            row.worth = Ranking.IsWorthCrafting(row)
            if row.worth then
                counts.worth = counts.worth + 1
            end
            rows[#rows + 1] = row
        end
    end
    return rows, counts
end

-- Route candidates (see Skill.Route) from learned rows and, optionally, learn rows.
-- thresholds(recipeID) -> Skill.Thresholds result or nil; learnSkill(recipeID) -> skill or nil.
-- Only complete plans are used. Unlearned recipes need a known learn cost and must be trainer/vendor ones.
function Ranking.RouteCandidates(rows, learnRows, thresholds, learnSkill)
    local list = {}
    local function add(row, learnCost, toLearn)
        local id = row.recipe.recipeID
        local t = thresholds(id)
        if row.complete and t then
            list[#list + 1] = {
                key = id,
                row = row,
                name = row.recipe.name,
                learn = learnSkill(id) or 0,
                thresholds = t,
                net = row.net,
                cost = row.cost,
                learnCost = learnCost,
                toLearn = toLearn,
            }
        end
    end
    for _, row in ipairs(rows or {}) do
        add(row, 0, false)
    end
    for _, row in ipairs(learnRows or {}) do
        if row.learnCost and row.learn and (row.sources:find("t") or row.sources:find("v")) then
            add(row, row.learnCost, true)
        end
    end
    return list
end

-- Keeps rows for which keep(row) is true
function Ranking.Filter(rows, keep)
    local kept = {}
    for _, row in ipairs(rows) do
        if keep(row) then
            kept[#kept + 1] = row
        end
    end
    return kept
end

local function rowName(row)
    return row.recipe.name or ""
end

local getters = {
    name = rowName,
    cost = function(row) return row.cost end,
    sale = function(row) return row.saleTotal end,
    profit = function(row) return row.complete and row.profit or nil end,
    margin = function(row) return row.complete and row.margin or nil end,
    net = function(row) return row.complete and row.net or nil end,
    perPoint = function(row) return row.perPoint end,
    learn = function(row) return row.learn end,
    learnCost = function(row) return row.learnCost end,
    payback = function(row) return row.payback end,
}
Ranking.SORT_KEYS = getters

-- Per-point order: a point you earn money on counts as free (cost 0) rather than "lower chance = more crafts
-- = more money", which would put 25-crafts-per-point green recipes first. Among free points, fewer crafts
-- (higher chance) first, then the bigger earner. Returns <0, 0, >0 like a comparator.
function Ranking.ComparePerPoint(a, b)
    local ca, cb = math.max(a.perPoint, 0), math.max(b.perPoint, 0)
    if ca ~= cb then
        return ca < cb and -1 or 1
    end
    if (a.points or 0) ~= (b.points or 0) then
        return (a.points or 0) > (b.points or 0) and -1 or 1
    end
    if a.perPoint ~= b.perPoint then
        return a.perPoint < b.perPoint and -1 or 1
    end
    return 0
end

-- Sorts in place by key (see getters). Rows without a value (no price, missing reagent prices, can't level)
-- always go last, whatever the direction. Ties break by name, then recipeID, so the order is stable.
function Ranking.Sort(rows, key, ascending)
    local get = getters[key] or getters.profit
    table.sort(rows, function(a, b)
        local va, vb = get(a), get(b)
        if va == nil or vb == nil then
            if va ~= vb then
                return vb == nil
            end
        elseif key == "perPoint" then
            local c = Ranking.ComparePerPoint(a, b)
            if c ~= 0 then
                if ascending then
                    return c < 0
                end
                return c > 0
            end
        elseif va ~= vb then
            if ascending then
                return va < vb
            end
            return va > vb
        end
        local na, nb = rowName(a), rowName(b)
        if na ~= nb then
            return na < nb
        end
        return (a.recipe.recipeID or 0) < (b.recipe.recipeID or 0)
    end)
    return rows
end
