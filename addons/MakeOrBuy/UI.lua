-- UI: adds "Make or Buy" cost/profit lines under Auctionator's crafting info in the Professions window.
-- Hover for the full plan; click (with the Auction House open) to search the shopping list in Auctionator;
-- Shift-click to see where to farm the priciest reagent (needs the WhereToFarm addon).
-- The plan follows the window's "craft N" box and uses what you own (needs the Stockpile addon).
local _, ns = ...

local UI = {}
ns.UI = UI

local GREEN, RED, GREY, ORANGE = "ff40ff40", "ffff4040", "ffa0a0a0", "ffff9933"
local function color(hex, text)
    return "|c" .. hex .. text .. "|r"
end
UI.color = color

local frame, form, lastPlan, lastCrafts

local function CurrentRecipe()
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    if not info or not info.recipeID then
        return nil
    end
    -- Read live from the game so the selected recipe works even before its profession was scanned
    return ns.Scanner.ReadRecipe(info.recipeID)
end

-- How many crafts the window's quantity box asks for (1 if there's no box)
function UI.BatchSize()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local box = page and page.CreateMultipleInputBox
    if box and box.GetValue then
        local ok, n = pcall(box.GetValue, box)
        if ok and type(n) == "number" and n >= 1 then
            return math.floor(n)
        end
    end
    return 1
end

local function Anchor()
    frame:ClearAllPoints()
    local auctionator = _G.AuctionatorCraftingInfoProfessionsFrame
    if auctionator and auctionator:IsShown() then
        local text = auctionator.Total and auctionator.Total:GetText()
        if text and text ~= "" then
            frame:SetPoint("TOPLEFT", auctionator, "BOTTOMLEFT", 0, -2)
        else
            -- Its cost/profit lines are turned off: take their place
            frame:SetPoint("TOPLEFT", auctionator, "TOPLEFT", 0, 0)
        end
    elseif form.Reagents then
        frame:SetPoint("TOPLEFT", form.Reagents, "BOTTOMLEFT", 0, -10)
    else
        frame:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 10, 10)
    end
end

-- "For 5 crafts: spend 7s 20c (using 12 you own)" when the batch or your items change the picture
local function CashLine(plan, crafts)
    local have = ns.Owned()
    local lines, _, _, cash = ns.Planner.Expand(plan, crafts, have)
    local used = 0
    for _, line in ipairs(lines) do
        used = used + (line.owned or 0)
    end
    if crafts == 1 and used == 0 then
        return nil
    end
    local text = (crafts > 1 and ("For " .. crafts .. " crafts: ") or "") .. "spend " .. color("ffffffff", ns.Money(cash))
    if used > 0 then
        text = text .. color(GREEN, " (using " .. used .. " you own)")
    elseif crafts > 1 then
        text = text .. color(GREY, " (" .. ns.Money(plan.total * crafts) .. " at market)")
    end
    return text
end

