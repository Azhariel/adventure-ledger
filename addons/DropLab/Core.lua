-- Core: saved data, reading loot windows and XP lines, the mob tooltip, /droplab and the public API.
-- No combat log (Forever forbids it): kills come from "X dies, you gain N experience" lines, and what each corpse
-- dropped from the loot window (GetLootSourceInfo names the corpse of every slot).
local addonName, ns = ...
local Stats = ns.Stats

local DB_VERSION = 1
local CYAN, GREY, WHITE, GREEN = "ff4dd2ff", "ff9d9d9d", "ffffffff", "ff40ff40"

local corpses = {}   -- this session's corpses (see Stats.RecordLoot)
local openGuids = {} -- corpses in the loot window that's open now
local xpPattern

local function color(hex, text)
    return "|c" .. hex .. text .. "|r"
end

local function secret(v)
    return issecretvalue and issecretvalue(v)
end

-- A value that's safe to keep: secret values become nil
local function safe(v)
    if v == nil or secret(v) then
        return nil
    end
    return v
end

function ns.InitDB()
    if type(DropLabDB) ~= "table" or DropLabDB.version ~= DB_VERSION then
        DropLabDB = Stats.NewDB()
    end
    local db = DropLabDB
    db.mobs, db.objects, db.names, db.unnamed = db.mobs or {}, db.objects or {}, db.names or {}, db.unnamed or {}
    if db.tooltip == nil then
        db.tooltip = true
    end
    db.lastKill = nil -- a pace never spans a logout
    Stats.Tidy(db)
    ns.db = db
end

-- A mob's name from Questie's NPC data (nil when Questie isn't loaded or doesn't know it)
function ns.NpcName(npcID)
    local lib = rawget(_G, "LibQuestieDB")
    local get = type(lib) == "table" and type(lib.Npc) == "table" and lib.Npc.Get
    if type(get) == "function" then
        local ok, name = pcall(get, npcID, "name")
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    local loader = rawget(_G, "QuestieLoader")
    local mods = type(loader) == "table" and rawget(loader, "_modules")
    local qdb = type(mods) == "table" and mods.QuestieDB
    if qdb and type(qdb.QueryNPCSingle) == "function" then
        local ok, name = pcall(qdb.QueryNPCSingle, npcID, "name")
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return nil
end

-- Names mobs known only by the corpse's ID (dungeons hide unit names), which also moves the kills waiting under
-- that name onto them. Returns how many were named.
function ns.NameMobs()
    if not ns.db then
        return 0
    end
    local named = 0
    for _, id in ipairs(Stats.Nameless(ns.db)) do
        local name = ns.NpcName(id)
        if name then
            Stats.Learn(ns.db, name, id)
            named = named + 1
        end
    end
    return named
end

function ns.Now()
    return GetTime and GetTime() or 0
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff4dd2ffDropLab|r: " .. msg)
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
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return copper .. "c"
end

-- Prices come from Make or Buy (a required addon): what selling a drop brings, and what buying one costs
function ns.SaleValue(itemID)
    local api = MakeOrBuy and MakeOrBuy.API
    return api and api.GetSaleValue and api.GetSaleValue(itemID) or nil
end

function ns.BuyPrice(itemID)
    local api = MakeOrBuy and MakeOrBuy.API
    if api and api.GetBuyPrice then
        return api.GetBuyPrice(itemID)
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Names: which npcID a name belongs to (the XP line only has the name)

local function creatureOf(unit)
    if not (UnitExists and UnitExists(unit)) or (UnitIsPlayer and UnitIsPlayer(unit)) then
        return nil
    end
    local guid = safe(UnitGUID(unit))
    local kind, id = Stats.ParseGUID(guid)
    if kind ~= "creature" then
        return nil
    end
    local name = safe(UnitName(unit))
    return id, type(name) == "string" and name or nil, guid
end

function ns.LearnUnit(unit)
    if not ns.db then
        return
    end
    local id, name = creatureOf(unit)
    if id and name then
        Stats.Learn(ns.db, name, id)
    end
end

-- The npcID of a mob that just died with this name: your target or mouse-over if it's that dead mob, else
-- the name learned before
local function deadNpc(name)
    for _, unit in ipairs({ "target", "mouseover" }) do
        local id, uname = creatureOf(unit)
        if id and uname == name and UnitIsDead and safe(UnitIsDead(unit)) then
            return id
        end
    end
    return nil
