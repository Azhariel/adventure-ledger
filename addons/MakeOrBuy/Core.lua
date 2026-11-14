-- Core: saved data, the Auctionator price source, events and the /mob slash command.
local addonName, ns = ...

ns.CALLER = addonName -- Auctionator API caller ID
ns.recipesByOutput = {}

local DB_VERSION = 1

function ns.InitDB()
    if type(MakeOrBuyCharDB) ~= "table" or MakeOrBuyCharDB.version ~= DB_VERSION then
        MakeOrBuyCharDB = { version = DB_VERSION, recipes = {} }
    end
    MakeOrBuyCharDB.recipes = MakeOrBuyCharDB.recipes or {}
    MakeOrBuyCharDB.unlearned = MakeOrBuyCharDB.unlearned or {}
    MakeOrBuyCharDB.bounds = MakeOrBuyCharDB.bounds or {}
    MakeOrBuyCharDB.skill = MakeOrBuyCharDB.skill or {}
    MakeOrBuyCharDB.restock = MakeOrBuyCharDB.restock or {}
    ns.db = MakeOrBuyCharDB
    -- Account-wide: one profile per character, so alts can see what each other crafts with (Alts.lua)
    if type(MakeOrBuyDB) ~= "table" or MakeOrBuyDB.version ~= DB_VERSION then
        MakeOrBuyDB = { version = DB_VERSION, chars = {} }
    end
    MakeOrBuyDB.chars = MakeOrBuyDB.chars or {}
    ns.account = MakeOrBuyDB
    -- Fix recipes an older version saved under the wrong profession
    if ns.Scanner and ns.Scanner.Repair then
        ns.Scanner.Repair(ns.db)
    end
    ns.Reindex()
end

function ns.Reindex()
    ns.recipesByOutput = ns.Planner.IndexByOutput(ns.db and ns.db.recipes)
end

