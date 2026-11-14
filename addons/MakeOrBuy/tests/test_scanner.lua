-- Component tests for Scanner.lua against a fake C_TradeSkillUI (ISTQB: component test level using stubs).
return function(H)
    local mock = require("wow_mock")
    local slot = mock.slot

    local function fresh(recipes, opts)
        mock.installTradeSkill(recipes, opts)
        return H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Scanner.lua" })
    end

    local tailoring = {
        [2964] = { learned = true, schematic = { name = "Bolt of Woolen Cloth", outputItemID = 2997, quantityMin = 1,
            reagentSlotSchematics = { slot(2592, 3) } } },
        [3757] = { learned = true, schematic = { name = "Woolen Bag", outputItemID = 4241, quantityMin = 1,
            reagentSlotSchematics = { slot(2997, 3), slot(2321, 1), slot(9999, 1, 1) } } }, -- last slot optional
        [8000] = { learned = false, schematic = { name = "Unlearned", outputItemID = 8001, quantityMin = 1,
            reagentSlotSchematics = { slot(2592, 1) } } },
        [7000] = { learned = true, schematic = { name = "Enchant (no item)", reagentSlotSchematics = { slot(1, 1) } } },
    }

    H.test("ReadRecipe keeps only basic reagents", function()
        local ns = fresh(tailoring)
        local bag = ns.Scanner.ReadRecipe(3757)
        H.eq(bag.outputItemID, 4241)
        H.eq(#bag.reagents, 2, "optional reagent slot skipped")
        H.eq(bag.reagents[1].itemID, 2997)
        H.eq(bag.reagents[1].qty, 3)
    end)

    H.test("ReadRecipe returns nil for recipes without an item output", function()
        local ns = fresh(tailoring)
        H.eq(ns.Scanner.ReadRecipe(7000), nil)
        H.eq(ns.Scanner.ReadRecipe(424242), nil, "unknown recipe")
    end)

    H.test("ReadRecipe falls back to GetRecipeOutputItemData when the schematic has no outputItemID", function()
        local ns = fresh({ [1] = { learned = true, schematic = { reagentSlotSchematics = { slot(2, 1) } } } })
        C_TradeSkillUI.GetRecipeOutputItemData = function(id) return id == 1 and { itemID = 77 } or nil end
        H.eq(ns.Scanner.ReadRecipe(1).outputItemID, 77)
    end)

    H.test("ReadRecipe defaults a missing quantityMin to 1", function()
        local ns = fresh({ [1] = { learned = true, schematic = { outputItemID = 5, reagentSlotSchematics = { slot(2, 1) } } } })
        H.eq(ns.Scanner.ReadRecipe(1).outputQty, 1)
    end)

    H.test("ScanOpenProfession stores learned item recipes only", function()
        local ns = fresh(tailoring)
        local db = { recipes = {} }
        H.eq(ns.Scanner.ScanOpenProfession(db), 2)
        H.truthy(db.recipes[2964])
        H.truthy(db.recipes[3757])
        H.eq(db.recipes[8000], nil, "unlearned skipped")
        H.eq(db.recipes[2964].profession, 197)
    end)

    H.test("rescanning a profession replaces its old recipes but keeps other professions", function()
        local ns = fresh(tailoring, { professionID = 197 })
        local db = { recipes = {
            [1] = { recipeID = 1, profession = 197, outputItemID = 1, reagents = {} }, -- stale tailoring
            [2] = { recipeID = 2, profession = 165, outputItemID = 2, reagents = {} }, -- leatherworking
        } }
        ns.Scanner.ScanOpenProfession(db)
        H.eq(db.recipes[1], nil, "stale tailoring recipe removed")
        H.truthy(db.recipes[2], "leatherworking kept")
    end)

    H.test("a linked (someone else's) profession is never scanned", function()
        local ns = fresh(tailoring, { linked = true })
        local db = { recipes = { [5] = { profession = 197 } } }
        H.eq(ns.Scanner.ScanOpenProfession(db), nil)
        H.truthy(db.recipes[5], "existing data untouched")
    end)

    H.test("an empty recipe list (window not ready) changes nothing", function()
        local ns = fresh({})
        local db = { recipes = { [5] = { profession = 197 } } }
        H.eq(ns.Scanner.ScanOpenProfession(db), nil)
        H.truthy(db.recipes[5])
    end)

    H.test("integration: scanned recipes feed the planner", function()
        local ns = fresh(tailoring)
        local db = { recipes = {} }
        ns.Scanner.ScanOpenProfession(db)
        local plan = ns.Planner.PlanRecipe(ns.Scanner.ReadRecipe(3757), ns.Planner.IndexByOutput(db.recipes),
            H.prices({ [2592] = { 51, "ah" }, [2997] = { 600, "ah" }, [2321] = { 100, "vendor" } }))
        H.eq(plan.total, 559)
    end)

    H.test("scan records skill level and what each recipe's colour says about its thresholds", function()
        local ns = fresh({
            [1] = { learned = true, difficulty = 1, schematic = { name = "A", outputItemID = 11, reagentSlotSchematics = { slot(2, 1) } } },
        })
        C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 197, skillLevel = 63, maxSkillLevel = 75 } end
        local db = { recipes = {} }
        ns.Scanner.ScanOpenProfession(db)
        H.eq(db.skill[197].level, 63); H.eq(db.skill[197].max, 75)
        H.eq(db.bounds[1].y[2], 63, "yellow at 63: yellow started at or before 63")
        H.eq(db.bounds[1].g[1], 64)
    end)

    H.test("unlearned recipes from the game list go to db.unlearned, not db.recipes", function()
        local ns = fresh(tailoring)
        local db = { recipes = {} }
        ns.Scanner.ScanOpenProfession(db)
        H.eq(db.recipes[8000], nil)
        H.eq(db.unlearned[8000].name, "Unlearned")
        H.eq(db.unlearned[8000].profession, 197)
    end)

    H.test("recipes missing from the game list are found through RecipeData, filtered by faction", function()
        local ns = fresh(tailoring)
        ns.RecipeData = { [197] = {
            [8000] = { 10, 50, "t" },
            [9100] = { 20, 0, "v", 5000, "A" }, -- Alliance only
            [9200] = { 20, 0, "v", 5001, "H" }, -- Horde only
        } }
        C_TradeSkillUI.GetAllRecipeIDs = function() return { 2964, 3757 } end
        local base = C_TradeSkillUI.GetRecipeSchematic
        C_TradeSkillUI.GetRecipeSchematic = function(id)
            if id == 9100 or id == 9200 then
                return { name = "R" .. id, outputItemID = id + 1, reagentSlotSchematics = { slot(2592, 1) } }
            end
            return base(id)
        end
        UnitFactionGroup = function() return "Horde" end
        local db = { recipes = {} }
        ns.Scanner.ScanOpenProfession(db)
        UnitFactionGroup = nil
        H.truthy(db.unlearned[8000], "from data")
        H.truthy(db.unlearned[9200], "Horde recipe for a Horde character")
        H.eq(db.unlearned[9100], nil, "Alliance recipe skipped")
    end)

    -- Regression: switching from First Aid to Tailoring saved First Aid's recipes as Tailoring and wiped the
    -- real Tailoring ones (the list and the profession name disagree for a moment)
    H.test("mismatch: a list of another profession's recipes is not stored and existing data is untouched", function()
        local ns = fresh({
            [3275] = { learned = true, schematic = { name = "Linen Bandage", outputItemID = 1251, reagentSlotSchematics = { slot(2589, 1) } } },
            [3276] = { learned = true, schematic = { name = "Heavy Linen Bandage", outputItemID = 2581, reagentSlotSchematics = { slot(2589, 2) } } },
        }, { professionID = 197 }) -- window already says Tailoring
        ns.RecipeData = { [129] = { [3275] = { 1, 0, "" }, [3276] = { 40, 100, "t" } }, [197] = { [2964] = { 1, 0, "t" } } }
        local bolt = { recipeID = 2964, profession = 197, outputItemID = 2997, reagents = {} }
        local db = { recipes = { [2964] = bolt } }
        local count, reason = ns.Scanner.ScanOpenProfession(db)
        H.eq(count, nil); H.eq(reason, "mismatch")
        H.eq(db.recipes[2964], bolt, "Tailoring recipe kept")
        H.eq(db.recipes[3275], nil, "First Aid recipe not stored as Tailoring")
    end)

    H.test("a stray recipe of another profession in an otherwise right list is skipped", function()
        local recipes = {}
        for k, v in pairs(tailoring) do recipes[k] = v end
        recipes[3275] = { learned = true, schematic = { name = "Linen Bandage", outputItemID = 1251, reagentSlotSchematics = { slot(2589, 1) } } }
        local ns = fresh(recipes)
        ns.RecipeData = { [129] = { [3275] = { 1, 0, "" } }, [197] = { [2964] = { 1, 0, "t" }, [3757] = { 45, 0, "t" } } }
        local db = { recipes = {} }
        H.eq(ns.Scanner.ScanOpenProfession(db), 2)
        H.eq(db.recipes[3275], nil)
    end)

    H.test("state: a learned recipe whose details aren't loaded keeps its saved copy instead of being wiped", function()
        local ns = fresh(tailoring)
        local db = { recipes = {} }
        ns.Scanner.ScanOpenProfession(db)
        local saved = db.recipes[3757]
        C_TradeSkillUI.GetRecipeSchematic = function() return nil end -- nothing loaded yet
        H.eq(ns.Scanner.ScanOpenProfession(db), 2, "bolt and bag keep their saved copies")
        H.eq(db.recipes[3757], saved)
        H.eq(db.recipes[2964] ~= nil, true)
    end)

    H.test("RecipeProfession: bundled data first, then the game's skill line (parent line preferred)", function()
        local ns = fresh(tailoring)
        ns.RecipeData = { [197] = { [2964] = { 1, 0, "t" } } }
        C_TradeSkillUI.GetTradeSkillLineForRecipe = function(id)
            if id == 1229705 then return 2900, "Herbalism Crafting", 182 end
            if id == 1229745 then return 356, "Fishing", 0 end
            error("unknown")
        end
        H.eq(ns.Scanner.RecipeProfession(2964), 197)
        H.eq(ns.Scanner.RecipeProfession(1229705), 182)
        H.eq(ns.Scanner.RecipeProfession(1229745), 356, "no parent: the line itself")
        H.eq(ns.Scanner.RecipeProfession(42), nil, "lookup errors are contained")
    end)

    H.test("Repair moves mis-tagged recipes back and drops unlearned copies of learned ones", function()
        local ns = fresh(tailoring)
        ns.RecipeData = { [129] = { [3275] = { 1, 0, "" } }, [197] = { [2964] = { 1, 0, "t" } } }
        local db = {
            recipes = { [3275] = { profession = 197 }, [2964] = { profession = 197 }, [777] = { profession = 185 } },
            unlearned = { [2964] = { profession = 197 }, [8] = { profession = 197 } },
        }
        H.eq(ns.Scanner.Repair(db), 1)
        H.eq(db.recipes[3275].profession, 129)
        H.eq(db.recipes[777].profession, 185, "unknown recipe left alone")
        H.eq(db.unlearned[2964], nil); H.truthy(db.unlearned[8])
    end)

    H.test("SkillLevel prefers the child profession (expansion tier) and ignores 0", function()
        local ns = fresh(tailoring)
        C_TradeSkillUI.GetChildProfessionInfo = function() return { skillLevel = 0 } end
        C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 197, skillLevel = 40, maxSkillLevel = 75 } end
        local level, max = ns.Scanner.SkillLevel()
        H.eq(level, 40); H.eq(max, 75)
        C_TradeSkillUI.GetChildProfessionInfo = function() return { skillLevel = 12, maxSkillLevel = 75 } end
        H.eq(ns.Scanner.SkillLevel(), 12)
    end)
end
