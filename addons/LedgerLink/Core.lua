-- Ledger Link: the in-game half of the Adventure Ledger dashboard (_forever_/Dashboard).
-- 1. Turns the combat log on at every login (WoW switches it off at logout), so the Live tab always has data.
--    Not possible on Forever (tested 8 Nov 2026): making WoW write the log sooner. It writes on a fixed 5-minute
--    timer; LoggingCombat(false/true), /combatlog and /reload neither write it early nor open a new file.
-- 2. Keeps Neutral auction house prices apart. Auctionator keeps one price book per realm, so a scan at the
--    goblin AH (Gadgetzan, Booty Bay, Everlook) lands in the same book as your faction AH and drags its highs and
--    "now" price up. While the AH you opened is neutral, Ledger Link catches Auctionator's price writes and keeps
--    them in LedgerLinkDB.neutral (same shape: l/h/a per scan day, m = last seen). By default Auctionator's own
--    book is left untouched by those scans ("/ledger neutral both" also lets them through).
-- Public (ns.LedgerLink, for tests): Ensure(), Command(msg), IsNeutralHere(), OnAuctionShow(), HookAuctionator(),
--   RecordNeutral(dbKey, price, available, now).
local ADDON, ns = ...
local L = {}
ns.LedgerLink = L

local PREFIX = "|cffbd93f9Ledger Link|r: "
local DEFAULTS = { enable = true, quiet = false, neutralMode = "split" } -- split | both | off
local KEEP_DAYS = 60
local MAX_VISITS = 200
-- Auctionator's scan day: whole days since local midnight, 1 Jan 2020 (as Auctionator.Constants.SCAN_DAY_0)
local function scanDay0()
    local A = _G.Auctionator
    return A and A.Constants and A.Constants.SCAN_DAY_0 or time({ year = 2020, month = 1, day = 1, hour = 0 })
end

-- Zones whose auction house is the neutral (goblin) one. uiMapIDs first; English names as a fallback.
L.NEUTRAL_MAPS = { [1446] = "Tanaris", [1434] = "Stranglethorn Vale", [1452] = "Winterspring" }
L.NEUTRAL_NAMES = { ["Gadgetzan"] = true, ["Booty Bay"] = true, ["Everlook"] = true,
    ["Tanaris"] = true, ["Stranglethorn Vale"] = true, ["Winterspring"] = true }

local function db()
    LedgerLinkDB = LedgerLinkDB or {}
    for k, v in pairs(DEFAULTS) do
        if LedgerLinkDB[k] == nil then LedgerLinkDB[k] = v end
    end
    return LedgerLinkDB
end

local function say(msg)
    print(PREFIX .. msg)
end

-- LoggingCombat() reads, LoggingCombat(true/false) sets; guarded in case the client ever protects it
local function logging(set)
    local ok, on
    if set == nil then
        ok, on = pcall(LoggingCombat)
    else
        ok, on = pcall(LoggingCombat, set)
    end
    return ok and on and true or false, ok
end

function L.Ensure()
    if not db().enable then return false end
    if logging() then return false end
    local _, ok = logging(true)
    if ok and not db().quiet then say("combat log on (for the Adventure Ledger's Live tab).") end
    return ok
end

----------------------------------------------------------------------------------------------------
-- Neutral auction house

L.atNeutral = false -- the last auction house opened was the neutral one (Auctionator may still be processing)

-- true when the player stands in a zone with a neutral auction house
function L.IsNeutralHere()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID and L.NEUTRAL_MAPS[mapID] then return true, L.NEUTRAL_MAPS[mapID] end
    local sub = GetSubZoneText and GetSubZoneText() or ""
    local zone = GetZoneText and GetZoneText() or ""
    if L.NEUTRAL_NAMES[sub] or L.NEUTRAL_NAMES[zone] then return true, sub ~= "" and sub or zone end
    return false, zone
end

local function scanDay(now)
    return tostring(math.floor((now - scanDay0()) / 86400))