function UI.Refresh()
    if not frame or not form or not form:IsVisible() then
        return
    end
    lastPlan = nil
    local recipe = CurrentRecipe()
    if not recipe then
        frame:Hide()
        return
    end

    local plan = ns.Planner.PlanRecipe(recipe, ns.recipesByOutput, ns.Price)
    lastPlan, lastCrafts = plan, UI.BatchSize()

    local costText = "Make or Buy cost: " .. color("ffffffff", ns.Money(plan.total))
    local savings = plan.naiveTotal - plan.total
    if savings >= 1 then
        costText = costText .. color(GREEN, " (saves " .. ns.Money(savings) .. ")")
    elseif not ns.Planner.UsesSubCrafts(plan) then
        costText = costText .. color(GREY, " (buying is cheapest)")
    end
    if not plan.complete then
        costText = costText .. color(ORANGE, " (missing prices)")
    end

    local lines = { costText }
    local saleUnit, source = ns.SaleValue(recipe.outputItemID)
    if saleUnit then
        local profit = ns.Planner.ProfitFromValue(saleUnit, plan.outputQty, plan.total)
        local text = "Make or Buy profit: " .. color(profit >= 0 and "ffffffff" or RED, ns.Money(profit))
            .. (source == "vendor" and color(GREY, " (vendor)") or "")
        if source == "ah" and ns.Market.Risky(ns.MarketCheck(recipe.outputItemID)) then
            text = text .. color(ORANGE, " (price unreliable)")
        end
        lines[#lines + 1] = text
    end
    local cash = CashLine(plan, lastCrafts)
    if cash then
        lines[#lines + 1] = cash
    end

    frame.Text:SetText(table.concat(lines, "\n"))
    frame:SetHeight(16 * #lines)
    Anchor()
    frame:Show()
end

local function SourceLabel(line)
    if line.owned and line.owned >= line.qty then
        return color(GREEN, "you have them")
    end
    local label
    if line.method == "craft" then
        label = color(GREEN, "craft " .. line.crafts .. "x")
    elseif line.method == "buy" then
        label = line.buySource == "vendor" and "vendor" or "AH"
    else
        label = color(ORANGE, "no price")
    end
    if line.owned and line.owned > 0 then
        label = color(GREEN, "have " .. line.owned .. ", ") .. label
    end
    return label
end

-- Adds the plan breakdown to GameTooltip (shared with the Worth crafting tab)
function UI.AddPlanLines(plan, crafts)
    crafts = crafts or 1
    local lines, _, _, cash = ns.Planner.Expand(plan, crafts, ns.Owned())
    for _, line in ipairs(lines) do
        local left = string.rep("    ", line.depth) .. line.qty .. "x " .. ns.ItemName(line.itemID)
            .. "  " .. SourceLabel(line)
        local right = ns.Money(line.unitCost * line.qty)
        if line.qty > 1 and line.unitCost and line.unitCost > 0 then
            right = right .. color(GREY, " (@" .. ns.Money(line.unitCost) .. ")")
        end
        if line.method == "craft" and line.buyPrice then
            right = right .. color(GREY, " (AH " .. ns.Money(line.buyPrice * line.qty) .. ")")
        end
        GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Buying all reagents", ns.Money(plan.naiveTotal * crafts), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    GameTooltip:AddDoubleLine("Best plan", ns.Money(plan.total * crafts), 1, 1, 1, 1, 1, 1)
    if cash < plan.total * crafts - 0.5 then
        GameTooltip:AddDoubleLine("Cash to spend (using your items)", ns.Money(cash), 0.25, 1, 0.25, 0.25, 1, 0.25)
    end
end

function UI.IsAuctionHouseOpen()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown() and true or false
end

-- The item ItemRefTooltip shows (a chat link or ours), from its link
local function ShownItemID(tip)
    if not (tip:IsShown() and tip.GetItem) then
        return nil
    end
    local ok, _, link = pcall(tip.GetItem, tip)
    return ok and type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Shows the crafted item itself (stats, bag slots, ...) in the sticky tooltip chat links use.
-- Again on the same item closes it, like a chat link.
function UI.InspectItem(itemID)
    local tip = _G.ItemRefTooltip
    if not (tip and itemID) then
        return false
    end
    if ShownItemID(tip) == itemID then
        tip:Hide()
        return true
    end
    if ShowUIPanel then
        ShowUIPanel(tip)
    end
    if not tip:IsShown() then
        tip:SetOwner(UIParent, "ANCHOR_PRESERVE")
    end
    -- SetItemByID refreshes itself once an uncached item loads
    if tip.SetItemByID then
        tip:SetItemByID(itemID)
    else
        tip:SetHyperlink("item:" .. itemID)
    end
    tip:Show()
    return true
end

function UI.FarmAvailable()
    local api = _G.WhereToFarm and _G.WhereToFarm.API
    if not (api and api.Open) then
        return false
    end
    local ok, available = pcall(api.IsAvailable)
    return ok and available and true or false
end

local function ShowTooltip(self)
    if not lastPlan then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Make or Buy plan (" .. lastCrafts .. (lastCrafts == 1 and " craft)" or " crafts)"))
    UI.AddPlanLines(lastPlan, lastCrafts)
    if UI.IsAuctionHouseOpen() then
        GameTooltip:AddLine("Click: search shopping list in Auctionator", 0.4, 0.8, 1)
    end
    if UI.FarmAvailable() then
        GameTooltip:AddLine("Shift-click: where to get the reagents", 0.4, 0.8, 1)
    end
    GameTooltip:Show()
end

-- Searches a list of { itemID, qty, source } in Auctionator (needs the AH open). Vendor items are skipped.
function UI.SearchList(shopping)
    if not UI.IsAuctionHouseOpen() then
        return false
    end
    local terms = {}
    for _, entry in ipairs(shopping) do
        -- Vendor items are bought from a merchant, not the AH
        if entry.source ~= "vendor" and entry.qty > 0 then
            local name = C_Item.GetItemNameByID(entry.itemID)
            if name then
                terms[#terms + 1] = { searchString = name, isExact = true, quantity = entry.qty }
            end
        end
    end
    if #terms > 0 then
        Auctionator.API.v1.MultiSearchAdvanced(ns.CALLER, terms)
    end
    return #terms > 0
end

-- Searches a plan's AH shopping list in Auctionator, minus what you own
function UI.SearchShopping(plan, crafts)
    if not plan or not UI.IsAuctionHouseOpen() then
        return
    end
    local _, shopping = ns.Planner.Expand(plan, crafts or 1, ns.Owned())
    UI.SearchList(shopping)
end

-- Every item a plan buys, priciest first (what you own included: you may still want more)
function UI.ReagentChoices(plan, crafts)
    local _, shopping = ns.Planner.Expand(plan, crafts or 1, {})
    local list = {}
    for _, entry in ipairs(shopping) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        local va, vb = a.qty * (a.unitPrice or 0), b.qty * (b.unitPrice or 0)
        if va ~= vb then
            return va > vb
        end
        return a.itemID < b.itemID
    end)
    local ids = {}
    for i, entry in ipairs(list) do
        ids[i] = entry.itemID
    end
    return ids, shopping
end

-- Opens WhereToFarm for the reagent that costs the most to buy in this plan, with buttons to switch to
-- every other reagent it buys
function UI.FarmFor(plan, crafts)
    if not plan or not UI.FarmAvailable() then
        return false
    end
    local choices = UI.ReagentChoices(plan, crafts)
    local _, shopping = ns.Planner.Expand(plan, crafts or 1, ns.Owned())
    local itemID = ns.Planner.PriciestPurchase(shopping) or choices[1]
    if itemID then
        pcall(_G.WhereToFarm.API.Open, itemID, { choices = choices })
        return true
    end
    return false
end

-- Where to learn an unlearned recipe (needs WhereToFarm 0.3+)
function UI.LearnAvailable()
    local api = _G.WhereToFarm and _G.WhereToFarm.API
    return UI.FarmAvailable() and type(api.OpenRecipe) == "function"
end

-- What WhereToFarm needs to know about a recipe to say where it's learned
function UI.RecipeSpec(row)
    local recipe = row.recipe
    return {
        recipeID = recipe.recipeID,
        name = recipe.name or ns.ItemName(recipe.outputItemID),
        profession = type(recipe.profession) == "number" and recipe.profession or nil,
        learn = row.learn,
        sources = row.sources,
        teach = row.teach,
        icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(recipe.outputItemID) or nil,
    }
end

-- Opens WhereToFarm on where to learn the recipe, with buttons for its reagents too
function UI.LearnFor(row, crafts)
    if not row or not UI.LearnAvailable() then
        return false
    end
    local spec = UI.RecipeSpec(row)
    local choices = { spec }
    for _, id in ipairs((UI.ReagentChoices(row.plan, crafts))) do
        choices[#choices + 1] = id
    end
    pcall(_G.WhereToFarm.API.OpenRecipe, spec, { choices = choices })
    return true
end

-- The nearest place to learn a recipe, e.g. "Cook Ghilm, Dun Morogh (here)", or nil
function UI.NearestLearnText(row)
    local api = _G.WhereToFarm and _G.WhereToFarm.API
    if not (UI.LearnAvailable() and api.GetRecipeSources) then
        return nil
    end
    local ok, list = pcall(api.GetRecipeSources, UI.RecipeSpec(row))
    if not ok or type(list) ~= "table" then
        return nil
    end
    local kinds = { trainer = "trainer", vendor = "vendor", quest = "quest", npc = "drop", object = "chest" }
    for _, s in ipairs(list) do
        if kinds[s.kind] and not s.dim then
            local where = s.zoneName and (", " .. s.zoneName) or ""
            local dist = s.distanceText and s.distanceText ~= "-" and (" (" .. s.distanceText .. ")") or ""
            return s.name .. where .. dist, kinds[s.kind], #list
        end
    end
    return nil
end

function UI.Init()
    if frame or not (ProfessionsFrame and ProfessionsFrame.CraftingPage) then
        return
    end
    form = ProfessionsFrame.CraftingPage.SchematicForm
    if not form then
        return
    end

    frame = CreateFrame("Frame", "MakeOrBuyProfessionsFrame", form)
    frame:SetSize(300, 32)
    frame.Text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.Text:SetPoint("TOPLEFT")
    frame.Text:SetJustifyH("LEFT")
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", ShowTooltip)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    frame:SetScript("OnMouseUp", function()
        if IsShiftKeyDown and IsShiftKeyDown() then
            UI.FarmFor(lastPlan, lastCrafts)
        else
            UI.SearchShopping(lastPlan, lastCrafts)
        end
    end)
    frame:Hide()

    -- Same refresh triggers Auctionator uses for its own crafting info
    hooksecurefunc(form, "Init", UI.Refresh)
    if form.RegisterCallback and ProfessionsRecipeSchematicFormMixin and ProfessionsRecipeSchematicFormMixin.Event then
        form:RegisterCallback(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, UI.Refresh, frame)
    end
    -- Follow the "craft N" quantity box
    local box = ProfessionsFrame.CraftingPage.CreateMultipleInputBox
    if box and box.SetValue then
        pcall(hooksecurefunc, box, "SetValue", UI.Refresh)
    end
    if Auctionator and Auctionator.API and Auctionator.API.v1.RegisterForDBUpdate then
        Auctionator.API.v1.RegisterForDBUpdate(ns.CALLER, function()
            UI.Refresh()
            if ns.ProfitTab then
                ns.ProfitTab.Refresh()
            end
        end)
    end
    if ns.ProfitTab then
        ns.ProfitTab.Init()
    end
    UI.Refresh()
end
