-- Journal: Logbook's pure half. Saved-data shape, log lines, counters, sessions, the position trail, and the
-- parsers for the chat lines Logbook reads. No WoW calls: every clock and value comes in as an argument, so it
-- all runs in the offline tests.
--
-- LogbookCharDB (per character):
--   schema, since           when Logbook first recorded this character (the dashboard's cut-over from MuddyBoots)
--   char                    name, realm, guid, class, race, faction, sex, level, zone, first = { t, level }
--   log                     "t|played|mapID|x|y|kind|args..." lines (x, y in ten-thousandths of the map)
--   counts                  xp, activity, fights, deaths, distance, prof, auction, quests, spells, dungeons, character
--                           ("kill" = all levels, "kill:24" = at level 24)
--   sessions                { start, last, played0, played1, how } per login or reload
--   snap[level]             { t, played, money, zone, gear } when the level was reached
--   trail                   { v = 1, chunks = { { m = mapID, t = start, n = points, d = "dt,x,y;..." } } }
--   skills                  last rank seen per skill { [name] = "rank/max" }
--   baseline                MuddyBoots' counters and first record, copied once at Logbook's first login
-- LogbookDB (account): chars[guid] = { name, realm, guid, class, race, faction, level, money, played, lastSeen }
local _, ns = ...
local J = {}
ns.Journal = J

J.SCHEMA = 1
J.MAX_LOG = 60000      -- lines kept per character (about a year of play); the oldest go first
J.CHUNK_POINTS = 300   -- trail points per chunk
J.MAX_CHUNKS = 3000
J.TRAIL_STEP = 12      -- ten-thousandths of the map a point must move from the last one
J.HINT_SECONDS = 2     -- how long a hint (chat line, hook) can explain an XP or money change

J.COUNT_GROUPS = { "xp", "activity", "fights", "deaths", "distance", "prof", "auction", "quests", "spells",
    "dungeons", "character", "damage", "damageBy", "damageFrom", "flights" }
-- counters that hold a record, not a sum
J.MAX_KEYS = { longest = true, hardest = true, bestDps = true, biggest = true }
J.DPS_MIN_SECONDS = 10 -- best DPS only counts fights at least this long

----------------------------------------------------------------------------------------------------
-- Saved data

function J.NewChar(now)
    local db = { schema = J.SCHEMA, since = now }
    return J.Tidy(db)
end

-- Fills whatever is missing (older saves, hand edits); returns db
function J.Tidy(db)
    db.schema = db.schema or J.SCHEMA
    db.char = db.char or {}
    db.log = db.log or {}
    db.counts = db.counts or {}
    for _, g in ipairs(J.COUNT_GROUPS) do db.counts[g] = db.counts[g] or {} end
    db.sessions = db.sessions or {}
    db.snap = db.snap or {}
    db.trail = db.trail or { v = 1, chunks = {} }
    db.trail.chunks = db.trail.chunks or {}
    db.skills = db.skills or {}
    return db
end

function J.NewAccount()
    return { schema = J.SCHEMA, chars = {} }
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
J.Copy = copy

-- MuddyBoots' counters and first record, so the dashboard's totals carry on from them. Only the plain numeric
-- counters are kept. Returns nil when there's nothing to keep.
function J.Baseline(muddy, now)
    if type(muddy) ~= "table" or type(muddy.counts) ~= "table" then return nil end
    local counts = {}
    for _, g in ipairs(J.COUNT_GROUPS) do
        local src = muddy.counts[g]
        if type(src) == "table" then
            local dst = {}
            for k, v in pairs(src) do
                if type(k) == "string" and type(v) == "number" then dst[k] = v end
            end
            counts[g] = dst
        end
    end
    local first = type(muddy.char) == "table" and type(muddy.char.first) == "table" and copy(muddy.char.first) or nil
    return { from = "MuddyBoots", at = now, counts = counts, first = first }
end

----------------------------------------------------------------------------------------------------
-- Log lines

local function field(v)
    if v == nil then return "" end
    if type(v) == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.3f", v)
    end
    if type(v) == "boolean" then return v and "1" or "" end
    -- "|" splits fields, and in WoW strings starts an escape; newlines would break the line
    return (tostring(v):gsub("|", "/"):gsub("[\r\n]", " "))
end
J.Field = field

-- "t|played|map|x|y|kind|args..." (missing values stay empty)
function J.Line(t, played, map, x, y, kind, ...)
    local parts = { field(t), field(played), field(map), field(x), field(y), field(kind) }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = field((select(i, ...)))
    end
    -- trailing empty fields add nothing
    while #parts > 6 and parts[#parts] == "" do parts[#parts] = nil end
    return table.concat(parts, "|")
end

function J.Add(db, line)
    local log = db.log
    log[#log + 1] = line
    if #log > J.MAX_LOG then
        local drop = math.floor(J.MAX_LOG / 20)
        local kept = {}
        for i = drop + 1, #log do kept[#kept + 1] = log[i] end
        db.log = kept
    end
    return #db.log
end

-- Fills the played field of lines logged before the client told us the played time (TIME_PLAYED_MSG).
-- playedAt(t) gives the played time at real time t. Lines from index `from` on.
function J.BackfillPlayed(db, from, playedAt)
    for i = from or 1, #db.log do
        local line = db.log[i]
        local t, rest = line:match("^(%d+)||(.*)$")
        if t then
            local p = playedAt(tonumber(t))
            if p then db.log[i] = t .. "|" .. field(p) .. "|" .. rest end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Counters

-- counts[key] += n, and counts["key:level"] += n when a level is given
function J.Count(counts, key, n, level)
    n = n or 1
    counts[key] = (counts[key] or 0) + n
    if level then
        local k = key .. ":" .. level
        counts[k] = (counts[k] or 0) + n
    end
end

function J.Max(counts, key, v)
    if v and (not counts[key] or v > counts[key]) then counts[key] = v end
end

----------------------------------------------------------------------------------------------------
-- Sessions (one per login or reload; the dashboard joins pieces less than 30 minutes apart)

function J.StartSession(db, now, played, how)
    local s = { start = now, last = now, played0 = played, played1 = played, how = how }
    db.sessions[#db.sessions + 1] = s
    return s
end

function J.TouchSession(s, now, played)
    if not s then return end
    s.last = math.max(s.last or now, now)
    if played then
        s.played1 = played
        s.played0 = s.played0 or played
    end
end

----------------------------------------------------------------------------------------------------
-- Trail: where you've been, a point when you've moved, in chunks per map

-- Adds a point (x, y in ten-thousandths). flag: optional letter ("d" dead, "t" taxi, "w" first point of a chunk).
-- Returns true when a point was added.
function J.TrailPoint(trail, now, map, x, y, flag)
    if not (map and x and y) then return false end
    local chunks = trail.chunks
    local c = chunks[#chunks]
    if c and c.m == map and (c.n or 0) < J.CHUNK_POINTS then
        if c.lx and math.abs(x - c.lx) + math.abs(y - c.ly) < J.TRAIL_STEP then return false end
        c.d = c.d .. ";" .. (now - c.t) .. "," .. x .. "," .. y .. (flag and ("," .. flag) or "")
        c.n = c.n + 1
    else
        c = { m = map, t = now, n = 1, d = "0," .. x .. "," .. y .. "," .. (flag or "w") }
        chunks[#chunks + 1] = c
        if #chunks > J.MAX_CHUNKS then table.remove(chunks, 1) end
    end
    c.lx, c.ly = x, y
    return true
end

-- Keeps the saved trail small: the last point is only needed while recording
function J.TrailForSave(trail)
    for _, c in ipairs(trail.chunks) do c.lx, c.ly = nil, nil end
end

----------------------------------------------------------------------------------------------------
-- Explaining XP and money changes. The client sends the change (PLAYER_XP_UPDATE, PLAYER_MONEY) and the line
-- that says why (a chat line, a quest turn-in, a hook on a button) in either order, a moment apart. Both go into
-- a pending record; a short timer later Flush splits the change between the hints.

function J.NewPending()
    return { delta = 0, hints = {} }
end

-- hint = { source, amount (optional), detail (optional), rested (optional) }, clock = GetTime()
function J.Hint(p, hint, clock)
    hint.at = clock
    p.hints[#p.hints + 1] = hint
end

function J.Delta(p, delta)
    p.delta = p.delta + delta
end

local function freshHints(p, clock)
    local out = {}
    for _, h in ipairs(p.hints) do
        if not clock or not h.at or clock - h.at <= J.HINT_SECONDS then out[#out + 1] = h end
    end
    return out
end

-- XP: returns { { amount, source, detail, rested } } adding up to the change. Hints with an amount (kill and
-- exploration lines, quest rewards) take theirs; what's left goes to a hint without one, else "other".
-- Hints that arrive with no XP change yet stay pending (the change may still come), up to HINT_SECONDS.
function J.FlushXP(p, clock, fallback)
    local out = {}
    local left = p.delta
    local hints = freshHints(p, clock)
    if left <= 0 then
        p.delta = 0
        p.hints = hints
        return out
    end
    local open
    for _, h in ipairs(hints) do
        if h.amount and h.amount > 0 and left > 0 then
            local a = math.min(h.amount, left)
            out[#out + 1] = { amount = a, source = h.source, detail = h.detail, rested = h.rested }
            left = left - a
        elseif not h.amount and not open then
            open = h
        end
    end
    if left > 0 then
        out[#out + 1] = { amount = left, source = open and open.source or fallback or "other", detail = open and open.detail }
    end
    p.delta, p.hints = 0, {}
    return out
end

-- Money: what the change was for. Hints first: one whose amount matches exactly (a quest reward, an AH invoice),
-- then one for the same direction (a repair, a purchase, postage). Then the open window (frames[name] = true).
-- Returns source, detail, hint (the hint used, or nil).
J.FRAME_SOURCES = { -- order matters: the AH and the mailbox beat a vendor standing next to them
    { "auction", "auction" }, { "mail", "mail" }, { "trade", "trade" }, { "trainer", "trainer" },
    { "taxi", "flight" }, { "merchant", "vendor" }, { "bank", "bank" }, { "loot", "loot" }, { "gossip", "gossip" },
}

function J.MoneySource(delta, hints, frames, clock)
    local exact, same
    for _, h in ipairs(hints) do
        if not h.used and (not clock or not h.at or clock - h.at <= J.HINT_SECONDS) then
            if h.amount and h.amount == delta then
                exact = exact or h
            elseif not h.amount and (not h.sign or h.sign * delta > 0) then
                same = same or h
            end
        end
    end
    local h = exact or same
    if h then
        h.used = true
        return h.source, h.detail, h
    end
    for _, fs in ipairs(J.FRAME_SOURCES) do
        if frames and frames[fs[1]] then return fs[2], nil, nil end
    end
    return "other", nil, nil
end

----------------------------------------------------------------------------------------------------
-- Skills

-- list = { { name, rank, max } }; cache = { [name] = "rank/max" }. Returns the skills whose rank or max changed
-- (all of them the first time) and updates the cache.
function J.SkillChanges(cache, list)
    local out = {}
    for _, s in ipairs(list) do
        if s.name and s.rank then
            local key = s.rank .. "/" .. (s.max or 0)
            if cache[s.name] ~= key then
                cache[s.name] = key
                out[#out + 1] = s
            end
        end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Fights (between entering and leaving combat)

-- fight = { start = clock, minHealth = fraction }; returns the seconds it lasted
function J.EndFight(counts, fight, clock, died)
    local sec = math.max(0, math.floor(clock - fight.start + 0.5))
    local f = counts.fights
    J.Count(f, "n")
    J.Count(f, "sec", sec)
    J.Max(f, "longest", sec)
    if died then J.Count(f, "died") end
    local low = fight.minHealth
    if low and low <= 0.2 then
        J.Count(counts.deaths, "lowHealth")
        if low <= 0.1 and not died then J.Count(counts.deaths, "closeCalls") end
    end
    return sec
end

----------------------------------------------------------------------------------------------------
-- Damage meter (C_DamageMeter: Blizzard's own meter, readable once you're out of combat)

-- The local player's entry among a meter session's combatSources
function J.MeterSelf(session)
    if type(session) ~= "table" or type(session.combatSources) ~= "table" then return nil end
    for _, s in ipairs(session.combatSources) do
        if type(s) == "table" and s.isLocalPlayer == true then return s end
    end
    return nil
end

local function amount(v) return type(v) == "number" and v > 0 and math.floor(v + 0.5) or 0 end

-- One fight from the meter's readings, or nil when the meter saw nothing:
--   m = { seconds, done, taken, healed, enemies (sessions), spells, hits (your source's spell breakdowns),
--         spellName = function(id) }
-- Returns { seconds, done, taken, healed, enemies, spells = { name = n }, from = { mob = n }, worst, worstAmount,
--           killer, killSpell }
function J.MeterFight(m)
    local function total(session)
        local me = J.MeterSelf(session)
        return me and amount(me.totalAmount) or 0
    end
    local f = { seconds = m.seconds, done = total(m.done), taken = total(m.taken), healed = total(m.healed),
        spells = {}, from = {} }
    if f.done == 0 and f.taken == 0 and f.healed == 0 then return nil end
    if type(m.enemies) == "table" and type(m.enemies.combatSources) == "table" then
        f.enemies = #m.enemies.combatSources
    end
    local name = m.spellName or function() return nil end
    local function spellLabel(id)
        if type(id) ~= "number" or id <= 0 then return "Melee" end
        return name(id) or ("spell " .. id)
    end
    for _, sp in ipairs(type(m.spells) == "table" and m.spells.combatSpells or {}) do
        local n = amount(sp.totalAmount)
        if n > 0 then
            local key = spellLabel(sp.spellID)
            f.spells[key] = (f.spells[key] or 0) + n
        end
    end
    for _, sp in ipairs(type(m.hits) == "table" and m.hits.combatSpells or {}) do
        local n = amount(sp.totalAmount)
        local unit = type(sp.combatSpellDetails) == "table" and sp.combatSpellDetails.unitName
        local mob = (type(sp.creatureName) == "string" and sp.creatureName ~= "" and sp.creatureName)
            or (type(unit) == "string" and unit ~= "" and unit) or nil
        if n > 0 and mob then
            f.from[mob] = (f.from[mob] or 0) + n
            if not f.worst or f.from[mob] > f.worstAmount then f.worst, f.worstAmount = mob, f.from[mob] end
        end
        if sp.isDeadly == true and not f.killer then
            f.killer, f.killSpell = mob, spellLabel(sp.spellID)
        end
    end
    return f
end

-- Adds a meter fight to counts.damage (totals and per level), counts.damageBy (your spells) and
-- counts.damageFrom (what hit you)
function J.CountDamage(counts, f, level)
    local d = counts.damage
    J.Count(d, "fights", 1, level)
    J.Count(d, "sec", f.seconds or 0, level)
    J.Count(d, "done", f.done, level)
    J.Count(d, "taken", f.taken, level)
    J.Count(d, "healed", f.healed, level)
    J.Max(d, "biggest", f.done)
    if (f.seconds or 0) >= J.DPS_MIN_SECONDS then J.Max(d, "bestDps", math.floor(f.done / f.seconds + 0.5)) end
    for k, n in pairs(f.spells) do J.Count(counts.damageBy, k, n) end
    for k, n in pairs(f.from) do J.Count(counts.damageFrom, k, n) end
end

-- What you were doing for the last tick: afk | dead | combat | dungeon | travel | town | idle
-- s = { afk, dead, combat, instance, moving, taxi, resting }
function J.Activity(s)
    if s.afk then return "afk" end
    if s.dead then return "dead" end
    if s.combat then return "combat" end
    if s.taxi or s.moving then return s.instance and "dungeon" or "travel" end
    if s.instance then return "dungeon" end
    if s.resting then return "town" end
    return "idle"
end

----------------------------------------------------------------------------------------------------
-- Parsers

-- A client format string ("%s dies, you gain %d experience.") as a Lua pattern with captures. Not anchored at the
-- end, so a trailing bonus text still matches.
function J.FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local out, i, n = { "^" }, 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local whole, spec = fmt:match("^(%%%d*%$?([sd]))", i)
            if spec then
                out[#out + 1] = spec == "d" and "(%d+)" or "(.+)"
                i = i + #whole
            else
                out[#out + 1] = "%%"
                i = i + (fmt:sub(i + 1, i + 1) == "%" and 2 or 1)
            end
        elseif c:match("[%^%$%(%)%.%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- "Mob dies, you gain 150 experience. (+75 exp Rested bonus)" -> "Mob", 150, 75 (rested bonus or nil)
function J.ParseKillXP(text, pattern)
    if type(text) ~= "string" then return nil end
    local name, xp
    if pattern then name, xp = text:match(pattern) end
    if not name then name, xp = text:match("^(.+) dies, you gain (%d+) experience") end
    if not name then return nil end
    local rested
    for amount, kind in text:gmatch("%(%+?(%d+) exp ([^%)]-) bonus") do
        if kind:lower():find("rest") then rested = tonumber(amount) end
    end
    return name, tonumber(xp), rested
end

-- "Discovered Crusader Outpost: 70 experience gained" -> "Crusader Outpost", 70
function J.ParseDiscover(text, pattern)
    if type(text) ~= "string" then return nil end
    local zone, xp
    if pattern then zone, xp = text:match(pattern) end
    if not zone then zone, xp = text:match("^Discovered (.+): (%d+) experience gained") end
    if zone then return zone, tonumber(xp) end
    return nil
end

-- "|cff1eff00|Hitem:2589::...|h[Linen Cloth]|h|r" -> 2589, "Linen Cloth", quality (from the link's colour)
J.QUALITY_COLORS = { ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4,
    ["ff8000"] = 5, ["e6cc80"] = 6 }
function J.ParseItemLink(link)
    if type(link) ~= "string" then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return nil end
    local name = link:match("%[(.-)%]")
    local color = link:match("|c%x%x(%x%x%x%x%x%x)")
    return id, name, color and J.QUALITY_COLORS[color:lower()] or nil
end

-- The chat lines for items you receive, most specific first (the single forms would also match "x5").
-- defs = { { pattern, how, multiple } } built by Core from the client's strings; English fallbacks follow.
J.LOOT_FALLBACK = {
    { "^You receive loot: (.+)x(%d+)%.", "loot", true },
    { "^You receive loot: (.+)%.", "loot", false },
    { "^You receive item: (.+)x(%d+)%.", "pushed", true },
    { "^You receive item: (.+)%.", "pushed", false },
    { "^You create: (.+)x(%d+)%.", "created", true },
    { "^You create: (.+)%.", "created", false },
    { "^You won: (.+)", "won", false },
}

-- Returns link, count, how ("loot" | "pushed" | "created" | "won") or nil
function J.ParseLoot(text, defs)
    if type(text) ~= "string" then return nil end
    for _, list in ipairs({ defs or {}, J.LOOT_FALLBACK }) do
        for _, d in ipairs(list) do
            local link, count = text:match(d[1])
            if link and link:find("item:") then
                return link, d[3] and tonumber(count) or 1, d[2]
            end
        end
    end
    return nil
end

-- "Creature-0-1-2-3-4-1866-0000" -> "creature", 1866
function J.ParseGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" then return "creature", tonumber(id) end
    if guid:match("^Player%-") then return "player", nil end
    return nil
end

-- "Wool Cloth" + 20 -> "Wool Cloth x20" (the dashboard's item-and-count form); 1 stays bare
function J.ItemQty(name, count)
    if not name or name == "" then return "" end
    count = tonumber(count) or 1
    return count > 1 and (name .. " x" .. count) or name
end

-- "Auction successful: Wool Cloth (20)" -> "Wool Cloth", 20
function J.ParseMailSubject(subject)
    if type(subject) ~= "string" then return nil end
    local item = subject:match(":%s*(.+)$") or subject
    local name, count = item:match("^(.-)%s*%((%d+)%)$")
    if name then return name, tonumber(count) end
    return item, 1
end

return J
