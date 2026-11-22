-- Smoke test for UI.lua + ProfitTab.lua (ISTQB: smoke test using fakes). Widgets are fake objects whose
-- unknown methods are no-ops, so this checks that the real code paths run without Lua errors and produce
-- the expected text/state. It cannot check layout; that is verified in game.
return function(H)
    local F = require("ui_fakes")
    local mock, newObj, Fake, click = F.mock, F.newObj, F.Fake, F.click
    local function boot(opts) return F.boot(H, opts) end

    H.test("cost line under Auctionator shows best cost, savings and profit", function()
        boot()
        local text = _G.MakeOrBuyProfessionsFrame.Text.text
        H.truthy(text:find("559c"), text)
        H.truthy(text:find("saves 1341c"), text)
        H.truthy(text:find("Make or Buy profit: |cffffffff296c"), text)
    end)

    H.test("cost line takes Auctionator's place when its lines are turned off", function()
        mock.anchors = {}
        boot()
        local auct = newObj()
        auct.Total = newObj()
        auct.Total.text = ""
        _G.AuctionatorCraftingInfoProfessionsFrame = auct
        local line = _G.MakeOrBuyProfessionsFrame
        line.SetPoint = function(_, point, rel, relPoint) mock.anchor = { point, rel, relPoint } end
        line:Hide()
        ProfessionsFrame.CraftingPage.SchematicForm.Init() -- hooked refresh
        H.eq(mock.anchor[2], auct)
        H.eq(mock.anchor[3], "TOPLEFT", "empty Auctionator frame: anchor to its top")
        auct.Total.text = "To Craft: 35c"
        ProfessionsFrame.CraftingPage.SchematicForm.Init()
        H.eq(mock.anchor[3], "BOTTOMLEFT", "Auctionator lines visible: go below them")
        _G.AuctionatorCraftingInfoProfessionsFrame = nil
    end)

    H.test("side tab is a LargeSideTab with an icon and tooltip, inactive at first", function()
        local _, _, tab, panel, returnTab = boot()
        H.truthy(tab and tab.mouseUp, "side tab with a mouse-up handler")
        H.eq(tab.tooltipText, "Worth crafting")
        H.eq(tab.checked, false)
        H.eq(panel:IsShown(), false)
        H.eq(returnTab:IsShown(), false)
    end)

    H.test("opening the tab covers the window above Auctionator's frame level (520)", function()
        local _, _, tab, panel, returnTab = boot()
        mock.selectedNative.SelectedTexture.shown = true
        click(tab)
        H.eq(panel:IsShown(), true)
        H.eq(tab.checked, true)
        H.truthy(panel.level > 520 + 1000, "panel level " .. tostring(panel.level))
        H.eq(returnTab:IsShown(), true, "return tab drawn over the selected native tab")
        H.eq(returnTab.tooltipText, mock.selectedNative.tooltipText)
        H.eq(#mock.rows, 2, "bolt (600 vs 153) and bag (900 vs 559) are both profitable")
        H.eq(mock.rows[1].recipe.name, "Bolt of Woolen Cloth", "sorted by profit desc (417 > 296)")
    end)

    H.test("rows render text and tooltips; left-click opens the recipe and closes the tab", function()
        local _, _, tab, panel = boot()
        click(tab)
        local button = newObj()
        mock.view.init(button, mock.rows[2])
        H.truthy(button.Name.text:find("Woolen Bag"), button.Name.text)
        H.truthy(button.Name.text:find("%*"), "sub-craft marker")
        H.eq(button.cells[3].text, "|cff40ff40296c|r")
        H.eq(button.cells[4].text, "53%")

        button.scripts.OnEnter(button)
        local joined = table.concat(GameTooltip.lines, "\n")
        H.truthy(joined:find("If you bought every reagent | %-1045c"), joined)
        H.truthy(joined:find("9x Item2592"), joined)
        H.truthy(joined:find("@51c"), joined)
        H.truthy(joined:find("@153c"), joined)

        button.scripts.OnClick(button, "LeftButton")
        H.eq(mock.selected, 3757, "left-click opens the recipe")
        H.eq(panel:IsShown(), false)
    end)

    H.test("every way back to the native page closes the tab", function()
        local _, _, tab, panel, returnTab = boot({ whatsTraining = true })
        local ways = {
            { "tab clicked again", function() click(tab) end },
            { "return tab", function() click(returnTab) end },
            { "native side tab", function()
                local t = ProfessionsFrame.rightProfessionTabs[1]
                t.scripts.OnMouseUp(t, "LeftButton")
            end },
            { "overview tab", function()
                local t = ProfessionsFrame.ProfessionsOverviewTab
                t.scripts.OnMouseUp(t, "LeftButton")
            end },
            { "WhatsTraining tab", function()
                local t = _G.WhatsTrainingCraftingTab
                t.scripts.OnMouseUp(t, "LeftButton")
            end },
            { "profession switched", function() mock.callbacks["Professions.ProfessionSelected"]() end },
            { "window closed", function() ProfessionsFrame:Hide() ProfessionsFrame:Show() end },
        }
        for _, way in ipairs(ways) do
            click(tab)
            H.eq(panel:IsShown(), true, way[1] .. ": opened")
            way[2]()
            H.eq(panel:IsShown(), false, way[1] .. ": closed")
            H.eq(tab.checked, false, way[1] .. ": tab unchecked")
        end
    end)

    H.test("Show all recipes reveals unprofitable rows; sorting by name toggles", function()
        local _, frames, tab = boot()
        Auctionator.API.v1.GetAuctionPriceByItemID = function(_, id)
            return ({ [2592] = 51, [2997] = 100, [4241] = 900 })[id]
        end
        click(tab)
        H.eq(#mock.rows, 1, "bolt at 100 is unprofitable, hidden")
        local check
        for _, f in ipairs(frames) do
            if f.scripts.OnClick and f.checked ~= nil and f ~= tab then check = f end
        end
        H.truthy(check, "checkbox found")
        check.checked = true
        check.scripts.OnClick(check)
        H.eq(#mock.rows, 2)
        local function header(text)
            for _, f in ipairs(frames) do
                if f.Text and f.Text.text == text then return f end
            end
        end
        H.truthy(header("|cffffffffProfit v|r"), "profit header marked as active descending sort")
        local nameHeader = header("Recipe")
        nameHeader.scripts.OnClick(nameHeader)
        H.eq(mock.rows[1].recipe.name, "Bolt of Woolen Cloth", "A-Z")
        nameHeader.scripts.OnClick(nameHeader)
        H.eq(mock.rows[1].recipe.name, "Woolen Bag", "Z-A")
    end)

    H.test("Auctionator price updates refresh the open tab", function()
        local _, _, tab = boot()
        click(tab)
        Auctionator.API.v1.GetAuctionPriceByItemID = function(_, id)
            return ({ [2592] = 51, [2997] = 600, [4241] = 100 })[id]
        end
        mock.dbUpdate()
        H.eq(#mock.rows, 1, "bag no longer profitable after a new scan")
    end)

    H.test("vendor price beats a low AH price in the tab and in the cost line", function()
        local _, _, tab = boot({ vendorSell = { [4241] = 900 } }) -- AH 900 nets 855; vendor pays 900
        H.truthy(_G.MakeOrBuyProfessionsFrame.Text.text:find("341c.-%(vendor%)"), _G.MakeOrBuyProfessionsFrame.Text.text)
        click(tab)
        local bag
        for _, row in ipairs(mock.rows) do
            if row.recipe.recipeID == 3757 then bag = row end
        end
        H.eq(bag.saleSource, "vendor")
        local button = newObj()
        mock.view.init(button, bag)
        H.eq(button.cells[2].text, "900c|cffa0a0a0 (v)|r")
        H.eq(button.cells[3].text, "|cff40ff40341c|r", "900 - 559")
        button.scripts.OnEnter(button)
        local joined = table.concat(GameTooltip.lines, "\n")
        H.truthy(joined:find("Vendor price | 900c"), joined)
        H.truthy(joined:find("Profit %(using vendor%) | 341c"), joined)
    end)

    H.test("an item with no AH listing is valued at its vendor price", function()
        local _, _, tab = boot({ vendorSell = { [2997] = 200 } })
        Auctionator.API.v1.GetAuctionPriceByItemID = function(_, id)
            return ({ [2592] = 51, [2997] = nil, [4241] = 900 })[id]
        end
        click(tab)
        local bolt
        for _, row in ipairs(mock.rows) do
            if row.recipe.recipeID == 2964 then bolt = row end
        end
        H.truthy(bolt, "bolt listed: 200 vendor - 153 cost = +47")
        H.eq(bolt.profit, 47)
    end)

    local function modeButton(frames, key)
        for _, f in ipairs(frames) do
            if f.mode == key then return f end
        end
    end

    -- Regression (in game, 2026-11-07): bounds saved with math.huge came back as { 79 }; building the view
    -- errored halfway, so the title, the selected button and sorting stopped following clicks
    H.test("saved bounds from an older version: every mode button switches the view and sorting works", function()
        local _, frames, tab = boot({ skillLevel = 63, maxSkill = 150,
            db = { version = 1, recipes = {}, bounds = { [3757] = { y = { 79 }, g = { 0 }, r = { 0 } },
                [2964] = { y = { 0 }, g = { 0 }, r = { 0, 78 } } } } })
        click(tab)
        for _, key in ipairs({ "skill", "route", "learn", "profit" }) do
            local b = modeButton(frames, key)
            b.scripts.OnClick(b)
            H.eq(MakeOrBuyCharDB.mode, key)
            H.eq(b.disabled, true, key .. " button selected")
            H.truthy(mock.rows, key .. " rows built")
        end
        H.truthy(_G.MakeOrBuyProfitPanel and true)
        H.eq(mock.lastError, nil, "no error")
    end)

    H.test("an error while building a view is reported and shown, and the buttons stay in step", function()
        local ns, frames, tab = boot()
        mock.lastError = nil
        geterrorhandler = function() return function(e) mock.lastError = e end end
        click(tab)
        ns.Ranking.Build = function() error("boom") end
        local b = modeButton(frames, "skill")
        b.scripts.OnClick(b)
        H.eq(b.disabled, true)
        H.truthy(tostring(mock.lastError):find("boom"), tostring(mock.lastError))
        local found = false
        for _, f in ipairs(mock.fonts) do
            if f.text and f.text:find("hit an error building this view") then found = true end
        end
        H.truthy(found, "message shown in the tab")
        H.eq(#mock.rows, 0)
        geterrorhandler = nil
    end)

    H.test("skill-up mode: switches columns, filters to recipes that level, cheapest point first", function()
        local _, frames, tab = boot()
        click(tab)
        local skillButton
        for _, f in ipairs(frames) do
            if f.mode == "skill" then skillButton = f end
        end
        H.truthy(skillButton, "mode button")
        skillButton.scripts.OnClick(skillButton)
        H.eq(skillButton.disabled, true, "active mode button reads as selected")
        H.eq(#mock.rows, 2)
        -- Bolt: orange, net 153 - 570 = -417 per point. Bag: yellow, net 559 - 855 = -296 over 0.75 = -394.7
        H.eq(mock.rows[1].recipe.name, "Bolt of Woolen Cloth")
        local button = newObj()
        mock.view.init(button, mock.rows[1])
        H.eq(button.cells[3].text, "|cff40ff40+417c|r", "net cost: you earn")
        H.eq(button.cells[4].text, "|cff40ff40+417c|r", "orange: exact per point")
        mock.view.init(button, mock.rows[2])
        H.eq(button.cells[4].text, "|cff40ff40~+395c|r", "yellow: estimate")
        H.truthy(button.Name.text:find("^|cffffff00"), "yellow name")

        local function header(text)
            for _, f in ipairs(frames) do
                if f.Text and f.Text.text == text then return f end
            end
        end
        H.truthy(header("|cffffffffPer point ^|r"), "per point is the default ascending sort")
        H.truthy(header("Net cost"))

        button.scripts.OnEnter(button)
        local joined = table.concat(GameTooltip.lines, "\n")
        H.truthy(joined:find("Yellow.- recipe | skill%-up chance ~75%%"), joined)

        -- Mode is remembered per character
        tab.mouseUp(tab, "LeftButton", true)
        tab.mouseUp(tab, "LeftButton", true)
        H.eq(MakeOrBuyCharDB.mode, "skill")
        H.truthy(header("|cffffffffPer point ^|r"), "reopens in skill-up mode")
    end)

    H.test("skill-up mode hides grey recipes unless Show all is ticked", function()
        local _, frames, tab = boot()
        C_TradeSkillUI.GetRecipeInfo = function(id) return { recipeID = id, learned = true, relativeDifficulty = id == 2964 and 3 or 0 } end
        click(tab)
        for _, f in ipairs(frames) do
            if f.mode == "skill" then f.scripts.OnClick(f) end
        end
        H.eq(#mock.rows, 1, "grey bolt hidden")
        H.eq(mock.rows[1].recipe.name, "Woolen Bag")
    end)

    local function modeButton(frames, key)
        for _, f in ipairs(frames) do
            if f.mode == key then return f end
        end
    end
    local function font(pattern)
        for _, fs in ipairs(mock.fonts) do
            if type(fs.text) == "string" and fs.text:find(pattern) then return fs end
        end
    end

    H.test("batch of 3 and owned items: the cost line shows the cash still to spend", function()
        boot()
        ProfessionsFrame.CraftingPage.CreateMultipleInputBox = { GetValue = function() return 3 end }
        Stockpile = { API = { GetOwnedMap = function() return { [2592] = 4 } end } }
        ProfessionsFrame.CraftingPage.SchematicForm.Init()
        local text = _G.MakeOrBuyProfessionsFrame.Text.text
        -- 3 bags: 27 wool + 3 thread; own 4 wool -> 23 x 51 + 3 x 100 = 1473
        H.truthy(text:find("For 3 crafts: spend |cffffffff1473c|r"), text)
        H.truthy(text:find("using 4 you own"), text)
        local line = _G.MakeOrBuyProfessionsFrame
        line.scripts.OnEnter(line)
        local joined = table.concat(GameTooltip.lines, "\n")
        H.truthy(joined:find("plan %(3 crafts%)"), joined)
        H.truthy(joined:find("have 4, craft 1x") or joined:find("27x Item2592  |cff40ff40have 4, "), joined)
        H.truthy(joined:find("Cash to spend %(using your items%) | 1473c"), joined)
        Stockpile = nil
    end)

    H.test("Shift-click opens WhereToFarm for the priciest reagent", function()
        boot()
        local opened
        WhereToFarm = { API = { IsAvailable = function() return true end, Open = function(id) opened = id end } }
        IsShiftKeyDown = function() return true end
        ProfessionsFrame.CraftingPage.SchematicForm.Init()
        local line = _G.MakeOrBuyProfessionsFrame
        line.scripts.OnEnter(line)
        H.truthy(table.concat(GameTooltip.lines, "\n"):find("Shift%-click: where to get the reagents"))
        line.scripts.OnMouseUp(line)
        H.eq(opened, 2592, "9 Wool (459c) costs more than 1 Thread (100c)")
        WhereToFarm, IsShiftKeyDown = nil, nil
    end)

    H.test("Shift-click passes every reagent the plan buys as choices, priciest first", function()
        boot()
        local opened, opts
        WhereToFarm = { API = { IsAvailable = function() return true end,
            Open = function(id, o) opened, opts = id, o end } }
        IsShiftKeyDown = function() return true end
        ProfessionsFrame.CraftingPage.SchematicForm.Init()
        local line = _G.MakeOrBuyProfessionsFrame
        line.scripts.OnMouseUp(line)
        H.eq(opened, 2592)
        H.truthy(opts and opts.choices, "choices passed")
        H.eq(opts.choices[1], 2592, "Wool first")
        H.truthy(#opts.choices >= 2, "Thread too")
        WhereToFarm, IsShiftKeyDown = nil, nil
    end)

    H.test("learn row: tooltip names the nearest trainer; Shift-click opens where to learn it", function()
        local ns, frames, tab = boot({ skillLevel = 60, maxSkill = 75 })
        ns.RecipeData = { [197] = { [3758] = { 50, 500, "t" } } }
        local spec, opts, asked
        WhereToFarm = { API = { IsAvailable = function() return true end, Open = function() end,
            OpenRecipe = function(s, o) spec, opts = s, o end,
            GetRecipeSources = function(s)
                asked = s
                return { { kind = "trainer", name = "Far Tailor", zoneName = "Elsewhere", distanceText = "2.0k yd", dim = true },
                    { kind = "trainer", name = "Sewa Mistrunner", zoneName = "Silverpine Forest", distanceText = "320 yd" } }
            end } }
        click(tab)
        modeButton(frames, "learn").scripts.OnClick(modeButton(frames, "learn"))
        local button = newObj()
        mock.view.init(button, mock.rows[1])
        button.scripts.OnEnter(button)
        local lines = table.concat(GameTooltip.lines, "\n")
        H.truthy(lines:find("Learn from (trainer, 1 of 2) | Sewa Mistrunner, Silverpine Forest (320 yd)", 1, true), lines)
        H.truthy(lines:find("Shift-click: where to learn it", 1, true), lines)
        H.eq(asked.sources, "t"); H.eq(asked.learn, 50)
        IsShiftKeyDown = function() return true end
        button.scripts.OnClick(button, "LeftButton")
        H.eq(spec.name, "Trainer Bag"); H.eq(spec.recipeID, 3758); H.eq(spec.profession, 197)
        H.eq(opts.choices[1], spec, "the recipe first"); H.truthy(#opts.choices >= 2, "then its reagents")
        WhereToFarm, IsShiftKeyDown = nil, nil
    end)

    H.test("learn row with an older WhereToFarm (no OpenRecipe): Shift-click falls back to the reagents", function()
        local ns, frames, tab = boot({ skillLevel = 60, maxSkill = 75 })
        ns.RecipeData = { [197] = { [3758] = { 50, 500, "t" } } }
        local opened
        WhereToFarm = { API = { IsAvailable = function() return true end, Open = function(id) opened = id end } }
        click(tab)
        modeButton(frames, "learn").scripts.OnClick(modeButton(frames, "learn"))
        local button = newObj()
        mock.view.init(button, mock.rows[1])
        button.scripts.OnEnter(button)
        H.truthy(table.concat(GameTooltip.lines, "\n"):find("where to get its reagents", 1, true))
        IsShiftKeyDown = function() return true end
        button.scripts.OnClick(button, "LeftButton")
        H.eq(opened, 2592)
        WhereToFarm, IsShiftKeyDown = nil, nil
    end)

    H.test("a spiking AH price is flagged in the cost line, the profit cell and the tooltip", function()
        local _, _, tab = boot()
        Auctionator.Database = { GetPriceHistory = function(_, key)
            if key == "4241" then
                return { { minSeen = 900, available = 8 }, { minSeen = 300 }, { minSeen = 300 }, { minSeen = 300 } }
            end
            return {}
        end }
        ProfessionsFrame.CraftingPage.SchematicForm.Init()
        H.truthy(_G.MakeOrBuyProfessionsFrame.Text.text:find("price unreliable"))
        click(tab)
        local bag
        for _, r in ipairs(mock.rows) do if r.recipe.name == "Woolen Bag" then bag = r end end
        local button = newObj()
        mock.view.init(button, bag)
        H.truthy(button.cells[3].text:find(" !"), button.cells[3].text)
        button.scripts.OnEnter(button)
        local joined = table.concat(GameTooltip.lines, "\n")
        H.truthy(joined:find("AH price unreliable: 3.0x the usual 300c"), joined)
        Auctionator.Database = nil
    end)

    H.test("route mode: one row per segment, summary with crafts and spend, editable target", function()
        local ns, frames, tab = boot({ skillLevel = 60, maxSkill = 75 })
        click(tab)
        local route = modeButton(frames, "route")
        route.scripts.OnClick(route)
        H.eq(route.disabled, true)
        H.truthy(#mock.rows >= 1, "segments")
        H.truthy(font("^60 to 75: ~%d+ crafts, spend "), "summary")
        H.truthy(font("^Include recipes to learn$"), "checkbox label for this mode")
        local button = newObj()
        mock.view.init(button, mock.rows[1])
        H.truthy(button.cells[1].text:find("^60 %- "), button.cells[1].text)
        H.truthy(button.cells[2].text:find("^~%d+x$"), button.cells[2].text)

        ns.ProfitTab.SetTarget("62")
        H.truthy(font("^60 to 62: "), "target changed")
        H.eq(MakeOrBuyCharDB.routeTarget[197], 62)
        ns.ProfitTab.SetTarget("99")
        H.truthy(font("^60 to 75: "), "target capped at the skill cap")
    end)

    H.test("route mode without a known skill level explains instead of erroring", function()
        local _, frames, tab = boot()
        click(tab)
        modeButton(frames, "route").scripts.OnClick(modeButton(frames, "route"))
        H.eq(#mock.rows, 0)
        H.truthy(font("^Skill level unknown"))
    end)

    H.test("learn mode lists unlearned recipes with learn level, cost and payback", function()
        local ns, frames, tab = boot({ skillLevel = 60, maxSkill = 75 })
        ns.RecipeData = { [197] = { [3758] = { 50, 500, "t" } } }
        click(tab)
        modeButton(frames, "learn").scripts.OnClick(modeButton(frames, "learn"))
        H.eq(#mock.rows, 1)
        H.eq(mock.rows[1].recipe.name, "Trainer Bag")
        local button = newObj()
        mock.view.init(button, mock.rows[1])
        H.eq(button.cells[1].text, "50", "learnable now: plain")
        H.eq(button.cells[2].text, "500c")
        H.eq(button.cells[4].text, "2 crafts", "500 / 296 -> 2")
        H.truthy(font("^1 of 1 recipes you don't know would be profitable"))
        -- Clicking an unlearned recipe doesn't try to open it
        mock.selected = nil
        button.scripts.OnClick(button, "LeftButton")
        H.eq(mock.selected, nil)
    end)

    H.test("route learns a recipe part-way when that becomes cheaper per point, and marks it", function()
        -- Bolt is grey (no points). Woolen Bag is yellow at 60 and loses 84c per craft (sells 475, costs 559).
        -- Trainer Bag (same reagents) costs 100c to learn at 60 and stays orange: per point it's 84c plus the
        -- learn cost spread over the points left. As the Woolen Bag's chance drops, learning wins (at skill 63).
        local ns, frames, tab = boot({ skillLevel = 60, maxSkill = 75, boltDifficulty = 3, bagPrice = 500 })
        ns.RecipeData = { [197] = { [3758] = { 60, 100, "t" } } }
        click(tab)
        modeButton(frames, "route").scripts.OnClick(modeButton(frames, "route"))
        H.eq(#mock.rows, 2)
        H.eq(mock.rows[1].recipe.name, "Woolen Bag")
        H.eq(mock.rows[1].segment.from, 60); H.eq(mock.rows[1].segment.to, 63)
        H.eq(mock.rows[2].recipe.name, "Trainer Bag")
        H.eq(mock.rows[2].segment.to, 75)
        local button = newObj()
        mock.view.init(button, mock.rows[2])
        H.truthy(button.Name.text:find("%(learn%)"), button.Name.text)
        H.truthy(font("Learn 1 recipe on the way"), "legend")
        -- 12 orange crafts at 559c plus 100c to learn
        H.eq(button.cells[3].text, (12 * 559 + 100) .. "c")
        -- Not known yet: left-click doesn't try to open it
        mock.selected = nil
        button.scripts.OnClick(button, "LeftButton")
        H.eq(mock.selected, nil)

        -- Unticking "Include recipes to learn" keeps to known recipes
        local box
        for _, f in ipairs(frames) do
            if f.checked ~= nil and f.scripts.OnClick and not f.mode then box = f end
        end
        box.checked = false
        box.scripts.OnClick(box)
        H.eq(MakeOrBuyCharDB.routeLearn, false)
        H.eq(#mock.rows, 1)
        H.eq(mock.rows[1].recipe.name, "Woolen Bag")
    end)

    H.test("skill-up order: earning recipes count as free; fewest crafts first, not most money", function()
        local ns = H.load({ "Planner.lua", "Market.lua", "Skill.lua", "Ranking.lua" })
        local rows = {
            { recipe = { name = "Green earner", recipeID = 1 }, perPoint = -400, points = 0.2 },
            { recipe = { name = "Orange earner", recipeID = 2 }, perPoint = -100, points = 1 },
            { recipe = { name = "Orange cost", recipeID = 3 }, perPoint = 50, points = 1 },
            { recipe = { name = "Orange bigger earner", recipeID = 4 }, perPoint = -150, points = 1 },
        }
        ns.Ranking.Sort(rows, "perPoint", true)
        H.eq(rows[1].recipe.name, "Orange bigger earner")
        H.eq(rows[2].recipe.name, "Orange earner")
        H.eq(rows[3].recipe.name, "Green earner")
        H.eq(rows[4].recipe.name, "Orange cost")
    end)
    local function restockWidgets(frames)
        local out = {}
        for _, f in ipairs(frames) do
            if f.text == "Search AH" and f.SetSize and f ~= nil then out.search = out.search or {} ; out.search[#out.search + 1] = f end
            if f.text == "Clear" then out.clear = f end
        end
        -- the route bar also has a "Search AH" button; the restock one is created last
        out.search = out.search and out.search[#out.search]
        return out
    end

    local function barText()
        for _, f in ipairs(mock.fonts) do
            if f.text and (f.text:find("Restock") ) then return f.text end
        end
    end

    H.test("Ctrl-click shows the crafted item in ItemRefTooltip; again on the same item closes it", function()
        local ns, frames, tab = boot()
        click(tab)
        local shownID
        ItemRefTooltip = newObj()
        ItemRefTooltip.shown = false
        ItemRefTooltip.SetItemByID = function(self, id) shownID = id end
        ItemRefTooltip.GetItem = function() return "x", shownID and ("|Hitem:" .. shownID .. "::|h") end
        IsControlKeyDown = function() return true end
        local bag
        for _, r in ipairs(mock.rows) do if r.recipe.name == "Woolen Bag" then bag = r end end
        local button = newObj()
        mock.view.init(button, bag)
        button.scripts.OnEnter(button)
        local hint
        for _, l in ipairs(GameTooltip.lines) do if l:find("Ctrl%-click: show the crafted item") then hint = l end end
        H.truthy(hint, "tooltip hint")
        button.scripts.OnClick(button, "LeftButton")
        H.eq(shownID, 4241)
        H.truthy(ItemRefTooltip:IsShown())
        H.eq(MakeOrBuyCharDB.restock[3757], nil, "Ctrl no longer adds to restock")
        button.scripts.OnClick(button, "LeftButton")
        H.eq(ItemRefTooltip:IsShown(), false, "toggles off")
        IsControlKeyDown, ItemRefTooltip = nil, nil
    end)

    H.test("restock: Alt-click adds crafts, the row shows the count and the bar sums the list", function()
        local ns, frames, tab = boot()
        click(tab)
        H.truthy(barText():find("Alt%-click a recipe to add a craft"), "empty hint")
        IsAltKeyDown = function() return true end
        local rows = mock.rows
        local bag
        for _, r in ipairs(rows) do if r.recipe.name == "Woolen Bag" then bag = r end end
        local button = newObj()
        mock.view.init(button, bag)
        button.scripts.OnClick(button, "LeftButton")
        button.scripts.OnClick(button, "LeftButton")
        H.eq(MakeOrBuyCharDB.restock[3757], 2)
        mock.view.init(button, bag)
        H.truthy(button.Name.text:find("|cff4dd2ff %[2%]|r", 1, false), button.Name.text)
        -- 2 bags = 6 bolts crafted from 18 wool (918c) + 2 thread (200c)
        local text = barText()
        H.truthy(text:find("2x Woolen Bag"), text)
        H.truthy(text:find("1118c"), text)
        button.scripts.OnClick(button, "RightButton")
        H.eq(MakeOrBuyCharDB.restock[3757], 1, "Alt-right-click removes one")
        IsAltKeyDown = nil
    end)

    H.test("restock: Search AH sends the merged list (minus vendor items), only with the AH open; Clear empties", function()
        local ns, frames, tab = boot()
        click(tab)
        MakeOrBuyCharDB.restock = { [3757] = 1, [2964] = 2 }
        ns.ProfitTab.Refresh()
        local w = restockWidgets(frames)
        mock.chat = {}
        w.search.scripts.OnClick(w.search)
        H.truthy(mock.chat[#mock.chat]:find("Open the Auction House first"), mock.chat[#mock.chat])
        AuctionHouseFrame = newObj()
        w.search.scripts.OnClick(w.search)
        H.eq(#mock.searched, 1, "thread is a vendor item")
        H.eq(mock.searched[1].searchString, "Item2592")
        H.eq(mock.searched[1].quantity, 9 + 6, "wool for 3 bolts (bag) + 2 bolts")
        AuctionHouseFrame = nil
        w.clear.scripts.OnClick(w.clear)
        H.eq(next(MakeOrBuyCharDB.restock), nil)
        H.truthy(barText():find("Alt%-click a recipe"), "back to the hint")
    end)

    H.test("restock: owned items lower the spend; the bar tooltip lists crafts, purchases and profit", function()
        local ns, frames, tab = boot()
        Stockpile = { API = { GetOwnedMap = function() return { [2592] = 9 } end } }
        click(tab)
        MakeOrBuyCharDB.restock = { [3757] = 1 }
        ns.ProfitTab.Refresh()
        local text = barText()
        H.truthy(text:find("using 9 you own"), text)
        H.truthy(text:find("spend |r100c"), text)
        ns.ProfitTab.RestockTooltip(newObj())
        local lines = table.concat(GameTooltip.lines, "\n")
        H.truthy(lines:find("1x Woolen Bag | 296c"), lines)
        H.truthy(lines:find("1x Item2321"), lines)
        H.truthy(lines:find("Cash to spend %(using 9 you own%) | 100c"), lines)
        Stockpile = nil
    end)

    H.test("/mob restock prints the list; /mob restock clear empties it", function()
        local ns = boot()
        MakeOrBuyCharDB.restock = { [2964] = 2 }
        mock.chat = {}
        SlashCmdList.MAKEORBUY("restock")
        H.truthy(mock.chat[1]:find("Restock: 2x Bolt of Woolen Cloth"), mock.chat[1])
        H.truthy(mock.chat[2]:find("6x Item2592 %- AH 306c %(@51c%)"), mock.chat[2])
        H.truthy(mock.chat[3]:find("Spend 306c, expected profit 834c"), mock.chat[3])
        SlashCmdList.MAKEORBUY("restock clear")
        H.eq(next(MakeOrBuyCharDB.restock), nil)
        SlashCmdList.MAKEORBUY("restock")
        H.truthy(mock.chat[#mock.chat]:find("Restock list is empty"))
    end)
end
