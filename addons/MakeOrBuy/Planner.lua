-- Planner: pure make-or-buy cost logic. No WoW API calls here, so tests can run it outside the game.
--
-- A recipe is { recipeID, name, outputItemID, outputQty, reagents = { { itemID, qty }, ... } }.
-- A price function is price(itemID) -> unitCopper or nil, sourceLabel ("vendor" | "ah").
--
-- For each reagent the planner picks the cheaper of:
--   buy   - its vendor/AH unit price
--   craft - the per-unit cost of a known recipe that makes it, itself planned recursively
-- Cycles are cut (an item is never crafted from itself further down the chain) and depth is capped.
local _, ns = ...

local Planner = {}
ns.Planner = Planner

Planner.MAX_DEPTH = 6
Planner.AH_CUT = 0.95 -- same constant Auctionator uses (Auctionator.Constants.AfterAHCut)

local floor, ceil = math.floor, math.ceil

-- Groups saved recipes by the item they make: { [outputItemID] = { recipe, ... } }
function Planner.IndexByOutput(recipes)
    local index = {}
    for _, recipe in pairs(recipes or {}) do
        if recipe.outputItemID then
            local list = index[recipe.outputItemID]
            if not list then
                list = {}
                index[recipe.outputItemID] = list
            end
            list[#list + 1] = recipe
        end
    end
    -- Deterministic order so ties resolve the same way every time
    for _, list in pairs(index) do
        table.sort(list, function(a, b)
            return (a.recipeID or 0) < (b.recipeID or 0)
        end)
    end
    return index
end

local craftNode -- forward declaration (mutual recursion with itemNode)

-- Cheapest way to obtain one unit of itemID.
-- Returns { itemID, method = "buy"|"craft"|"missing", unitCost, buyPrice, buySource, craftUnitCost, craft }
local function itemNode(ctx, itemID, depth, visiting)
    local buyPrice, buySource = ctx.price(itemID)
    local node = { itemID = itemID, buyPrice = buyPrice, buySource = buySource }

    local best
    if depth < ctx.maxDepth and not visiting[itemID] then
        local recipes = ctx.recipesByOutput[itemID]
        if recipes then
            visiting[itemID] = true
            for _, recipe in ipairs(recipes) do
                local option = craftNode(ctx, recipe, depth + 1, visiting)
                if option.complete and (best == nil or option.unitCost < best.unitCost) then
                    best = option
                end
            end
            visiting[itemID] = nil
        end
    end

    node.craftUnitCost = best and best.unitCost or nil
    if best and (buyPrice == nil or best.unitCost < buyPrice) then
        node.method = "craft"
        node.unitCost = best.unitCost
        node.craft = best
    elseif buyPrice then
        node.method = "buy"
        node.unitCost = buyPrice
    else
        node.method = "missing"
        node.unitCost = 0
    end
    return node
end

-- Cost of crafting a recipe once.
-- Returns { recipe, outputQty, reagents = { { itemID, qty, node } }, total, unitCost, naiveTotal, complete }
--   total      - copper per craft using the best option for every reagent (missing prices count as 0)
--   naiveTotal - copper per craft buying every direct reagent, as Auctionator does (missing count as 0)
--   complete   - false if any reagent, at any depth, has no price and no craftable route
craftNode = function(ctx, recipe, depth, visiting)
    local outputQty = recipe.outputQty
    if not outputQty or outputQty < 1 then
        outputQty = 1
    end
    local result = {
        recipe = recipe,
        outputQty = outputQty,
        reagents = {},
        total = 0,
        naiveTotal = 0,
        complete = true,
    }
    for _, reagent in ipairs(recipe.reagents or {}) do
        local child = itemNode(ctx, reagent.itemID, depth, visiting)
        result.reagents[#result.reagents + 1] = { itemID = reagent.itemID, qty = reagent.qty, node = child }
        result.total = result.total + reagent.qty * child.unitCost
        result.naiveTotal = result.naiveTotal + reagent.qty * (child.buyPrice or 0)
        if child.method == "missing" then
            result.complete = false
        end
    end
    result.unitCost = result.total / outputQty
    return result
end

local function newContext(recipesByOutput, price, opts)
    return {
        recipesByOutput = recipesByOutput or {},
        price = price,
        maxDepth = (opts and opts.maxDepth) or Planner.MAX_DEPTH,
    }
end

-- Plans one craft of `recipe`. The recipe's own output is never used as one of its ingredients.
function Planner.PlanRecipe(recipe, recipesByOutput, price, opts)
    local ctx = newContext(recipesByOutput, price, opts)
    local visiting = {}
    if recipe.outputItemID then
        visiting[recipe.outputItemID] = true
    end
    return craftNode(ctx, recipe, 0, visiting)
end

-- Plans obtaining one unit of an arbitrary item (used by the /mob slash command).
function Planner.PlanItem(itemID, recipesByOutput, price, opts)
    return itemNode(newContext(recipesByOutput, price, opts), itemID, 0, {})
end

-- Profit after the AH cut, in copper (rounded down to the copper).
-- Auctionator rounds down to the silver instead; at low levels that hides real profits
-- (a 84c profit on a 2s item shows as 0), so we deliberately don't copy it.
function Planner.Profit(saleUnitPrice, outputQty, cost)
    return floor(saleUnitPrice * outputQty * Planner.AH_CUT - cost)
end

-- What one crafted item is worth to you: the better of selling on the AH (after the 5% cut) or to a vendor.
-- The vendor price is a floor: certain, instant, and it values items with no AH listings. Ties go to the
-- vendor for the same reasons. Returns netUnitValue, "ah"|"vendor" (or nil when neither is known).
function Planner.SaleValue(ahPrice, vendorPrice)
    local ah = ahPrice and ahPrice > 0 and ahPrice * Planner.AH_CUT or nil
    local vendor = vendorPrice and vendorPrice > 0 and vendorPrice or nil
    if vendor and (not ah or vendor >= ah) then
        return vendor, "vendor"
    elseif ah then
        return ah, "ah"
    end
    return nil
end

-- Profit from a net (after-cut) unit value
function Planner.ProfitFromValue(netUnitValue, outputQty, cost)
    return floor(netUnitValue * outputQty - cost)
end

-- Adds `entry` ({ itemID, qty, source, unitPrice }) to a shopping list, merging by item.
-- `index` maps itemID -> entry for that list.
function Planner.AddToShopping(shopping, index, entry)
    local existing = index[entry.itemID]
    if existing then
        existing.qty = existing.qty + entry.qty
    else
        existing = { itemID = entry.itemID, qty = entry.qty, source = entry.source, unitPrice = entry.unitPrice }
        index[entry.itemID] = existing
        shopping[#shopping + 1] = existing
    end
    return existing
end

-- Flattens a craft plan into display lines and a shopping list for `crafts` crafts.
-- Intermediate crafts round up (you cannot craft half a Bolt), so quantities are whole numbers.
-- `have` (optional, { [itemID] = count }) is what you already own; it is used before buying or crafting,
-- at any depth (owning 2 Bolts means crafting fewer Bolts). The table is consumed (counts go down), so
-- several plans can share one inventory.
-- Returns lines = { { depth, itemID, qty, owned, method, unitCost, buyPrice, buySource, crafts } },
--         shopping = { { itemID, qty, source, unitPrice } } (leaf purchases, merged, in first-seen order),
--         missing = { itemID, ... },
--         cash = copper you still have to spend on the shopping list
function Planner.Expand(plan, crafts, have)
    crafts = crafts or 1
    local lines, shopping, missing = {}, {}, {}
    local shopIndex, missingSeen = {}, {}
    local cash = 0

    local function walk(craft, numCrafts, depth)
        for _, reagent in ipairs(craft.reagents) do
            local need = reagent.qty * numCrafts
            local owned = 0
            if have and (have[reagent.itemID] or 0) > 0 then
                owned = math.min(have[reagent.itemID], need)
                have[reagent.itemID] = have[reagent.itemID] - owned
            end
            local rest = need - owned
            local node = reagent.node
            local line = {
                depth = depth,
                itemID = reagent.itemID,
                qty = need,
                owned = owned,
                method = node.method,
                unitCost = node.unitCost,
                buyPrice = node.buyPrice,
                buySource = node.buySource,
            }
            lines[#lines + 1] = line
            if rest <= 0 then
                line.crafts = 0
            elseif node.method == "craft" then
                local subCrafts = ceil(rest / node.craft.outputQty)
                line.crafts = subCrafts
                walk(node.craft, subCrafts, depth + 1)
            elseif node.method == "buy" then
                Planner.AddToShopping(shopping, shopIndex,
                    { itemID = reagent.itemID, qty = rest, source = node.buySource, unitPrice = node.buyPrice })
                cash = cash + rest * node.buyPrice
            elseif not missingSeen[reagent.itemID] then
                missingSeen[reagent.itemID] = true
                missing[#missing + 1] = reagent.itemID
            end
        end
    end

    walk(plan, crafts, 0)
    return lines, shopping, missing, cash
end

-- The bought reagent that costs the most in a shopping list (a good thing to farm instead)
function Planner.PriciestPurchase(shopping)
    local best, bestValue
    for _, entry in ipairs(shopping) do
        local value = entry.qty * (entry.unitPrice or 0)
        if not bestValue or value > bestValue then
            best, bestValue = entry, value
        end
    end
    return best and best.itemID or nil
end

-- True if the plan crafts at least one reagent instead of buying it
function Planner.UsesSubCrafts(plan)
    for _, reagent in ipairs(plan.reagents) do
        if reagent.node.method == "craft" then
            return true
        end
    end
    return false
end
