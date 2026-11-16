-- Core: Logbook's game half. Listens to the client and writes LogbookCharDB / LogbookDB through Journal.lua.
-- No combat log (Forever forbids it): kills come from the "X dies, you gain N experience" line, deaths from
-- PLAYER_DEAD with your last hostile target as the likely killer, and fights from entering and leaving combat.
-- Damage, healing and the killing blow come from Blizzard's damage meter (C_DamageMeter) once a fight is over.
-- Every API call is guarded: a missing function, an error or a "secret" value just leaves that field empty.
local ADDON, ns = ...
local J = ns.Journal
local L = {}
ns.Core = L

local unpack = unpack or table.unpack
local floor = math.floor

ns.Now = function() return time() end
ns.Clock = function() return GetTime() end
ns.After = function(sec, fn)
    if C_Timer and C_Timer.After then C_Timer.After(sec, fn) else fn() end
end

L.TICK = 5          -- seconds between activity / trail / distance samples
L.FLUSH = 0.4       -- seconds to wait for the line that explains an XP or money change
L.CLOSED_GRACE = 2  -- a window closed this recently still explains a money change (the flight master closes first)
L.FOES_MAX = 400
L.METER_DELAY = 1   -- seconds after leaving combat before reading the damage meter (it closes the session first)

----------------------------------------------------------------------------------------------------
-- Safe calls

local function secret(v)
    return issecretvalue ~= nil and v ~= nil and issecretvalue(v)
end

-- Calls fn(...) when it exists; returns its results with secret values as nil, or nothing on error
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    local n = 0
    for k in pairs(r) do if k > n then n = k end end
    for i = 2, n do if secret(r[i]) then r[i] = nil end end
    return unpack(r, 2, n)
end
L.Call = call

local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local n = call(C_Spell.GetSpellName, id)
        if type(n) == "string" and n ~= "" then return n end
    end
    local n = call(GetSpellInfo, id)
    return type(n) == "string" and n ~= "" and n or nil
end

local function str(v)
    if type(v) ~= "string" or secret(v) or v == "" then return nil end
    return v
end

local function number(v)
    if type(v) ~= "number" or secret(v) then return nil end
    return v
end

