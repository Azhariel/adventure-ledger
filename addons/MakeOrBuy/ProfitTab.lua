-- ProfitTab: a side tab on the Professions window with four views of the open profession:
--   Profit   - what's worth crafting to sell (make-or-buy cost vs. the best sale value)
--   Skill-up - the cheapest way to your next skill point (net cost after selling the result, per point)
--   Route    - the cheapest expected path from your skill to a target, recipes to learn included
--   Learn    - recipes you don't know yet and how many crafts until they pay for themselves
-- A restock bar at the bottom collects crafts you plan to make (Alt-click a row) into one shopping list.
-- The tab itself sits with the profession icons (see the "Side tab" section below).
local _, ns = ...

local ProfitTab = {}
ns.ProfitTab = ProfitTab

local ROW_HEIGHT = 22
local SLOT_WIDTHS = { 100, 110, 100, 84 } -- numeric columns, left to right
local DIFFICULTY_COLORS = { [0] = "ffff8040", [1] = "ffffff00", [2] = "ff40bf40", [3] = "ff808080" }
local DIFFICULTY_NAMES = { [0] = "Orange", [1] = "Yellow", [2] = "Green", [3] = "Grey" }
local GREEN, RED, GREY, ORANGE, WHITE = "ff40ff40", "ffff4040", "ffa0a0a0", "ffff9933", "ffffffff"
local CYAN = "ff4dd2ff"

local function color(hex, text)
    return "|c" .. hex .. text .. "|r"
end

local function Earned(copper)
    return color(GREEN, "+" .. ns.Money(-copper))
end

----------------------------------------------------------------------------------------------------
-- Columns and modes

local CELL = {}
function CELL.cost(row)
    return ns.Money(row.cost)
end
function CELL.sale(row)
    if not row.saleTotal then
        return color(GREY, "no price")
    end
    return ns.Money(row.saleTotal) .. (row.saleSource == "vendor" and color(GREY, " (v)") or "")
end
function CELL.profit(row)
    if not row.complete then
        return color(ORANGE, "missing prices")
    elseif not row.profit then
        return color(GREY, "-")
    end
    return color(row.profit > 0 and GREEN or RED, ns.Money(row.profit)) .. (row.risky and color(ORANGE, " !") or "")
end
function CELL.margin(row)
    if row.complete and row.margin then
        return string.format("%d%%", math.floor(row.margin * 100 + 0.5))
    end
    return ""
end
function CELL.net(row)
    if not row.complete then
        return color(ORANGE, "missing prices")
    elseif row.net < 0 then
        return Earned(row.net)
    end
    return ns.Money(row.net)
end
function CELL.perPoint(row)
    if not row.perPoint then
        return color(GREY, row.complete and "no skill-up" or "-")
    end
    local approx = row.estimated and "~" or ""
    if row.perPoint < 0 then
        return color(GREEN, approx .. "+" .. ns.Money(-row.perPoint))
    end
    return approx .. ns.Money(row.perPoint)
end
function CELL.learn(row)
    if not row.learn then
        return color(GREY, "?")
    end
    return row.canLearn and tostring(row.learn) or color(GREY, tostring(row.learn))
end
local SOURCE_NAMES = { t = "trainer", v = "vendor", d = "drop", q = "quest", c = "crafted" }
function CELL.learnCost(row)
    if row.learnCost then
        return ns.Money(row.learnCost)
    end
    local first = row.sources and row.sources:sub(1, 1)
    return color(GREY, SOURCE_NAMES[first] or "?")
end
function CELL.payback(row)
    if row.payback then
        return row.payback == 1 and "1 craft" or (row.payback .. " crafts")
    end
    return color(GREY, "-")
end
-- Route rows (one per segment)
function CELL.range(row)
    return row.segment.from .. " - " .. row.segment.to
end
function CELL.crafts(row)
    return "~" .. row.segment.wholeCrafts .. "x"
end
function CELL.spend(row)
    return ns.Money(row.segment.wholeCrafts * row.cost + (row.learnHere or 0))
end
function CELL.routeNet(row)
    local net = row.segment.wholeCrafts * row.net + (row.learnHere or 0)
    return net < 0 and Earned(net) or ns.Money(net)
end

