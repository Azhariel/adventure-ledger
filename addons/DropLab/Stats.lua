-- Stats: pure logic for DropLab. Records loot windows and kills into the saved data and turns them into drop
-- rates with a 95% range. No WoW calls, so it runs in the offline tests.
--
-- Saved data (account-wide; drop tables are the same for every character):
--   db.mobs[npcID]      = { name, kills, looted, money, items = { [itemID] = { drops, qty } },
--                           gather = { opened, items }, paceSum, paceN, last }
--   db.objects[objID]   = { opened, items }            herb, ore and chest loot
--   db.names[name]      = npcID                        learned from targets, mouse-overs and loot
--   db.unnamed[name]    = kills not yet tied to an npcID (the XP line only names the mob)
local _, ns = ...
local Stats = {}
ns.Stats = Stats

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

Stats.Z = 1.96          -- 95% range
Stats.MIN_KILLS = 5     -- fewer kills than this: listed, but not ranked by value
Stats.PACE_GAP = 120    -- seconds; kills of the same mob closer than this count towards your pace
Stats.MIN_PACE = 5      -- gaps needed before a kills-per-hour figure is shown

function Stats.NewDB()
    return { version = 1, mobs = {}, objects = {}, names = {}, unnamed = {} }
end

-- "Creature-0-1-2-3-1234-0000ABCD" -> "creature", 1234. Vehicles count as creatures; game objects are nodes and chests.
function Stats.ParseGUID(guid)
    if type(guid) ~= "string" then
        return nil
    end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" then
        return "creature", tonumber(id)
    elseif kind == "GameObject" then
        return "object", tonumber(id)
    end
    return nil
end

-- "Defias Pillager dies, you gain 45 experience." -> "Defias Pillager", 45. pattern: built from the client's string.
function Stats.ParseXP(text, pattern)
    if type(text) ~= "string" then
        return nil
    end
    local name, xp
    if pattern then
        name, xp = text:match(pattern)
    end
    if not name then
        name, xp = text:match("^(.+) dies, you gain ([%d,]+) experience")
    end
    if not name then
        return nil
    end
    return name, tonumber((tostring(xp):gsub(",", "")))
end

