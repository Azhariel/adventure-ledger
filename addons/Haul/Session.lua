-- Session: pure bookkeeping for one farming session. No WoW calls; every function takes `now`
-- (seconds, e.g. time()) explicitly so it can be tested.
local _, ns = ...

local Session = {}
ns.Session = Session

local floor, max, min = math.floor, math.max, math.min

Session.AFK_LEAD = 300       -- the game flags you AFK after 5 idle minutes; that idle time is excluded too
Session.HISTORY_LIMIT = 30
Session.AH_CUT = 0.95

-- New session. level/xp/xpMax are the player's values at the start (any may be nil).
function Session.New(now, level, xp, xpMax)
    return {
        start = now,
        elapsed = 0,          -- active seconds banked before runningSince
        runningSince = now,   -- nil while paused
        pauseReason = nil,
        lastActivity = now,
        money = { loot = 0, quest = 0 },
        itemValue = 0,
        items = {},           -- [itemID] = { count, value, pending, link }
        xp = 0,
        level = level,
        lastXP = xp,
        lastXPMax = xpMax,
        zones = {},           -- [name] = { time, value }
        zone = nil,
        zoneSince = nil,
    }
end

function Session.IsPaused(s)
    return s.runningSince == nil
end

-- Active (unpaused) seconds so far
function Session.Elapsed(s, now)
    if s.runningSince then
        return s.elapsed + max(0, now - s.runningSince)
    end
    return s.elapsed
end

-- Moves the time spent in the current zone into its bucket, up to `now`.
local function flushZone(s, now)
    if s.zone and s.zoneSince and s.runningSince then
        local z = s.zones[s.zone]
        z.time = z.time + max(0, now - max(s.zoneSince, s.runningSince))
    end
    s.zoneSince = now
end

function Session.SetZone(s, now, name)
    if not name or name == "" then
        return
    end
    flushZone(s, now)
    s.zone = name
    s.zones[name] = s.zones[name] or { time = 0, value = 0 }
end

function Session.Touch(s, now)
    s.lastActivity = now
end

-- Pauses the clock. For "afk", the idle time before the AFK flag (up to AFK_LEAD, back to the last
-- activity) is excluded as well.
function Session.Pause(s, now, reason)
    if not s.runningSince then
        return
    end
    local stopAt = now
    if reason == "afk" then
        stopAt = max(s.runningSince, s.lastActivity or now, now - Session.AFK_LEAD)
        stopAt = min(stopAt, now)
    end
    flushZone(s, stopAt)
    s.elapsed = s.elapsed + max(0, stopAt - s.runningSince)
    s.runningSince = nil
    s.pauseReason = reason or "manual"
end

function Session.Resume(s, now)
    if s.runningSince then
        return
    end
    s.runningSince = now
    s.zoneSince = now
    s.pauseReason = nil
    s.lastActivity = now
end

local function addZoneValue(s, copper)
    if s.zone and s.zones[s.zone] then
        s.zones[s.zone].value = s.zones[s.zone].value + copper
    end
end

-- kind: "loot" (coin from mobs/chests) or "quest"
function Session.AddMoney(s, now, kind, copper)
    if type(copper) ~= "number" or copper <= 0 or not s.money[kind] then
        return
    end
    s.money[kind] = s.money[kind] + copper
    addZoneValue(s, copper)
    s.lastActivity = now
end

-- Value of one item: AH after the cut or the vendor price, whichever is higher. 0 when neither exists.
function Session.ItemValue(ahPrice, vendorPrice)
    local ah = (ahPrice and ahPrice > 0) and floor(ahPrice * Session.AH_CUT) or 0
    local vendor = (vendorPrice and vendorPrice > 0) and vendorPrice or 0
    return max(ah, vendor)
end

-- unitValue may be nil (item data not loaded yet): the item is recorded as pending and valued later.
function Session.AddItem(s, now, itemID, count, unitValue, link)
    if type(itemID) ~= "number" or type(count) ~= "number" or count <= 0 then
        return
    end
    local it = s.items[itemID]
    if not it then
        it = { count = 0, value = 0, unit = nil, link = link }
        s.items[itemID] = it
    end
    it.count = it.count + count
    it.link = it.link or link
    if unitValue then
        local v = unitValue * count
        it.unit = unitValue
        it.value = it.value + v
        s.itemValue = s.itemValue + v
        addZoneValue(s, v)
    else
        it.pendingCount = (it.pendingCount or 0) + count
        it.pendingZone = it.pendingZone or s.zone
    end
    s.lastActivity = now
end

-- Values items that were looted before their data was known. Returns true if anything changed.
function Session.Revalue(s, itemID, unitValue)
    local it = s.items[itemID]
    if not (it and it.pendingCount and unitValue) then
        return false
    end
    local v = unitValue * it.pendingCount
    it.unit = unitValue
    it.value = it.value + v
    s.itemValue = s.itemValue + v
    local z = it.pendingZone and s.zones[it.pendingZone]
    if z then
        z.value = z.value + v
    end
    it.pendingCount, it.pendingZone = nil, nil
    return true
