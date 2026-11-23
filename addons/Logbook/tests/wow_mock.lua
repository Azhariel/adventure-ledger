-- Test doubles for the client API Logbook touches. M.install(opts) sets the globals and returns the state the
-- tests drive (st.money, st.xp, st.clock...). Timers run when the test calls M.runTimers(); the event frame's
-- handler is reached with M.fire(event, ...).
local M = {}

function M.install(opts)
    opts = opts or {}
    local st = {
        now = opts.now or 1794000000, clock = 100, money = opts.money or 1000, level = opts.level or 20,
        xp = opts.xp or 500, xpMax = opts.xpMax or 10000, zone = opts.zone or "The Barrens", map = opts.map or 1413,
        x = 0.5, y = 0.4, world = { 100, 200 }, speed = 0, afk = false, combat = false, dead = false, ghost = false,
        resting = false, taxi = opts.taxi or false, instance = false, instanceType = "none", instanceName = nil,
        target = nil, units = {}, skills = opts.skills or {}, inbox = {}, sendItems = {}, secrets = {},
        quests = {}, spells = {}, timers = {}, printed = {}, played = opts.played or 50000,
        realm = opts.realm == nil and "CAMWOW US2 Realm 2 PvP" or opts.realm, rules = opts.rules,
    }
    M.state = st
    local frame = { events = {} }
    function frame:RegisterEvent(e) self.events[e] = true end
    function frame:SetScript(_, fn) self.handler = fn end
    M.frame = frame
    CreateFrame = function() return frame end
    SlashCmdList = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) st.printed[#st.printed + 1] = m end }
    issecretvalue = function(v) return st.secrets[v] == true end
    geterrorhandler = function() return function(e) error(e, 0) end end
    time = function() return st.now end
    date = os.date
    GetTime = function() return st.clock end
    C_Timer = {
        After = function(sec, fn) st.timers[#st.timers + 1] = fn end,
        NewTicker = function(sec, fn) st.ticker = fn return {} end,
    }
    hooks = {}
    hooksecurefunc = function(a, b, c)
        local tbl, name, fn = a, b, c
        if type(a) == "string" then tbl, name, fn = _G, a, b end
        local original = tbl[name]
        tbl[name] = function(...)
            local r = { original(...) }
            fn(...)
            return table.unpack(r)
        end
    end
    -- player
    UnitName = function(u)
        if u == "player" then return "Azhariel" end
        local d = st.units[u]
        return d and d.name
    end
    UnitGUID = function(u)
        if u == "player" then return "Player-6800-00A90C3E" end
        local d = st.units[u]
        return d and d.guid
    end
    GetRealmName = function() return st.realm end
    -- opts.rules: the active game rules by Enum.GameRule name ({ PvPRuleset = true }); without it, no C_GameRules
    C_GameRules = st.rules and { IsGameRuleActive = function(rule) return st.rules[rule] == true end } or nil
    UnitClass = function(u)
        local d = u ~= "player" and st.units[u]
        if d then return d.classToken, d.classToken end
        return "Priest", "PRIEST"
    end
    UnitRace = function(u)
        local d = u ~= "player" and st.units[u]
        if d then return d.race, d.race end
        return "Undead", "Scourge"
    end
    UnitIsUnit = function(a, b) return a == b end
    GetGuildInfo = function(u) local d = st.units[u] return d and d.guild end
    GetNumGroupMembers = function() return st.group or 0 end
    IsInRaid = function() return false end
    UnitFactionGroup = function() return "Horde" end
    UnitSex = function() return 2 end
    UnitLevel = function(u)
        if u == "player" then return st.level end
        local d = st.units[u]
        return d and d.level
    end
    UnitXP = function() return st.xp end
    UnitXPMax = function() return st.xpMax end
    GetMoney = function() return st.money end
    UnitIsAFK = function() return st.afk end
    UnitIsDeadOrGhost = function() return st.dead or st.ghost end
    UnitIsGhost = function() return st.ghost end
    UnitAffectingCombat = function() return st.combat end
    UnitOnTaxi = function() return st.taxi end
    IsResting = function() return st.resting end
    IsSwimming = function() return false end
    IsMounted = function() return false end
    GetUnitSpeed = function() return st.speed end
    UnitHealth = function() return st.hp or 100 end
    UnitHealthMax = function() return 100 end
    UnitPosition = function() return st.world[2], st.world[1], 0, 1 end
    IsInInstance = function() return st.instance, st.instanceType end
    GetInstanceInfo = function() return st.instanceName, st.instanceType, 1 end
    GetRealZoneText = function() return st.zone end
    GetZoneText = function() return st.zone end
    C_Map = {
        GetBestMapForUnit = function() return st.map end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return st.x, st.y end }
        end,
    }
    -- units
    UnitCanAttack = function(_, u) local d = st.units[u] return d and d.hostile end
    UnitCreatureType = function(u) local d = st.units[u] return d and d.type end
    UnitClassification = function(u) local d = st.units[u] return d and (d.class or "normal") end
    UnitIsPlayer = function(u) local d = st.units[u] return d and d.player end
    -- played
    RequestTimePlayed = function() st.playedAsked = (st.playedAsked or 0) + 1 end
    ChatFrame_DisplayTimePlayed = function() st.playedShown = (st.playedShown or 0) + 1 end
    -- gear, skills, quests, spells
    GetInventoryItemID = function(_, slot) return slot == 16 and 2489 or nil end
    GetNumSkillLines = function() return #st.skills end
    GetSkillLineInfo = function(i)
        local s = st.skills[i]
        return s[1], s.header, false, s[2], 0, 0, s[3]
    end
    GetQuestLogTitle = function(i) local q = st.quests[i] return q and q[1], q and q[2] end
    GetTitleText = function() return st.questTitle end
    GetAbandonQuestName = function() return st.abandon end
    AbandonQuest = function() end
    GetSpellInfo = function(id) return st.spells[id] end
    IsFishingLoot = function() return st.fishing end
    GetTradeSkillLine = function() return st.tradeSkill end
    C_Item = { GetItemQualityByID = function() return nil end, GetItemNameByID = function(id) return "Item" .. id end }
    -- money hooks
    RepairAllItems = function() end
    TakeTaxiNode = function() end
    TaxiNodeName = function(i) return "Node" .. i end
    NumTaxiNodes = function() return 5 end
    TaxiNodeGetType = function(i) return i == (st.taxiHere or 1) and "CURRENT" or "REACHABLE" end
    TaxiNodeCost = function(i) return i * 100 end
    -- st.taxiRoutes[dest] = { slot of each hop's end }; a direct flight when not set
    GetNumRoutes = function(i) return st.taxiRoutes and st.taxiRoutes[i] and #st.taxiRoutes[i] or 1 end
    TaxiGetNodeSlot = function(i, hop, source)
        local r = st.taxiRoutes and st.taxiRoutes[i] or { i }
        if source then return hop == 1 and (st.taxiHere or 1) or r[hop - 1] end
        return r[hop]
    end
    BuyMerchantItem = function() end
    GetMerchantItemInfo = function(i) return "Merchant item " .. i end
    C_Container = {
        UseContainerItem = function() end,
        GetContainerItemInfo = function(bag, slot)
            local it = st.bags and st.bags[bag .. ":" .. slot]
            return it and { stackCount = it.count, hyperlink = it.link }
        end,
    }
    -- mail
    GetInboxHeaderInfo = function(i)
        local m = st.inbox[i]
        if not m then return nil end
        return nil, nil, m.sender, m.subject, m.money or 0, 0, 30, m.items and #m.items or 0
    end
    GetInboxInvoiceInfo = function(i)
        local m = st.inbox[i]
        local v = m and m.invoice
        if not v then return nil end
        return v.kind, v.item, v.player, v.bid, v.buyout, 0, 0
    end
    GetInboxItem = function(i, a)
        local m = st.inbox[i]
        local it = m and m.items and m.items[a]
        if not it then return nil end
        return it[1], 1, 1, it[2]
    end
    TakeInboxMoney = function() end
    AutoLootMailItem = function() end
    TakeInboxItem = function() end
    SendMail = function() end
    GetSendMailItem = function(a) local it = st.sendItems[a] if it then return it[1], 1, 1, it[2] end end
    -- AH (modern)
    C_AuctionHouse = {
        PostCommodity = function() end, PostItem = function() end,
        ConfirmCommoditiesPurchase = function() end, PlaceBid = function() end,
    }
    C_Item.GetItemID = function(loc) return loc.id end
    C_Item.GetItemName = function(loc) return loc.name end
    -- client strings
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
    ERR_ZONE_EXPLORED_XP = "Discovered %s: %d experience gained"
    ERR_AUCTION_EXPIRED_S = "Your auction of %s has expired."
    LOOT_ITEM_SELF = "You receive loot: %s."
    LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
    LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
    LOOT_ITEM_CREATED_SELF = "You create: %s."
    LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
    -- damage meter: st.meter.sessions = { { id, seconds, [type] = { sources = {...}, spells = {...} } } }
    st.meter = { sessions = opts.meterSessions or {}, available = true }
    Enum = { DamageMeterType = { DamageDone = 0, HealingDone = 2, DamageTaken = 7, EnemyDamageTaken = 10 },
             GameRule = { PvPRuleset = "PvPRuleset", RPRuleset = "RPRuleset", HardcoreRuleset = "HardcoreRuleset" } }
    local function meterSession(id)
        for _, s in ipairs(st.meter.sessions) do if s.id == id then return s end end
    end
    C_DamageMeter = {
        IsDamageMeterAvailable = function() return st.meter.available, st.meter.available and "" or "disabled" end,
        GetAvailableCombatSessions = function()
            local out = {}
            for _, s in ipairs(st.meter.sessions) do
                out[#out + 1] = { sessionID = s.id, name = "Fight " .. s.id, durationSeconds = s.seconds }
            end
            return out
        end,
        GetCombatSessionFromID = function(id, kind)
            local s = meterSession(id)
            local d = s and s[kind]
            return { combatSources = d and d.sources or {}, maxAmount = 0, totalAmount = 0, durationSeconds = s and s.seconds }
        end,
        GetCombatSessionSourceFromID = function(id, kind, guid)
            local s = meterSession(id)
            local d = s and s[kind]
            return { combatSpells = d and d.spells or {}, maxAmount = 0, totalAmount = 0 }
        end,
    }
    C_Spell = { GetSpellName = function(id) return st.spells[id] end }
    LogbookCharDB, LogbookDB, MuddyBootsCharDB = opts.charDB, opts.accountDB, opts.muddy
    MuddyBootsDB = opts.muddyAccount
    return st
end

function M.fire(event, ...)
    M.frame.handler(M.frame, event, ...)
end

-- Runs the pending C_Timer.After callbacks (and any they schedule)
function M.runTimers()
    local st = M.state
    while #st.timers > 0 do
        local list = st.timers
        st.timers = {}
        for _, fn in ipairs(list) do fn() end
    end
end

function M.link(id, name, color)
    return "|cff" .. (color or "ffffff") .. "|Hitem:" .. id .. "::::::::|h[" .. name .. "]|h|r"
end

-- Loads Journal.lua and Core.lua fresh, logs in and enters the world. Returns ns, st.
function M.boot(root, opts)
    local st = M.install(opts)
    local ns = {}
    for _, f in ipairs({ "Journal.lua", "Core.lua", "StatusWindow.lua", "Status.lua" }) do
        assert(loadfile(root .. f))("Logbook", ns)
    end
    M.fire("PLAYER_LOGIN")
    M.fire("PLAYER_ENTERING_WORLD", true, opts and opts.reload or false)
    return ns, st
end

-- Swaps CreateFrame for fake widgets: unknown Set*/Get*/... methods do nothing, Show/Hide/SetText are kept.
-- Returns { [frame name] = frame, fonts = { every font string made } } for the test to look at.
function M.useFakeWidgets()
    local made = { fonts = {} }
    local function noop() end
    local Fake = {}
    local function new()
        return setmetatable({ scripts = {}, shown = true }, { __index = function(_, k)
            if Fake[k] then return Fake[k] end
            if type(k) == "string" and (k:match("^Set%u") or k:match("^Get%u") or k:match("^Enable") or k:match("^Clear")
                or k:match("^Register") or k:match("^Start") or k:match("^Stop")) then return noop end
        end })
    end
    function Fake:Show() if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
    function Fake:Hide() self.shown = false end
    function Fake:IsShown() return self.shown end
    function Fake:SetScript(name, fn) self.scripts[name] = fn end
    function Fake:SetText(t) self.text = t end
    function Fake:GetText() return self.text end
    function Fake:CreateTexture() return new() end
    function Fake:CreateFontString() local fs = new(); made.fonts[#made.fonts + 1] = fs; return fs end
    CreateFrame = function(_, name)
        local f = new()
        if name then made[name] = f end
        return f
    end
    UIParent = UIParent or new()
    UISpecialFrames = {}
    return made
end

-- The log as parsed rows { t, played, map, x, y, kind, args = {...} }, optionally only one kind
function M.rows(kind)
    local out = {}
    for _, line in ipairs(LogbookCharDB.log) do
        local f = {}
        for part in (line .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
        if not kind or f[6] == kind then
            local args = {}
            for i = 7, #f do args[#args + 1] = f[i] end
            out[#out + 1] = { t = tonumber(f[1]), played = tonumber(f[2]), map = tonumber(f[3]), kind = f[6], args = args }
        end
    end
    return out
end

return M
