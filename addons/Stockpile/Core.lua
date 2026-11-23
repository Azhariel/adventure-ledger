-- Core: saved data, scanning bags/bank/mail on events, change callbacks and the /stockpile command.
local addonName, ns = ...
local Store = ns.Store

ns.callbacks = {}
ns.bankOpen = false

-- This client can hand out "secret" values; never compare, save or index with one.
local function safe(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then
        return nil
    end
    return v
end
ns.Safe = safe

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffStockpile|r: " .. msg)
end

function ns.InitDB()
    StockpileDB = Store.Upgrade(StockpileDB)
    ns.db = StockpileDB
end

-- GetRealmName() answers "" on Forever since the client update of 2026-11-21. Then: the realm this character
-- was saved under (so the dashboard still matches it with Logbook's row), else the ruleset from the game rules
-- (Auctionator's names), else nil.
function ns.BlankRealm(name)
    local found
    for _, c in pairs(ns.db and ns.db.chars or {}) do
        if c.name == name and type(c.realm) == "string" and c.realm ~= "" then
            if found and found ~= c.realm then return nil end -- the same name on two realms: can't tell
            found = c.realm
        end
    end
    if found then return found end
    local rules, E = C_GameRules, Enum and Enum.GameRule
    if not (rules and rules.IsGameRuleActive and E) then return nil end
    local function on(rule) return rule ~= nil and rules.IsGameRuleActive(rule) end
    local pvp, rp = on(E.PvPRuleset), on(E.RPRuleset)
    if pvp and rp then return "RPPvP" end
    if pvp then return "PvP" end
    if rp then return "RP" end
    if on(E.HardcoreRuleset) then return "HC" end
    return "PvE"
end

-- Registers the current character (name, realm, class) and returns its key.
function ns.EnsurePlayer()
    if not ns.db then
        return nil
    end
    local name = safe(UnitName("player"))
    local realm = safe((GetRealmName and GetRealmName()) or nil)
    if realm == "" and type(name) == "string" then
        realm = ns.BlankRealm(name)
    end
    if type(name) ~= "string" or type(realm) ~= "string" or name == "" or realm == "" then
        return nil
    end
    local _, class = UnitClass("player")
    ns.playerKey = Store.EnsureChar(ns.db, name, realm, safe(class))
    return ns.playerKey
end

-- Containers -----------------------------------------------------------------------------------

local function numSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return safe(C_Container.GetContainerNumSlots(bag)) or 0
    end
    return GetContainerNumSlots and safe(GetContainerNumSlots(bag)) or 0
end

-- itemID, count of one slot (nil when empty or secret).
local function slotItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) ~= "table" then
            return nil
        end
        return safe(info.itemID), safe(info.stackCount)
    end
    if GetContainerItemInfo then
        local _, count, _, _, _, _, _, _, _, itemID = GetContainerItemInfo(bag, slot)
        return safe(itemID), safe(count)
    end
end

local function countContainers(bags)
    local counts = {}
    for _, bag in ipairs(bags) do
        local n = numSlots(bag)
        if type(n) == "number" then
            for slot = 1, n do
                local itemID, count = slotItem(bag, slot)
                Store.Add(counts, itemID, count)
            end
        end
    end
    return counts
end

-- Backpack plus equipped bags (the reagent bag is included where the client has one).
function ns.BagIDs()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    local ids = {}
    for bag = 0, last do
        ids[#ids + 1] = bag
    end
    return ids
end

-- Bank containers. Newer clients use character bank tabs, older ones the bank slots (-1) plus bank bags.
-- Both sets are read: containers a client doesn't have report 0 slots, so this works whichever layout it uses.
function ns.BankIDs()
    local ids, seen = {}, {}
    local function add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    local bagIndex = Enum and Enum.BagIndex
    if bagIndex then
        local i = 1
        while bagIndex["CharacterBankTab_" .. i] do
            add(bagIndex["CharacterBankTab_" .. i])
            i = i + 1
        end
    end
    add((bagIndex and bagIndex.Bank) or BANK_CONTAINER or -1)
    local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) + 1
    for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do
        add(bag)
    end
    add((bagIndex and bagIndex.Reagentbank) or REAGENTBANK_CONTAINER)
    return ids
end

function ns.CountMail()
    local counts = {}
    if not GetInboxNumItems or not GetInboxItem then
        return counts
    end
    local mails = safe(GetInboxNumItems()) or 0
    for i = 1, mails do
        for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
            local _, itemID, _, count = GetInboxItem(i, a)
            Store.Add(counts, safe(itemID), safe(count))
        end
    end
    return counts
end

-- Change callbacks ------------------------------------------------------------------------------

local notifyPending = false
function ns.NotifyChanged()
    if notifyPending then
        return
    end
    notifyPending = true
    C_Timer.After(0.3, function()
        notifyPending = false
        for owner, fn in pairs(ns.callbacks) do
            local ok, err = pcall(fn, owner)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
        end
    end)
end

local function store(location, counts)
    local key = ns.playerKey
    if not (key and ns.db.chars[key]) then
        key = ns.EnsurePlayer() -- first scan, or the character was forgotten
    end
    if key and Store.SetLocation(ns.db, key, location, counts) then
        ns.NotifyChanged()
    end
    return key
end

function ns.ScanBags()
    store("bags", countContainers(ns.BagIDs()))
end

-- The bank can only be read while it's open; outside that the last snapshot stays.
function ns.ScanBank()
    if not ns.bankOpen then
        return
    end
    local counts = countContainers(ns.BankIDs())
    local key = store("bank", counts)
    local c = key and ns.db.chars[key]
    if not c then
        return
    end
    c.bankTime = time and time() or c.bankTime
    if not ns.bankAnnounced then
        -- Once per session, so you know the visit counted
        ns.bankAnnounced = true
        local stacks, items = 0, 0
        for _, n in pairs(counts) do
            stacks, items = stacks + 1, items + n
        end
        ns.Print(stacks > 0 and string.format("bank saved (%d items, %d kinds).", items, stacks)
            or "bank saved (it looks empty).")
    end
end

function ns.ScanMail()
    store("mail", ns.CountMail())
end

-- Events ------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local function register(event)
    pcall(frame.RegisterEvent, frame, event) -- unknown events error on some clients
end
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED", "MAIL_SHOW",
    "MAIL_INBOX_UPDATE", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    register(e)
end

local function isBanker(kind)
    local types = Enum and Enum.PlayerInteractionType
    return types and types.Banker ~= nil and kind == types.Banker
end

local function openBank()
    ns.bankOpen = true
    ns.ScanBank()
    -- The bank's contents can arrive just after the window opens: read it again a moment later
    C_Timer.After(0.5, ns.ScanBank)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            ns.InitDB()
            if ns.Tooltip then
                ns.Tooltip.Init()
            end
        end
        return
    end
    if not ns.db then
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ns.EnsurePlayer()
        ns.ScanBags()
    elseif event == "BAG_UPDATE_DELAYED" then
        ns.ScanBags()
        ns.ScanBank()
    elseif event == "BANKFRAME_OPENED" then
        openBank()
    elseif event == "BANKFRAME_CLOSED" then
        ns.bankOpen = false
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if isBanker(arg1) then openBank() end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if isBanker(arg1) then ns.bankOpen = false end
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERREAGENTBANKSLOTS_CHANGED" then
        ns.ScanBank()
    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
        ns.ScanMail()
    end
end)

-- Slash command ---------------------------------------------------------------------------------

function ns.ColorName(row)
    local colors = RAID_CLASS_COLORS
    local c = row.class and colors and colors[row.class]
    if c and c.colorStr then
        return "|c" .. c.colorStr .. row.name .. "|r"
    end
    return row.name
end

function ns.ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not name and GetItemInfo then
        name = GetItemInfo(itemID)
    end
    return safe(name) or ("item " .. itemID)
end

local function printItem(itemID)
    local total, list = Store.Count(ns.db, itemID, "realm", ns.playerKey)
    if total == 0 then
        ns.Print(ns.ItemName(itemID) .. ": none on this realm")
        return
    end
    ns.Print(ns.ItemName(itemID) .. ": " .. total)
    for _, row in ipairs(list) do
        ns.Print("  " .. ns.ColorName(row) .. ": " .. Store.Breakdown(row))
    end
end

local function printUsage()
    ns.Print("/stockpile [item link or id] - who has it and where")
    ns.Print("/stockpile forget Name-Realm - stop tracking a character")
    local me = ns.playerKey and ns.db.chars[ns.playerKey]
    if me then
        ns.Print("Bank: " .. (me.bankTime and ("saved " .. date("%Y-%m-%d %H:%M", me.bankTime))
            or "not saved yet. Talk to a banker once; it updates on every visit."))
    end
    local keys = {}
    for key in pairs(ns.db.chars) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    ns.Print("Tracked characters: " .. (#keys > 0 and table.concat(keys, ", ") or "none yet"))
end

SLASH_STOCKPILE1 = "/stockpile"
SLASH_STOCKPILE2 = "/stock"
SlashCmdList.STOCKPILE = function(msg)
    if not ns.db then
        return
    end
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local forget = msg:match("^[Ff]orget%s+(.+)$")
    if forget then
        if Store.Forget(ns.db, forget) then
            ns.Print("Forgot " .. forget .. ".")
            ns.NotifyChanged()
        else
            ns.Print("No character called " .. forget .. ". Use the Name-Realm shown by /stockpile.")
        end
        return
    end
    local itemID = msg ~= "" and Store.ParseItemID(msg)
    if itemID then
        printItem(itemID)
    else
        printUsage()
    end
end
