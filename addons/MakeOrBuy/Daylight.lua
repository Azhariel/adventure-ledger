-- Daylight: Make or Buy inside Daylight UI's profession window, through its plugin API (DaylightUI.API 1.2+,
-- API.md "The profession window"). Daylight UI parks the game's Professions window off screen and shows its
-- own, so the lines and side tab UI.lua and ProfitTab.lua put on the game's window can't be seen. With
-- Daylight UI's window in use (its CraftShown event fires only then):
--   * a slim pane docked to the window's right edge shows the selected recipe's cost, profit and cash
--     (UI.BlockEntries), its reagents (click one: where to get it), Where to get / Search AH / restock
--     buttons, the restock list, and a Views button that opens the Profit/Learn/Route views as a window
--   * each recipe line's profit, in the spot Daylight UI keeps for its own (its Profit.Of, wrapped)
--   * a recipe on the restock list gets its count in the corner of its icon
-- Without Daylight UI, or with its profession window off, nothing here runs and UI.lua works as before.
local _, ns = ...

local D = {}
ns.Daylight = D

D.PANE_W = 240
D.MAX_REAGENTS = 8 -- the window can be as short as 420px; the restock list sits at the bottom
local PAD = 14

local API, me, pane
local open = false -- Daylight UI's profession window is on screen
local picked -- its selected recipe id
local profits = {} -- recipeID -> profit (copper) | false (unpriced), until prices or what you own change

-- DaylightUI.API, when it is new enough for the profession window (1.2) and the rich tooltips (1.12, used by
-- DropLab: checked there)
function D.API()
    local dui = _G.DaylightUI
    local api = type(dui) == "table" and dui.API
    if type(api) == "table" and api.major == 1 and (api.minor or 0) >= 2 then
        return api
    end
    return nil
end

-- True while Daylight UI's profession window is open (and so the game's is parked out of sight)
function D.InUse()
    return open
end

----------------------------------------------------------------------------------------------------
-- Colors: Daylight UI's text colors (API.Colors) as |c codes, read each time (the player can change them)

local function ink(key)
    local c = API and API.Colors()[key]
    if not c then
        return "ffffffff"
    end
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return string.format("ff%02x%02x%02x", byte(c[1]), byte(c[2]), byte(c[3]))
end

local function paint(text, key)
    return "|c" .. ink(key) .. text .. "|r"
end

local NOTE_INK = { good = "GOOD", off = "OFF", warn = "WARN" }

local function setColor(fs, key)
    local c = API.Colors()[key]
    if c then
        fs:SetTextColor(c[1], c[2], c[3])
    end
end

----------------------------------------------------------------------------------------------------
-- Profit per recipe line