end

-- Same bookkeeping as Auctionator's DatabaseMixin:SetPrice, into LedgerLinkDB.neutral
function L.RecordNeutral(dbKey, price, available, now)
    now = now or time()
    local d = db()
    d.neutral = d.neutral or {}
    local book = d.neutral
    local e = book[dbKey]
    if not e then
        e = { l = {}, h = {}, a = {}, m = 0 }
        book[dbKey] = e
    end
    local day = scanDay(now)
    e.m = price
    e.t = now
    local high = e.h[day]
    if high == nil or price > high then
        e.h[day] = price
        high = price
    end
    if price < high and (e.l[day] == nil or price < e.l[day]) then e.l[day] = price end
    if available ~= nil then e.a[day] = math.max(e.a[day] or 0, available) end
    local cutoff = tonumber(day) - KEEP_DAYS
    for _, list in ipairs({ e.l, e.h, e.a }) do
        for k in pairs(list) do
            if tonumber(k) <= cutoff then list[k] = nil end
        end
    end
    d.neutralLast = now
end

-- Wraps Auctionator.Database:SetPrice on the live instance (Auctionator mixes its methods into the object, so
-- the instance is what ProcessScan calls). Safe to call again: it wraps once.
function L.HookAuctionator()
    local A = _G.Auctionator
    local dbo = A and A.Database
    if not dbo or type(dbo.SetPrice) ~= "function" then return false end
    if dbo.__ledgerLink then return true end
    local original = dbo.SetPrice
    dbo.SetPrice = function(self, dbKey, price, available, ...)
        local mode = db().neutralMode
        if L.atNeutral and mode ~= "off" then
            pcall(L.RecordNeutral, dbKey, price, available)
            if mode == "split" then return end
        end
        return original(self, dbKey, price, available, ...)
    end
    dbo.__ledgerLink = true
    return true
end

function L.OnAuctionShow(now)
    local neutral, where = L.IsNeutralHere()
    L.atNeutral = neutral
    L.HookAuctionator()
    local d = db()
    d.visits = d.visits or {}
    table.insert(d.visits, { t = now or time(), kind = neutral and "neutral" or "faction", zone = where })
    while #d.visits > MAX_VISITS do table.remove(d.visits, 1) end
    if neutral and d.neutralMode ~= "off" and not d.quiet then
        say(("neutral auction house (%s): prices go to the Ledger's Neutral book%s."):format(where or "?",
            d.neutralMode == "split" and ", not Auctionator's" or " and Auctionator's"))
    end
end

local function neutralCount()
    local n = 0
    for _ in pairs(db().neutral or {}) do n = n + 1 end
    return n
end

----------------------------------------------------------------------------------------------------
-- /ledger

function L.Command(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local d = db()
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "off" then
        d.enable = false
        say("won't switch the combat log on any more (/ledger on to undo).")
    elseif cmd == "on" then
        d.enable = true
        L.Ensure()
        say("will switch the combat log on at every login.")
    elseif cmd == "neutral" then
        if arg == "split" or arg == "both" or arg == "off" then d.neutralMode = arg end
        local text = {
            split = "Neutral AH scans go to the Ledger only (Auctionator keeps faction prices).",
            both = "Neutral AH scans go to the Ledger and to Auctionator.",
            off = "Neutral AH scans aren't kept apart (Auctionator gets them all).",
        }
        say(("%s %d items in the Neutral book.  /ledger neutral split | both | off"):format(
            text[d.neutralMode] or "?", neutralCount()))
    else
        say(("combat log %s; switched on at login: %s; neutral AH: %s.  /ledger on | off | neutral"):format(
            logging() and "ON" or "off", d.enable and "yes" or "no", d.neutralMode))
    end
end

SLASH_LEDGERLINK1 = "/ledger"
SlashCmdList.LEDGERLINK = L.Command

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        L.OnAuctionShow()
    else
        C_Timer.After(1, L.Ensure)
    end
end)
