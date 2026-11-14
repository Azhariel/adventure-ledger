-- Component integration tests for Core.lua: saved data, price source, event-driven scanning, slash command.
return function(H)
    local mock = require("wow_mock")

    local function boot(vendor, ah)
        local frame = mock.installCore()
        mock.installAuctionator(vendor or {}, ah or {})
        mock.installTradeSkill({
            [2964] = { learned = true, schematic = { outputItemID = 2997, quantityMin = 1,
                reagentSlotSchematics = { mock.slot(2592, 3) } } },
        })
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Scanner.lua", "Core.lua" })
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        return ns, frame
    end

    H.test("ADDON_LOADED creates an empty character DB", function()
        local ns = boot()
        H.eq(MakeOrBuyCharDB.version, 1)
        H.eq(next(MakeOrBuyCharDB.recipes), nil)
        H.eq(ns.db, MakeOrBuyCharDB)
    end)

    H.test("ADDON_LOADED for another addon does nothing", function()
        local frame = mock.installCore()
        mock.installAuctionator({}, {})
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Scanner.lua", "Core.lua" })
        frame:Fire("ADDON_LOADED", "Auctionator")
        H.eq(ns.db, nil)
    end)

    H.test("existing saved recipes survive a reload", function()
        local frame = mock.installCore()
        mock.installAuctionator({}, {})
        MakeOrBuyCharDB = { version = 1, recipes = { [1] = { recipeID = 1, outputItemID = 7, reagents = {} } } }
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Scanner.lua", "Core.lua" })
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        H.truthy(ns.recipesByOutput[7], "index rebuilt from saved data")
    end)

    H.test("Price picks the cheaper of vendor and AH and reports the source", function()
        local ns = boot({ [1] = 100, [2] = 50 }, { [1] = 80, [2] = 90, [3] = 70 })
        local p, s = ns.Price(1)
        H.eq(p, 80); H.eq(s, "ah")
        p, s = ns.Price(2)
        H.eq(p, 50); H.eq(s, "vendor")
        p, s = ns.Price(3)
        H.eq(p, 70); H.eq(s, "ah")
        H.eq(ns.Price(4), nil)
        H.truthy(mock.callers.MakeOrBuy, "uses addon name as Auctionator caller ID")
    end)

    H.test("Public API (for DropLab): buy price and sale value; invalid input gives nil", function()
        local ns = boot({ [2] = 50 }, { [1] = 80, [2] = 90 })
        local p, s = MakeOrBuy.API.GetBuyPrice(2)
        H.eq(p, 50); H.eq(s, "vendor")
        H.eq(MakeOrBuy.API.GetBuyPrice(4), nil)
        H.eq(MakeOrBuy.API.GetBuyPrice("2"), nil)
        H.eq(MakeOrBuy.API.GetSaleValue(1), ns.SaleValue(1))
        H.truthy(MakeOrBuy.API.GetSaleValue(1) < 80, "after the AH cut")
        H.eq(MakeOrBuy.API.GetSaleValue(nil), nil)
    end)

    H.test("TRADE_SKILL_SHOW schedules one debounced scan that fills the index", function()
        local ns, frame = boot()
        frame:Fire("TRADE_SKILL_SHOW")
        frame:Fire("TRADE_SKILL_LIST_UPDATE")
        frame:Fire("TRADE_SKILL_LIST_UPDATE")
        H.eq(#mock.timers, 1, "debounced")
        mock.runTimers()
        H.truthy(ns.db.recipes[2964])
        H.truthy(ns.recipesByOutput[2997])
    end)

    H.test("a scan caught mid profession switch is retried until the list matches (state: mismatch -> scanned)", function()
        local ns, frame = boot()
        ns.RecipeData = { [129] = { [2964] = { 1, 0, "" } } } -- the list still holds "First Aid" recipes
        ns.Scanner.ResetCache()
        frame:Fire("TRADE_SKILL_LIST_UPDATE")
        mock.runTimers()
        H.eq(ns.db.recipes[2964], nil, "nothing stored while they disagree")
        H.eq(#mock.timers, 1, "retry scheduled")
        ns.RecipeData = { [197] = { [2964] = { 1, 0, "t" } } } -- the window caught up
        ns.Scanner.ResetCache()
        mock.runTimers()
        H.truthy(ns.db.recipes[2964])
        H.eq(#mock.timers, 0, "no more retries")
    end)

    H.test("retries stop after a few attempts (boundary: last retry)", function()
        local ns, frame = boot()
        ns.RecipeData = { [129] = { [2964] = { 1, 0, "" } } }
        ns.Scanner.ResetCache()
        frame:Fire("TRADE_SKILL_LIST_UPDATE")
        local runs = 0
        while #mock.timers > 0 and runs < 20 do
            mock.runTimers()
            runs = runs + 1
        end
        H.eq(runs, 6, "first scan + 5 retries")
    end)

    H.test("loading saved data repairs recipes saved under the wrong profession", function()
        local frame = mock.installCore()
        mock.installAuctionator({}, {})
        MakeOrBuyCharDB = { version = 1, recipes = { [3275] = { recipeID = 3275, profession = 197, outputItemID = 1251, reagents = {} } } }
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Scanner.lua", "Core.lua" })
        ns.RecipeData = { [129] = { [3275] = { 1, 0, "" } } }
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        H.eq(ns.db.recipes[3275].profession, 129)
    end)

    H.test("/mob with an item link prints the craft plan", function()
        local ns = boot({}, { [2592] = 51, [2997] = 600 })
        ns.db.recipes[2964] = ns.Scanner.ReadRecipe(2964)
        ns.Reindex()
        SlashCmdList.MAKEORBUY("|cffffffff|Hitem:2997::::::::|h[Bolt of Woolen Cloth]|h|r")
        H.truthy(mock.chat[1]:find("craft for 153c each %(buy: 600c%)"), mock.chat[1])
        H.truthy(mock.chat[2]:find("3x Item2592 %- buy 153c"), mock.chat[2])
    end)

    H.test("vendor sell price: uncached items are requested, then one refresh follows the data burst", function()
        local ns, frame = boot({}, { [5] = 100 })
        local cached, requested = false, {}
        C_Item.GetItemInfo = function(id)
            if not cached then return nil end
            return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, 96
        end
        C_Item.RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end
        local refreshes = 0
        ns.UI = { Refresh = function() refreshes = refreshes + 1 end }

        H.eq(ns.VendorSellPrice(5), nil, "not cached yet")
        H.eq(requested[1], 5)
        local v, s = ns.SaleValue(5)
        H.eq(v, 95); H.eq(s, "ah", "AH after cut until the vendor price is known")

        cached = true
        frame:Fire("GET_ITEM_INFO_RECEIVED", 5)
        frame:Fire("GET_ITEM_INFO_RECEIVED", 6)
        H.eq(#mock.timers, 1, "one refresh for the burst")
        mock.runTimers()
        H.eq(refreshes, 1)
        v, s = ns.SaleValue(5)
        H.eq(v, 96); H.eq(s, "vendor")

        frame:Fire("GET_ITEM_INFO_RECEIVED", 7)
        H.eq(#mock.timers, 0, "no refresh when nothing was waiting")
    end)

    H.test("vendor sell price of 0 (unsellable item) counts as no price", function()
        local ns = boot()
        C_Item.GetItemInfo = function(id) return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0 end
        H.eq(ns.VendorSellPrice(5), nil)
    end)

    H.test("/mob auctionator toggles Auctionator's cost and profit lines together", function()
        boot()
        local store = { crafting_info_show_profit = true, crafting_info_show_cost = false }
        Auctionator.Config = {
            Options = { CRAFTING_INFO_SHOW_PROFIT = "crafting_info_show_profit", CRAFTING_INFO_SHOW_COST = "crafting_info_show_cost" },
            Get = function(k) return store[k] end,
            Set = function(k, v) store[k] = v end,
        }
        SlashCmdList.MAKEORBUY("auctionator")
        H.eq(store.crafting_info_show_profit, false, "either line on -> both off")
        H.eq(store.crafting_info_show_cost, false)
        H.truthy(mock.chat[#mock.chat]:find("hidden"), mock.chat[#mock.chat])
        SlashCmdList.MAKEORBUY("Auctionator")
        H.eq(store.crafting_info_show_profit, true, "both off -> both on")
        H.eq(store.crafting_info_show_cost, true)
    end)

    H.test("/mob auctionator without Auctionator config explains instead of erroring", function()
        boot()
        SlashCmdList.MAKEORBUY("auctionator")
        H.truthy(mock.chat[1]:find("not available"), mock.chat[1])
    end)

    H.test("/mob without arguments prints the recipe count", function()
        boot()
        SlashCmdList.MAKEORBUY("")
        H.truthy(mock.chat[1]:find("0 recipes known"), mock.chat[1])
    end)

    -- Optional addons and new data sources (ISTQB: component integration with stubbed Stockpile/Auctionator)
    H.test("Owned reads this character's items from Stockpile; off switch and missing addon give nil", function()
        local ns = boot()
        H.eq(ns.Owned(), nil, "no Stockpile")
        local scopes = {}
        Stockpile = { API = { GetOwnedMap = function(scope) scopes[#scopes + 1] = scope return { [2592] = 4 } end } }
        H.eq(ns.Owned()[2592], 4)
        H.eq(scopes[1], "character")
        SlashCmdList.MAKEORBUY("owned")
        H.eq(ns.db.useOwned, false)
        H.eq(ns.Owned(), nil, "switched off")
        SlashCmdList.MAKEORBUY("owned")
        H.eq(ns.db.useOwned, true)
        Stockpile.API.GetOwnedMap = function() error("boom") end
        H.eq(ns.Owned(), nil, "an erroring Stockpile is ignored")
        Stockpile = nil
    end)

    H.test("Stockpile changes refresh the UI (callback registered at load)", function()
        local frame = mock.installCore()
        mock.installAuctionator({}, {})
        local registered
        Stockpile = { API = { RegisterCallback = function(owner, fn) registered = { owner, fn } end } }
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Scanner.lua", "Core.lua" })
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        Stockpile = nil
        H.eq(registered[1], "MakeOrBuy")
        local refreshed = 0
        ns.UI = { Refresh = function() refreshed = refreshed + 1 end }
        registered[2]()
        H.eq(refreshed, 1)
    end)

    H.test("MarketCheck reads Auctionator's price history (by item ID string) and age", function()
        local ns = boot({}, { [5] = 300 })
        Auctionator.API.v1.GetAuctionAgeByItemID = function() return 0 end
        local asked
        Auctionator.Database = { GetPriceHistory = function(_, key)
            asked = key
            return { { minSeen = 300, available = 9 }, { minSeen = 100 }, { minSeen = 100 }, { minSeen = 100 } }
        end }
        local a = ns.MarketCheck(5)
        H.eq(asked, "5")
        H.eq(a.spike, true)
        H.eq(ns.MarketCheck(6), nil, "no AH price, nothing to check")
    end)

    H.test("SkillChance uses estimated thresholds but only when they agree with the colour shown", function()
        local ns = boot()
        ns.RecipeData = { [197] = { [77] = { 1, 0, "t" } } } -- learned at 1: Y 26, R 51 by default
        C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 197, skillLevel = 30 } end
        H.near(ns.SkillChance(77, 1, 197), (51 - 30) / 25, "yellow at 30")
        H.eq(ns.SkillChance(77, 0, 197), nil, "game says orange: estimate disagrees, fall back")
        H.eq(ns.SkillChance(99, 1, 197), nil, "unknown recipe")
        H.eq(ns.LearnInfo(77, 197).sources, "t")
        H.eq(ns.LearnInfo(77).learn, 1, "any profession")
    end)
end