-- A Lua pattern from a client format string like "%s dies, you gain %d experience." (only the start is matched,
-- so rested and group bonus suffixes don't matter)
function Stats.XPPattern(format)
    if type(format) ~= "string" or not format:find("%%s") then
        return nil
    end
    local head = format:match("^(.-%%d)") or format
    head = head:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
    head = head:gsub("%%s", "(.+)"):gsub("%%d", "([%%d,]+)")
    return "^" .. head
end

local function mobOf(db, npcID)
    local m = db.mobs[npcID]
    if not m then
        m = { kills = 0, looted = 0, money = 0, items = {} }
        db.mobs[npcID] = m
    end
    return m
end

local function objectOf(db, id)
    local o = db.objects[id]
    if not o then
        o = { opened = 0, items = {} }
        db.objects[id] = o
    end
    return o
end

-- Remembers which npcID a name belongs to, and moves kills counted under that name to it
function Stats.Learn(db, name, npcID)
    if type(name) ~= "string" or name == "" or type(npcID) ~= "number" then
        return
    end
    db.names[name] = npcID
    local waiting = db.unnamed[name]
    -- Only mobs with kills or loot get a record: hovering a vendor just remembers its name
    if not (waiting or db.mobs[npcID]) then
        return
    end
    local m = mobOf(db, npcID)
    m.name = name
    if waiting then
        m.kills = m.kills + waiting
        db.unnamed[name] = nil
    end
end

-- npcIDs of mobs with data but no name yet (in dungeons the game hides unit names; only the corpse's ID is known)
function Stats.Nameless(db)
    local out = {}
    for id, m in pairs(db.mobs) do
        if not m.name then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- Drops mob records with nothing counted (left by older versions for every NPC you hovered). Returns how many.
function Stats.Tidy(db)
    local gone = 0
    for id, m in pairs(db.mobs) do
        if (m.kills or 0) == 0 and (m.looted or 0) == 0 and not next(m.items or {})
            and not (m.gather and m.gather.opened > 0) then
            db.mobs[id] = nil
            gone = gone + 1
        end
    end
    return gone
end

-- One kill credited by an XP line. npcID may be nil (then the name decides, now or once it's learned).
-- now: seconds (GetTime) for the kill pace.
function Stats.RecordKill(db, name, npcID, now)
    npcID = npcID or (name and db.names[name])
    if not npcID then
        if type(name) == "string" and name ~= "" then
            db.unnamed[name] = (db.unnamed[name] or 0) + 1
        end
        db.lastKill = nil
        return nil
    end
    if name and not db.names[name] then
        Stats.Learn(db, name, npcID)
    end
    local m = mobOf(db, npcID)
    m.kills = m.kills + 1
    m.name = m.name or name
    local last = db.lastKill
    if now and last and last.npcID == npcID and now - last.t > 0 and now - last.t <= Stats.PACE_GAP then
        m.paceSum = (m.paceSum or 0) + (now - last.t)
        m.paceN = (m.paceN or 0) + 1
    end
    db.lastKill = now and { npcID = npcID, t = now } or nil
    return npcID
end

local function addItem(items, bucket, itemID, qty)
    local prev = bucket[itemID] or 0
    if qty <= prev then
        return
    end
    local s = items[itemID]
    if not s then
        s = { drops = 0, qty = 0 }
        items[itemID] = s
    end
    if prev == 0 then
        s.drops = s.drops + 1
    end
    s.qty = s.qty + (qty - prev)
    bucket[itemID] = qty
end

-- One loot window. entries: { { guid, itemID = n | nil, money = copper | nil, qty } } (one per slot and source).
-- corpses: this session's memory of what each corpse showed, so reopening one never counts twice:
--   corpses[guid] = { items = {}, gathered = {}, closed, gather, money, t }
-- After a corpse's own loot is gone, a new window from it with only new items is a gather (skinning): its items go
-- to mob.gather, not the drop rates. Returns the number of new corpses or objects counted.
function Stats.RecordLoot(db, corpses, entries, now)
    local byGuid, order = {}, {}
    for _, e in ipairs(entries or {}) do
        if type(e.guid) == "string" and (e.itemID or e.money) then
            if not byGuid[e.guid] then
                byGuid[e.guid] = {}
                order[#order + 1] = e.guid
            end
            local list = byGuid[e.guid]
            list[#list + 1] = e
        end
    end
    local fresh = 0
    for _, guid in ipairs(order) do
        local kind, id = Stats.ParseGUID(guid)
        if kind then
            local list = byGuid[guid]
            local c = corpses[guid]
            if not c then
                c = { items = {}, gathered = {}, t = now }
                corpses[guid] = c
                fresh = fresh + 1
                if kind == "creature" then
                    local m = mobOf(db, id)
                    m.looted = m.looted + 1
                    m.last = now
                else
                    local o = objectOf(db, id)
                    o.opened = o.opened + 1
                end
            elseif c.closed and kind == "creature" and not c.gather then
                local old = false
                for _, e in ipairs(list) do
                    if e.money or (e.itemID and c.items[e.itemID]) then
                        old = true
                    end
                end
                if not old then
                    c.gather = true
                    local m = mobOf(db, id)
                    m.gather = m.gather or { opened = 0, items = {} }
                    m.gather.opened = m.gather.opened + 1
                end
            end
            for _, e in ipairs(list) do
                if kind == "object" then
                    if e.itemID then
                        addItem(objectOf(db, id).items, c.items, e.itemID, e.qty or 1)
                    end
                elseif c.gather and not (e.itemID and c.items[e.itemID]) then
                    if e.itemID then
                        addItem(db.mobs[id].gather.items, c.gathered, e.itemID, e.qty or 1)
                    end
                elseif e.money then
                    if not c.money then
                        c.money = true
                        local m = mobOf(db, id)
                        m.money = m.money + e.money
                    end
                else
                    addItem(mobOf(db, id).items, c.items, e.itemID, e.qty or 1)
                end
            end
        end
    end
    return fresh
end

-- The loot window closed: every corpse it showed is now "closed" (a later window from it may be a gather)
function Stats.Close(corpses, guids)
    for _, guid in ipairs(guids or {}) do
        if corpses[guid] then
            corpses[guid].closed = true
        end
    end
end

-- Forgets corpses older than maxAge seconds (they despawn long before)
function Stats.Prune(corpses, now, maxAge)
    for guid, c in pairs(corpses) do
        if c.t and now - c.t > (maxAge or 900) then
            corpses[guid] = nil
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Rates

-- Wilson score interval for k successes in n trials: lo, hi (fractions). n = 0 -> 0, 1.
function Stats.Wilson(k, n, z)
    if not n or n <= 0 then
        return 0, 1
    end
    z = z or Stats.Z
    local p = k / n
    local z2 = z * z
    local denom = 1 + z2 / n
    local centre = (p + z2 / (2 * n)) / denom
    local half = z * sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denom
    return max(0, centre - half), min(1, centre + half)
end

-- The number of kills to divide by, and what it's based on: "kills" (XP lines) or "looted" (only corpses you
-- opened: grey and level-60 kills give no XP line, and a corpse with nothing on it can't be opened, so rates
-- based on looted corpses run high).
function Stats.Kills(mob)
    local kills, looted = mob.kills or 0, mob.looted or 0
    if kills > 0 and kills >= looted then
        return kills, "kills"
    end
    return looted, "looted"
end

-- { drops, qty, n, rate, lo, hi, perKill, basis } for one item from one mob
function Stats.ItemRate(mob, itemID)
    local n, basis = Stats.Kills(mob)
    local s = mob.items and mob.items[itemID]
    local drops, qty = s and s.drops or 0, s and s.qty or 0
    drops = min(drops, n)
    local lo, hi = Stats.Wilson(drops, n)
    return { drops = drops, qty = qty, n = n, basis = basis, rate = n > 0 and drops / n or nil, lo = lo, hi = hi,
        perKill = n > 0 and qty / n or nil }
end

-- Expected copper per kill: items at price(itemID) plus coin. Returns value, unpriced (items with no price).
function Stats.Value(mob, price)
    local n = Stats.Kills(mob)
    if n <= 0 then
        return nil, 0
    end
    local total, unpriced = mob.money or 0, 0
    for itemID, s in pairs(mob.items or {}) do
        local p = price and price(itemID)
        if p then
            total = total + s.qty * p
        else
            unpriced = unpriced + 1
        end
    end
    return total / n, unpriced
end

-- Your pace on this mob: kills per hour, from kills of it in a row (nil until MIN_PACE gaps)
function Stats.KillsPerHour(mob)
    if not mob.paceN or mob.paceN < Stats.MIN_PACE or not mob.paceSum or mob.paceSum <= 0 then
        return nil
    end
    return 3600 / (mob.paceSum / mob.paceN)
end

-- Kills needed for `want` more of an item at perKill items per kill
function Stats.KillsFor(perKill, want)
    if not perKill or perKill <= 0 or not want or want <= 0 then
        return nil
    end
    return math.ceil(want / perKill - 1e-9)
end

-- Your rate against a published one (percent, e.g. Questie's): "higher" | "lower" | "matches" (inside your range)
function Stats.Compare(published, lo, hi)
    if not published then
        return nil
    end
    local p = published / 100
    if p < lo then
        return "higher"
    elseif p > hi then
        return "lower"
    end
    return "matches"
end

-- Every mob that dropped an item, best first by the low end of the range (a sure 30% beats a lucky 2 of 3).
-- { npcID, name, drops, qty, n, rate, lo, hi, perKill, basis }
function Stats.ForItem(db, itemID)
    local out = {}
    for npcID, mob in pairs(db.mobs or {}) do
        if mob.items and mob.items[itemID] then
            local r = Stats.ItemRate(mob, itemID)
            r.npcID, r.name = npcID, mob.name
            out[#out + 1] = r
        end
    end
    table.sort(out, function(a, b)
        if a.lo ~= b.lo then return a.lo > b.lo end
        if a.n ~= b.n then return a.n > b.n end
        return a.npcID < b.npcID
    end)
    return out
end

-- A mob's drops, most likely first: list of ItemRate + itemID
function Stats.Drops(mob)
    local out = {}
    for itemID in pairs(mob.items or {}) do
        local r = Stats.ItemRate(mob, itemID)
        r.itemID = itemID
        out[#out + 1] = r
    end
    table.sort(out, function(a, b)
        if (a.rate or 0) ~= (b.rate or 0) then return (a.rate or 0) > (b.rate or 0) end
        return a.itemID < b.itemID
    end)
    return out
end

-- Mobs worth farming: value per kill (and per hour when your pace is known), only mobs with MIN_KILLS or more.
-- { npcID, name, n, basis, value, unpriced, perHour, killsPerHour }
function Stats.Best(db, price)
    local out = {}
    for npcID, mob in pairs(db.mobs or {}) do
        local n, basis = Stats.Kills(mob)
        if n >= Stats.MIN_KILLS then
            local value, unpriced = Stats.Value(mob, price)
            local kph = Stats.KillsPerHour(mob)
            out[#out + 1] = { npcID = npcID, name = mob.name, n = n, basis = basis, value = value or 0,
                unpriced = unpriced, killsPerHour = kph, perHour = kph and value and value * kph or nil }
        end
    end
    table.sort(out, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.npcID < b.npcID
    end)
    return out
end

----------------------------------------------------------------------------------------------------
-- Text

-- 0.3125 -> "31%", 0.045 -> "4.5%", 0.0042 -> "0.42%"
function Stats.Percent(f)
    if not f then
        return "?"
    end
    local p = f * 100
    if p >= 10 or p == 0 then
        return string.format("%d%%", floor(p + 0.5))
    elseif p >= 1 then
        return string.format("%.1f%%", p)
    end
    return string.format("%.2f%%", p)
end

-- "31% (22-42%)"
function Stats.RateText(r)
    if not r.rate then
        return "?"
    end
    return Stats.Percent(r.rate) .. " (" .. Stats.Percent(r.lo):gsub("%%", "") .. "-" .. Stats.Percent(r.hi) .. ")"
end

-- "84 kills" or "12 looted corpses"
function Stats.SampleText(n, basis)
    if basis == "looted" then
        return n .. (n == 1 and " looted corpse" or " looted corpses")
    end
    return n .. (n == 1 and " kill" or " kills")
end

return Stats