local MODES = {
    profit = {
        label = "Profit",
        title = "Worth crafting",
        cols = { { "cost", "Best cost" }, { "sale", "Sale value" }, { "profit", "Profit" }, { "margin", "Margin" } },
        keep = function(row) return row.worth end,
        sort = { "profit", false },
        summary = function(counts, total)
            return counts.worth .. " of " .. total .. " recipes profitable at current prices.",
                "Sale value: AH after 5% cut, or vendor " .. color(GREY, "(v)") .. " if higher.   "
                    .. color(GREEN, "*") .. " own reagents.   " .. color(ORANGE, "!") .. " AH price unreliable."
        end,
        empty = "Nothing is profitable at current prices.\nScan the Auction House with Auctionator to refresh them, or tick \"Show all recipes\".",
    },
    skill = {
        label = "Skill-up",
        title = "Cheapest skill-ups",
        cols = { { "cost", "Best cost" }, { "sale", "Sale value" }, { "net", "Net cost" }, { "perPoint", "Per point" } },
        keep = function(row) return row.levels end,
        sort = { "perPoint", true },
        summary = function(counts, total)
            return counts.levels .. " of " .. total .. " recipes still give skill points.",
                "Net cost: best cost minus sale value.   " .. color(GREEN, "+") .. " you earn while leveling.   "
                    .. "~ estimated chance."
        end,
        empty = "No learned recipe gives skill points any more.\nVisit your trainer for new recipes, or tick \"Show all recipes\".",
    },
    route = {
        label = "Route",
        title = "Skill-up route",
        cols = { { "range", "Skill" }, { "crafts", "Crafts" }, { "spend", "Spend" }, { "routeNet", "Net cost" } },
        fixedOrder = true,
        checkbox = "Include recipes to learn",
        empty = "No known recipe gives skill points here.\nTick \"Include recipes to learn\", or scan the AH so reagents have prices.",
    },
    learn = {
        label = "Learn",
        title = "Recipes to learn",
        cols = { { "learn", "Learn at" }, { "learnCost", "Learn cost" }, { "profit", "Profit" }, { "payback", "Pays back" } },
        keep = function(row) return row.worth end,
        sort = { "profit", false },
        summary = function(counts, total)
            return counts.worth .. " of " .. total .. " recipes you don't know would be profitable.",
                "Pays back: crafts until the profit covers the learn cost.   Grey skill: not yet."
        end,
        empty = "None of the recipes you could learn is profitable at current prices.\nTick \"Show all recipes\" to see them all.",
    },
}
local MODE_ORDER = { "learn", "route", "skill", "profit" } -- laid out right to left

local tab, panel, scrollBox, slotHeaders, nameHeader, emptyText, title, summary, legend, showAll, showAllLabel,
    modeButtons, targetBox, targetLabel, shopButton, restockText, restockInfo, restockSearch, restockClear
local lastRoute

local function settings()
    local db = ns.db or {}
    db.mode = MODES[db.mode] and db.mode or "profit"
    db.sorts = db.sorts or {}
    for key, mode in pairs(MODES) do
        if mode.sort then
            db.sorts[key] = db.sorts[key] or { key = mode.sort[1], asc = mode.sort[2] }
        end
    end
    if db.routeLearn == nil then
        db.routeLearn = true
    end
    db.routeTarget = db.routeTarget or {}
    return db
end

local function CurrentMode()
    local s = settings()
    return MODES[s.mode], s.sorts[s.mode], s
end

local function ProfessionName()
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    return ok and info and info.professionName or nil
end

----------------------------------------------------------------------------------------------------
-- Rows

local function OpenRecipe(recipeID)
    ProfitTab.Deactivate()
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    local page = ProfessionsFrame.CraftingPage
    if info and page and page.SelectRecipe and pcall(page.SelectRecipe, page, info) then
        return
    end
    if C_TradeSkillUI.OpenRecipe then
        pcall(C_TradeSkillUI.OpenRecipe, recipeID)
    end
end

local function Line(left, right, dim)
    local c = dim and 0.7 or 1
    GameTooltip:AddDoubleLine(left, right, c, c, c, c, c, c)
end

-- Only recipes you know can be opened in the crafting page
local function Openable(row)
    if row.segment then
        return not row.segment.candidate.toLearn
    end
    return row.learn == nil
end

local function Crafts(row)
    return row.segment and row.segment.wholeCrafts or 1
end