end

function ns.OnXP(text)
    if not ns.db or secret(text) then
        return
    end
    if xpPattern == nil then
        xpPattern = Stats.XPPattern(COMBATLOG_XPGAIN_FIRSTPERSON) or false
    end
    local name = Stats.ParseXP(text, xpPattern or nil)
    if not name then
        return
    end
    Stats.RecordKill(ns.db, name, deadNpc(name), ns.Now())
end

----------------------------------------------------------------------------------------------------
-- Loot windows

local LOOT_MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2

-- "1 Gold\n5 Silver\n3 Copper" -> 10503 (fallback when the source doesn't give the copper amount)
function ns.ParseCoins(text)
    if type(text) ~= "string" then
        return nil
    end
    local total, found = 0, false
    for n, unit in text:gmatch("(%d+)%s*(%a+)") do
        local u = unit:lower()
        local mult = (u == "gold" and 10000) or (u == "silver" and 100) or (u == "copper" and 1) or nil
        if mult then
            total, found = total + tonumber(n) * mult, true
        end
    end
    return found and total or nil
end

-- The loot window as entries for Stats.RecordLoot: one per slot and corpse
function ns.ReadLootWindow()
    local entries = {}
    if not (GetNumLootItems and GetLootSourceInfo) then
        return entries
    end
    if IsFishingLoot and IsFishingLoot() then
        return entries
    end
    for slot = 1, GetNumLootItems() or 0 do
        local slotType = GetLootSlotType and GetLootSlotType(slot)
        local itemID, money
        if slotType == LOOT_MONEY then
            money = true
        else
            local link = safe(GetLootSlotLink and GetLootSlotLink(slot))
            itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        end
        if itemID or money then
            local src = { GetLootSourceInfo(slot) }
            local nSources = math.floor(#src / 2)
            for i = 1, #src, 2 do
                local guid, qty = safe(src[i]), safe(src[i + 1])
                if type(guid) == "string" then
                    local e = { guid = guid, itemID = itemID, qty = type(qty) == "number" and qty or 1 }
                    if money then
                        local copper = type(qty) == "number" and qty > 0 and qty or nil
                        if not copper and nSources == 1 and GetLootSlotInfo then
                            local _, text = GetLootSlotInfo(slot)
                            copper = ns.ParseCoins(safe(text))
                        end
                        e.money, e.qty = copper, nil
                    end
                    if e.itemID or e.money then
                        entries[#entries + 1] = e
                    end
                end
            end
        end
    end
    return entries
end

function ns.OnLootOpened()
    if not ns.db then
        return
    end
    local entries = ns.ReadLootWindow()
    local now = ns.Now()
    Stats.Prune(corpses, now)
    -- name the corpse you're targeting (most loots are of your target)
    local tid, tname, tguid = creatureOf("target")
    local seen = {}
    for _, g in ipairs(openGuids) do
        seen[g] = true
    end
    for _, e in ipairs(entries) do
        if not seen[e.guid] then
            seen[e.guid] = true
            openGuids[#openGuids + 1] = e.guid
            if tguid == e.guid and tname then
                Stats.Learn(ns.db, tname, tid)
            end
        end
    end
    Stats.RecordLoot(ns.db, corpses, entries, now)
    ns.NameMobs()
end

function ns.OnLootClosed()
    Stats.Close(corpses, openGuids)
    openGuids = {}
end

----------------------------------------------------------------------------------------------------
-- Reports

-- Questie's drop rate (percent) per npcID for an item, via WhereToFarm when it's installed
local function publishedRates(itemID)
    local api = WhereToFarm and WhereToFarm.API
    local out = {}
    if api and api.GetSources then
        local ok, list = pcall(api.GetSources, itemID, { showAll = true })
        if ok and type(list) == "table" then
            for _, s in ipairs(list) do
                if s.npcID and s.rate then
                    out[s.npcID] = s.rate
                end
            end
        end
    end
    return out
end
ns.PublishedRates = publishedRates

function ns.MobName(npcID, mob)
    return (mob and mob.name) or ("npc " .. npcID)
end

-- Lines describing one mob (tooltip and /droplab target)
function ns.MobLines(npcID, maxDrops)
    local mob = ns.db and ns.db.mobs[npcID]
    if not mob then
        return {}
    end
    local n, basis = Stats.Kills(mob)
    local value, unpriced = Stats.Value(mob, ns.SaleValue)
    local head = Stats.SampleText(n, basis)
    if value and value > 0 then
        head = head .. ", " .. ns.Money(value) .. " per kill"
    end
    local kph = Stats.KillsPerHour(mob)
    if kph and value and value > 0 then
        head = head .. " (~" .. ns.Money(value * kph) .. "/h)"
    end
    local lines = { color(CYAN, "DropLab: ") .. head }
    if n < Stats.MIN_KILLS then
        lines[#lines + 1] = color(GREY, "  few kills so far: rates are rough")
    end
    for i, r in ipairs(Stats.Drops(mob)) do
        if i > (maxDrops or 4) then
            break
        end
        lines[#lines + 1] = "  " .. ns.ItemName(r.itemID) .. "  " .. color(WHITE, Stats.RateText(r))
    end
    if mob.gather and mob.gather.opened > 0 then
        local best, bestQty
        for itemID, s in pairs(mob.gather.items) do
            if not bestQty or s.qty > bestQty then
                best, bestQty = itemID, s.qty
            end
        end
        if best then
            lines[#lines + 1] = color(GREY, string.format("  gathered %d times: %.1f %s each", mob.gather.opened,
                bestQty / mob.gather.opened, ns.ItemName(best)))
        end
    end
    if unpriced > 0 then
        lines[#lines + 1] = color(GREY, "  " .. unpriced .. " drop(s) have no price yet")
    end
    return lines
end

-- /droplab <item>: every mob you've seen drop it
function ns.PrintItem(itemID)
    local list = Stats.ForItem(ns.db, itemID)
    if #list == 0 then
        ns.Print(ns.ItemName(itemID) .. ": none of your kills dropped it yet.")
        return
    end
    local published = publishedRates(itemID)
    local buy = ns.BuyPrice(itemID)
    ns.Print(ns.ItemName(itemID) .. (buy and (" (buy: " .. ns.Money(buy) .. " each)") or "") .. ", from your kills:")
    for i, r in ipairs(list) do
        if i > 8 then
            ns.Print("   +" .. (#list - 8) .. " more")
            break
        end
        local mob = ns.db.mobs[r.npcID]
        local parts = { ns.MobName(r.npcID, mob) .. ": " .. Stats.RateText(r) .. " over " .. Stats.SampleText(r.n, r.basis) }
        if r.perKill and r.perKill > 0 then
            parts[#parts + 1] = string.format("%.2f per kill", r.perKill)
            local kph = Stats.KillsPerHour(mob)
            if kph then
                parts[#parts + 1] = string.format("~%d per hour", math.floor(r.perKill * kph + 0.5))
            end
        end
        local q = published[r.npcID]
        if q then
            local verdict = Stats.Compare(q, r.lo, r.hi)
            parts[#parts + 1] = "Questie " .. Stats.Percent(q / 100) .. (verdict == "matches" and " (matches)"
                or verdict == "higher" and " (you get more)" or " (you get less)")
        end
        ns.Print("   " .. table.concat(parts, ", "))
    end
end

-- /droplab: the mobs worth most per kill
function ns.PrintBest()
    local list = Stats.Best(ns.db, ns.SaleValue)
    if #list == 0 then
        ns.Print("Not enough kills yet (" .. Stats.MIN_KILLS .. "+ of a mob). Kill and loot as usual; DropLab counts.")
        return
    end
    ns.Print("Best value per kill (items at their sale value, plus coin):")
    for i, b in ipairs(list) do
        if i > 8 then
            break
        end
        ns.Print(string.format("   %s: %s per kill over %s%s", ns.MobName(b.npcID, b),
            ns.Money(b.value), Stats.SampleText(b.n, b.basis),
            b.perHour and (", ~" .. ns.Money(b.perHour) .. "/h at your pace") or ""))
    end
end

----------------------------------------------------------------------------------------------------
-- Mob tooltip

function ns.OnUnitTooltip(tooltip, data)
    if not (ns.db and ns.db.tooltip) or tooltip ~= GameTooltip then
        return
    end
    local guid = data and safe(data.guid)
    if not guid and tooltip.GetUnit then
        -- The unit token can itself be a secret value (e.g. nameplates); UnitGUID
        -- then raises from tainted code, so skip secret tokens and contain errors.
        local _, unit = tooltip:GetUnit()
        unit = safe(unit)
        if unit then
            local ok, g = pcall(UnitGUID, unit)
            guid = ok and safe(g) or nil
        end
    end
    local kind, npcID = Stats.ParseGUID(guid)
    if kind ~= "creature" or not ns.db.mobs[npcID] then
        return
    end
    for _, line in ipairs(ns.MobLines(npcID, 3)) do
        tooltip:AddLine(line, 1, 0.82, 0)
    end
end

local function hookTooltip()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, ns.OnUnitTooltip)
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tt) ns.OnUnitTooltip(tt) end)
    end
end

----------------------------------------------------------------------------------------------------
-- Public API

DropLab = DropLab or {}
DropLab.API = {
    version = 1,
    -- Your rate for an item from a mob: { drops, qty, n, rate, lo, hi, perKill, basis } (fractions), or nil
    GetItemRate = function(npcID, itemID)
        local mob = ns.db and ns.db.mobs[npcID]
        if not mob or type(itemID) ~= "number" then
            return nil
        end
        return Stats.ItemRate(mob, itemID)
    end,
    -- Every mob you've seen drop an item, best first (see Stats.ForItem)
    GetItemSources = function(itemID)
        if not ns.db or type(itemID) ~= "number" then
            return {}
        end
        return Stats.ForItem(ns.db, itemID)
    end,
    -- { name, n, basis, value, killsPerHour } for a mob, or nil
    GetMob = function(npcID)
        local mob = ns.db and ns.db.mobs[npcID]
        if not mob then
            return nil
        end
        local n, basis = Stats.Kills(mob)
        return { name = mob.name, n = n, basis = basis, value = Stats.Value(mob, ns.SaleValue),
            killsPerHour = Stats.KillsPerHour(mob) }
    end,
}

----------------------------------------------------------------------------------------------------
-- Events

local handlers = {
    ADDON_LOADED = function(name)
        if name == addonName then
            ns.InitDB()
        end
    end,
    PLAYER_LOGIN = function()
        hookTooltip()
        ns.NameMobs()
        -- Questie loads its data a few seconds after login
        if C_Timer and C_Timer.After then
            C_Timer.After(20, function() pcall(ns.NameMobs) end)
        end
    end,
    -- both: with fast auto-loot one of them can come with the slots already gone; counting is idempotent
    LOOT_READY = ns.OnLootOpened,
    LOOT_OPENED = ns.OnLootOpened,
    LOOT_CLOSED = ns.OnLootClosed,
    CHAT_MSG_COMBAT_XP_GAIN = function(text) ns.OnXP(text) end,
    PLAYER_TARGET_CHANGED = function() ns.LearnUnit("target") end,
    UPDATE_MOUSEOVER_UNIT = function() ns.LearnUnit("mouseover") end,
}

local frame = CreateFrame("Frame")
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(handlers[event], ...)
    if not ok and geterrorhandler then
        geterrorhandler()(err)
    end
end)
ns.frame = frame

----------------------------------------------------------------------------------------------------
-- /droplab

function ns.ParseItem(msg)
    local id = type(msg) == "string" and (msg:match("item:(%d+)") or msg:match("^%s*(%d+)%s*$"))
    return id and tonumber(id) or nil
end

SLASH_DROPLAB1 = "/droplab"
SLASH_DROPLAB2 = "/drops"
SlashCmdList.DROPLAB = function(msg)
    if not ns.db then
        return
    end
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local lower = msg:lower()
    local itemID = ns.ParseItem(msg)
    if itemID then
        ns.PrintItem(itemID)
    elseif lower == "target" then
        local id = creatureOf("target")
        if not id then
            ns.Print("Target a creature first.")
        elseif not ns.db.mobs[id] then
            ns.Print("No kills or loot of your target recorded yet.")
        else
            for _, line in ipairs(ns.MobLines(id, 10)) do
                DEFAULT_CHAT_FRAME:AddMessage(line)
            end
        end
    elseif lower == "tooltip" then
        ns.db.tooltip = not ns.db.tooltip
        ns.Print("Mob tooltip lines " .. (ns.db.tooltip and color(GREEN, "on") or "off") .. ".")
    elseif lower == "" then
        ns.PrintBest()
    else
        ns.Print("/droplab - mobs worth most per kill. /droplab [item] - who dropped it and how often.")
        ns.Print("/droplab target - your target's drops. /droplab tooltip - mob tooltip lines on/off.")
    end
end
