-- Component tests for Ranking.lua and Planner.SaleValue (ISTQB: equivalence partitioning on the
-- "worth crafting" and "levels" decisions, boundary values at profit = 0 and AH = vendor, a decision table
-- for the sale source, and sorting with missing values).
return function(H)
    local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Ranking.lua" })
    local R, P = ns.Ranking, ns.Planner

    local WOOL, BOLT, THREAD, BAG, SHIRT = 2592, 2997, 2321, 4241, 2580
    local TAILORING, LW = 197, 165
    local recipes = {
        [1] = { recipeID = 1, name = "Bolt of Woolen Cloth", profession = TAILORING, outputItemID = BOLT, outputQty = 1,
            reagents = { { itemID = WOOL, qty = 3 } } },
        [2] = { recipeID = 2, name = "Woolen Bag", profession = TAILORING, outputItemID = BAG, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } } },
        [3] = { recipeID = 3, name = "Linen Shirt", profession = TAILORING, outputItemID = SHIRT, outputQty = 1,
            reagents = { { itemID = 9001, qty = 1 } } }, -- reagent has no price
        [4] = { recipeID = 4, name = "Leather Thing", profession = LW, outputItemID = 7000, outputQty = 1,
            reagents = { { itemID = WOOL, qty = 1 } } },
    }
    local index = P.IndexByOutput(recipes)
    local price = H.prices({ [WOOL] = { 51, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" } })

    -- Sale value from AH and vendor tables, through the real Planner.SaleValue
    local function sale(ah, vendor)
        vendor = vendor or {}
        return function(itemID) return P.SaleValue(ah[itemID], vendor[itemID]) end
    end
    local function byName(rows)
        local t = {}
        for _, row in ipairs(rows) do t[row.recipe.name] = row end
        return t
    end

    -- Planner.SaleValue decision table
    H.test("SaleValue: AH only -> AH after the 5% cut", function()
        local v, s = P.SaleValue(200, nil)
        H.eq(v, 190); H.eq(s, "ah")
    end)
    H.test("SaleValue: vendor only (no AH listings) -> vendor", function()
        local v, s = P.SaleValue(nil, 35)
        H.eq(v, 35); H.eq(s, "vendor")
    end)
    H.test("SaleValue: vendor beats a low AH price -> vendor", function()
        local v, s = P.SaleValue(100, 96)
        H.eq(v, 96, "AH nets 95"); H.eq(s, "vendor")
    end)
    H.test("SaleValue boundary: vendor equal to AH after cut -> vendor (certain and instant)", function()
        local _, s = P.SaleValue(100, 95)
        H.eq(s, "vendor")
        _, s = P.SaleValue(100, 94)
        H.eq(s, "ah")
    end)
    H.test("SaleValue: neither, or 0 vendor price (can't be sold) -> nil", function()
        H.eq(P.SaleValue(nil, nil), nil)
        H.eq(P.SaleValue(nil, 0), nil)
        H.eq(P.SaleValue(0, 0), nil)
    end)

    H.test("profit uses the best sale value; worth = profit > 0 with every reagent priced", function()
        local rows, counts = R.Build(recipes, index, price, sale({ [BOLT] = 600, [BAG] = 900, [SHIRT] = 5000 }),
            { profession = TAILORING })
        H.eq(#rows, 3, "Build returns every recipe of the profession")
        H.eq(counts.worth, 2)
        local t = byName(rows)
        H.eq(t["Bolt of Woolen Cloth"].profit, 417, "570 - 153")
        H.eq(t["Woolen Bag"].profit, 296, "855 - 559")
        H.truthy(t["Woolen Bag"].subCrafts)
        H.eq(t["Linen Shirt"].worth, false, "missing reagent price")
    end)

    H.test("vendor price gives a value to items with no AH listing", function()
        local rows = R.Build(recipes, index, price, sale({}, { [BAG] = 700 }), { profession = TAILORING })
        local bag = byName(rows)["Woolen Bag"]
        H.eq(bag.saleSource, "vendor")
        H.eq(bag.profit, 141, "700 - 559")
        H.eq(bag.worth, true)
    end)

    H.test("boundary: profit of exactly 0 is not worth crafting", function()
        H.eq(R.IsWorthCrafting({ profit = 0, complete = true }), false)
        H.eq(R.IsWorthCrafting({ profit = 1, complete = true }), true)
        H.eq(R.IsWorthCrafting({ profit = -1, complete = true }), false)
        H.eq(R.IsWorthCrafting({ profit = 100, complete = false }), false, "missing reagent prices")
        H.eq(R.IsWorthCrafting({ profit = nil, complete = true }), false, "no sale value")
    end)

    H.test("skill-up: expected points by difficulty (orange/yellow/green/grey)", function()
        local diff = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
        local rows = R.Build(recipes, index, price, sale({}), {
            recipeInfo = function(id) return { relativeDifficulty = diff[id] } end,
        })
        local t = byName(rows)
        H.eq(t["Bolt of Woolen Cloth"].points, 1)
        H.eq(t["Woolen Bag"].points, 0.75)
        H.eq(t["Linen Shirt"].points, 0.25)
        H.eq(t["Leather Thing"].points, 0)
        H.eq(t["Leather Thing"].levels, false, "grey never levels")
        H.eq(t["Leather Thing"].perPoint, nil)
    end)

    H.test("skill-up: net cost and cost per point include what the item sells back for", function()
        local rows = R.Build(recipes, index, price, sale({ [BAG] = 400 }), {
            profession = TAILORING,
            recipeInfo = function(id) return { relativeDifficulty = id == 2 and 1 or 0 } end,
        })
        local t = byName(rows)
        local bag = t["Woolen Bag"] -- cost 559, sells 380 net, yellow
        H.eq(bag.net, 179)
        H.near(bag.perPoint, 179 / 0.75)
        local bolt = t["Bolt of Woolen Cloth"] -- cost 153, no sale value, orange
        H.eq(bolt.net, 153, "nothing to sell: net = full cost")
        H.eq(bolt.perPoint, 153)
        H.eq(t["Linen Shirt"].perPoint, nil, "incomplete plans get no per-point figure")
    end)

    H.test("skill-up: a profitable skill-up has a negative cost per point", function()
        local rows = R.Build(recipes, index, price, sale({ [BOLT] = 600 }), {
            profession = TAILORING,
            recipeInfo = function() return { relativeDifficulty = 0 } end,
        })
        local bolt = byName(rows)["Bolt of Woolen Cloth"]
        H.eq(bolt.net, -417)
        H.eq(bolt.perPoint, -417)
    end)

    H.test("skill-up: orange recipes that give several points divide the cost", function()
        local rows = R.Build({ recipes[1] }, index, price, sale({}), {
            recipeInfo = function() return { relativeDifficulty = 0, numSkillUps = 3 } end,
        })
        H.eq(rows[1].points, 3)
        H.eq(rows[1].perPoint, 51)
    end)

    H.test("recipes without difficulty info have no skill-up figures", function()
        local rows = R.Build({ recipes[1] }, index, price, sale({}), {})
        H.eq(rows[1].points, nil)
        H.eq(rows[1].levels, false)
    end)

    H.test("profession nil lists every profession; Filter keeps matching rows", function()
        local rows = R.Build(recipes, index, price, sale({ [BOLT] = 600 }), {})
        H.eq(#rows, 4)
        H.eq(#R.Filter(rows, function(r) return r.worth end), 1)
    end)

    H.test("sort: rows without a value go last in both directions", function()
        local rows = {
            { recipe = { recipeID = 1, name = "A" }, complete = true, profit = nil },
            { recipe = { recipeID = 2, name = "B" }, complete = true, profit = 100 },
            { recipe = { recipeID = 3, name = "C" }, complete = true, profit = 300 },
            { recipe = { recipeID = 4, name = "D" }, complete = false, profit = 999 },
        }
        R.Sort(rows, "profit", false)
        H.eq(rows[1].recipe.name, "C"); H.eq(rows[2].recipe.name, "B")
        R.Sort(rows, "profit", true)
        H.eq(rows[1].recipe.name, "B")
        H.eq(rows[3].recipe.name, "A", "missing values last, by name")
        H.eq(rows[4].recipe.name, "D", "incomplete plan's profit counts as missing")
    end)

    H.test("sort: cheapest skill point first, earners before payers", function()
        local rows = {
            { recipe = { recipeID = 1, name = "Pricey" }, perPoint = 120 },
            { recipe = { recipeID = 2, name = "Earner" }, perPoint = -30 },
            { recipe = { recipeID = 3, name = "Cheap" }, perPoint = 5 },
            { recipe = { recipeID = 4, name = "Grey" }, perPoint = nil },
        }
        R.Sort(rows, "perPoint", true)
        H.eq(rows[1].recipe.name, "Earner")
        H.eq(rows[2].recipe.name, "Cheap")
        H.eq(rows[4].recipe.name, "Grey")
    end)

    H.test("sort: ties break by name, and name sort works", function()
        local rows = {
            { recipe = { recipeID = 1, name = "Zed" }, complete = true, profit = 100, cost = 5 },
            { recipe = { recipeID = 2, name = "Abe" }, complete = true, profit = 100, cost = 9 },
        }
        R.Sort(rows, "profit", false)
        H.eq(rows[1].recipe.name, "Abe")
        R.Sort(rows, "name", false)
        H.eq(rows[1].recipe.name, "Zed", "descending name")
        R.Sort(rows, "cost", true)
        H.eq(rows[1].recipe.name, "Zed")
    end)

    -- Skill chance from Skill thresholds, market flags, and the Learn view
    H.test("a provided skill chance replaces the band average; nil falls back to it", function()
        local info = function(id) return { relativeDifficulty = id == 2 and 1 or 0 } end
        local rows = R.Build(recipes, index, price, sale({ [BAG] = 900 }), {
            profession = TAILORING, recipeInfo = info,
            skillChance = function(id) if id == 2 then return 0.5 end end,
        })
        local t = byName(rows)
        H.eq(t["Woolen Bag"].chance, 0.5)
        H.eq(t["Woolen Bag"].perPoint, t["Woolen Bag"].net / 0.5)
        H.eq(t["Bolt of Woolen Cloth"].chance, 1, "orange fallback")
        H.eq(t["Woolen Bag"].estimated, true)
    end)

    H.test("risky flag only when the sale uses the AH and the market check says so", function()
        local market = function() return { spike = true } end
        local rows = R.Build(recipes, index, price, sale({ [BAG] = 900 }, { [BOLT] = 600 }),
            { profession = TAILORING, market = market })
        local t = byName(rows)
        H.eq(t["Woolen Bag"].risky, true)
        H.eq(t["Bolt of Woolen Cloth"].risky, nil, "valued at vendor: AH price irrelevant")
    end)

    local unlearned = {
        [10] = { recipeID = 10, name = "Trainer Bag", profession = TAILORING, outputItemID = BAG, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } } },
        [11] = { recipeID = 11, name = "Vendor Bag", profession = TAILORING, outputItemID = BAG, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } } },
        [12] = { recipeID = 12, name = "Drop Bag", profession = TAILORING, outputItemID = BAG, outputQty = 1,
            reagents = { { itemID = BOLT, qty = 3 }, { itemID = THREAD, qty = 1 } } },
    }
    local learnData = {
        [10] = { learn = 75, cost = 500, sources = "t" },
        [11] = { learn = 80, cost = 0, sources = "v", teach = 8000 },
        [12] = { learn = 85, cost = 0, sources = "d", teach = 8001 }, -- recipe item has no price
    }
    local learnPrice = H.prices({ [WOOL] = { 51, "ah" }, [BOLT] = { 600, "ah" }, [THREAD] = { 100, "vendor" },
        [8000] = { 1000, "vendor" } })

    H.test("Learn view: learn cost from the trainer or the recipe item's price; payback rounds up", function()
        local rows, counts = R.BuildLearn(unlearned, index, learnPrice, sale({ [BAG] = 900 }), {
            profession = TAILORING, skill = 80, learnInfo = function(id) return learnData[id] end,
        })
        local t = byName(rows)
        -- profit per bag 296 (see the Woolen Bag use case)
        H.eq(t["Trainer Bag"].learnCost, 500); H.eq(t["Trainer Bag"].learnSource, "trainer")
        H.eq(t["Trainer Bag"].payback, 2, "500 / 296 = 1.7 -> 2 crafts")
        H.eq(t["Vendor Bag"].learnCost, 1000); H.eq(t["Vendor Bag"].payback, 4, "1000 / 296 = 3.4 -> 4")
        H.eq(t["Drop Bag"].learnCost, nil); H.eq(t["Drop Bag"].payback, nil)
        H.eq(counts.worth, 3)
    end)

    H.test("Learn view: 'can learn now' boundary at your skill", function()
        local rows = R.BuildLearn(unlearned, index, learnPrice, sale({ [BAG] = 900 }), {
            profession = TAILORING, skill = 80, learnInfo = function(id) return learnData[id] end,
        })
        local t = byName(rows)
        H.eq(t["Trainer Bag"].canLearn, true, "75 < 80")
        H.eq(t["Vendor Bag"].canLearn, true, "80 = 80")
        H.eq(t["Drop Bag"].canLearn, false, "85 > 80")
    end)

    H.test("Learn view: a losing recipe never pays back", function()
        local rows = R.BuildLearn(unlearned, index, learnPrice, sale({ [BAG] = 100 }), {
            profession = TAILORING, learnInfo = function(id) return learnData[id] end,
        })
        H.eq(byName(rows)["Trainer Bag"].payback, nil)
    end)

    H.test("route candidates: complete learned recipes, plus trainer/vendor recipes with a known cost", function()
        local learned = R.Build(recipes, index, price, sale({ [BAG] = 900 }), { profession = TAILORING })
        local learn = R.BuildLearn(unlearned, index, learnPrice, sale({ [BAG] = 900 }), {
            profession = TAILORING, learnInfo = function(id) return learnData[id] end,
        })
        local t = { y = 100, g = 110, r = 120 }
        local list = R.RouteCandidates(learned, learn, function() return t end,
            function(id) return learnData[id] and learnData[id].learn end)
        local names = {}
        for _, c in ipairs(list) do names[c.name] = c end
        H.truthy(names["Woolen Bag"] and names["Bolt of Woolen Cloth"], "learned, complete")
        H.eq(names["Linen Shirt"], nil, "missing reagent price")
        H.eq(names["Trainer Bag"].learnCost, 500)
        H.eq(names["Vendor Bag"].learnCost, 1000)
        H.eq(names["Drop Bag"], nil, "drop recipes can't be planned")
        H.eq(names["Woolen Bag"].learnCost, 0)
    end)

    H.test("route candidates skip recipes without threshold estimates", function()
        local learned = R.Build(recipes, index, price, sale({}), { profession = TAILORING })
        H.eq(#R.RouteCandidates(learned, nil, function() return nil end, function() return nil end), 0)
    end)
end