local function RowTooltip(button)
    local row = button.row
    if not row then
        return
    end
    local itemID, qty = row.recipe.outputItemID, row.plan.outputQty
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine(row.recipe.name or ns.ItemName(itemID))

    local seg = row.segment
    if seg then
        Line("Skill " .. seg.from .. " to " .. seg.to, string.format("~%.1f crafts expected", seg.crafts))
        if row.learnHere then
            Line(color(ORANGE, "Learn first") .. " (skill " .. (row.learn or "?") .. ")", ns.Money(row.learnHere))
        end
        GameTooltip:AddLine(" ")
    end

    local ah, vendor = ns.AuctionPrice(itemID), ns.VendorSellPrice(itemID)
    local each = qty > 1 and (" (" .. qty .. "x)") or ""
    if ah then
        Line("AH price" .. each, ns.Money(ah * qty) .. color(GREY, "  " .. ns.Money(ah * qty * ns.Planner.AH_CUT) .. " after cut"),
            row.saleSource ~= "ah")
    end
    if vendor then
        Line("Vendor price" .. each, ns.Money(vendor * qty), row.saleSource ~= "vendor")
    end
    if row.saleTotal then
        Line("Profit (using " .. (row.saleSource == "vendor" and "vendor" or "AH") .. ")", ns.Money(row.profit))
        if row.subCrafts then
            Line("If you bought every reagent", ns.Money(math.floor(row.saleTotal - row.naiveCost)), true)
        end
        local reasons = ns.Market.Reasons(row.market, ns.Money)
        if #reasons > 0 and row.saleSource == "ah" then
            GameTooltip:AddLine((row.risky and "AH price unreliable: " or "AH price: ") .. table.concat(reasons, ", "),
                1, 0.6, 0.2, true)
        end
    else
        GameTooltip:AddLine("No AH or vendor price for the crafted item.", 1, 0.6, 0.2)
    end

    if row.learn and not seg then
        GameTooltip:AddLine(" ")
        Line("Learn at skill", tostring(row.learn))
        if row.learnCost then
            Line("Learn cost (" .. (row.learnSource == "trainer" and "trainer" or row.learnSource == "vendor" and "vendor" or "AH") .. ")",
                ns.Money(row.learnCost))
        else
            Line("Learn cost", "unknown (" .. (SOURCE_NAMES[row.sources:sub(1, 1)] or "?") .. ")")
        end
    end

    if row.difficulty ~= nil and not seg then
        GameTooltip:AddLine(" ")
        local chance = math.floor((row.chance or 0) * 100 + 0.5)
        Line(color(DIFFICULTY_COLORS[row.difficulty] or WHITE, DIFFICULTY_NAMES[row.difficulty] or "?")
            .. " recipe", "skill-up chance " .. (row.estimated and "~" or "") .. chance .. "%")
        if row.perPoint then
            Line("Net cost per skill point", row.perPoint < 0 and Earned(row.perPoint) or ns.Money(row.perPoint))
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Plan for " .. Crafts(row) .. (Crafts(row) == 1 and " craft" or " crafts"), 1, 0.82, 0)
    ns.UI.AddPlanLines(row.plan, Crafts(row))
    GameTooltip:AddLine(" ")
    if Openable(row) then
        GameTooltip:AddLine("Left-click: open recipe", 0.4, 0.8, 1)
    end
    if ns.UI.IsAuctionHouseOpen() then
        GameTooltip:AddLine("Right-click: search shopping list in Auctionator", 0.4, 0.8, 1)
    end
    if not Openable(row) and ns.UI.LearnAvailable() then
        local nearest, how, count = ns.UI.NearestLearnText(row)
        if nearest then
            Line("Learn from (" .. how .. (count > 1 and (", 1 of " .. count) or "") .. ")", nearest)
        end
        GameTooltip:AddLine("Shift-click: where to learn it, and to get its reagents", 0.4, 0.8, 1)
    elseif ns.UI.FarmAvailable() then
        GameTooltip:AddLine("Shift-click: where to get its reagents", 0.4, 0.8, 1)
    end
    if row.recipe.outputItemID then
        GameTooltip:AddLine("Ctrl-click: show the crafted item (stats, bag slots)", 0.4, 0.8, 1)
    end
    if ns.db.recipes[row.recipe.recipeID] then
        local n = ns.db.restock[row.recipe.recipeID]
        GameTooltip:AddLine("Alt-click: add " .. Crafts(row) .. " to the restock list"
            .. (n and (" (" .. n .. " listed; Alt-right-click removes)") or ""), 0.4, 0.8, 1)
    end
    GameTooltip:Show()
end

local function CreateCells(button)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)

    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetSize(18, 18)
    button.Icon:SetPoint("LEFT", 4, 0)

    button.cells = {}
    local right = -4
    for i = #SLOT_WIDTHS, 1, -1 do
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("RIGHT", right, 0)
        fs:SetWidth(SLOT_WIDTHS[i])
        fs:SetJustifyH("RIGHT")
        button.cells[i] = fs
        right = right - SLOT_WIDTHS[i]
    end
    button.Name = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
    button.Name:SetPoint("RIGHT", right - 8, 0)
    button.Name:SetJustifyH("LEFT")
    button.Name:SetWordWrap(false)

    button:SetScript("OnEnter", RowTooltip)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button:SetScript("OnClick", function(self, mouse)
        local row = self.row
        if not row then
            return
        end
        if IsControlKeyDown and IsControlKeyDown() then
            ns.UI.InspectItem(row.recipe.outputItemID)
        elseif IsAltKeyDown and IsAltKeyDown() then
            -- Restock list: left adds, right removes (a route segment counts its whole crafts)
            ns.RestockAdd(row.recipe.recipeID, (mouse == "RightButton" and -1 or 1) * Crafts(row))
        elseif IsShiftKeyDown and IsShiftKeyDown() then
            if Openable(row) or not ns.UI.LearnFor(row, Crafts(row)) then
                ns.UI.FarmFor(row.plan, Crafts(row))
            end
        elseif mouse == "RightButton" then
            ns.UI.SearchShopping(row.plan, Crafts(row))
        elseif Openable(row) then
            OpenRecipe(row.recipe.recipeID)
        end
    end)
end

