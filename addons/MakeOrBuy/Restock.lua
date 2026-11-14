-- Restock: a list of crafts you plan to make ("3x Woolen Bag, 10x Bolt of Woolen Cloth") turned into one
-- combined shopping list. Pure logic (no WoW calls).
--
-- What you own is shared across the whole list: owning 4 Wool Cloth helps the first craft that needs it,
-- and isn't counted twice. Each craft uses the cheapest make-or-buy plan, as everywhere else.
local _, ns = ...

local Restock = {}
ns.Restock = Restock

Restock.MAX = 999 -- crafts per recipe

-- Changes the count for a recipe by `delta` (removing it at 0). Returns the new count.
function Restock.Add(list, recipeID, delta)
    local n = (list[recipeID] or 0) + (delta or 1)
    if n > Restock.MAX then
        n = Restock.MAX
    end
    if n <= 0 then
        list[recipeID] = nil
        return 0
    end
    list[recipeID] = n
    return n
end

function Restock.Count(list)
    local recipes, crafts = 0, 0
    for _, n in pairs(list or {}) do
        recipes, crafts = recipes + 1, crafts + n
    end
    return recipes, crafts
end

-- list:      { [recipeID] = crafts }
-- recipes:   { [recipeID] = recipe } (learned recipes; others are reported in `unknown`)
-- price, saleValue: as for the planner and ranking (saleValue may be nil)
-- have:      { [itemID] = count } you own, or nil; it is consumed
-- Returns {
--   entries  = { { recipe, crafts, plan, cash, cost, profit (nil if unpriced), complete } } sorted by name,
--   shopping = merged { itemID, qty, source, unitPrice } over all entries (minus what you own),
--   cash     = total copper still to spend, cost = market cost of everything, profit = summed known profit,
--   missing  = { itemID, ... } with no price, unknown = { recipeID, ... } not learned / not found,
--   ownedUsed = number of owned items used }
function Restock.Build(list, recipes, recipesByOutput, price, saleValue, have)
    local result = { entries = {}, shopping = {}, cash = 0, cost = 0, profit = 0, missing = {}, unknown = {}, ownedUsed = 0 }
    local ids = {}
    for recipeID, crafts in pairs(list or {}) do
        if (recipes or {})[recipeID] and crafts > 0 then
            ids[#ids + 1] = recipeID
        else
            result.unknown[#result.unknown + 1] = recipeID
        end
    end
    table.sort(result.unknown)
    table.sort(ids, function(a, b)
        local na, nb = recipes[a].name or "", recipes[b].name or ""
        if na ~= nb then return na < nb end
        return a < b
    end)

    local index, missingSeen = {}, {}
    for _, recipeID in ipairs(ids) do
        local recipe, crafts = recipes[recipeID], list[recipeID]
        local plan = ns.Planner.PlanRecipe(recipe, recipesByOutput, price)
        local lines, shopping, missing, cash = ns.Planner.Expand(plan, crafts, have)
        for _, line in ipairs(lines) do
            result.ownedUsed = result.ownedUsed + (line.owned or 0)
        end
        for _, entry in ipairs(shopping) do
            ns.Planner.AddToShopping(result.shopping, index, entry)
        end
        for _, itemID in ipairs(missing) do
            if not missingSeen[itemID] then
                missingSeen[itemID] = true
                result.missing[#result.missing + 1] = itemID
            end
        end
        local cost = plan.total * crafts
        local profit
        local value = saleValue and saleValue(recipe.outputItemID)
        if value and plan.complete ~= false then
            profit = ns.Planner.ProfitFromValue(value, plan.outputQty or 1, plan.total) * crafts
            result.profit = result.profit + profit
        end
        result.cash = result.cash + cash
        result.cost = result.cost + cost
        result.entries[#result.entries + 1] = {
            recipe = recipe, crafts = crafts, plan = plan, cash = cash, cost = cost, profit = profit,
            complete = plan.complete ~= false and #missing == 0,
        }
    end
    return result
end

-- "3x Woolen Bag, 10x Bolt of Woolen Cloth" (at most `max` names, then "+N more")
function Restock.Summary(entries, nameOf, max)
    max = max or 3
    local parts = {}
    for i, e in ipairs(entries) do
        if i > max then
            parts[#parts + 1] = "+" .. (#entries - max) .. " more"
            break
        end
        parts[#parts + 1] = e.crafts .. "x " .. nameOf(e.recipe)
    end
    return table.concat(parts, ", ")
end
