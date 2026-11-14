-- Core: saved data, income detection from game events, item valuation and the /haul command.
local addonName, ns = ...

local Session = ns.Session
local floor = math.floor

ns.CALLER = addonName -- Auctionator API caller ID
ns.RESUME_WINDOW = 600 -- a login within 10 minutes of logout (e.g. /reload) continues the same session
ns.MONEY_WINDOW = 1    -- seconds between a money change and its "You loot X" chat line

local DB_VERSION = 1

-- Clocks are indirections so tests can drive them
ns.Now = function() return time() end
ns.Clock = function() return GetTime() end

-- This client hides some values as "secret": they can't be compared or used, so we skip them.
local function secret(v)
    return issecretvalue ~= nil and v ~= nil and issecretvalue(v)
end
ns.IsSecret = secret

local function num(v)
    if secret(v) or type(v) ~= "number" then
        return nil
    end
    return v
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffe6b422Haul|r: " .. msg)
end

function ns.Money(copper)
    copper = floor((copper or 0) + 0.5)
    if GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    return GetMoneyString(copper, true)
end

-- Rates are shown to the silver once they pass a gold, to stay short
function ns.Rate(copper)
    if not copper then
        return "--"
    end
    if copper >= 10000 then
        copper = floor(copper / 100) * 100
    end
    return ns.Money(copper) .. "/h"
end

function ns.Duration(seconds)
    seconds = floor(seconds or 0)
    local h = floor(seconds / 3600)
    local m = floor((seconds % 3600) / 60)
    return string.format("%d:%02d", h, m)
end

-- "25m" under an hour, "2h 05m" above
function ns.Eta(seconds)
    seconds = math.ceil(seconds or 0)
    if seconds < 3600 then
        return math.max(1, math.ceil(seconds / 60)) .. "m"
    end
    return string.format("%dh %02dm", floor(seconds / 3600), floor((seconds % 3600) / 60))
end

function ns.Short(n)
    if n >= 1000000 then
        return string.format("%.1fm", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(floor(n))
end

---------------------------------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------------------------------

function ns.InitDB()
    if type(HaulCharDB) ~= "table" or HaulCharDB.version ~= DB_VERSION then
        HaulCharDB = { version = DB_VERSION }
    end
    HaulCharDB.history = HaulCharDB.history or {}
    HaulCharDB.window = HaulCharDB.window or { shown = true }
    ns.db = HaulCharDB
end

local function PlayerXP()
    local level = num(UnitLevel and UnitLevel("player"))
    local xp = num(UnitXP and UnitXP("player"))
    local xpMax = num(UnitXPMax and UnitXPMax("player"))
    return level, xp, xpMax
end

local function CurrentZone()
    local zone = GetRealZoneText and GetRealZoneText()
    if secret(zone) or type(zone) ~= "string" or zone == "" then
        return nil
    end
    return zone
end

local function NewSession()
    local now = ns.Now()
    local s = Session.New(now, PlayerXP())
    Session.SetZone(s, now, CurrentZone())
    return s
end

-- Archives the running session and starts a fresh one
function ns.Reset()
    if ns.session then
        Session.PushHistory(ns.db.history, Session.Summary(ns.session, ns.Now()))
    end
    ns.session = NewSession()
    ns.db.current = nil
end

-- At login: continue the saved session after a /reload or a quick relog, otherwise archive it.
function ns.StartOrResume()
    local now = ns.Now()
    local saved = ns.db.current
    ns.db.current = nil
    if saved and saved.session and saved.savedAt and now - saved.savedAt <= ns.RESUME_WINDOW then
        local s = saved.session
        if s.pauseReason == "logout" then
            Session.Resume(s, now)
        end
        -- XP baseline is re-read; a level gained while logged out isn't ours
        local level, xp, xpMax = PlayerXP()
        s.level, s.lastXP, s.lastXPMax = level, xp, xpMax
        ns.session = s
        Session.SetZone(s, now, CurrentZone())
        return "resumed"
    end
    if saved and saved.session then
        Session.PushHistory(ns.db.history, Session.Summary(saved.session, saved.savedAt or now))
    end
    ns.session = NewSession()
    return "new"
end

function ns.SaveForLogout()
    local s = ns.session
    if not (s and ns.db) then
        return
    end
    local now = ns.Now()
    if not Session.IsPaused(s) then
        Session.Pause(s, now, "logout")
    end
    ns.db.current = { session = s, savedAt = now }
end

---------------------------------------------------------------------------------------------------
-- Item value: AH after the 5% cut or the vendor price, whichever is higher
---------------------------------------------------------------------------------------------------

function ns.AuctionPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionPriceByItemID) then
        return nil
    end
    local ok, price = pcall(api.GetAuctionPriceByItemID, ns.CALLER, itemID)
    return ok and num(price) or nil