local function InitRow(button, row)
    if not button.cells then
        CreateCells(button)
    end
    button:SetHeight(ROW_HEIGHT)
    button.row = row
    local recipe = row.recipe
    local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(recipe.outputItemID)
    button.Icon:SetTexture(icon or 134400) -- question mark
    local name = recipe.name or ns.ItemName(recipe.outputItemID)
    if row.plan.outputQty > 1 then
        name = name .. " x" .. row.plan.outputQty
    end
    if row.subCrafts then
        name = name .. color(GREEN, " *")
    end
    local text = color(DIFFICULTY_COLORS[row.difficulty] or WHITE, name)
    if row.learnHere then
        text = text .. color(ORANGE, " (learn)")
    end
    local listed = ns.db.restock[recipe.recipeID]
    if listed then
        text = text .. color(CYAN, " [" .. listed .. "]")
    end
    button.Name:SetText(text)

    local mode = CurrentMode()
    for i, col in ipairs(mode.cols) do
        button.cells[i]:SetText(CELL[col[1]](row))
    end
end

----------------------------------------------------------------------------------------------------
-- Panel

local function UpdateHeaders()
    local mode, sort = CurrentMode()
    local function label(key, text)
        if sort and sort.key == key and not mode.fixedOrder then
            return color(WHITE, text .. (sort.asc and " ^" or " v"))
        end
        return text
    end
    for i, col in ipairs(mode.cols) do
        slotHeaders[i].key = col[1]
        slotHeaders[i].Text:SetText(label(col[1], col[2]))
    end
    nameHeader.Text:SetText(label("name", "Recipe"))
end

-- Default direction when picking a new column: names A-Z, costs cheapest first, gains highest first
local ASCENDING_FIRST = { name = true, cost = true, net = true, perPoint = true, learn = true, learnCost = true, payback = true }

local function SortBy(key)
    local mode, sort = CurrentMode()
    if mode.fixedOrder or not sort then
        return
    end
    if sort.key == key then
        sort.asc = not sort.asc
    else
        sort.key, sort.asc = key, ASCENDING_FIRST[key] or false
    end
    ProfitTab.Refresh()
end

local function CreateHeader(width, justify)
    local button = CreateFrame("Button", nil, panel)
    button:SetHeight(18)
    if width then
        button:SetWidth(width)
    end
    button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.Text:SetAllPoints()
    button.Text:SetJustifyH(justify)
    button:SetScript("OnClick", function(self)
        SortBy(self.key)
    end)
    return button
end

function ProfitTab.SetMode(key)
    if MODES[key] then
        settings().mode = key
        ProfitTab.Refresh()
    end
end

-- Route target for a profession: saved value, else the current cap
local function RouteTarget(s, profession, level, maxLevel)
    local target = s.routeTarget[profession or "?"] or maxLevel or ((level or 0) + 25)
    if maxLevel and target > maxLevel then
        target = maxLevel
    end
    return target
end

function ProfitTab.SetTarget(value)
    local n = tonumber(value)
    local s = settings()
    local profession = ns.Scanner.ProfessionKey()
    if n then
        s.routeTarget[profession or "?"] = math.floor(n)
    end
    ProfitTab.Refresh()
end

----------------------------------------------------------------------------------------------------
-- Restock bar

local function RecipeName(recipe)
    return recipe.name or ns.ItemName(recipe.outputItemID)
end

function ProfitTab.RestockText(r)
    if #r.entries == 0 then
        return color(GREY, "Restock list: Alt-click a recipe to add a craft, Alt-right-click to remove one.")
    end
    return color(CYAN, "Restock: ") .. ns.Restock.Summary(r.entries, RecipeName, 2) .. "  "
        .. color(GREY, "spend ") .. ns.Money(r.cash)
        .. (r.ownedUsed > 0 and color(GREY, " (using " .. r.ownedUsed .. " you own)") or "")
end

function ProfitTab.UpdateRestock()
    if not restockText then
        return
    end
    local r = ns.RestockBuild()
    ProfitTab.lastRestock = r
    restockText:SetText(ProfitTab.RestockText(r))
    if #r.shopping > 0 then restockSearch:Enable() else restockSearch:Disable() end
    if #r.entries > 0 or #r.unknown > 0 then restockClear:Enable() else restockClear:Disable() end
end

