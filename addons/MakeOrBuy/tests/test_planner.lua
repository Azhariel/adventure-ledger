-- Component tests for Planner.lua (ISTQB: component/unit test level, functional testing).
-- Techniques: equivalence partitioning on the buy/craft/missing decision, boundary value analysis
-- on the depth cap and output quantities, and a use-case test for the original Woolen Bag scenario.
return function(H)
    local ns = H.load({ "Planner.lua" })
    local P = ns.Planner

    -- Item IDs (values only need to be distinct)
    local WOOL, BOLT, THREAD, BAG = 2592, 2997, 2321, 4241

    local boltRecipe = { recipeID = 2964, outputItemID = BOLT, outputQty = 1, reagents = { { itemID = WOOL, qty = 3 } } }
    local bagRecipe = {
        recipeID = 3757,
        outputItemID = BAG,
        outputQty = 1,
        reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } },
    }

    H.test("use case: Woolen Bag is cheaper when you craft the bolts yourself", function()
        local price = H.prices({
            [WOOL] = { 51, "ah" },
            [BOLT] = { 600, "ah" },
            [THREAD] = { 100, "vendor" },
        })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)

        H.eq(plan.naiveTotal, 3 * 600 + 100, "Auctionator-style cost buys the bolts")
        H.eq(plan.total, 3 * (3 * 51) + 100, "best plan crafts bolts from 9 wool")
        H.eq(plan.reagents[1].node.method, "craft")
        H.eq(plan.reagents[2].node.method, "buy")
        H.truthy(plan.complete, "all prices known")

        -- 9s sale: buying bolts loses money, crafting them makes money
        H.eq(P.Profit(900, 1, plan.naiveTotal), -1045, "855 - 1900")
        H.eq(P.Profit(900, 1, plan.total), 296, "855 - 559")
    end)

    H.test("use case: expanded plan says buy 9 Wool Cloth and 1 Fine Thread", function()
        local price = H.prices({ [WOOL] = { 51, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
        local lines, shopping, missing = P.Expand(plan, 1)

        H.eq(#lines, 3)
        H.eq(lines[1].itemID, BOLT)
        H.eq(lines[1].crafts, 3)
        H.eq(lines[2].itemID, WOOL)
        H.eq(lines[2].depth, 1)
        H.eq(lines[2].qty, 9)
        H.eq(#shopping, 2)
        H.eq(shopping[1].itemID, WOOL)
        H.eq(shopping[1].qty, 9)
        H.eq(shopping[2].itemID, THREAD)
        H.eq(shopping[2].source, "vendor")
        H.eq(#missing, 0)
    end)

    H.test("partition: buying wins when the intermediate is cheaper on the AH", function()
        local price = H.prices({ [WOOL] = { 300, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
        local bolt = plan.reagents[1].node
        H.eq(bolt.method, "buy")
        H.eq(bolt.craftUnitCost, 900, "craft cost still reported for comparison")
        H.eq(plan.total, plan.naiveTotal)
        H.eq(P.UsesSubCrafts(plan), false)
    end)

    H.test("boundary: equal buy and craft cost prefers buying (no pointless crafting)", function()
        local price = H.prices({ [WOOL] = { 200, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
        H.eq(plan.reagents[1].node.method, "buy")
    end)

    H.test("partition: no known recipe for a reagent means buy", function()
        local price = H.prices({ [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, {}, price)
        H.eq(plan.reagents[1].node.method, "buy")
        H.eq(plan.total, 1900)
    end)

    H.test("partition: an intermediate with no AH price is still crafted", function()
        local price = H.prices({ [WOOL] = { 51, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
        local bolt = plan.reagents[1].node
        H.eq(bolt.method, "craft")
        H.eq(bolt.buyPrice, nil)
        H.truthy(plan.complete)
        H.eq(plan.naiveTotal, 100, "naive cost counts the unpriced bolts as 0, like Auctionator")
    end)

    H.test("partition: no price and no recipe marks the plan incomplete", function()
        local price = H.prices({ [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, {}, price)
        H.eq(plan.reagents[1].node.method, "missing")
        H.eq(plan.complete, false)
        H.eq(plan.total, 100)
        local _, _, missing = P.Expand(plan, 1)
        H.eq(#missing, 1)
        H.eq(missing[1], BOLT)
    end)

    H.test("a craft route with a missing leaf price is not chosen over buying", function()
        local price = H.prices({ [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } }) -- wool unpriced
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
        H.eq(plan.reagents[1].node.method, "buy", "0-cost wool must not make crafting look free")
        H.truthy(plan.complete)
    end)

    H.test("multiple recipes for the same item: the cheapest is used", function()
        local cheap = { recipeID = 2, outputItemID = BOLT, outputQty = 1, reagents = { { itemID = WOOL, qty = 2 } } }
        local price = H.prices({ [WOOL] = { 51, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe, cheap }), price)
        H.eq(plan.reagents[1].node.craft.recipe.recipeID, 2)
        H.eq(plan.total, 3 * 102 + 100)
    end)

    H.test("boundary: recipe with output quantity 2 halves unit cost and rounds crafts up", function()
        local twoBolts = { recipeID = 9, outputItemID = BOLT, outputQty = 2, reagents = { { itemID = WOOL, qty = 3 } } }
        local price = H.prices({ [WOOL] = { 50, "ah" }, [THREAD] = { 100, "vendor" } })
        local plan = P.PlanRecipe(bagRecipe, P.IndexByOutput({ twoBolts }), price)
        H.near(plan.reagents[1].node.unitCost, 75)
        H.near(plan.total, 3 * 75 + 100)
        local lines, shopping = P.Expand(plan, 1)
        H.eq(lines[1].crafts, 2, "3 bolts at 2 per craft needs 2 crafts")
        H.eq(shopping[1].qty, 6)
    end)

    H.test("boundary: output quantity 0 or nil is treated as 1", function()
        local r = { recipeID = 1, outputItemID = 5, outputQty = 0, reagents = { { itemID = WOOL, qty = 1 } } }
        local plan = P.PlanRecipe(r, {}, H.prices({ [WOOL] = { 10, "ah" } }))
        H.eq(plan.outputQty, 1)
        H.eq(plan.unitCost, 10)
    end)

    H.test("cycles terminate: A from B and B from A", function()
        local A, B = 1, 2
        local aFromB = { recipeID = 10, outputItemID = A, outputQty = 1, reagents = { { itemID = B, qty = 1 } } }
        local bFromA = { recipeID = 11, outputItemID = B, outputQty = 1, reagents = { { itemID = A, qty = 1 } } }
        local node = P.PlanItem(A, P.IndexByOutput({ aFromB, bFromA }), H.prices({ [B] = { 5, "ah" } }))
        H.eq(node.method, "craft")
        H.eq(node.unitCost, 5)
    end)

    H.test("the recipe's own output is never used as its ingredient", function()
        -- Planning Bolt must not "craft" Wool from Bolt
        local woolFromBolt = { recipeID = 12, outputItemID = WOOL, outputQty = 10, reagents = { { itemID = BOLT, qty = 1 } } }
        local plan = P.PlanRecipe(boltRecipe, P.IndexByOutput({ woolFromBolt }), H.prices({ [WOOL] = { 51, "ah" } }))
        H.eq(plan.reagents[1].node.method, "buy")
    end)

    H.test("boundary: depth cap - a chain exactly at maxDepth is crafted, one deeper is bought", function()
        -- 4 <- 3 <- 2 <- 1 ; only item 1 has a price
        local r = {}
        for i = 2, 4 do
            r[#r + 1] = { recipeID = i, outputItemID = i, outputQty = 1, reagents = { { itemID = i - 1, qty = 1 } } }
        end
        local index = P.IndexByOutput(r)
        local price = H.prices({ [1] = { 1, "ah" }, [2] = { 100, "ah" } })
        local root = r[3] -- makes 4 from 3
        local atCap = P.PlanRecipe(root, index, price, { maxDepth = 2 })
        H.eq(atCap.reagents[1].node.method, "craft", "3 crafted")
        H.eq(atCap.reagents[1].node.craft.reagents[1].node.method, "craft", "2 crafted at depth 2")
        H.eq(atCap.total, 1)
        local belowCap = P.PlanRecipe(root, index, price, { maxDepth = 1 })
        H.eq(belowCap.reagents[1].node.craft.reagents[1].node.method, "buy", "2 bought when cap is hit")
        H.eq(belowCap.total, 100)
    end)

    H.test("shopping list merges the same leaf item from different branches", function()
        local r = { recipeID = 20, outputItemID = 99, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 1 }, { itemID = WOOL, qty = 2 } } }
        local plan = P.PlanRecipe(r, P.IndexByOutput({ boltRecipe }), H.prices({ [WOOL] = { 10, "ah" } }))
        local _, shopping = P.Expand(plan, 2)
        H.eq(#shopping, 1)
        H.eq(shopping[1].qty, 2 * 3 + 2 * 2)
    end)

    H.test("Profit is exact to the copper after the 5% cut", function()
        H.eq(P.Profit(1000, 1, 0), 950)
        H.eq(P.Profit(1000, 2, 1850), 50)
        H.eq(P.Profit(0, 1, 1), -1)
        H.eq(P.Profit(54, 1, 48), 3, "51.3 - 48 = 3.3 rounds down to 3")
    end)

    H.test("regression: small profits are not rounded away (Brown Linen Pants, in-game 2026-11-06)", function()
        -- Cost 1s 6c, sells 2s: 190 - 106 = 84c. Silver rounding showed 0 and hid the recipe.
        H.eq(P.Profit(200, 1, 106), 84)
        -- Bolt of Woolen Cloth: cost 4s 92c, sells 4s 98c -> 473.1 - 492 = -18.9 -> -19c, not -1s
        H.eq(P.Profit(498, 1, 492), -19)
    end)

    H.test("IndexByOutput groups by output and ignores recipes without one", function()
        local index = P.IndexByOutput({ boltRecipe, bagRecipe, { recipeID = 3, reagents = {} } })
        H.eq(#index[BOLT], 1)
        H.eq(#index[BAG], 1)
        H.eq(P.IndexByOutput(nil) ~= nil, true)
    end)

    -- Owned items (Stockpile). Techniques: equivalence partitions for owning none / some / all of a reagent,
    -- at leaf and intermediate depth, and state transition of a shared inventory across two plans.
    local function bagPlan()
        local price = H.prices({ [WOOL] = { 51, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })
        return P.PlanRecipe(bagRecipe, P.IndexByOutput({ boltRecipe }), price)
    end

    H.test("owning nothing: cash equals the best plan", function()
        local _, shopping, _, cash = P.Expand(bagPlan(), 1, {})
        H.eq(cash, 559)
        H.eq(shopping[1].qty, 9)
        H.eq(shopping[1].unitPrice, 51)
    end)

    H.test("owning some leaf reagents: buy only the rest", function()
        local lines, shopping, _, cash = P.Expand(bagPlan(), 1, { [WOOL] = 4 })
        H.eq(shopping[1].itemID, WOOL); H.eq(shopping[1].qty, 5)
        H.eq(cash, 5 * 51 + 100)
        local owned = 0
        for _, l in ipairs(lines) do owned = owned + l.owned end
        H.eq(owned, 4)
    end)

    H.test("owning an intermediate: fewer crafts of it (2 Bolts owned -> craft 1, buy 3 Wool)", function()
        local lines, shopping, _, cash = P.Expand(bagPlan(), 1, { [BOLT] = 2 })
        H.eq(lines[1].itemID, BOLT); H.eq(lines[1].owned, 2); H.eq(lines[1].crafts, 1)
        H.eq(shopping[1].qty, 3)
        H.eq(cash, 3 * 51 + 100)
    end)

    H.test("owning everything: nothing to buy, the line says no crafts", function()
        local lines, shopping, _, cash = P.Expand(bagPlan(), 1, { [BOLT] = 3, [THREAD] = 5 })
        H.eq(#shopping, 0); H.eq(cash, 0)
        H.eq(lines[1].crafts, 0)
    end)

    H.test("one inventory shared by two plans is used up once (state carries over)", function()
        local have = { [WOOL] = 10 }
        local _, _, _, first = P.Expand(bagPlan(), 1, have)
        H.eq(first, 100, "9 of 10 wool used, only thread bought")
        H.eq(have[WOOL], 1)
        local _, _, _, second = P.Expand(bagPlan(), 1, have)
        H.eq(second, 8 * 51 + 100)
    end)

    H.test("batch of 3 bags multiplies the shopping list", function()
        local _, shopping, _, cash = P.Expand(bagPlan(), 3)
        H.eq(shopping[1].qty, 27); H.eq(shopping[2].qty, 3)
        H.eq(cash, 3 * 559)
    end)

    H.test("PriciestPurchase picks the reagent with the highest total cost", function()
        H.eq(P.PriciestPurchase({ { itemID = 1, qty = 9, unitPrice = 51 }, { itemID = 2, qty = 1, unitPrice = 100 } }), 1)
        H.eq(P.PriciestPurchase({}), nil)
    end)
end