end

-- Returns the unit value, or nil when the item's data isn't loaded yet (it is requested then).
function ns.ItemValue(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, sellPrice
    if getInfo then
        local r = { getInfo(itemID) }
        name, sellPrice = r[1], r[11]
    end
    if name == nil then
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return nil
    end
    return Session.ItemValue(ns.AuctionPrice(itemID), num(sellPrice))
end

---------------------------------------------------------------------------------------------------
-- Income detection
---------------------------------------------------------------------------------------------------

-- Windows where money or "You receive item" lines are not farming income: buying, mail, trading, AH, bank
local blockers = {}
local function Blocked()
    return next(blockers) ~= nil
end
ns.blockers = blockers

local BLOCK_EVENTS = {
    MERCHANT_SHOW = { "merchant", true }, MERCHANT_CLOSED = { "merchant", false },
    MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
    TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
    AUCTION_HOUSE_SHOW = { "ah", true }, AUCTION_HOUSE_CLOSED = { "ah", false },
    BANKFRAME_OPENED = { "bank", true }, BANKFRAME_CLOSED = { "bank", false },
}

-- Coin from loot. A money change counts as loot when the loot window is open, or when the client's
-- "You loot ..." / "Your share of the loot ..." line (CHAT_MSG_MONEY) arrives within MONEY_WINDOW of it,
-- in either order. Each chat line pairs with at most one money change, so nothing is counted twice, and
-- the localized chat text never has to be parsed.
local money = { last = nil, lootOpen = false, pending = nil, msgAt = nil, countedAt = nil }
ns.moneyState = money

local function CountLootMoney(amount)
    if ns.session and not Session.IsPaused(ns.session) then
        Session.AddMoney(ns.session, ns.Now(), "loot", amount)
    end
end

local function OnPlayerMoney()
    local current = num(GetMoney and GetMoney())
    if not current then
        return
    end
    local delta = money.last and (current - money.last) or 0
    money.last = current
    if delta <= 0 or Blocked() then
        return
    end
    local t = ns.Clock()
    if money.lootOpen then
        CountLootMoney(delta)
        money.countedAt = t
    elseif money.msgAt and t - money.msgAt <= ns.MONEY_WINDOW then
        CountLootMoney(delta)
        money.msgAt = nil
    else
        money.pending = { amount = delta, t = t }
    end
end

local function OnChatMoney()
    local t = ns.Clock()
    if money.countedAt and t - money.countedAt <= ns.MONEY_WINDOW then
        money.countedAt = nil -- this line belongs to the change already counted
    elseif money.pending and t - money.pending.t <= ns.MONEY_WINDOW then
        CountLootMoney(money.pending.amount)
        money.pending = nil
    else
        money.msgAt = t
    end
end

-- Chat patterns for items you receive. Multiples first: the single pattern would also match "x5".
-- "You create" (crafted items) is deliberately not among them.
local lootPatterns
local function LootPatterns()
    if lootPatterns then
        return lootPatterns
    end
    lootPatterns = {}
    local defs = {
        { "LOOT_ITEM_SELF_MULTIPLE", false, true },
        { "LOOT_ITEM_PUSHED_SELF_MULTIPLE", true, true },
        { "LOOT_ITEM_SELF", false, false },
        { "LOOT_ITEM_PUSHED_SELF", true, false },
    }
    for _, d in ipairs(defs) do
        local p = Session.FormatToPattern(_G[d[1]])
        if p then
            lootPatterns[#lootPatterns + 1] = { pattern = p, pushed = d[2], multiple = d[3] }
        end
    end
    return lootPatterns
end
ns.LootPatterns = LootPatterns

-- Returns itemID, count, link, pushed for a chat line about an item you received, or nil.
function ns.ParseLoot(text)
    if type(text) ~= "string" then
        return nil
    end
    for _, p in ipairs(LootPatterns()) do
        local link, count = text:match(p.pattern)
        if link then
            local itemID = tonumber(link:match("item:(%d+)"))
            if itemID then
                return itemID, (p.multiple and tonumber(count)) or 1, link, p.pushed
            end
        end
    end
    return nil
end

local function OnChatLoot(text)
    if secret(text) or not ns.session or Session.IsPaused(ns.session) then
        return
    end
    local itemID, count, link, pushed = ns.ParseLoot(text)
    if not itemID or (pushed and Blocked()) then
        return
    end
    Session.AddItem(ns.session, ns.Now(), itemID, count, ns.ItemValue(itemID), link)
end

local function OnQuestTurnedIn(_, _, moneyReward)
    moneyReward = num(moneyReward)
    if moneyReward and ns.session and not Session.IsPaused(ns.session) then
        Session.AddMoney(ns.session, ns.Now(), "quest", moneyReward)
    end
end

local function OnXP()
    local s = ns.session
    if not s then
        return
    end
    local level, xp, xpMax = PlayerXP()
    if Session.IsPaused(s) then
        -- keep the baseline current so XP earned while paused isn't counted later
        s.lastXP, s.lastXPMax, s.level = xp or s.lastXP, xpMax or s.lastXPMax, level or s.level
        return
    end
    Session.XPUpdate(s, ns.Now(), xp, xpMax, level)
end

local function OnFlags(unit)
    if unit ~= nil and (secret(unit) or unit ~= "player") then
        return
    end
    local s = ns.session
    if not (s and UnitIsAFK) then
        return
    end
    local afk = UnitIsAFK("player")
    if secret(afk) then
        return
    end
    if afk and not Session.IsPaused(s) then
        Session.Pause(s, ns.Now(), "afk")
    elseif not afk and s.pauseReason == "afk" then
        Session.Resume(s, ns.Now())
    end
end

local function OnItemInfo(itemID)
    itemID = num(itemID)
    local s = ns.session
    if not (itemID and s and s.items[itemID] and s.items[itemID].pendingCount) then
        return
    end
    local v = ns.ItemValue(itemID)
    if v then
        Session.Revalue(s, itemID, v)
    end
end

function ns.Update()
    if ns.UI then
        ns.UI.Update()
    end
end

local handlers = {
    ADDON_LOADED = function(name)
        if name == addonName then
            ns.InitDB()
        end
    end,
    PLAYER_LOGIN = function()
        if not ns.db then
            ns.InitDB()
        end
        money.last = num(GetMoney and GetMoney())
        ns.StartOrResume()
        if ns.UI then
            ns.UI.Init()
        end
        if C_Timer and C_Timer.NewTicker and not ns.ticker then
            ns.ticker = C_Timer.NewTicker(1, ns.Update)
        end
    end,
    PLAYER_LOGOUT = function()
        ns.SaveForLogout()
    end,
    PLAYER_ENTERING_WORLD = function()
        if ns.session then
            Session.SetZone(ns.session, ns.Now(), CurrentZone())
        end
    end,
    PLAYER_MONEY = OnPlayerMoney,
    CHAT_MSG_MONEY = OnChatMoney,
    LOOT_OPENED = function() money.lootOpen = true end,
    LOOT_CLOSED = function() money.lootOpen = false end,
    CHAT_MSG_LOOT = OnChatLoot,
    QUEST_TURNED_IN = OnQuestTurnedIn,
    PLAYER_XP_UPDATE = OnXP,
    PLAYER_FLAGS_CHANGED = OnFlags,
    GET_ITEM_INFO_RECEIVED = OnItemInfo,
}
handlers.ZONE_CHANGED_NEW_AREA = handlers.PLAYER_ENTERING_WORLD
for event, def in pairs(BLOCK_EVENTS) do
    handlers[event] = function()
        blockers[def[1]] = def[2] or nil
    end
end
ns.handlers = handlers

local events = CreateFrame("Frame")
for event in pairs(handlers) do
    -- pcall: registering an event this client doesn't have raises an error
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then
        fn(...)
    end
end)

---------------------------------------------------------------------------------------------------
-- /haul
---------------------------------------------------------------------------------------------------

function ns.PrintHistory(limit)
    local history = ns.db and ns.db.history or {}
    if #history == 0 then
        ns.Print("No finished sessions yet.")
        return
    end
    for i = 1, math.min(limit or 5, #history) do
        local h = history[i]
        local total = (h.loot or 0) + (h.quest or 0) + (h.items or 0)
        ns.Print(string.format("%s  %s  %s  (%s)  %s XP",
            date and date("%m/%d %H:%M", h.start) or tostring(h.start), ns.Duration(h.duration), ns.Money(total),
            ns.Rate(Session.PerHour(total, h.duration)), ns.Short(h.xp or 0)))
    end
end

SLASH_HAUL1 = "/haul"
SlashCmdList.HAUL = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    local s = ns.session
    if cmd == "" then
        if ns.UI then
            ns.UI.Toggle()
        end
    elseif cmd == "reset" then
        ns.Reset()
        ns.Print("New session started.")
    elseif cmd == "pause" then
        if s then
            Session.Pause(s, ns.Now(), "manual")
        end
        ns.Print("Paused. /haul resume to continue.")
    elseif cmd == "resume" then
        if s then
            Session.Resume(s, ns.Now())
        end
        ns.Print("Resumed.")
    elseif cmd == "history" then
        ns.PrintHistory(5)
    else
        ns.Print("/haul (show/hide), /haul reset, /haul pause, /haul resume, /haul history")
    end
    ns.Update()
end