function ProfitTab.SearchRestock()
    local r = ns.RestockBuild()
    if not ns.UI.IsAuctionHouseOpen() then
        ns.Print("Open the Auction House first, then press Search AH again.")
        return false
    end
    if not ns.UI.SearchList(r.shopping) then
        ns.Print("Nothing on the restock list needs buying on the AH" .. (#r.shopping > 0 and " (vendor items only)." or "."))
        return false
    end
    return true
end

function ProfitTab.RestockTooltip(owner)
    local r = ProfitTab.lastRestock or ns.RestockBuild()
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Restock list")
    if #r.entries == 0 then
        GameTooltip:AddLine("Alt-click recipes in any view to plan crafts across your professions.", 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    for _, e in ipairs(r.entries) do
        Line(e.crafts .. "x " .. RecipeName(e.recipe), e.profit and (e.profit >= 0 and ns.Money(e.profit) or color(RED, "-" .. ns.Money(-e.profit))) or "?")
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("To buy", 1, 0.82, 0)
    for _, e in ipairs(r.shopping) do
        local each = e.qty > 1 and e.unitPrice and ("  @" .. ns.Money(e.unitPrice)) or ""
        Line(e.qty .. "x " .. ns.ItemName(e.itemID) .. color(GREY, (e.source == "vendor" and "  vendor" or "  AH") .. each),
            ns.Money(e.qty * e.unitPrice), true)
    end
    if #r.shopping == 0 then
        GameTooltip:AddLine("Nothing: you own everything.", 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    Line("Cash to spend" .. (r.ownedUsed > 0 and (" (using " .. r.ownedUsed .. " you own)") or ""), ns.Money(r.cash))
    Line("Expected profit when sold", ns.Money(r.profit))
    if #r.missing > 0 then
        GameTooltip:AddLine(#r.missing .. " reagent(s) have no price yet.", 1, 0.6, 0.2)
    end
    if #r.unknown > 0 then
        GameTooltip:AddLine(#r.unknown .. " listed recipe(s) aren't learned on this character.", 1, 0.6, 0.2)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Search AH: buys only what you don't own; vendor items are left out.", 0.4, 0.8, 1, true)
    GameTooltip:Show()
end

local function CreatePanel()
    panel = CreateFrame("Frame", "MakeOrBuyProfitPanel", ProfessionsFrame)
    panel:EnableMouse(true) -- block clicks to the recipe list underneath
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function() end)
    panel:Hide()

    -- Opaque backing with the same art WhatsTraining's page uses on this client
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.05, 0.04, 1)
    local art = panel:CreateTexture(nil, "BORDER")
    art:SetAllPoints()
    if not (art.SetAtlas and pcall(art.SetAtlas, art, "Profession-Background-Overview")) then
        art:Hide()
    end

    title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)

    summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    summary:SetPoint("RIGHT", panel, "RIGHT", -230, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    legend = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -3)
    legend:SetPoint("RIGHT", panel, "RIGHT", -230, 0)
    legend:SetJustifyH("LEFT")
    legend:SetWordWrap(false)

    -- Mode switch (top right): the active mode's button is disabled, which reads as "selected"
    modeButtons = {}
    local previous
    for _, key in ipairs(MODE_ORDER) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(72, 22)
        b:SetText(MODES[key].label)
        if previous then
            b:SetPoint("RIGHT", previous, "LEFT", -2, 0)
        else
            b:SetPoint("TOPRIGHT", -12, -8)
        end
        b:SetScript("OnClick", function()
            ProfitTab.SetMode(key)
        end)
        b.mode = key
        modeButtons[key] = b
        previous = b
    end

    showAll = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    showAll:SetSize(24, 24)
    -- Same row as the mode buttons, label between the box and the buttons
    showAll:SetPoint("RIGHT", modeButtons.profit, "LEFT", -150, 0)
    -- The title stops before the checkbox; its width is set in FitTitle
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    showAllLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showAllLabel:SetPoint("LEFT", showAll, "RIGHT", 2, 0)
    showAll:SetScript("OnClick", function(self)
        local s = settings()
        if s.mode == "route" then
            s.routeLearn = self:GetChecked() and true or false
        else
            s.showAll = self:GetChecked() and true or false
        end
        ProfitTab.Refresh()
    end)

    -- Route controls, under the mode buttons: target skill and "search the whole route"
    targetBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    targetBox:SetSize(36, 20)
    targetBox:SetPoint("TOPRIGHT", -14, -36)
    targetBox:SetAutoFocus(false)
    targetBox:SetNumeric(true)
    targetBox:SetMaxLetters(3)
    targetBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    targetBox:SetScript("OnEditFocusLost", function(self)
        ProfitTab.SetTarget(self:GetText())
    end)
    targetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetLabel:SetPoint("RIGHT", targetBox, "LEFT", -8, 0)
    targetLabel:SetText("Target skill")
    shopButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    shopButton:SetSize(96, 20)
    shopButton:SetPoint("RIGHT", targetLabel, "LEFT", -8, 0)
    shopButton:SetText("Search AH")
    shopButton:SetScript("OnClick", function()
        if lastRoute then
            ns.UI.SearchList(lastRoute.shopping)
        end
    end)

    -- Column headers (aligned with the row cells; 20px reserved for the scroll bar)
    slotHeaders = {}
    local headerTop = -66
    local right = -24
    for i = #SLOT_WIDTHS, 1, -1 do
        local h = CreateHeader(SLOT_WIDTHS[i], "RIGHT")
        h:SetPoint("TOPRIGHT", right, headerTop)
        slotHeaders[i] = h
        right = right - SLOT_WIDTHS[i]
    end
    nameHeader = CreateHeader(nil, "LEFT")
    nameHeader.key = "name"
    nameHeader:SetPoint("TOPLEFT", 32, headerTop)
    nameHeader:SetPoint("TOPRIGHT", right - 8, headerTop)

    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 0, headerTop - 20)
    scrollBox:SetPoint("BOTTOMRIGHT", -20, 34)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    -- Restock bar (bottom): the list, what it costs, Search AH and Clear
    restockClear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    restockClear:SetSize(60, 22)
    restockClear:SetPoint("BOTTOMRIGHT", -12, 6)
    restockClear:SetText("Clear")
    restockClear:SetScript("OnClick", function()
        ns.db.restock = {}
        ProfitTab.Refresh()
    end)
    restockSearch = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    restockSearch:SetSize(90, 22)
    restockSearch:SetPoint("RIGHT", restockClear, "LEFT", -4, 0)
    restockSearch:SetText("Search AH")
    restockSearch:SetScript("OnClick", ProfitTab.SearchRestock)
    restockText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    restockText:SetPoint("LEFT", panel, "BOTTOMLEFT", 12, 17)
    restockText:SetPoint("RIGHT", restockSearch, "LEFT", -8, 0)
    restockText:SetJustifyH("LEFT")
    restockText:SetWordWrap(false)
    -- Hover area over the text for the full list
    restockInfo = CreateFrame("Frame", nil, panel)
    restockInfo:SetPoint("TOPLEFT", restockText, "TOPLEFT", 0, 4)
    restockInfo:SetPoint("BOTTOMRIGHT", restockText, "BOTTOMRIGHT", 0, -4)
    restockInfo:EnableMouse(true)
    restockInfo:SetScript("OnEnter", ProfitTab.RestockTooltip)
    restockInfo:SetScript("OnLeave", function() GameTooltip:Hide() end)

    emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER", scrollBox, "CENTER", 0, 20)
    emptyText:SetWidth(420)

    panel:SetScript("OnShow", ProfitTab.Refresh)
end

local function RecipeInfo(recipeID)
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    return ok and info or nil
end

-- Builds the rows for the current mode. Returns all, rows (filtered/sorted), line1, line2, emptyText
local function BuildMode(mode, sort, s)
    local profession = ns.Scanner.ProfessionKey()
    local level, maxLevel = ns.CurrentSkill(profession)
    local opts = {
        profession = profession,
        recipeInfo = RecipeInfo,
        market = ns.MarketCheck,
        skill = level,
        skillChance = function(id, d) return ns.SkillChance(id, d, profession) end,
        learnInfo = function(id) return ns.LearnInfo(id, profession) end,
    }

    if s.mode == "learn" then
        local all, counts = ns.Ranking.BuildLearn(ns.db.unlearned, ns.recipesByOutput, ns.Price, ns.SaleValue, opts)
        local rows = s.showAll and all or ns.Ranking.Filter(all, mode.keep)
        ns.Ranking.Sort(rows, sort.key, sort.asc)
        local l1, l2 = mode.summary(counts, #all)
        local empty = #all == 0 and "No unlearned recipes found for this profession." or mode.empty
        return all, rows, l1, l2, empty
    end

    local all, counts = ns.Ranking.Build(ns.db.recipes, ns.recipesByOutput, ns.Price, ns.SaleValue, opts)
    if s.mode ~= "route" then
        local rows = s.showAll and all or ns.Ranking.Filter(all, mode.keep)
        ns.Ranking.Sort(rows, sort.key, sort.asc)
        local l1, l2 = mode.summary(counts, #all)
        if s.mode == "skill" and level then
            l1 = l1 .. "   Skill " .. level .. (maxLevel and ("/" .. maxLevel) or "") .. "."
        end
        return all, rows, l1, l2, mode.empty
    end

    -- Route
    lastRoute = nil
    if not level then
        return all, {}, "Skill level unknown.", "", "Open the profession window again so I can read your skill."
    end
    local target = RouteTarget(s, profession, level, maxLevel)
    if not (targetBox.HasFocus and targetBox:HasFocus()) then
        targetBox:SetText(tostring(target))
    end
    local learnRows = s.routeLearn and ns.Ranking.BuildLearn(ns.db.unlearned, ns.recipesByOutput, ns.Price, ns.SaleValue, opts) or nil
    local candidates = ns.Ranking.RouteCandidates(all, learnRows,
        function(id) return ns.Thresholds(id, profession) end,
        function(id) local li = ns.LearnInfo(id, profession) return li and li.learn end)
    local route = ns.Skill.Route(candidates, level, target)

    -- One row per segment, plus the combined shopping list (minus what you own)
    local rows, shopping, index, have = {}, {}, {}, ns.Owned()
    local cash = 0
    local learnedSeen = {}
    for _, seg in ipairs(route.segments) do
        local base = seg.candidate.row
        local row = setmetatable({ segment = seg }, { __index = base })
        row.difficulty = ns.Skill.DifficultyAt(seg.candidate.thresholds, seg.from)
        if seg.candidate.toLearn and not learnedSeen[seg.candidate] then
            learnedSeen[seg.candidate] = true
            row.learnHere = seg.candidate.learnCost
        end
        rows[#rows + 1] = row
        local _, list, _, segCash = ns.Planner.Expand(base.plan, seg.wholeCrafts, have)
        for _, entry in ipairs(list) do
            ns.Planner.AddToShopping(shopping, index, entry)
        end
        cash = cash + segCash
    end
    route.shopping, route.cash = shopping, cash + route.learnCost
    lastRoute = route

    local reached = route.stuckAt or target
    local l1
    if level >= target then
        l1 = "Already at skill " .. level .. ". Raise the target skill."
    else
        l1 = level .. " to " .. reached .. ": ~" .. route.crafts .. " crafts, spend " .. ns.Money(route.cash)
            .. ", net " .. (route.net < 0 and ("+" .. ns.Money(-route.net)) or ns.Money(route.net)) .. " after selling."
    end
    local l2 = "Estimated skill-up chances (they get sharper as you level)."
    if route.stuckAt then
        l2 = color(ORANGE, "Stuck at " .. route.stuckAt .. ": no recipe with prices gives points there.") .. " " .. l2
    elseif #route.learned > 0 then
        l2 = color(ORANGE, "Learn " .. #route.learned .. " recipe" .. (#route.learned == 1 and "" or "s") .. " on the way.") .. "  " .. l2
    end
    return all, rows, l1, l2, (level >= target) and "" or mode.empty
end

-- Long titles ("Recipes to learn - Leatherworking") are cut short before the "Show all" checkbox
local function FitTitle()
    local left, boxLeft = panel:GetLeft(), showAll:GetLeft()
    if type(left) == "number" and type(boxLeft) == "number" then
        title:SetWidth(math.max(60, boxLeft - left - 12 - 6)) -- 12 = the title's left offset
    end
end
ProfitTab.FitTitle = FitTitle

function ProfitTab.Refresh()
    if not panel or not panel:IsShown() or not ns.db then
        return
    end
    local mode, sort, s = CurrentMode()
    for key, b in pairs(modeButtons) do
        if key == s.mode then b:Disable() else b:Enable() end
    end
    local isRoute = s.mode == "route"
    showAll:SetChecked((isRoute and s.routeLearn or (not isRoute and s.showAll)) and true or false)
    showAllLabel:SetText(mode.checkbox or "Show all recipes")
    targetBox:SetShown(isRoute)
    targetLabel:SetShown(isRoute)
    shopButton:SetShown(isRoute)
    if isRoute then
        if ns.UI.IsAuctionHouseOpen() then shopButton:Enable() else shopButton:Disable() end
    end

    title:SetText(mode.title .. (ProfessionName() and (" - " .. ProfessionName()) or ""))
    FitTitle()

    -- A Lua error here would leave the title, buttons and list out of step: show it instead and report it
    pcall(ProfitTab.UpdateRestock)
    local ok, all, rows, line1, line2, empty = pcall(BuildMode, mode, sort, s)
    if not ok then
        if geterrorhandler then
            geterrorhandler()(all)
        end
        summary:SetText("")
        legend:SetText("")
        emptyText:SetText("Make or Buy hit an error building this view (see BugGrabber). Other views may still work.")
        scrollBox:SetDataProvider(CreateDataProvider({}))
        return
    end
    summary:SetText(line1)
    legend:SetText(line2)

    if #all == 0 and s.mode ~= "learn" then
        emptyText:SetText("No recipes learned yet for this profession. They are saved the first time the window opens; try reopening it.")
    elseif #rows == 0 then
        emptyText:SetText(empty or mode.empty)
    else
        emptyText:SetText("")
    end

    scrollBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    UpdateHeaders()
end

----------------------------------------------------------------------------------------------------
-- Side tab. WoW Forever's Professions window has a column of LargeSideTabButtonTemplate tabs on its right
-- edge (ProfessionsOverviewTab + rightProfessionTabs). We add one more below them and mimic a real tab:
--   * our panel covers the content area below the rank bar, above everything native (and WhatsTraining)
--   * a "return tab" is drawn over the selected native tab so it looks unselected; clicking it, any native
--     tab, WhatsTraining's tab, switching profession or closing the window goes back to the native page
-- The pattern follows WhatsTraining/Crafting/Crafting.lua, which does the same on this client.

local book, returnTab
local active = false
local queued = false

local function NativeTabs()
    local tabs = {}
    if book.ProfessionsOverviewTab then
        tabs[#tabs + 1] = book.ProfessionsOverviewTab
    end
    for _, t in ipairs(book.rightProfessionTabs or {}) do
        tabs[#tabs + 1] = t
    end
    return tabs
end

local function SelectedNativeTab()
    for _, t in ipairs(NativeTabs()) do
        if t:IsShown() and t.SelectedTexture and t.SelectedTexture:IsShown() then
            return t
        end
    end
end

-- Lowest visible profession tab, and the gap between consecutive tabs so ours is spaced the same
local function LastSideTab()
    local shown = {}
    for _, t in ipairs(book.rightProfessionTabs or {}) do
        if t:IsShown() then
            shown[#shown + 1] = t
        end
    end
    local last, gap = shown[#shown], 4
    for i = 1, #shown - 1 do
        local b, t = shown[i]:GetBottom(), shown[i + 1]:GetTop()
        if b and t and b - t >= 0 and b - t < 30 then
            gap = b - t
            break
        end
    end
    if last and last.GetBottom and last:GetBottom() then
        for _, t in ipairs(shown) do
            if t:GetBottom() and t:GetBottom() < last:GetBottom() then
                last = t
            end
        end
    end
    return last, gap
end

local function PlaceTab()
    tab:ClearAllPoints()
    local last, gap = LastSideTab()
    if last then
        tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -gap)
    else
        tab:SetPoint("TOPLEFT", book, "TOPRIGHT", 0, -80)
    end
end

-- Covers from the top of the recipe list (just under the rank bar) to the bottom of the window
local function PlacePanel()
    local list = book.CraftingPage and book.CraftingPage.RecipeList
    local top = -80
    if list and list.GetTop and list:GetTop() and book:GetTop() then
        top = list:GetTop() - book:GetTop()
    end
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", book, "TOPLEFT", 3, top)
    panel:SetPoint("BOTTOMRIGHT", book, "BOTTOMRIGHT", -3, 3)
end

local function Sync()
    queued = false
    if not book:IsVisible() then
        active = false
        panel:Hide()
        returnTab:Hide()
        return
    end
    -- Native content and WhatsTraining's list sit up to ~1000 levels above the portrait; go above them
    local base = book.PortraitContainer and book.PortraitContainer:GetFrameLevel() or book:GetFrameLevel() + 500
    panel:SetFrameLevel(math.min(base + 1200, 9000))
    tab:SetFrameLevel(base)
    returnTab:SetFrameLevel(base)
    PlaceTab()
    PlacePanel()
    if tab.SetChecked then
        tab:SetChecked(active)
    end
    tab:Show()
    panel:SetShown(active)

    local selected = active and SelectedNativeTab() or nil
    returnTab:SetShown(selected ~= nil)
    if selected then
        returnTab:ClearAllPoints()
        returnTab:SetPoint("CENTER", selected)
        if selected.Icon and returnTab.Icon then
            returnTab.Icon:SetTexture(selected.Icon:GetTexture())
        end
        returnTab.tooltipText = selected.tooltipText
    end
end

local function Request()
    if queued then
        return
    end
    queued = true
    if RunNextFrame then
        RunNextFrame(Sync)
    else
        C_Timer.After(0, Sync)
    end
end

function ProfitTab.Deactivate()
    if active then
        active = false
        Sync()
    end
end

function ProfitTab.Toggle()
    active = not active
    Sync()
end

local function MakeSideTab(name)
    local ok, t = pcall(CreateFrame, "Frame", name, book, "LargeSideTabButtonTemplate")
    if not ok or not t.SetCustomOnMouseUpHandler then
        return nil
    end
    t:Hide()
    t:EnableMouse(true)
    if t.SetFillToInterior then
        t:SetFillToInterior(true)
    end
    t:SetChecked(false)
    return t
end

local function OnLeftUp(fn)
    return function(_, button, upInside)
        if button == "LeftButton" and upInside ~= false then
            fn()
        end
    end
end

function ProfitTab.Init()
    if tab or not ProfessionsFrame then
        return
    end
    book = ProfessionsFrame

    tab = MakeSideTab("MakeOrBuyTab")
    if tab then
        tab.Icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
        tab.tooltipText = "Worth crafting"
        tab:SetCustomOnMouseUpHandler(OnLeftUp(ProfitTab.Toggle))
        returnTab = MakeSideTab("MakeOrBuyReturnTab")
        returnTab:SetCustomOnMouseUpHandler(OnLeftUp(ProfitTab.Deactivate))
    else
        -- Client without side tabs: plain button on the window's right edge
        tab = CreateFrame("Button", "MakeOrBuyTab", book, "UIPanelButtonTemplate")
        tab:SetSize(120, 24)
        tab:SetText("Worth crafting")
        tab:SetScript("OnClick", ProfitTab.Toggle)
        returnTab = CreateFrame("Frame", nil, book)
        returnTab:Hide()
    end

    CreatePanel()

    for _, t in ipairs(NativeTabs()) do
        t:HookScript("OnMouseUp", ProfitTab.Deactivate)
    end
    local wtTab = _G.WhatsTrainingCraftingTab
    if wtTab then
        wtTab:HookScript("OnMouseUp", ProfitTab.Deactivate)
    end
    book:HookScript("OnHide", function()
        active = false
        Sync()
    end)
    book:HookScript("OnShow", Request)
    book:HookScript("OnSizeChanged", Request)
    if EventRegistry then
        EventRegistry:RegisterCallback("Professions.ProfessionSelected", ProfitTab.Deactivate, tab)
        EventRegistry:RegisterCallback("Professions.ShowSelectedCraftingPage", ProfitTab.Deactivate, tab)
    end
    if book.SetTab then
        hooksecurefunc(book, "SetTab", ProfitTab.Deactivate)
    end
    Request()
end