-- Our profit for one learned recipe at the current prices (a craft's worth, after the AH cut), or nil when
-- a price is missing
function D.ProfitOf(recipeID)
    local hit = profits[recipeID]
    if hit ~= nil then
        return hit or nil
    end
    local recipe = ns.db and ns.db.recipes and ns.db.recipes[recipeID]
    local value = false
    if recipe and recipe.outputItemID then
        local plan = ns.Planner.PlanRecipe(recipe, ns.recipesByOutput, ns.Price)
        local sale = ns.SaleValue(recipe.outputItemID)
        if sale and plan.complete then
            value = ns.Planner.ProfitFromValue(sale, plan.outputQty, plan.total)
        end
    end
    profits[recipeID] = value
    return value or nil
end

-- Daylight UI draws a line's profit from Profit.Of(recipe). Ours goes there instead, so the line keeps its
-- own layout. Only { profit } is handed back: Daylight UI's recipe page shows its Profit section only for a
-- full answer (`known`), so its own cost and sale rows stay off and our pane has them.
local function WrapProfit()
    local dui = _G.DaylightUI
    local mod = dui and dui.GetModule and dui:GetModule("Professions")
    local Profit = mod and mod.ns and mod.ns.Profit
    if type(Profit) ~= "table" or type(Profit.Of) ~= "function" or not me.Wrap then
        return false
    end
    me.Wrap(Profit, "Of", function(original, r, ...)
        local id = type(r) == "table" and r.id
        local p = id and D.ProfitOf(id)
        if p then
            return { profit = p }
        end
        return original(r, ...)
    end)
    return true
end

----------------------------------------------------------------------------------------------------
-- Recipe lines: the restock count on the icon

local function RestockBadge(row, parts, info)
    local holder = API.Attach(row)
    if not holder then
        return
    end
    if not holder.mobRestock then
        holder.mobRestock = API.Text(holder, "tiny", "RIGHT")
    end
    local badge = holder.mobRestock
    local id = info and info.recipeID
    local n = id and ns.db and ns.db.restock and ns.db.restock[id]
    badge:ClearAllPoints()
    if parts and parts.icon then
        badge:SetPoint("BOTTOMRIGHT", parts.icon, "BOTTOMRIGHT", 1, -1)
    else
        badge:SetPoint("LEFT", holder, "LEFT", 2, 0)
    end
    badge:SetText(n and tostring(n) or "")
    local r, g, b = API.Accent()
    badge:SetTextColor(r, g, b)
    badge:SetShown(n ~= nil)
end

----------------------------------------------------------------------------------------------------
-- The pane

local P = {} -- the pane's pieces
local current = { recipe = nil, plan = nil }

local function Recipe(id)
    if not id then
        return nil
    end
    -- Read live, so a recipe works before its profession was scanned (as UI.lua does)
    return ns.Scanner.ReadRecipe(id) or (ns.db and ns.db.recipes and ns.db.recipes[id])
end

-- A pool of rows: label left, value right, an optional note line under them
local function EntryRow(i)
    P.entries = P.entries or {}
    local row = P.entries[i]
    if row then
        return row
    end
    row = {}
    row.label = API.Text(pane, "small", "LEFT")
    row.value = API.Text(pane, "body", "RIGHT")
    row.note = API.Text(pane, "tiny", "LEFT")
    row.note:SetWidth(D.PANE_W - 2 * PAD)
    P.entries[i] = row
    return row
end

-- A pool of clickable reagent lines
local function ReagentRow(i)
    P.reagents = P.reagents or {}
    local row = P.reagents[i]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, pane)
    row:SetHeight(16)
    row.left = API.Text(row, "small", "LEFT")
    row.left:SetPoint("LEFT", 0, 0)
    row.right = API.Text(row, "small", "RIGHT")
    row.right:SetPoint("RIGHT", 0, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetWordWrap(false)
    row:SetScript("OnEnter", function(self)
        if not self.itemID then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(self.itemID)
        end
        if ns.UI.FarmAvailable() then
            GameTooltip:AddLine("Click: where to get it", 0.4, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if self.itemID and ns.UI.FarmAvailable() then
            local choices = ns.UI.ReagentChoices(current.plan, 1)
            pcall(_G.WhereToFarm.API.Open, self.itemID, { choices = choices })
        end
    end)
    P.reagents[i] = row
    return row
end

local function Button(text, width, onClick)
    local b = API.Button(pane, text, 22)
    b:SetSize(width, 22)
    b:SetScript("OnClick", onClick)
    return b
end

local function SetEnabled(b, on)
    if on then b:Enable() else b:Disable() end
end

-- Short source words for a reagent line ("AH", "craft 2x", "have 3", "no price")
local function SourceWord(line)
    if line.owned and line.owned >= line.qty then
        return paint("have", "GOOD")
    end
    local word
    if line.method == "craft" then
        word = paint("craft " .. line.crafts .. "x", "GOOD")
    elseif line.method == "buy" then
        word = line.buySource == "vendor" and "vendor" or "AH"
    else
        word = paint("no price", "WARN")
    end
    if line.owned and line.owned > 0 then
        word = paint("have " .. line.owned .. ", ", "GOOD") .. word
    end
    return word
end

local function Layout()
    local y = -PAD
    P.title:ClearAllPoints()
    P.title:SetPoint("TOPLEFT", PAD, y)
    y = y - 24

    local recipe, plan = current.recipe, current.plan
    P.empty:SetShown(recipe == nil)
    local entries = recipe and ns.UI.BlockEntries(recipe, plan, 1) or {}
    for i = 1, math.max(#entries, P.entries and #P.entries or 0) do
        local row, e = EntryRow(i), entries[i]
        local shown = e ~= nil
        row.label:SetShown(shown)
        row.value:SetShown(shown)
        row.note:SetShown(shown and #e.notes > 0)
        if shown then
            row.label:ClearAllPoints()
            row.label:SetPoint("TOPLEFT", PAD, y)
            row.label:SetText(e.short)
            setColor(row.label, "LABEL")
            row.value:ClearAllPoints()
            row.value:SetPoint("TOPRIGHT", -PAD, y)
            row.value:SetText(e.value)
            setColor(row.value, e.bad and "BAD" or "VALUE")
            y = y - 17
            if #e.notes > 0 then
                local parts = {}
                for k, n in ipairs(e.notes) do
                    parts[k] = paint(n.text, NOTE_INK[n.kind] or "OFF")
                end
                row.note:ClearAllPoints()
                row.note:SetPoint("TOPLEFT", PAD, y)
                row.note:SetText(table.concat(parts, paint("  ·  ", "OFF")))
                y = y - 14
            end
            y = y - 4
        end
    end

    -- Reagents of the cheapest plan, as a craft of one needs them
    local lines = plan and ns.Planner.Expand(plan, 1, ns.Owned()) or {}
    P.reagentHead:SetShown(#lines > 0)
    if #lines > 0 then
        y = y - 6
        P.reagentHead:ClearAllPoints()
        P.reagentHead:SetPoint("TOPLEFT", PAD, y)
        y = y - 18
    end
    local shownCount = math.min(#lines, D.MAX_REAGENTS)
    for i = 1, math.max(shownCount, P.reagents and #P.reagents or 0) do
        local row = ReagentRow(i)
        local line = i <= shownCount and lines[i] or nil
        row:SetShown(line ~= nil)
        if line then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", PAD + 10 * line.depth, y)
            row:SetPoint("TOPRIGHT", -PAD, y)
            row.itemID = line.itemID
            row.left:SetText(line.qty .. "x " .. ns.ItemName(line.itemID))
            setColor(row.left, "TEXT")
            row.right:SetText(SourceWord(line))
            setColor(row.right, "LABEL")
            y = y - 16
        end
    end
    P.more:SetShown(#lines > shownCount)
    if #lines > shownCount then
        P.more:ClearAllPoints()
        P.more:SetPoint("TOPLEFT", PAD, y)
        P.more:SetText("+" .. (#lines - shownCount) .. " more")
        y = y - 14
    end

    -- Buttons for this recipe
    y = y - 10
    P.where:ClearAllPoints()
    P.where:SetPoint("TOPLEFT", PAD, y)
    P.search:ClearAllPoints()
    P.search:SetPoint("TOPRIGHT", -PAD, y)
    SetEnabled(P.where, plan ~= nil and ns.UI.FarmAvailable())
    SetEnabled(P.search, plan ~= nil and ns.UI.IsAuctionHouseOpen())
    y = y - 26
    local listed = recipe and ns.db and ns.db.restock[recipe.recipeID]
    P.add:ClearAllPoints()
    P.add:SetPoint("TOPLEFT", PAD, y)
    P.add:SetText(listed and ("Restock: " .. listed .. " (+1)") or "Add to restock")
    SetEnabled(P.add, recipe ~= nil and ns.db and ns.db.recipes[recipe.recipeID] ~= nil)
end

local function LayoutRestock()
    local r = ns.RestockBuild()
    P.lastRestock = r
    if #r.entries == 0 then
        P.restockText:SetText(paint("Nothing listed. Add a recipe above, or Alt-click one in the views.", "OFF"))
    else
        local function name(recipe) return recipe.name or ns.ItemName(recipe.outputItemID) end
        P.restockText:SetText(ns.Restock.Summary(r.entries, name, 3) .. "\n" .. paint("spend ", "LABEL")
            .. ns.Money(r.cash) .. (r.ownedUsed > 0 and paint("  (using " .. r.ownedUsed .. " you own)", "GOOD") or ""))
    end
    setColor(P.restockText, "TEXT")
    SetEnabled(P.restockSearch, #r.shopping > 0 and ns.UI.IsAuctionHouseOpen())
    SetEnabled(P.restockClear, #r.entries > 0 or #r.unknown > 0)
end

function D.Refresh()
    if not (pane and open) then
        return
    end
    profits = {}
    current.recipe = Recipe(picked)
    current.plan = current.recipe and ns.Planner.PlanRecipe(current.recipe, ns.recipesByOutput, ns.Price) or nil
    local ok, err = pcall(Layout)
    if ok then
        ok, err = pcall(LayoutRestock)
    end
    if not ok and geterrorhandler then
        geterrorhandler()(err)
    end
end

-- Daylight UI has no call to redraw its recipe lines, but stopping a painter puts its own look back on
-- every line at once (API.md, Paint), which redraws the list: profits (Profit.Of) and our badges with it
local paintHandle
function D.RepaintRows()
    if not (me and me.Paint) then
        return
    end
    if paintHandle then
        API.Off(paintHandle)
    end
    paintHandle = me.Paint("craftrow", RestockBadge)
end

-- Prices, what you own or the restock list changed: lines' profits and badges are stale too
function D.Invalidate()
    profits = {}
    D.Refresh()
    if open then
        D.RepaintRows()
    end
end

local function Build()
    pane = me.AttachCraftPane(D.PANE_W)
    if not pane then
        return false
    end
    P.title = API.Text(pane, "head", "LEFT")
    P.title:SetText("Make or Buy")
    setColor(P.title, "TITLE")
    P.empty = API.Text(pane, "small", "LEFT")
    P.empty:SetPoint("TOPLEFT", PAD, -PAD - 24)
    P.empty:SetWidth(D.PANE_W - 2 * PAD)
    P.empty:SetText("Pick a recipe.")
    setColor(P.empty, "OFF")

    P.reagentHead = API.Text(pane, "small", "LEFT")
    P.reagentHead:SetText("Reagents")
    local r, g, b = API.Accent()
    P.reagentHead:SetTextColor(r, g, b)
    P.more = API.Text(pane, "tiny", "LEFT")
    setColor(P.more, "OFF")

    local half = (D.PANE_W - 2 * PAD - 6) / 2
    P.where = Button("Where to get", half, function()
        ns.UI.FarmFor(current.plan, 1)
    end)
    P.search = Button("Search AH", half, function()
        ns.UI.SearchShopping(current.plan, 1)
    end)
    P.add = Button("Add to restock", D.PANE_W - 2 * PAD, nil) -- its click is set below (right-click too)
    P.add:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    P.add:SetScript("OnClick", function(_, button)
        local recipe = current.recipe
        if recipe then
            ns.RestockAdd(recipe.recipeID, button == "RightButton" and -1 or 1)
            D.Invalidate()
        end
    end)
    P.add:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Click: one more craft on the restock list")
        GameTooltip:AddLine("Right-click: one less", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    P.add:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Bottom: the restock list and the views
    P.views = Button("Profit, Learn, Route views", D.PANE_W - 2 * PAD, function()
        if ns.ProfitTab then
            ns.ProfitTab.ToggleWindow()
        end
    end)
    P.views:SetPoint("BOTTOMLEFT", PAD, PAD)
    P.restockSearch = Button("Search AH", half, function()
        if ns.ProfitTab then
            ns.ProfitTab.SearchRestock()
        end
    end)
    P.restockSearch:SetPoint("BOTTOMLEFT", P.views, "TOPLEFT", 0, 8)
    P.restockClear = Button("Clear", half, function()
        ns.db.restock = {}
        ns.PublishSelf()
        D.Invalidate()
        if ns.ProfitTab then
            ns.ProfitTab.Refresh()
        end
    end)
    P.restockClear:SetPoint("BOTTOMRIGHT", P.views, "TOPRIGHT", 0, 8)
    P.restockText = API.Text(pane, "small", "LEFT")
    P.restockText:SetPoint("BOTTOMLEFT", P.restockSearch, "TOPLEFT", 0, 8)
    P.restockText:SetWidth(D.PANE_W - 2 * PAD)
    P.restockHead = API.Text(pane, "small", "LEFT")
    P.restockHead:SetText("Restock list")
    P.restockHead:SetTextColor(r, g, b)
    P.restockHead:SetPoint("BOTTOMLEFT", P.restockText, "TOPLEFT", 0, 6)
    -- Hover the list for every craft, the merged shopping list and its profit
    P.restockHover = CreateFrame("Frame", nil, pane)
    P.restockHover:SetPoint("TOPLEFT", P.restockHead, "TOPLEFT", 0, 2)
    P.restockHover:SetPoint("BOTTOMRIGHT", P.restockText, "BOTTOMRIGHT", 0, -2)
    P.restockHover:EnableMouse(true)
    P.restockHover:SetScript("OnEnter", function(self)
        if ns.ProfitTab then
            ns.ProfitTab.lastRestock = P.lastRestock
            ns.ProfitTab.RestockTooltip(self)
        end
    end)
    P.restockHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return true
end

----------------------------------------------------------------------------------------------------
-- Setup

local function OnShown()
    open = true
    if ns.ProfitTab then
        ns.ProfitTab.HostChanged()
    end
    D.Refresh()
end

local function OnHidden()
    open = false
    picked = nil
    if ns.ProfitTab then
        ns.ProfitTab.HideWindow()
        ns.ProfitTab.HostChanged()
    end
end

-- Called at login, after Daylight UI has loaded (it is an optional dependency, so it loads first)
function D.Init()
    if me then
        return true
    end
    API = D.API()
    if not API then
        return false
    end
    me = API.For("MakeOrBuy")
    if not (me and Build()) then
        me = nil
        return false
    end
    me.On("CraftShown", OnShown)
    me.On("CraftHidden", OnHidden)
    me.On("CraftProfessionChanged", function()
        picked = nil
        D.Refresh()
    end)
    me.On("CraftRecipeSelected", function(recipeID)
        picked = recipeID
        D.Refresh()
    end)
    WrapProfit()
    D.RepaintRows()
    -- Daylight UI's skin kit, to dress the views window's game-template controls (nil with its Skins off)
    if me.RegisterSkin then
        me.RegisterSkin("MakeOrBuy", function(Kit)
            D.Kit = Kit
            return true
        end)
    end
    return true
end

-- Selects a recipe in Daylight UI's window (the views' "open the recipe"); false when it can't
function D.SelectRecipe(recipeID)
    return open and API and API.SelectCraftRecipe(recipeID) or false
end

-- Daylight UI's look on a window of ours: its shell, and its fonts and controls through the skin kit when
-- the Skins module is on. Returns true when it was applied.
function D.SkinWindow(frame, fonts)
    API = API or D.API()
    if not API then
        return false
    end
    API.Skin(frame, { window = true })
    local Kit = D.Kit
    if Kit then
        pcall(Kit.Auto, frame, { rows = false }) -- our list rows keep their own cells
        for fs, size in pairs(fonts or {}) do
            pcall(Kit.Font, fs, size)
        end
    end
    return true
end