-- A game value that's safe to keep: secret values (this client's protected values) and non-strings become nil
local function safeText(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return type(v) == "string" and v ~= "" and v or nil
end

-- This character: key (GUID) and profile { name, surname, faction, uses, needs, updated } (see Alts.Profile)
function ns.SelfProfile()
    local key = UnitGUID and safeText(UnitGUID("player"))
    local name, surname
    if UnitName then
        name, surname = UnitName("player") -- WoW Forever: the second value is the surname
    end
    name, surname = safeText(name), safeText(surname)
    if not (key and name and ns.db and ns.Alts) then
        return nil
    end
    local shopping
    if ns.db.restock and next(ns.db.restock) then
        local ok, r = pcall(ns.RestockBuild)
        shopping = ok and r and r.shopping or nil
    end
    local uses, needs = ns.Alts.Profile(ns.db.recipes, shopping)
    return key, { name = name, surname = surname, faction = UnitFactionGroup and safeText(UnitFactionGroup("player")),
        uses = uses, needs = needs, updated = time and time() or nil }
end

-- Saves this character's profile to the account-wide data (on login, logout and when the restock list changes)
function ns.PublishSelf()
    if not ns.account then
        return
    end
    local key, profile = ns.SelfProfile()
    if key then
        ns.account.chars[key] = profile
    end
end

-- Cheapest known purchase price per unit, from Auctionator's vendor cache and AH scan data.
function ns.Price(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api then
        return nil
    end
    local vendor = api.GetVendorPriceByItemID(ns.CALLER, itemID)
    local ah = api.GetAuctionPriceByItemID(ns.CALLER, itemID)
    if vendor and ah then
        if vendor <= ah then
            return vendor, "vendor"
        end
        return ah, "ah"
    elseif vendor then
        return vendor, "vendor"
    elseif ah then
        return ah, "ah"
    end
    return nil
end

function ns.AuctionPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    return api and api.GetAuctionPriceByItemID(ns.CALLER, itemID) or nil
end

-- What a vendor pays for one of the item (nil if unknown or unsellable). Item data may not be cached yet;
-- then we request it and refresh when GET_ITEM_INFO_RECEIVED arrives.
local waitingForItems = false
function ns.VendorSellPrice(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then
        return nil
    end
    local name, _, _, _, _, _, _, _, _, _, sellPrice = getInfo(itemID)
    if name == nil then
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        waitingForItems = true
        return nil
    end
    return sellPrice and sellPrice > 0 and sellPrice or nil
end

-- Net value of one crafted item: AH after cut or vendor, whichever is higher (see Planner.SaleValue)
function ns.SaleValue(itemID)
    return ns.Planner.SaleValue(ns.AuctionPrice(itemID), ns.VendorSellPrice(itemID))
end

-- What this character owns (bags, bank, mail) via the optional Stockpile addon: a fresh { [itemID] = n }
-- the caller may consume, or nil when Stockpile isn't installed or the option is off.
function ns.Owned()
    local api = _G.Stockpile and _G.Stockpile.API
    if not (api and api.GetOwnedMap) or (ns.db and ns.db.useOwned == false) then
        return nil
    end
    local ok, map = pcall(api.GetOwnedMap, "character")
    return ok and type(map) == "table" and map or nil
end

-- The restock list as one shopping list, using what you own (see Restock.Build)
function ns.RestockBuild()
    return ns.Restock.Build(ns.db.restock, ns.db.recipes, ns.recipesByOutput, ns.Price, ns.SaleValue, ns.Owned())
end

-- Adds `delta` crafts of a learned recipe to the restock list. Returns the new count, or nil if not learned.
function ns.RestockAdd(recipeID, delta)
    if not (ns.db and ns.db.recipes[recipeID]) then
        return nil
    end
    local n = ns.Restock.Add(ns.db.restock, recipeID, delta)
    ns.PublishSelf()
    if ns.ProfitTab then
        ns.ProfitTab.Refresh()
    end
    return n
end

local function printRestock()
    local r = ns.RestockBuild()
    if #r.entries == 0 then
        ns.Print("Restock list is empty. Alt-click recipes in the Worth crafting tab to add them.")
        return
    end
    ns.Print("Restock: " .. ns.Restock.Summary(r.entries, function(recipe) return recipe.name or ns.ItemName(recipe.outputItemID) end, 99))
    for _, e in ipairs(r.shopping) do
        local each = e.qty > 1 and e.unitPrice and (" (@" .. ns.Money(e.unitPrice) .. ")") or ""
        ns.Print("   " .. e.qty .. "x " .. ns.ItemName(e.itemID) .. " - " .. (e.source == "vendor" and "vendor " or "AH ")
            .. ns.Money(e.qty * e.unitPrice) .. each)
    end
    ns.Print("Spend " .. ns.Money(r.cash) .. (r.ownedUsed > 0 and (" (using " .. r.ownedUsed .. " you own)") or "")
        .. (r.profit ~= 0 and (", expected profit " .. ns.Money(r.profit)) or "") .. ".")
end
ns.PrintRestock = printRestock

-- How far to trust the AH price of an item (see Market.Assess)
function ns.MarketCheck(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    local current = ns.AuctionPrice(itemID)
    if not current then
        return nil
    end
    local age = api.GetAuctionAgeByItemID and api.GetAuctionAgeByItemID(ns.CALLER, itemID)
    local history
    local database = Auctionator.Database
    if database and database.GetPriceHistory then
        local ok, h = pcall(database.GetPriceHistory, database, tostring(itemID))
        history = ok and h or nil
    end
    return ns.Market.Assess(current, history, age)
end

-- Learn data from WhatsTraining's tables: { learn, cost, sources, teach } or nil
function ns.LearnInfo(recipeID, profession)
    local data = ns.RecipeData
    if not data then
        return nil
    end
    local tables = profession and data[profession] and { data[profession] } or data
    for _, list in pairs(tables) do
        local e = list[recipeID]
        if e then
            return { learn = e[1], cost = e[2], sources = e[3], teach = e[4] }
        end
    end
    return nil
end

function ns.Thresholds(recipeID, profession)
    local info = ns.LearnInfo(recipeID, profession)
    return ns.Skill.Thresholds(info and info.learn, ns.db and ns.db.bounds and ns.db.bounds[recipeID])
end

-- Current skill of a profession: level, max
function ns.CurrentSkill(profession)
    local level, maxLevel = ns.Scanner.SkillLevel()
    if level then
        return level, maxLevel
    end
    local saved = ns.db and ns.db.skill and profession and ns.db.skill[profession]
    if saved then
        return saved.level, saved.max
    end
    return nil
end

-- Skill-up chance of a learned recipe at the current skill; nil when its thresholds can't be estimated
function ns.SkillChance(recipeID, difficulty, profession)
    local level = ns.CurrentSkill(profession)
    local t = level and ns.Thresholds(recipeID, profession)
    if not t then
        return nil
    end
    -- The colour the game shows right now is the truth; the estimate only refines the chance within it
    if ns.Skill.DifficultyAt(t, level) ~= difficulty then
        return nil
    end
    return ns.Skill.Chance(t, level)
end

local function RefreshAll()
    if ns.UI then
        ns.UI.Refresh()
    end
    if ns.ProfitTab then
        ns.ProfitTab.Refresh()
    end
end

-- Item data arrives one item at a time; refresh once after a burst
local refreshPending = false
local function ScheduleRefresh()
    if refreshPending or not waitingForItems then
        return
    end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        waitingForItems = false
        RefreshAll()
    end)
end

-- Public API (used by DropLab). Prices in copper per unit, nil when unknown.
MakeOrBuy = MakeOrBuy or {}
MakeOrBuy.API = {
    version = 1,
    -- Cheapest way to buy one: vendor or AH. Returns copper, "vendor" | "ah"
    GetBuyPrice = function(itemID)
        if type(itemID) ~= "number" then return nil end
        local ok, price, source = pcall(ns.Price, itemID)
        if ok then return price, source end
        return nil
    end,
    -- What selling one brings: AH after the 5% cut, or the vendor price if higher
    GetSaleValue = function(itemID)
        if type(itemID) ~= "number" then return nil end
        local ok, value = pcall(ns.SaleValue, itemID)
        return ok and value or nil
    end,
}

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffMakeOrBuy|r: " .. msg)
end

function ns.ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not name and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
    return name or ("item:" .. itemID)
end

function ns.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper < 0 then
        return "-" .. GetMoneyString(-copper, true)
    end
    return GetMoneyString(copper, true)
end

-- Scans after the profession list settles; several TRADE_SKILL_LIST_UPDATE events can fire in a row.
-- A scan that catches the window mid-switch (list and profession disagree) is retried a few times.
local scanPending = false
local MAX_RETRIES = 5
local function ScheduleScan(retries, delay)
    if scanPending then
        return
    end
    scanPending = true
    retries = retries or MAX_RETRIES
    C_Timer.After(delay or 0.3, function()
        scanPending = false
        if not ns.db then
            return
        end
        local count, reason = ns.Scanner.ScanOpenProfession(ns.db)
        if count then
            ns.Reindex()
            ns.PublishSelf()
            RefreshAll()
        elseif reason == "mismatch" and retries > 0 then
            ScheduleScan(retries - 1, 0.5)
        end
    end)
end
ns.ScheduleScan = ScheduleScan

local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "GET_ITEM_INFO_RECEIVED",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "PLAYER_LOGIN", "PLAYER_LOGOUT" }) do
    -- pcall: registering an event this client doesn't have raises an error
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            ns.InitDB()
            -- Owned counts change the cash figures: refresh when Stockpile reports a change
            local api = _G.Stockpile and _G.Stockpile.API
            if api and api.RegisterCallback then
                pcall(api.RegisterCallback, addonName, RefreshAll)
            end
        end
    elseif event == "TRADE_SKILL_SHOW" then
        if ns.UI then
            ns.UI.Init()
        end
        ScheduleScan()
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        ScheduleScan()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        ScheduleRefresh()
    elseif event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
        RefreshAll() -- the Search AH buttons and hints depend on it
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_LOGOUT" then
        ns.PublishSelf() -- logout: the restock needs reflect what you hold as you leave
    end
end)