function ns.Print(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff8be9fdLogbook|r: " .. msg) end
end

----------------------------------------------------------------------------------------------------
-- State

local st = {
    frames = {},          -- open windows: name -> true, or the clock when it closed
    xp = J.NewPending(),
    money = J.NewPending(),
    foes = {}, foeCount = 0, -- name -> { npc, type, class, level, player }
}
L.state = st

function L.Reset()
    st.frames, st.xp, st.money, st.foes, st.foeCount = {}, J.NewPending(), J.NewPending(), {}, 0
    st.played, st.playedClock, st.session, st.sessionFrom = nil, nil, nil, nil
    st.lastMoney, st.lastXP, st.lastXPMax, st.xpLevel = nil, nil, nil, nil
    st.fight, st.lastFoe, st.env, st.zone, st.instance = nil, nil, nil, nil, nil
    st.lastTick, st.lastWorld, st.started = nil, nil, nil
    st.tradeSkill, st.gather, st.lootKind, st.questTitle, st.questTitles = nil, nil, nil, nil, {}
    st.turnedIn = {}
    st.ahAction, st.xpFlushing, st.moneyFlushing, st.wasDead = nil, nil, nil, nil
    st.meterLast, st.meterReading, st.mailBought, st.abandoning = nil, nil, nil, nil
    st.abandonTarget = nil
    st.players, st.playerCount, st.met, st.sent = {}, 0, {}, {}
end
L.Reset()

local function open(name)
    local v = st.frames[name]
    return v == true or (type(v) == "number" and ns.Clock() - v <= L.CLOSED_GRACE)
end

local function openFrames()
    local out = {}
    for name in pairs(st.frames) do
        if open(name) then out[name] = true end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Saved data

function L.InitDB()
    local now = ns.Now()
    if type(LogbookCharDB) ~= "table" or (LogbookCharDB.schema or 0) > J.SCHEMA then
        LogbookCharDB = J.NewChar(now)
    end
    J.Tidy(LogbookCharDB)
    LogbookCharDB.since = LogbookCharDB.since or now
    if type(LogbookDB) ~= "table" then LogbookDB = J.NewAccount() end
    LogbookDB.chars = LogbookDB.chars or {}
    ns.db, ns.account = LogbookCharDB, LogbookDB
    return ns.db
end

function L.Played()
    if not st.played then return nil end
    return floor(st.played + (ns.Clock() - st.playedClock) + 0.5)
end

local function level()
    return number(call(UnitLevel, "player"))
end

-- Your level as far as Logbook knows: the client's, the saved one or the highest level reached, whichever is
-- higher. Levels never go down, and at a logout to the character list the client can report level 1.
function L.KnownLevel()
    local db = ns.db
    local best = level() or 0
    if db then
        best = math.max(best, db.char.level or 0)
        for lvl in pairs(db.snap or {}) do
            if type(lvl) == "number" and lvl > best then best = lvl end
        end
    end
    return best > 0 and best or nil
end

-- Where you are: uiMapID and x, y in ten-thousandths (nil inside instances and where the client hides it)
function L.Position()
    local map = C_Map and number(call(C_Map.GetBestMapForUnit, "player"))
    if not map then return nil end
    local pos = call(C_Map.GetPlayerMapPosition, map, "player")
    if type(pos) ~= "table" then return map end
    local x, y = call(pos.GetXY, pos)
    x, y = number(x), number(y)
    if not x or not y or x <= 0 or y <= 0 or x > 1 or y > 1 then return map end
    return map, floor(x * 10000 + 0.5), floor(y * 10000 + 0.5)
end

function L.Log(kind, ...)
    local db = ns.db
    if not db then return end
    local map, x, y = L.Position()
    return J.Add(db, J.Line(ns.Now(), L.Played(), map, x, y, kind, ...))
end

local function zoneName()
    return str(call(GetRealZoneText)) or str(call(GetZoneText))
end

-- Name, realm, class, race... of the player, into db.char
function L.Identity()
    local c = ns.db.char
    c.name = str(call(UnitName, "player")) or c.name
    c.realm = str(call(GetRealmName)) or c.realm
    c.guid = str(call(UnitGUID, "player")) or c.guid
    local _, classToken = call(UnitClass, "player")
    c.class = str(classToken) or c.class
    local _, raceToken = call(UnitRace, "player")
    c.race = str(raceToken) or c.race
    c.faction = str(call(UnitFactionGroup, "player")) or c.faction
    c.sex = number(call(UnitSex, "player")) or c.sex
    c.level = L.KnownLevel() or c.level
    c.zone = zoneName() or c.zone
    if not c.first then c.first = { t = ns.Now(), level = c.level } end
    return c
end

-- The account-wide row for this character (Characters module: level, gold, played, last seen)
function L.UpdateAccount()
    local c = ns.db and ns.db.char
    if not (c and c.guid and ns.account) then return end
    local row = ns.account.chars[c.guid] or {}
    ns.account.chars[c.guid] = row
    row.from = nil -- a row copied from MuddyBoots is Logbook's own from now on
    row.name, row.realm, row.guid, row.class, row.race = c.name, c.realm, c.guid, c.class, c.race
    row.faction, row.sex, row.level = c.faction, c.sex, c.level
    -- the gold Logbook has tracked: at a logout to the character list the client can report 0
    row.money = st.lastMoney or number(call(GetMoney)) or row.money
    row.played = L.Played() or row.played
    row.lastSeen = ns.Now()
    row.zone = c.zone
end

-- MuddyBoots' counters, once: the dashboard adds Logbook's on top, so its totals carry on
function L.ImportBaseline()
    local db = ns.db
    if db.baseline or db.noBaseline then return end
    local mb = rawget(_G, "MuddyBootsCharDB")
    local b = J.Baseline(mb, ns.Now())
    if b then
        db.baseline = b
    else
        db.noBaseline = true
    end
end

-- MuddyBoots' older history, once, whenever MuddyBoots is loaded and Logbook doesn't have it yet; and its
-- account rows for characters Logbook hasn't seen. With both copied, MuddyBoots' files can go.
function L.ImportHistory()
    local db = ns.db
    if not db.history then
        local h = J.History(rawget(_G, "MuddyBootsCharDB"), db.since, ns.Now())
        if h then db.history = h end
    end
    if ns.account then J.ImportAccountRows(ns.account.chars, rawget(_G, "MuddyBootsDB")) end
end

----------------------------------------------------------------------------------------------------
-- Played time. RequestTimePlayed answers with TIME_PLAYED_MSG; the chat frame's print of it is held back while
-- Logbook asked (a /played you type still prints).

local wantPlayed = false
function L.RequestPlayed()
    if type(RequestTimePlayed) ~= "function" then return end
    if not L.playedHooked and type(ChatFrame_DisplayTimePlayed) == "function" then
        local original = ChatFrame_DisplayTimePlayed
        ChatFrame_DisplayTimePlayed = function(...)
            if wantPlayed then return end
            return original(...)
        end
        L.playedHooked = true
    end
    wantPlayed = true
    pcall(RequestTimePlayed)
end

function L.OnTimePlayed(total)
    wantPlayed = false
    total = number(total)
    if not total then return end
    local known = st.played ~= nil
    st.played, st.playedClock = total, ns.Clock()
    if known or not ns.db then return end
    -- fill in what was logged before we knew it
    local now, played = ns.Now(), total
    local function at(t) return math.max(0, played - (now - t)) end
    J.BackfillPlayed(ns.db, st.sessionFrom, at)
    local s = st.session
    if s then s.played0 = at(s.start); s.played1 = played end
    for _, snap in pairs(ns.db.snap) do
        if not snap.played and snap.t and s and snap.t >= s.start then snap.played = at(snap.t) end
    end
    L.UpdateAccount()
end

----------------------------------------------------------------------------------------------------
-- Sessions, zones, instances

function L.StartSession(how)
    if st.started then return end
    st.started = true
    st.sessionFrom = #ns.db.log + 1
    st.session = J.StartSession(ns.db, ns.Now(), L.Played(), how)
    L.Log("in", how)
    st.zone = nil
    L.OnZone()
end

function L.OnZone()
    local zone = zoneName()
    if zone and zone ~= st.zone then
        st.zone = zone
        ns.db.char.zone = zone
        L.Log("zo", zone)
    end
    L.CheckInstance()
end

-- Dungeon runs: "ie|name|type|difficulty" on the way in, "il|name|seconds" on the way out (MuddyBoots' di / dx
-- mean other things, and both logs end up side by side on the dashboard)
function L.CheckInstance()
    local inside, kind = call(IsInInstance)
    local now = ns.Now()
    if inside and kind and kind ~= "none" then
        local name, _, difficulty = call(GetInstanceInfo)
        name = str(name) or zoneName() or "?"
        if not st.instance or st.instance.name ~= name then
            if st.instance then L.LeaveInstance(now) end
            st.instance = { name = name, kind = kind, t = now }
            L.Log("ie", name, kind, number(difficulty))
            J.Count(ns.db.counts.dungeons, "entered:" .. name)
        end
    elseif st.instance then
        L.LeaveInstance(now)
    end
end

function L.LeaveInstance(now)
    local i = st.instance
    st.instance = nil
    if not i then return end
    local sec = (now or ns.Now()) - i.t
    L.Log("il", i.name, sec)
    J.Count(ns.db.counts.dungeons, "seconds:" .. i.name, sec)
end

function L.OnLogout()
    if not ns.db then return end
    L.Tick()
    if st.fight then L.OnCombatEnd() end
    if st.instance then L.LeaveInstance() end
    L.FlushXP(true)
    L.FlushMoney(true)
    L.Log("out")
    J.TouchSession(st.session, ns.Now(), L.Played())
    ns.db.char.level = L.KnownLevel() or ns.db.char.level
    L.UpdateAccount()
    J.TrailForSave(ns.db.trail)
end

----------------------------------------------------------------------------------------------------
-- The activity tick: what you're doing, how far you went, where you are

local function mode()
    if call(UnitIsGhost, "player") then return "ghost" end
    if call(UnitOnTaxi, "player") then return "fly" end
    if call(IsSwimming) then return "swim" end
    if call(IsMounted) then return "mount" end
    return "foot"
end

function L.Tick()
    local db = ns.db
    if not db then return end
    L.CheckFlight()
    local now = ns.Now()
    local last = st.lastTick or now
    st.lastTick = now
    local dt = math.min(now - last, L.TICK * 3) -- a stall (loading screen) isn't time spent doing anything
    local lvl = level()
    local speed = number(call(GetUnitSpeed, "player")) or 0
    local inside = call(IsInInstance)
    local taxi = call(UnitOnTaxi, "player") and true or false
    if dt > 0 then
        local what = J.Activity({
            afk = call(UnitIsAFK, "player"), dead = call(UnitIsDeadOrGhost, "player"),
            combat = call(UnitAffectingCombat, "player"), instance = inside, moving = speed > 0,
            taxi = taxi, resting = call(IsResting),
        })
        J.Count(db.counts.activity, what, dt, lvl)
    end
    -- distance from world coordinates (yards); a jump of more than a flight's worth is a hearth or a portal
    local wy, wx, _, instanceID = call(UnitPosition, "player")
    wy, wx = number(wy), number(wx)
    if wx and wy then
        local prev = st.lastWorld
        if prev and prev.instance == instanceID then
            local d = math.sqrt((wx - prev.x) ^ 2 + (wy - prev.y) ^ 2)
            if d > 0.5 then
                if d > 60 * math.max(dt, 1) then
                    J.Count(db.counts.distance, "hearth", floor(d + 0.5), lvl)
                else
                    J.Count(db.counts.distance, mode(), floor(d + 0.5), lvl)
                end
            end
        end
        st.lastWorld = { x = wx, y = wy, instance = instanceID }
    end
    local map, x, y = L.Position()
    if map and x then
        local flag = (call(UnitIsDeadOrGhost, "player") and "d") or (taxi and "t") or nil
        J.TrailPoint(db.trail, now, map, x, y, flag)
    end
    J.TouchSession(st.session, now, L.Played())
end

----------------------------------------------------------------------------------------------------
-- XP

local patterns
local function P()
    if patterns then return patterns end
    patterns = {
        kill = J.FormatToPattern(rawget(_G, "COMBATLOG_XPGAIN_FIRSTPERSON")),
        discover = J.FormatToPattern(rawget(_G, "ERR_ZONE_EXPLORED_XP")),
        expired = J.FormatToPattern(rawget(_G, "ERR_AUCTION_EXPIRED_S")),
        won = J.FormatToPattern(rawget(_G, "ERR_AUCTION_WON_S")),
        sold = J.FormatToPattern(rawget(_G, "ERR_AUCTION_SOLD_S")),
        loot = {},
    }
    local defs = {
        { "LOOT_ITEM_SELF_MULTIPLE", "loot", true }, { "LOOT_ITEM_SELF", "loot", false },
        { "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "pushed", true }, { "LOOT_ITEM_PUSHED_SELF", "pushed", false },
        { "LOOT_ITEM_CREATED_SELF_MULTIPLE", "created", true }, { "LOOT_ITEM_CREATED_SELF", "created", false },
        { "LOOT_ROLL_YOU_WON", "won", false },
    }
    for _, d in ipairs(defs) do
        local p = J.FormatToPattern(rawget(_G, d[1]))
        if p then patterns.loot[#patterns.loot + 1] = { p, d[2], d[3] } end
    end
    return patterns
end
L.Patterns = P

function L.OnXPUpdate()
    local xp, xpMax, lvl = number(call(UnitXP, "player")), number(call(UnitXPMax, "player")), level()
    if not xp then return end
    if st.lastXP and lvl then
        local delta
        if st.xpLevel and lvl > st.xpLevel then
            delta = (st.lastXPMax or 0) - st.lastXP + xp
        else
            delta = xp - st.lastXP
        end
        if delta > 0 then
            J.Delta(st.xp, delta)
            L.ScheduleXP()
        end
    end
    st.lastXP, st.lastXPMax, st.xpLevel = xp, xpMax, lvl
end

function L.ScheduleXP()
    if st.xpFlushing then return end
    st.xpFlushing = true
    ns.After(L.FLUSH, function() L.FlushXP() end)
end

-- Writes "xp|amount|source|detail" lines; force = at logout (hints don't wait for a change that won't come)
function L.FlushXP(force)
    st.xpFlushing = false
    if not ns.db then return end
    local lvl = st.xpLevel or level()
    -- in dungeons the chat lines are secret: XP nobody explained there is dungeon XP
    local fallback = call(IsInInstance) and "dungeon" or "other"
    for _, g in ipairs(J.FlushXP(st.xp, (not force) and ns.Clock() or nil, fallback)) do
        L.Log("xp", g.amount, g.source, g.detail)
        local counts = ns.db.counts.xp
        J.Count(counts, "all", g.amount)
        J.Count(counts, g.source, g.amount, lvl)
        if g.rested then J.Count(counts, "rested", math.min(g.rested, g.amount), lvl) end
    end
end

-- Mob info by name (from target, mouse-over and nameplates), for the kill line that only has a name
function L.Learn(unit)
    local name = str(call(UnitName, unit))
    if not name or not call(UnitCanAttack, "player", unit) then return end
    local kind, npc = J.ParseGUID(str(call(UnitGUID, unit)))
    local info = {
        npc = npc, player = kind == "player", type = str(call(UnitCreatureType, unit)),
        class = str(call(UnitClassification, unit)), level = number(call(UnitLevel, unit)),
    }
    if not st.foes[name] then
        st.foeCount = st.foeCount + 1
        if st.foeCount > L.FOES_MAX then st.foes, st.foeCount = {}, 1 end
    end
    st.foes[name] = info
    if call(UnitAffectingCombat, "player") then st.lastFoe = { name = name, info = info, at = ns.Clock() } end
    return info
end

function L.OnCombatXP(text)
    if not str(text) then return end
    local p = P()
    local zone, dxp = J.ParseDiscover(text, p.discover)
    if zone then
        J.Hint(st.xp, { source = "discover", amount = dxp, detail = zone }, ns.Clock())
        L.ScheduleXP()
        return
    end
    local name, xp, rested = J.ParseKillXP(text, p.kill)
    if not name then return end
    local info = st.foes[name] or {}
    L.Log("ki", name, info.npc, info.type, info.class, xp, info.level)
    J.Count(ns.db.counts.fights, "kills")
    J.Hint(st.xp, { source = "kill", amount = xp, detail = name, rested = rested }, ns.Clock())
    L.ScheduleXP()
end

function L.OnLevelUp(newLevel)
    newLevel = number(newLevel) or level()
    if not newLevel then return end
    local db = ns.db
    db.char.level = newLevel
    L.Log("lv", newLevel)
    local gear = {}
    for slot = 1, 19 do gear[slot] = number(call(GetInventoryItemID, "player", slot)) or 0 end
    gear = table.concat(gear, ",")
    L.Log("ge", newLevel, gear, "ding")
    db.snap[newLevel] = { t = ns.Now(), played = L.Played(), money = number(call(GetMoney)), zone = zoneName(),
        gear = gear }
    L.UpdateAccount()
end

----------------------------------------------------------------------------------------------------
-- Money

function L.OnMoney()
    local now = number(call(GetMoney))
    if not now then return end
    if st.lastMoney then
        local delta = now - st.lastMoney
        if delta ~= 0 then
            -- each change is explained on its own (two quick vendor sales are two lines)
            st.money.queue = st.money.queue or {}
            table.insert(st.money.queue, { delta = delta, frames = openFrames(), at = ns.Clock() })
            L.ScheduleMoney()
        end
    end
    st.lastMoney = now
end

function L.MoneyHint(hint)
    J.Hint(st.money, hint, ns.Clock())
    if st.money.queue and #st.money.queue > 0 then L.ScheduleMoney() end
end

function L.ScheduleMoney()
    if st.moneyFlushing then return end
    st.moneyFlushing = true
    ns.After(L.FLUSH, function() L.FlushMoney() end)
end

-- Writes "mn|delta|source|detail" lines (and the AH lines a money change confirms)
function L.FlushMoney()
    st.moneyFlushing = false
    if not ns.db then return end
    local queue = st.money.queue or {}
    st.money.queue = {}
    local lvl = level()
    for _, m in ipairs(queue) do
        local source, detail, hint = J.MoneySource(m.delta, st.money.hints, m.frames, ns.Clock())
        L.Log("mn", m.delta, source, detail)
        local counts = ns.db.counts
        if source == "repair" then J.Count(counts.character, "repairCopper", -m.delta, lvl) end
        if hint and hint.sold then
            -- this letter's retries are spent: a later letter for the same item brings its own hints
            for _, h in ipairs(st.money.hints) do
                if h.sold and not h.used and h.amount == hint.amount and h.detail == hint.detail
                    and (h.at or 0) < m.at then
                    h.used = true
                end
            end
            L.Log("ma", "invoice", hint.sold.player or "?", m.delta, detail)
            L.Log("ah", "sold", m.delta, detail)
            J.Count(counts.auction, "sold")
            J.Count(counts.auction, "soldCopper", m.delta)
        end
        if hint and hint.ah then
            -- a post's deposit, a buyout's price: the AH line carries what the money paid
            L.Log("ah", hint.ah, math.abs(m.delta), detail)
            J.Count(counts.auction, hint.ah)
            J.Count(counts.auction, hint.ah .. "Copper", math.abs(m.delta))
        end
    end
    local keep = {}
    for _, h in ipairs(st.money.hints) do
        if not h.used and ns.Clock() - (h.at or 0) <= J.HINT_SECONDS then keep[#keep + 1] = h end
    end
    st.money.hints = keep
end

----------------------------------------------------------------------------------------------------
-- Windows

L.WINDOWS = {
    MERCHANT_SHOW = { "merchant", true }, MERCHANT_CLOSED = { "merchant", false },
    MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
    TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
    AUCTION_HOUSE_SHOW = { "auction", true }, AUCTION_HOUSE_CLOSED = { "auction", false },
    BANKFRAME_OPENED = { "bank", true }, BANKFRAME_CLOSED = { "bank", false },
    TRAINER_SHOW = { "trainer", true }, TRAINER_CLOSED = { "trainer", false },
    TAXIMAP_OPENED = { "taxi", true }, TAXIMAP_CLOSED = { "taxi", false },
    GOSSIP_SHOW = { "gossip", true }, GOSSIP_CLOSED = { "gossip", false },
    LOOT_OPENED = { "loot", true }, LOOT_CLOSED = { "loot", false },
    QUEST_COMPLETE = { "quest", true }, QUEST_FINISHED = { "quest", false },
}

-- The retail client opens NPC windows through the player interaction manager; its old *_CLOSED events don't
-- always fire (the mailbox stayed "open" through a whole vendor visit). Enum.PlayerInteractionType values:
L.INTERACTIONS = { [1] = "trade", [3] = "gossip", [5] = "merchant", [6] = "taxi", [7] = "trainer", [8] = "bank",
    [12] = "merchant", [17] = "mail", [21] = "auction" }
-- You talk to one NPC at a time: opening one of these windows closes the others
L.NPC_WINDOWS = { merchant = true, mail = true, auction = true, bank = true, trainer = true, taxi = true,
    gossip = true }

function L.SetWindow(name, isOpen)
    if isOpen then
        if L.NPC_WINDOWS[name] then
            for other in pairs(L.NPC_WINDOWS) do
                if other ~= name then st.frames[other] = nil end -- closed for good: no grace
            end
        end
        st.frames[name] = true
    elseif st.frames[name] == true then
        st.frames[name] = ns.Clock()
    end
end

function L.OnWindow(event)
    local w = L.WINDOWS[event]
    if not w then return end
    L.SetWindow(w[1], w[2])
end

function L.OnInteraction(isOpen, kind)
    local name = L.INTERACTIONS[number(kind) or -1]
    if name then L.SetWindow(name, isOpen) end
end

----------------------------------------------------------------------------------------------------
-- Quests

local function questTitle(id, index)
    local Q = rawget(_G, "C_QuestLog")
    local info = index and Q and call(Q.GetInfo, index)
    local t = (type(info) == "table" and str(info.title)) or (index and str(call(GetQuestLogTitle, index)))
    if t then return t end
    if Q and id then
        t = str(call(Q.GetTitleForQuestID, id)) or str(call(Q.GetQuestInfo, id))
    end
    return t
end

-- Classic sends (questLogIndex, questID); newer clients (questID)
function L.OnQuestAccepted(a, b)
    local id, index = number(b) or number(a), number(b) and number(a) or nil
    if not id then return end
    local Q = rawget(_G, "C_QuestLog")
    index = index or (Q and number(call(Q.GetLogIndexForQuestID, id)))
    local title = questTitle(id, index)
    st.questTitles[id] = title
    local info = index and Q and call(Q.GetInfo, index)
    local qlevel = (type(info) == "table" and number(info.level)) or (index and number(select(2, call(GetQuestLogTitle, index))))
    L.Log("qa", id, title, qlevel)
    J.Count(ns.db.counts.quests, "accepted", 1, level())
end

function L.OnQuestComplete()
    st.questTitle = str(call(GetTitleText))
end

function L.OnQuestTurnedIn(id, xp, copper)
    id, xp, copper = number(id), number(xp) or 0, number(copper) or 0
    local title = (id and st.questTitles[id]) or st.questTitle or (id and questTitle(id)) or "?"
    if id then st.questTitles[id] = nil end
    st.questTitle = nil
    if id then st.turnedIn[id] = true end
    L.Log("qt", id, xp, copper, title)
    J.Count(ns.db.counts.quests, "done", 1, level())
    local now = ns.Clock()
    if xp > 0 then
        J.Hint(st.xp, { source = "quest", amount = xp, detail = title }, now)
        L.ScheduleXP()
    end
    if copper > 0 then L.MoneyHint({ source = "quest", amount = copper, detail = title }) end
    st.questHintAt = now
end

-- A quest leaving the log without being turned in was abandoned. QUEST_REMOVED and QUEST_TURNED_IN can come
-- in either order, so the check waits a moment.
L.ABANDON_SECONDS = 10 -- an abandon click this recent explains a quest leaving the log

-- The abandon dialog names its quest first (SetAbandonQuest); the confirmation (AbandonQuest) may clear it
function L.OnSetAbandon()
    local Q = rawget(_G, "C_QuestLog")
    local id = Q and number(call(Q.GetAbandonQuest))
    if id and id > 0 then st.abandonTarget = id end
end

-- You confirmed "Abandon": remember which quest (retail names it by id, Classic by title)
function L.OnAbandon()
    local Q = rawget(_G, "C_QuestLog")
    local id = Q and number(call(Q.GetAbandonQuest))
    if not id or id <= 0 then id = st.abandonTarget end
    local title = str(call(GetAbandonQuestName)) or (id and questTitle(id))
    st.abandoning, st.abandonTarget = { id = id, title = title, at = ns.Clock() }, nil
end

-- A quest left the log. Only one you chose to abandon is logged as abandoned: a quest can also leave without a
-- turn-in when it fails or the game removes it.
function L.OnQuestRemoved(id)
    id = number(id)
    if not id then return end
    ns.After(1, function()
        if st.turnedIn[id] then st.turnedIn[id] = nil return end
        local title = st.questTitles[id] or questTitle(id)
        st.questTitles[id] = nil
        local a = st.abandoning
        if not a or ns.Clock() - a.at > L.ABANDON_SECONDS then return end
        if a.id and a.id ~= id then return end
        if not a.id and a.title and title and a.title ~= title then return end
        st.abandoning = nil
        L.Log("qx", id, title)
        J.Count(ns.db.counts.quests, "abandoned", 1, level())
    end)
end

----------------------------------------------------------------------------------------------------
-- Loot, crafting, gathering

L.GATHER = { ["Herb Gathering"] = "Herbalism", ["Herbalism"] = "Herbalism", ["Mining"] = "Mining", ["Skinning"] = "Skinning",
    ["Fishing"] = "Fishing", ["Disenchant"] = "Enchanting" }


----------------------------------------------------------------------------------------------------
-- Players you meet: "pl|name|realm|level|class|race|guild|how|spell", at most once per player, way and spell
-- every L.PLAYER_EVERY seconds. how: target (you targeted them), enemy (an enemy player you targeted or whose
-- nameplate showed), buff (a spell you cast on them), attack (a spell you cast on an enemy player), group.
-- A player you only mouse over is remembered, not logged: UNIT_SPELLCAST_SENT names a spell's target by name
-- only, so a buff cast on someone you moused over can still say who it was.
L.PLAYER_EVERY = 900
L.PLAYERS_MAX = 300
L.SENT_SECONDS = 30

function L.PlayerInfo(unit)
    if not call(UnitIsPlayer, unit) or call(UnitIsUnit, unit, "player") then return nil end
    local name, realm = call(UnitName, unit)
    name = str(name)
    if not name then return nil end
    local _, class = call(UnitClass, unit)
    local _, race = call(UnitRace, unit)
    return { name = name, realm = str(realm), level = number(call(UnitLevel, unit)), class = str(class),
        race = str(race), guild = str((call(GetGuildInfo, unit))), hostile = call(UnitCanAttack, "player", unit) and true or false }
end

-- Remembers the player on unit (target, mouseover, a nameplate, a group member); returns what it learned
function L.SeePlayer(unit)
    local p = L.PlayerInfo(unit)
    if not p then return nil end
    if not st.players[p.name] then
        st.playerCount = st.playerCount + 1
        if st.playerCount > L.PLAYERS_MAX then st.players, st.playerCount = {}, 1 end
    end
    st.players[p.name] = p
    return p
end

function L.MetPlayer(p, how, spell)
    if not (p and ns.db) then return end
    local key = p.name .. "|" .. how .. "|" .. (spell or "")
    local now = ns.Clock()
    if st.met[key] and now - st.met[key] < L.PLAYER_EVERY then return end
    st.met[key] = now
    L.Log("pl", p.name, p.realm, p.level, p.class, p.race, p.guild, how, spell)
    J.Count(ns.db.counts.players, how, 1, level())
end

function L.OnTargetPlayer()
    local p = L.SeePlayer("target")
    if p then L.MetPlayer(p, p.hostile and "enemy" or "target") end
end

function L.OnNameplate(unit)
    local p = L.SeePlayer(unit)
    if p and p.hostile then L.MetPlayer(p, "enemy") end
end

function L.OnGroup()
    local n = number(call(GetNumGroupMembers)) or 0
    local raid = call(IsInRaid)
    for i = 1, n do
        local p = L.SeePlayer((raid and "raid" or "party") .. i)
        if p then L.MetPlayer(p, "group") end
    end
end

-- UNIT_SPELLCAST_SENT: unit, target name, cast GUID, spell
function L.OnSpellSent(unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    target, castGUID = str(target), str(castGUID)
    if not (target and castGUID) then return end
    local now = ns.Clock()
    for k, s in pairs(st.sent) do if now - s.at > L.SENT_SECONDS then st.sent[k] = nil end end
    st.sent[castGUID] = { name = target:match("^([^%-]+)") or target, spell = number(spellID), at = now }
end

function L.OnSpellcast(unit, castGUID, spellID)
    if unit ~= "player" then return end
    local sent = str(castGUID) and st.sent[castGUID]
    if sent then
        st.sent[castGUID] = nil
        local p = st.players[sent.name]
        if p then L.MetPlayer(p, p.hostile and "attack" or "buff", spellName(number(spellID) or sent.spell)) end
    end
    local name = spellName(number(spellID))
    if not name or name:match("^%u+$") then return end -- LOGINEFFECT and other internal casts
    J.Count(ns.db.counts.spells, name)
    local prof = L.GATHER[name]
    if prof then st.gather = { prof = prof, at = ns.Clock() } end
end

function L.OnLootOpened()
    L.OnWindow("LOOT_OPENED")
    if call(IsFishingLoot) then
        st.lootKind = "Fishing"
    elseif st.gather and ns.Clock() - st.gather.at <= 6 then
        st.lootKind = st.gather.prof
    else
        st.lootKind = nil
    end
    st.gather = nil
end

function L.OnLootClosed()
    L.OnWindow("LOOT_CLOSED")
    st.lootClosedAt = ns.Clock()
end

function L.OnTradeSkill()
    local ui = rawget(_G, "C_TradeSkillUI")
    local info = ui and (call(ui.GetBaseProfessionInfo) or call(ui.GetChildProfessionInfo))
    local name = (type(info) == "table" and str(info.professionName) or nil)
        or str(call(GetTradeSkillLine)) or str(call(GetCraftDisplaySkillLine))
    if name then st.tradeSkill = { name = name, at = ns.Clock() } end
end

local function lootHow(how)
    if how == "created" then return "made" end
    if how == "won" then return "roll" end
    if how == "loot" then return "loot" end
    if open("mail") then
        return (st.mailBought and ns.Clock() - st.mailBought <= 3) and "bought" or "mail"
    end
    if open("merchant") then return "bought" end
    if open("trade") then return "trade" end
    if open("quest") or (st.questHintAt and ns.Clock() - st.questHintAt <= 3) then return "quest" end
    if open("auction") then return "auction" end
    return "other"
end

function L.OnLoot(text)
    if not str(text) then return end
    local link, count, how = J.ParseLoot(text, P().loot)
    if not link then return end
    local id, name, quality = J.ParseItemLink(link)
    if not id then return end
    quality = quality or number(C_Item and call(C_Item.GetItemQualityByID, id))
    local kind = lootHow(how)
    L.Log("lo", id, quality, nil, kind, name, count)
    local counts, lvl = ns.db.counts, level()
    J.Count(counts.character, "loot:" .. kind, count)
    if kind == "made" then
        local prof = st.tradeSkill and st.tradeSkill.name or "?"
        J.Count(counts.prof, (prof == "Cooking" and "cooked" or "made") .. "|" .. (name or id) .. "|" .. prof, count)
    elseif kind == "loot" and st.lootKind then
        local verb = st.lootKind == "Fishing" and "caught" or "gathered"
        J.Count(counts.prof, verb .. "|" .. (name or id) .. "|" .. st.lootKind, count)
        if verb == "gathered" then L.Log("ga", st.lootKind, id, name, count) end
    end
    if lvl then J.Count(counts.character, "items", count, lvl) end
end

----------------------------------------------------------------------------------------------------
-- Skills

-- Forever runs the retail API: GetProfessions / GetProfessionInfo. GetSkillLineInfo (Classic) is a fallback.
-- Weapon skills only reach us through CHAT_MSG_SKILL (L.OnSkillLine).
function L.SkillList()
    local list = {}
    if type(GetProfessions) == "function" then
        -- prof1, prof2, archaeology, fishing, cooking, first aid: missing ones are nil, so not ipairs
        local idx = { call(GetProfessions) }
        for i = 1, 6 do
            local name, _, rank, max = call(GetProfessionInfo, idx[i])
            if idx[i] and str(name) and number(rank) then
                list[#list + 1] = { name = name, rank = rank, max = number(max) }
            end
        end
    end
    local n = number(call(GetNumSkillLines))
    for i = 1, n or 0 do
        local name, header, _, rank, _, _, max = call(GetSkillLineInfo, i)
        if str(name) and not header and number(rank) then
            list[#list + 1] = { name = name, rank = rank, max = number(max) }
        end
    end
    return list
end

function L.OnSkills()
    local list = L.SkillList()
    for _, s in ipairs(J.SkillChanges(ns.db.skills, list)) do
        L.Log("sk", s.name, s.rank, s.max)
    end
end

-- "Your skill in Defense has increased to 112." (the max stays what was seen last)
function L.OnSkillLine(text)
    if not str(text) then return end
    local p = J.FormatToPattern(rawget(_G, "SKILL_RANK_UP")) or "^Your skill in (.+) has increased to (%d+)"
    local name, rank = text:match(p)
    if not name then name, rank = text:match("^Your skill in (.+) has increased to (%d+)") end
    rank = tonumber(rank)
    if not (name and rank) then return end
    local max = tonumber((ns.db.skills[name] or ""):match("/(%d+)$"))
    if max == 0 then max = nil end -- "rank/0": the max was never known
    for _, s in ipairs(J.SkillChanges(ns.db.skills, { { name = name, rank = rank, max = max } })) do
        L.Log("sk", s.name, s.rank, s.max)
    end
end

----------------------------------------------------------------------------------------------------
-- Fights and deaths

function L.OnCombatStart()
    st.fight = { start = ns.Clock(), minHealth = 1 }
    st.lastFoe = nil
    L.Learn("target")
end

function L.OnCombatEnd()
    local f = st.fight
    st.fight = nil
    L.ScheduleMeter()
    if not f then return end
    J.EndFight(ns.db.counts, f, ns.Clock(), f.died)
end

function L.OnHealth(unit)
    if unit ~= "player" or not st.fight then return end
    local hp, max = number(call(UnitHealth, "player")), number(call(UnitHealthMax, "player"))
    if hp and max and max > 0 then
        local r = hp / max
        if r < st.fight.minHealth then st.fight.minHealth = r end
    end
end

function L.OnMirrorTimer(timer, ...)
    if timer == "BREATH" then st.env = "drowning" elseif timer == "EXHAUSTION" then st.env = "fatigue" end
end

-- "de|killer|npc|spell|env|place|boss|klevel|kclass|amount|byPlayer"
function L.OnDead()
    local db = ns.db
    local inside, kind = call(IsInInstance)
    local place = (inside and kind and kind ~= "none") and kind or "world"
    local foe = st.lastFoe
    if foe and ns.Clock() - foe.at > 30 then foe = nil end
    if not foe then
        local name = str(call(UnitName, "target"))
        if name and call(UnitCanAttack, "player", "target") then foe = { name = name, info = L.Learn("target") or {} } end
    end
    local info = foe and foe.info or {}
    local env = (not foe) and st.env or nil
    L.Log("de", foe and foe.name, info.npc, nil, env, place, nil, info.level, info.class, nil,
        info.player and 1 or nil)
    local d = db.counts.deaths
    J.Count(d, "total", 1, level())
    J.Count(d, place == "world" and "world" or "dungeon")
    if env then J.Count(d, "env." .. env) end
    if info.player then J.Count(d, "player") end
    if st.fight then st.fight.died = true end
    st.wasDead = "corpse"
end

-- PLAYER_ALIVE: back from a spirit healer, or released to a ghost; PLAYER_UNGHOST: back at the corpse
function L.OnAlive()
    if not st.wasDead then return end
    if call(UnitIsGhost, "player") then return end
    J.Count(ns.db.counts.deaths, "revive." .. (st.spiritHealer and "spirit" or "other"))
    st.wasDead, st.spiritHealer = nil, nil
end

function L.OnUnghost()
    if not st.wasDead then return end
    J.Count(ns.db.counts.deaths, "revive." .. (st.spiritHealer and "spirit" or "corpse"))
    st.wasDead, st.spiritHealer = nil, nil
end

----------------------------------------------------------------------------------------------------
-- Damage meter
-- C_DamageMeter keeps a session per fight. Its numbers are secret during combat, so each finished session is
-- read after you leave combat: your damage, damage taken and healing, per spell and per attacker, how many
-- enemies you hit, and the hit that killed you ("isDeadly"). Sessions are read oldest first and once each.

local function meterType(name, fallback)
    local e = Enum and Enum.DamageMeterType
    return (e and number(e[name])) or fallback
end

-- A copy of a meter table without secret values (and without anything past a few levels deep)
local function clean(v, depth)
    if secret(v) then return nil end
    if type(v) ~= "table" then return v end
    depth = depth or 0
    if depth > 4 then return nil end
    local out = {}
    for k, x in pairs(v) do
        if not secret(k) then out[k] = clean(x, depth + 1) end
    end
    return out
end

-- Session ids the meter has, oldest first, with their durations: { { id, seconds } }
function L.MeterSessions()
    local DM = C_DamageMeter
    local list = DM and clean(call(DM.GetAvailableCombatSessions))
    local out = {}
    for _, s in ipairs(type(list) == "table" and list or {}) do
        if type(s) == "table" and type(s.sessionID) == "number" then
            out[#out + 1] = { id = s.sessionID, seconds = number(s.durationSeconds) }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- At login: what the meter can do, and which sessions are already there (not ours to count)
function L.InitMeter()
    local DM = C_DamageMeter
    if not DM then ns.db.meter = { available = false, reason = "no C_DamageMeter" } return end
    local ok, reason = call(DM.IsDamageMeterAvailable)
    ns.db.meter = { available = ok == true, reason = str(reason) }
    local list = L.MeterSessions()
    st.meterLast = list[#list] and list[#list].id or 0
end

function L.ScheduleMeter()
    if st.meterReading or not C_DamageMeter then return end
    st.meterReading = true
    ns.After(L.METER_DELAY, function()
        st.meterReading = nil
        L.ReadMeter()
    end)
end

-- "fi|seconds|damage|taken|healed|enemies|worstMob|worstAmount|killer|killSpell"
function L.ReadMeter()
    local DM, db = C_DamageMeter, ns.db
    if not DM or not db then return end
    if call(UnitAffectingCombat, "player") then return end -- back in combat: secret again, read after this one
    local guid = str(call(UnitGUID, "player"))
    local DONE, TAKEN, HEALED, ENEMIES = meterType("DamageDone", 0), meterType("DamageTaken", 7),
        meterType("HealingDone", 2), meterType("EnemyDamageTaken", 10)
    for _, s in ipairs(L.MeterSessions()) do
        if s.id > (st.meterLast or 0) then
            local function session(kind) return clean(call(DM.GetCombatSessionFromID, s.id, kind)) end
            local function source(kind)
                return guid and clean(call(DM.GetCombatSessionSourceFromID, s.id, kind, guid)) or nil
            end
            local done = session(DONE)
            local f = J.MeterFight({
                seconds = s.seconds or (done and number(done.durationSeconds)),
                done = done, taken = session(TAKEN), healed = session(HEALED), enemies = session(ENEMIES),
                spells = source(DONE), hits = source(TAKEN), spellName = spellName,
            })
            db.meterSample = nil -- left by an earlier version
            st.meterLast = s.id
            if f then
                f.seconds = f.seconds and floor(f.seconds + 0.5) or nil
                J.CountDamage(db.counts, f, level())
                L.Log("fi", f.seconds, f.done, f.taken, f.healed, f.enemies, f.worst, f.worstAmount, f.killer,
                    f.killSpell)
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Flights
-- Picking a destination at the flight master notes the route and fare; the flight starts when you're on the
-- taxi and ends when you're off it (PLAYER_CONTROL_LOST / _GAINED, and the 5-second tick as a fallback).
-- The flight in progress is kept in the saved data, so a /reload in the air doesn't lose it.
-- "fl|from|to|copper|seconds|via" (via: the stops on the way, "A;B", from the flight map's route)

L.TAKEOFF_SECONDS = 15 -- a route picked this long ago without taking off was cancelled

function L.CurrentTaxiNode()
    for i = 1, number(call(NumTaxiNodes)) or 0 do
        if call(TaxiNodeGetType, i) == "CURRENT" then return str(call(TaxiNodeName, i)) end
    end
    return nil
end

-- The stops between here and node i: the route is a chain of hops, each ending at a node; all but the last
-- hop end at a stop
function L.TaxiStops(i)
    local stops = {}
    local hops = number(call(GetNumRoutes, i)) or 0
    for hop = 1, hops - 1 do
        local slot = number(call(TaxiGetNodeSlot, i, hop, false))
        local name = slot and str(call(TaxiNodeName, slot))
        if name then stops[#stops + 1] = name end
    end
    return #stops > 0 and table.concat(stops, ";") or nil
end

function L.OnTakeTaxi(i)
    local to = str(call(TaxiNodeName, i))
    L.MoneyHint({ source = "flight", sign = -1, detail = to })
    if ns.db then
        ns.db.flying = { from = L.CurrentTaxiNode(), to = to, via = L.TaxiStops(i), cost = number(call(TaxiNodeCost, i)),
            asked = ns.Now() }
    end
end

function L.CheckFlight()
    local db = ns.db
    local f = db and db.flying
    if not f then return end
    local onTaxi = call(UnitOnTaxi, "player") and true or false
    local now = ns.Now()
    if not f.start then
        if onTaxi then
            f.start = now
        elseif now - (f.asked or now) > L.TAKEOFF_SECONDS then
            db.flying = nil
        end
        return
    end
    if onTaxi then return end
    db.flying = nil
    local sec = math.max(0, now - f.start)
    L.Log("fl", f.from, f.to, f.cost, sec, f.via)
    local c, lvl = db.counts.flights, level()
    J.Count(c, "n", 1, lvl)
    J.Count(c, "sec", sec, lvl)
    if f.cost then J.Count(c, "copper", f.cost, lvl) end
    J.Max(c, "longest", sec)
end

-- At login: a flight you're still on carries on; one that ended while the game was closed is dropped
function L.ResumeFlight()
    local db = ns.db
    if db and db.flying and not call(UnitOnTaxi, "player") then db.flying = nil end
end

----------------------------------------------------------------------------------------------------
-- Auction house and mail

-- An AH action waiting for its money change: { act = "post" | "buyout" | "bid", detail = "Item xN" }
function L.AHAction(act, name, count)
    if not name then return end
    L.MoneyHint({ source = "auction", detail = J.ItemQty(name, count), sign = -1, ah = act })
end

function L.OnSystem(text)
    if not str(text) then return end
    local p = P()
    local zone, xp = J.ParseDiscover(text, p.discover)
    if zone then
        J.Hint(st.xp, { source = "discover", amount = xp, detail = zone }, ns.Clock())
        L.ScheduleXP()
        return
    end
    local item = p.expired and text:match(p.expired) or text:match("^Your auction of (.+) has expired")
    if item then
        L.Log("ah", "expired", nil, item)
        J.Count(ns.db.counts.auction, "expired")
        return
    end
    item = p.sold and text:match(p.sold) or text:match("^A buyer has been found for your auction of (.+)%.")
    if item then
        J.Count(ns.db.counts.auction, "soldNotice")
    end
end

local function invoiceItem(index)
    local kind, item, player, bid, buyout, deposit, consignment = call(GetInboxInvoiceInfo, index)
    return str(kind), str(item), str(player), number(bid), number(buyout), number(deposit), number(consignment)
end

-- Taking money (or the whole letter) from the mailbox: "ma|invoice|player|copper|Item xN" for AH letters, and a
-- money hint so the change is filed under auction or mail with the item
function L.OnTakeMail(index)
    if not ns.db then return end
    local _, _, sender, subject, money = call(GetInboxHeaderInfo, index)
    money = number(money) or 0
    sender, subject = str(sender), str(subject)
    local kind, item, player = invoiceItem(index)
    local _, count = J.ParseMailSubject(subject)
    if kind == "seller" and item then
        -- The mailbox's open-all calls this again and again until the gold arrives, and the buyer's name can
        -- appear only on a later call. The sale is logged once, when its gold comes in (FlushMoney).
        local what = J.ItemQty(item, count)
        if money > 0 then
            for _, h in ipairs(st.money.hints) do
                if h.sold and not h.used and h.amount == money and h.detail == what and not h.sold.player then
                    h.sold.player = player
                end
            end
            L.MoneyHint({ source = "auction", amount = money, detail = what, sold = { player = player } })
        end
    elseif kind == "buyer" and item then
        st.mailBought = ns.Clock()
        L.Log("ma", "invoice", player or "?", nil, J.ItemQty(item, count))
    elseif money > 0 then
        L.MoneyHint({ source = "mail", amount = money, detail = sender })
    end
    local items = number(select(8, call(GetInboxHeaderInfo, index))) or 0
    if items > 0 and kind ~= "buyer" then
        for a = 1, 16 do
            local name, _, _, n = call(GetInboxItem, index, a)
            if str(name) then L.Log("ma", "take", sender, nil, J.ItemQty(name, number(n))) end
        end
    end
end

function L.OnTakeMailItem(index, attachment)
    if not ns.db then return end
    -- an item you won or bought on the AH arrives with a "buyer" invoice: it was bought, not sent to you
    local kind, _, seller = invoiceItem(index)
    st.mailBought = kind == "buyer" and ns.Clock() or nil
    local _, _, sender = call(GetInboxHeaderInfo, index)
    local name, _, _, n = call(GetInboxItem, index, attachment)
    if not str(name) then return end
    if kind == "buyer" then
        L.Log("ma", "invoice", seller or "?", nil, J.ItemQty(name, number(n)))
    else
        L.Log("ma", "take", str(sender), nil, J.ItemQty(name, number(n)))
    end
end

function L.OnSendMail(to)
    if not ns.db then return end
    to = str(to)
    for a = 1, 16 do
        local name, _, _, n = call(GetSendMailItem, a)
        if str(name) then L.Log("ma", "send", to, nil, J.ItemQty(name, number(n))) end
    end
    L.MoneyHint({ source = "postage", sign = -1, detail = to })
    J.Count(ns.db.counts.character, "mailSent")
end

-- Selling to a vendor: the item is still in the slot (locked) when the hook runs
function L.OnUseContainerItem(bag, slot)
    if not open("merchant") then return end
    local name, count, link
    if C_Container and C_Container.GetContainerItemInfo then
        local info = call(C_Container.GetContainerItemInfo, bag, slot)
        if type(info) == "table" then
            count = number(info.stackCount)
            link = str(info.hyperlink)
            local _, iname = J.ParseItemLink(link)
            name = iname
        end
    else
        local _, n, _, _, _, _, l = call(GetContainerItemInfo, bag, slot)
        count, link = number(n), str(l)
        local _, iname = J.ParseItemLink(link)
        name = iname
    end
    if not name then return end
    -- with the item's sell price the hint names its exact amount, so a fast run of sales can't swap names
    local price = number(select(11, call((C_Item and C_Item.GetItemInfo) or GetItemInfo, link)))
    if price == 0 then return end -- can't be sold: no money is coming
    L.MoneyHint({ source = "vendor", sign = 1, amount = price and price * (count or 1) or nil,
        detail = J.ItemQty(name, count) })
end

-- The item's name at a merchant slot: C_MerchantFrame.GetItemInfo (retail 11+), the old GetMerchantItemInfo, or
-- the slot's link
function L.MerchantItemName(index)
    local info = C_MerchantFrame and call(C_MerchantFrame.GetItemInfo, index)
    local name = type(info) == "table" and str(info.name)
    if not name then name = str(call(GetMerchantItemInfo, index)) end
    if not name then
        local link = str(call(GetMerchantItemLink, index))
        name = link and select(2, J.ParseItemLink(link))
    end
    return name
end

function L.OnBuyMerchant(index, qty)
    local name = L.MerchantItemName(index)
    L.MoneyHint({ source = "vendor", sign = -1, detail = name and J.ItemQty(name, number(qty)) or nil })
end

local function itemNameByID(id)
    if C_Item and C_Item.GetItemNameByID then return str(call(C_Item.GetItemNameByID, id)) end
    return str(call(GetItemInfo, id))
end

-- The hooks: run after the client's own function (hooksecurefunc never taints)
function L.Hook()
    if L.hooked or type(hooksecurefunc) ~= "function" then return end
    L.hooked = true
    local function hook(tbl, name, fn)
        if tbl then
            if type(tbl[name]) == "function" then pcall(hooksecurefunc, tbl, name, fn) end
        elseif type(rawget(_G, name)) == "function" then
            pcall(hooksecurefunc, name, fn)
        end
    end
    local function safely(fn) return function(...) pcall(fn, ...) end end
    hook(nil, "RepairAllItems", safely(function() L.MoneyHint({ source = "repair", sign = -1 }) end))
    hook(nil, "TakeTaxiNode", safely(L.OnTakeTaxi))
    hook(nil, "ConfirmTalentWipe", safely(function()
        L.MoneyHint({ source = "respec", sign = -1 })
        J.Count(ns.db.counts.character, "respecs")
    end))
    hook(nil, "BuyMerchantItem", safely(L.OnBuyMerchant))
    if C_QuestLog and type(C_QuestLog.AbandonQuest) == "function" then
        hook(C_QuestLog, "SetAbandonQuest", safely(L.OnSetAbandon))
        hook(C_QuestLog, "AbandonQuest", safely(L.OnAbandon))
    else
        hook(nil, "AbandonQuest", safely(L.OnAbandon))
    end
    hook(nil, "TakeInboxMoney", safely(L.OnTakeMail))
    hook(nil, "AutoLootMailItem", safely(L.OnTakeMail))
    hook(nil, "TakeInboxItem", safely(L.OnTakeMailItem))
    hook(nil, "SendMail", safely(L.OnSendMail))
    if C_Container and type(C_Container.UseContainerItem) == "function" then
        hook(C_Container, "UseContainerItem", safely(L.OnUseContainerItem))
    else
        hook(nil, "UseContainerItem", safely(L.OnUseContainerItem))
    end
    -- legacy AH
    hook(nil, "PostAuction", safely(function(_, _, _, stack, stacks)
        local name, _, count = call(GetAuctionSellItemInfo)
        L.AHAction("post", str(name), (number(stack) or number(count) or 1) * (number(stacks) or 1))
    end))
    hook(nil, "PlaceAuctionBid", safely(function(list, index, bid)
        local name, _, count, _, _, _, _, _, _, buyout = call(GetAuctionItemInfo, list, index)
        L.AHAction((number(buyout) and bid == buyout) and "buyout" or "bid", str(name), number(count))
    end))
    -- modern AH
    local AH = rawget(_G, "C_AuctionHouse")
    if AH then
        local function located(loc)
            local id = C_Item and number(call(C_Item.GetItemID, loc))
            return (C_Item and str(call(C_Item.GetItemName, loc))) or (id and itemNameByID(id))
        end
        hook(AH, "PostItem", safely(function(loc, _, qty) L.AHAction("post", located(loc), number(qty)) end))
        hook(AH, "PostCommodity", safely(function(loc, _, qty) L.AHAction("post", located(loc), number(qty)) end))
        hook(AH, "ConfirmCommoditiesPurchase", safely(function(id, qty)
            L.AHAction("buyout", itemNameByID(id), number(qty))
        end))
        hook(AH, "PlaceBid", safely(function(auctionID)
            local info = call(AH.GetAuctionInfoByID, auctionID)
            local key = type(info) == "table" and info.itemKey
            local name = key and key.itemID and itemNameByID(key.itemID)
            L.AHAction("buyout", name, type(info) == "table" and number(info.quantity) or 1)
        end))
    end
end

----------------------------------------------------------------------------------------------------
-- Events

function L.OnLogin()
    L.InitDB()
    L.Identity()
    L.ImportBaseline()
    L.ImportHistory()
    L.ResumeFlight()
    st.lastMoney = number(call(GetMoney))
    st.lastXP, st.lastXPMax, st.xpLevel = number(call(UnitXP, "player")), number(call(UnitXPMax, "player")), level()
    L.Hook()
    L.InitMeter()
    L.RequestPlayed()
    L.UpdateAccount()
    if C_Timer and C_Timer.NewTicker and not L.ticker then
        L.ticker = C_Timer.NewTicker(L.TICK, function() pcall(L.Tick) end)
    end
end

function L.OnEnteringWorld(isLogin, isReload)
    if not ns.db then L.OnLogin() end
    if not st.started then
        L.StartSession((isReload and "reload") or "login")
        L.OnSkills()
    else
        L.OnZone()
    end
end

local handlers = {
    PLAYER_LOGIN = L.OnLogin,
    PLAYER_ENTERING_WORLD = L.OnEnteringWorld,
    PLAYER_LOGOUT = L.OnLogout,
    TIME_PLAYED_MSG = L.OnTimePlayed,
    ZONE_CHANGED_NEW_AREA = L.OnZone,
    PLAYER_XP_UPDATE = L.OnXPUpdate,
    PLAYER_LEVEL_UP = L.OnLevelUp,
    CHAT_MSG_COMBAT_XP_GAIN = L.OnCombatXP,
    CHAT_MSG_SYSTEM = L.OnSystem,
    CHAT_MSG_LOOT = L.OnLoot,
    CHAT_MSG_SKILL = L.OnSkillLine,
    CHAT_MSG_MONEY = function() L.MoneyHint({ source = "loot", sign = 1 }) end,
    PLAYER_MONEY = L.OnMoney,
    QUEST_ACCEPTED = L.OnQuestAccepted,
    QUEST_COMPLETE = function() L.OnWindow("QUEST_COMPLETE"); L.OnQuestComplete() end,
    QUEST_TURNED_IN = L.OnQuestTurnedIn,
    QUEST_REMOVED = L.OnQuestRemoved,
    SKILL_LINES_CHANGED = L.OnSkills,
    PLAYER_REGEN_DISABLED = L.OnCombatStart,
    PLAYER_REGEN_ENABLED = L.OnCombatEnd,
    UNIT_HEALTH = L.OnHealth,
    PLAYER_TARGET_CHANGED = function() L.Learn("target"); L.OnTargetPlayer() end,
    UPDATE_MOUSEOVER_UNIT = function() L.Learn("mouseover"); L.SeePlayer("mouseover") end,
    NAME_PLATE_UNIT_ADDED = function(unit) L.Learn(unit); L.OnNameplate(unit) end,
    GROUP_ROSTER_UPDATE = L.OnGroup,
    UNIT_SPELLCAST_SENT = L.OnSpellSent,
    PLAYER_DEAD = L.OnDead,
    PLAYER_ALIVE = L.OnAlive,
    PLAYER_UNGHOST = L.OnUnghost,
    CONFIRM_XP_LOSS = function() st.spiritHealer = true end,
    MIRROR_TIMER_START = L.OnMirrorTimer,
    MIRROR_TIMER_STOP = function() st.env = nil end,
    UNIT_SPELLCAST_SUCCEEDED = L.OnSpellcast,
    LOOT_OPENED = L.OnLootOpened,
    LOOT_CLOSED = L.OnLootClosed,
    TRADE_SKILL_SHOW = function() L.OnTradeSkill() end,
    TRADE_SKILL_UPDATE = function() L.OnTradeSkill() end,
    CRAFT_SHOW = function() L.OnTradeSkill() end,
    DAMAGE_METER_RESET = function() st.meterLast = 0 end,
    PLAYER_CONTROL_LOST = function() L.CheckFlight() end,
    PLAYER_CONTROL_GAINED = function() L.CheckFlight() end,
    PLAYER_INTERACTION_MANAGER_FRAME_SHOW = function(kind) L.OnInteraction(true, kind) end,
    PLAYER_INTERACTION_MANAGER_FRAME_HIDE = function(kind) L.OnInteraction(false, kind) end,
}
for event in pairs(L.WINDOWS) do
    if not handlers[event] then handlers[event] = function() L.OnWindow(event) end end
end
L.handlers = handlers

local frame = CreateFrame("Frame")
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event) -- an event this client doesn't have raises an error
end
frame:SetScript("OnEvent", function(_, event, ...)
    if event ~= "PLAYER_LOGIN" and event ~= "PLAYER_ENTERING_WORLD" and not ns.db then return end
    local ok, err = pcall(handlers[event], ...)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)
L.frame = frame

----------------------------------------------------------------------------------------------------
-- /logbook

SLASH_LOGBOOK1 = "/logbook"
SlashCmdList.LOGBOOK = function()
    local db = ns.db
    if not db then return end
    local base = db.baseline and (" Carried on from " .. db.baseline.from .. "'s counters.") or ""
    ns.Print(("%d lines since %s, %d sessions, %d trail chunks.%s"):format(#db.log,
        date and date("%d %b %Y", db.since) or tostring(db.since), #db.sessions, #db.trail.chunks, base))
    if db.history then
        ns.Print(("Kept %d of %s's older lines and %d sessions: its files are safe to delete."):format(
            #db.history.log, db.history.from, #db.history.sessions))
    end
    local m, d = db.meter or {}, db.counts.damage or {}
    ns.Print(m.available and ("Damage meter: %d fights read."):format(d.fights or 0)
        or ("Damage meter unavailable (%s)."):format(m.reason or "unknown"))
end