end

-- Item IDs still waiting for a value
function Session.PendingItems(s)
    local ids = {}
    for id, it in pairs(s.items) do
        if it.pendingCount then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

-- XP gained since the last update, handling level-ups: the rest of the old level counts plus the new xp.
-- Returns the gained amount.
function Session.XPUpdate(s, now, xp, xpMax, level)
    if type(xp) ~= "number" then
        return 0
    end
    local gained = 0
    local levelUp = level and s.level and level > s.level
    if s.lastXP == nil then
        gained = 0
    elseif levelUp or xp < s.lastXP then
        -- XP only goes down on a level-up; the client may report the new XP before the new level
        gained = max(0, (s.lastXPMax or s.lastXP) - s.lastXP) + xp
        if not levelUp and s.level then
            s.level = s.level + 1 -- so the level change arriving next isn't counted again
        end
    else
        gained = max(0, xp - s.lastXP)
    end
    s.xp = s.xp + gained
    s.lastXP, s.lastXPMax = xp, xpMax or s.lastXPMax
    if level and (not s.level or level > s.level) then
        s.level = level
    end
    if gained > 0 then
        s.lastActivity = now
    end
    return gained
end

function Session.Total(s)
    return s.money.loot + s.money.quest + s.itemValue
end

-- Amount per hour; nil until at least a minute of active time, so the first kills don't show silly rates.
Session.MIN_RATE_SECONDS = 60
function Session.PerHour(amount, seconds)
    if not seconds or seconds < Session.MIN_RATE_SECONDS then
        return nil
    end
    return amount * 3600 / seconds
end

-- Seconds until the next level at the current XP rate; nil when unknown or no XP is coming in.
function Session.TimeToLevel(s, now)
    local rate = Session.PerHour(s.xp, Session.Elapsed(s, now))
    if not rate or rate <= 0 or not s.lastXP or not s.lastXPMax then
        return nil
    end
    return max(0, s.lastXPMax - s.lastXP) / rate * 3600
end

-- Items sorted by total value (highest first), at most `limit`
function Session.TopItems(s, limit)
    local list = {}
    for id, it in pairs(s.items) do
        list[#list + 1] = { itemID = id, count = it.count, value = it.value, link = it.link,
            pending = it.pendingCount ~= nil }
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end
        return a.itemID < b.itemID
    end)
    for i = #list, (limit or #list) + 1, -1 do
        list[i] = nil
    end
    return list
end

-- Zones with time and gold per hour, best rate first. Time includes the current zone up to `now`.
function Session.ZoneRates(s, now)
    local list = {}
    for name, z in pairs(s.zones) do
        local t = z.time
        if name == s.zone and s.runningSince and s.zoneSince then
            t = t + max(0, now - max(s.zoneSince, s.runningSince))
        end
        list[#list + 1] = { zone = name, time = t, value = z.value, perHour = Session.PerHour(z.value, t) }
    end
    table.sort(list, function(a, b)
        local ra, rb = a.perHour or -1, b.perHour or -1
        if ra ~= rb then
            return ra > rb
        end
        return a.zone < b.zone
    end)
    return list
end

-- Compact record for the saved history
function Session.Summary(s, now)
    local zones = {}
    for i, z in ipairs(Session.ZoneRates(s, now)) do
        if i > 3 then
            break
        end
        zones[i] = { zone = z.zone, time = floor(z.time), value = floor(z.value) }
    end
    return {
        start = s.start,
        duration = floor(Session.Elapsed(s, now)),
        loot = s.money.loot,
        quest = s.money.quest,
        items = floor(s.itemValue),
        xp = s.xp,
        zones = zones,
    }
end

-- Adds a record (newest first) and trims to `limit`. Sessions with no active time are not kept.
function Session.PushHistory(history, record, limit)
    if not record or (record.duration or 0) <= 0 then
        return history
    end
    table.insert(history, 1, record)
    limit = limit or Session.HISTORY_LIMIT
    for i = #history, limit + 1, -1 do
        history[i] = nil
    end
    return history
end

-- Turns a client format string such as LOOT_ITEM_SELF_MULTIPLE ("You receive loot: %sx%d.") into an
-- anchored Lua pattern with captures. Supports %s, %d and positional %1$s / %2$d.
function Session.FormatToPattern(fmt)
    if type(fmt) ~= "string" then
        return nil
    end
    local out = {}
    local i, n = 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local spec = fmt:match("^%%%d*%$?([sd])", i)
            local whole = fmt:match("^%%%d*%$?[sd]", i)
            if spec then
                out[#out + 1] = spec == "d" and "(%d+)" or "(.+)"
                i = i + #whole
            elseif fmt:sub(i + 1, i + 1) == "%" then
                out[#out + 1] = "%%"
                i = i + 2
            else
                out[#out + 1] = "%%"
                i = i + 1
            end
        elseif c:find("[%^%$%(%)%.%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

