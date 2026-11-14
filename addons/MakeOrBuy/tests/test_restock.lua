-- Component tests for Restock.lua: the restock list and its combined shopping list.
-- Techniques (ISTQB): boundary values for the count (0, 1, MAX), equivalence partitions for what you own
-- (nothing, part, everything), a state-based test of owned items shared across entries, and a use case.
return function(H)
    local ns = H.load({ "Planner.lua", "Restock.lua" })
    local P, R = ns.Planner, ns.Restock

    local WOOL, BOLT, THREAD, BAG, SHIRT = 2592, 2997, 2321, 4241, 2575
    local recipes = {
        [2964] = { recipeID = 2964, name = "Bolt of Woolen Cloth", outputItemID = BOLT, outputQty = 1,
            reagents = { { itemID = WOOL, qty = 3 } } },
        [3757] = { recipeID = 3757, name = "Woolen Bag", outputItemID = BAG, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } } },
        [2386] = { recipeID = 2386, name = "Linen Shirt", outputItemID = SHIRT, outputQty = 1,
            reagents = { { itemID = 2996, qty = 1 }, { itemID = THREAD, qty = 1 } } }, -- Bolt of Linen has no price
    }
    local index = P.IndexByOutput(recipes)
    local price = H.prices({ [WOOL] = { 51, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
    local sale = function(id) return ({ [BAG] = 855, [BOLT] = 570 })[id] end

    H.test("Add: counts go up and down, 0 removes, the cap is a boundary", function()
        local list = {}
        H.eq(R.Add(list, 1, 1), 1)
        H.eq(R.Add(list, 1, 4), 5)
        H.eq(R.Add(list, 1, -5), 0); H.eq(list[1], nil, "removed at 0")
        H.eq(R.Add(list, 1, -1), 0, "removing from nothing stays at 0")
        H.eq(R.Add(list, 2, R.MAX + 5), R.MAX)
        local n, crafts = R.Count({ [1] = 2, [2] = 3 })
        H.eq(n, 2); H.eq(crafts, 5)
    end)

    H.test("use case: 2 Woolen Bags + 3 Bolts become one merged list (wool from both entries)", function()
        local r = R.Build({ [3757] = 2, [2964] = 3 }, recipes, index, price, sale, nil)
        H.eq(#r.entries, 2)
        H.eq(r.entries[1].recipe.name, "Bolt of Woolen Cloth", "sorted by name")
        -- Bags: 6 bolts = 18 wool + 2 thread; bolts: 9 wool. Wool merged: 27
        H.eq(#r.shopping, 2)
        H.eq(r.shopping[1].itemID, WOOL); H.eq(r.shopping[1].qty, 27)
        H.eq(r.shopping[2].itemID, THREAD); H.eq(r.shopping[2].qty, 2)
        H.eq(r.cash, 27 * 51 + 2 * 100)
        H.eq(r.cost, r.cash, "nothing owned: spend = market cost")
        -- Profit: bolt 570 - 153 = 417 x3; bag 855 - 559 = 296 x2
        H.eq(r.profit, 417 * 3 + 296 * 2)
        H.eq(r.ownedUsed, 0)
    end)

    H.test("owned items are shared across entries, never counted twice (state)", function()
        -- Own 10 wool: the first entry (Bolts, 9 wool) uses 9, the bags get the last 1
        local have = { [WOOL] = 10 }
        local r = R.Build({ [3757] = 2, [2964] = 3 }, recipes, index, price, sale, have)
        H.eq(r.shopping[1].qty, 27 - 10)
        H.eq(r.ownedUsed, 10)
        H.eq(have[WOOL], 0, "consumed")
        H.eq(r.cost, 27 * 51 + 2 * 100, "market cost unchanged")
    end)

    H.test("owning everything: empty shopping list, nothing to spend", function()
        local r = R.Build({ [2964] = 2 }, recipes, index, price, sale, { [WOOL] = 6 })
        H.eq(#r.shopping, 0); H.eq(r.cash, 0); H.eq(r.ownedUsed, 6)
    end)

    H.test("owning an intermediate (Bolts) means fewer sub-crafts and less wool", function()
        local r = R.Build({ [3757] = 1 }, recipes, index, price, sale, { [BOLT] = 2 })
        H.eq(r.shopping[1].itemID, WOOL); H.eq(r.shopping[1].qty, 3, "only one bolt left to craft")
    end)

    H.test("unpriced reagents are reported; unknown recipes are kept apart", function()
        local r = R.Build({ [2386] = 1, [99999] = 4 }, recipes, index, price, sale, nil)
        H.eq(#r.entries, 1)
        H.eq(r.entries[1].complete, false)
        H.eq(r.entries[1].profit, nil, "no sale value for the shirt")
        H.eq(r.missing[1], 2996)
        H.eq(r.unknown[1], 99999)
        H.eq(r.shopping[1].itemID, THREAD, "the priced reagent is still on the list")
    end)

    H.test("empty list: nothing at all", function()
        local r = R.Build({}, recipes, index, price, sale, nil)
        H.eq(#r.entries, 0); H.eq(#r.shopping, 0); H.eq(r.cash, 0); H.eq(r.profit, 0)
        H.eq(#R.Build(nil, recipes, index, price, sale, nil).entries, 0)
    end)

    H.test("Summary names the first entries and counts the rest", function()
        local entries = {
            { crafts = 2, recipe = { name = "A" } }, { crafts = 1, recipe = { name = "B" } }, { crafts = 5, recipe = { name = "C" } },
        }
        local name = function(r) return r.name end
        H.eq(R.Summary(entries, name, 2), "2x A, 1x B, +1 more")
        H.eq(R.Summary(entries, name, 3), "2x A, 1x B, 5x C")
    end)
end