-- Turns Auctionator's own "To Craft" / "Profit" lines off or on. Its crafting info frame (and AH Search
-- button) stays; only those two lines are toggled.
function ns.ToggleAuctionatorLines()
    local cfg = Auctionator and Auctionator.Config
    if not (cfg and cfg.Set and cfg.Get and cfg.Options) then
        ns.Print("Auctionator settings are not available.")
        return
    end
    local o = cfg.Options
    local show = not (cfg.Get(o.CRAFTING_INFO_SHOW_PROFIT) or cfg.Get(o.CRAFTING_INFO_SHOW_COST))
    cfg.Set(o.CRAFTING_INFO_SHOW_PROFIT, show)
    cfg.Set(o.CRAFTING_INFO_SHOW_COST, show)
    ns.Print("Auctionator's crafting cost/profit lines are now " .. (show and "shown" or "hidden")
        .. ". Type /mob auctionator again to switch back.")
    local f = _G.AuctionatorCraftingInfoProfessionsFrame
    if f and f.UpdateTotal and f:IsVisible() then
        f:UpdateTotal()
    end
    if ns.UI then
        ns.UI.Refresh()
    end
end

-- /mob auctionator   -> hide/show Auctionator's own cost and profit lines
-- /mob               -> how many recipes are known
-- /mob [item link]   -> print the cheapest way to get one of that item
SLASH_MAKEORBUY1 = "/mob"
SLASH_MAKEORBUY2 = "/makeorbuy"
SlashCmdList.MAKEORBUY = function(msg)
    if msg and msg:lower():match("^%s*auctionator") then
        ns.ToggleAuctionatorLines()
        return
    end
    if msg and msg:lower():match("^%s*owned") then
        ns.db.useOwned = ns.db.useOwned == false
        if not (_G.Stockpile and _G.Stockpile.API) then
            ns.Print("Install the Stockpile addon so I can see what you own.")
        else
            ns.Print("Using items you own: " .. (ns.db.useOwned and "on" or "off") .. ".")
        end
        RefreshAll()
        return
    end
    local restock = msg and msg:lower():match("^%s*restock%s*(.-)%s*$")
    if restock then
        if restock == "clear" then
            ns.db.restock = {}
            ns.PublishSelf()
            ns.Print("Restock list cleared.")
            RefreshAll()
        else
            printRestock()
        end
        return
    end
    if msg and msg:lower():match("^%s*alts") then
        ns.PrintAlts()
        return
    end
    local itemID = msg and tonumber(msg:match("item:(%d+)") or msg:match("^%s*(%d+)%s*$"))
    if not itemID then
        local count = 0
        for _ in pairs(ns.db.recipes) do
            count = count + 1
        end
        ns.Print(count .. " recipes known. Open each profession once to teach me its recipes. "
            .. "Usage: /mob [item link], /mob auctionator (hide/show Auctionator's cost lines), "
            .. "/mob owned (use items you own: " .. (ns.db.useOwned == false and "off" or "on") .. "), "
            .. "/mob restock [clear] (the restock shopping list), /mob alts (what to mail your other characters)")
        return
    end
    local node = ns.Planner.PlanItem(itemID, ns.recipesByOutput, ns.Price)
    if node.method == "craft" then
        ns.Print(ns.ItemName(itemID) .. ": craft for " .. ns.Money(node.unitCost) .. " each"
            .. (node.buyPrice and (" (buy: " .. ns.Money(node.buyPrice) .. ")") or ""))
        local lines = ns.Planner.Expand(node.craft, 1)
        for _, line in ipairs(lines) do
            local each = line.qty > 1 and line.unitCost and line.unitCost > 0 and (" (@" .. ns.Money(line.unitCost) .. ")") or ""
            ns.Print(string.rep("   ", line.depth + 1) .. line.qty .. "x " .. ns.ItemName(line.itemID)
                .. " - " .. line.method .. " " .. ns.Money(line.unitCost * line.qty) .. each)
        end
    elseif node.method == "buy" then
        ns.Print(ns.ItemName(itemID) .. ": buy for " .. ns.Money(node.buyPrice) .. " each ("
            .. node.buySource .. ")" .. (node.craftUnitCost and (", crafting costs " .. ns.Money(node.craftUnitCost)) or ""))
    else
        ns.Print(ns.ItemName(itemID) .. ": no price and no known recipe.")
    end
end
