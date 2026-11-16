-- Merge: one character's (or account's) saved data from several PCs into one, so play on another computer counts.
-- Each PC's WoW only writes its own sessions; copy another PC's WTF folder into data/pcs/<name>/WTF and the build
-- reads both. Pure functions over the saved tables. Every merge given one table returns it untouched, so a single
-- PC builds exactly as before.
local S = require("sources")

local Mg = {}

local function lineTime(line)
    return type(line) == "string" and tonumber(line:match("^(%-?%d+)")) or nil
end

-- The newest moment a Logbook file knows: its last log line, else its last session
local function lastSeen(db)
    local t = 0
    local log = db.log or {}
    for i = #log, math.max(1, #log - 50), -1 do t = math.max(t, lineTime(log[i]) or 0) end
    for _, s in ipairs(db.sessions or {}) do t = math.max(t, tonumber(s.last) or 0) end
    return t
end

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- Several LogbookCharDB tables for one character -> one, in the same shape (S.mergeJournal reads it as usual):
--   log       every line of every PC, exact repeats once (files copied between PCs share lines), in time order
--   sessions  every piece, a repeated start once
--   counts    added up (each PC counts only its own play), records (longest fight, best DPS) the highest
--   snap      per level, the earliest (a level is reached once; the other is a later copy)
--   trail     every chunk, a repeated (map, start) once
--   char, skills  from the PC that played last; since = the earliest; baseline and history (MuddyBoots' counters
--   and older log, copied once at Logbook's first login) from the PC that started first, so they count once
-- Returns the merged table and how many log lines two files shared (> 0 means a file was copied between PCs, so
-- its counters were counted on both and the totals run high).
function Mg.logbooks(list)
    local dbs = {}
    for _, db in ipairs(list or {}) do if type(db) == "table" then dbs[#dbs + 1] = db end end
    if #dbs <= 1 then return dbs[1], 0 end
    local byStart = copy(dbs)
    table.sort(byStart, function(a, b) return (tonumber(a.since) or math.huge) < (tonumber(b.since) or math.huge) end)
    local byLast = copy(dbs)
    table.sort(byLast, function(a, b) return lastSeen(a) < lastSeen(b) end)
    local first, newest = byStart[1], byLast[#byLast]
    local out = { schema = first.schema, since = first.since, baseline = first.baseline, history = first.history,
        noBaseline = first.noBaseline, char = {}, skills = copy(newest.skills), log = {}, sessions = {}, snap = {},
        counts = {}, trail = { v = 1, chunks = {} } }
    for _, db in ipairs(byLast) do for k, v in pairs(db.char or {}) do out.char[k] = v end end
    out.char.level = 0
    for _, db in ipairs(dbs) do out.char.level = math.max(out.char.level, tonumber(db.char and db.char.level) or 0) end
    if out.char.level == 0 then out.char.level = nil end
    out.char.first = first.char and first.char.first

    -- a line repeated within one file is that many real events (two identical sales in one second), so each line
    -- is kept as often as the copy holding it most; only repeats across copies are shared
    local kept, shared, lines = {}, 0, {}
    for src, db in ipairs(byStart) do
        local here = {}
        for i, line in ipairs(db.log or {}) do
            here[line] = (here[line] or 0) + 1
            if here[line] <= (kept[line] or 0) then
                shared = shared + 1
            else
                kept[line] = here[line]
                lines[#lines + 1] = { t = lineTime(line) or 0, src = src, i = i, line = line }
            end
        end
    end
    table.sort(lines, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a.src ~= b.src then return a.src < b.src end
        return a.i < b.i
    end)
    for i, l in ipairs(lines) do out.log[i] = l.line end

    local starts = {}
    for _, db in ipairs(byStart) do
        for _, s in ipairs(db.sessions or {}) do
            local key = tostring(s.start) .. "|" .. tostring(s.how)
            if type(s) == "table" and not starts[key] then
                starts[key] = true
                out.sessions[#out.sessions + 1] = s
            end
        end
    end
    table.sort(out.sessions, function(a, b) return (a.start or 0) < (b.start or 0) end)

    for _, db in ipairs(dbs) do
        for lvl, s in pairs(db.snap or {}) do
            local old = out.snap[lvl]
            if not old or (s.money and not old.money) or ((s.t or math.huge) < (old.t or math.huge) and (s.money or not old.money)) then
                out.snap[lvl] = s
            end
        end
    end

    local chunks = {}
    for _, db in ipairs(byStart) do
        for _, c in ipairs(db.trail and db.trail.chunks or {}) do
            local key = tostring(c.m) .. "|" .. tostring(c.t)
            if type(c) == "table" and not chunks[key] then
                chunks[key] = true
                out.trail.chunks[#out.trail.chunks + 1] = c
            end
        end
    end
    table.sort(out.trail.chunks, function(a, b) return (tonumber(a.t) or 0) < (tonumber(b.t) or 0) end)

    for _, db in ipairs(dbs) do
        for group, t in pairs(db.counts or {}) do
            if type(t) == "table" then
                local dst = out.counts[group] or {}
                out.counts[group] = dst
                for k, v in pairs(t) do
                    if type(v) == "number" then
                        dst[k] = S.MAX_COUNTERS[k] and math.max(dst[k] or v, v) or (dst[k] or 0) + v
                    end
                end
            end
        end
    end
    return out, shared
end

-- Several LogbookDB (account) tables -> one: per character row, the one seen last
function Mg.logbookAccounts(list)
    local dbs = {}
    for _, db in ipairs(list or {}) do if type(db) == "table" then dbs[#dbs + 1] = db end end
    if #dbs <= 1 then return dbs[1] end
    local out = copy(dbs[1])
    out.chars = {}
    for _, db in ipairs(dbs) do
        for guid, row in pairs(db.chars or {}) do
            local old = out.chars[guid]
            if type(row) == "table" and (not old or (row.lastSeen or 0) > (old.lastSeen or 0)) then out.chars[guid] = row end
        end
    end
    return out
end

-- Several HaulCharDB tables -> one: every archived session (a repeated start once, newest first, as Haul keeps
-- them) and the current session of the PC that played last
function Mg.haul(list)
    local dbs = {}
    for _, db in ipairs(list or {}) do if type(db) == "table" then dbs[#dbs + 1] = db end end
    if #dbs <= 1 then return dbs[1] end
    local out = copy(dbs[1])
    out.history, out.current = {}, nil
    local seen = {}
    for _, db in ipairs(dbs) do
        for _, h in ipairs(db.history or {}) do
            if type(h) == "table" and h.start and not seen[h.start] then
                seen[h.start] = true
                out.history[#out.history + 1] = h
            end
        end
        local cur = db.current and db.current.session
        local best = out.current and out.current.session
        if cur and cur.start and (not best or cur.start > (best.start or 0)) then out.current = db.current end
    end
    table.sort(out.history, function(a, b) return a.start > b.start end)
    return out
end

-- Several MakeOrBuyCharDB tables -> one: every recipe either PC saved, each profession's skill from the PC
-- where it's highest, and its colour observations from that PC too (they were seen at that PC's skill); the rest
-- (restock list, view settings) from the first
function Mg.makeOrBuy(list)
    local dbs = {}
    for _, db in ipairs(list or {}) do if type(db) == "table" then dbs[#dbs + 1] = db end end
    if #dbs <= 1 then return dbs[1] end
    local out = copy(dbs[1])
    out.recipes, out.unlearned, out.skill, out.bounds = {}, {}, {}, {}
    local from = {} -- profession -> the db with its highest skill
    for _, db in ipairs(dbs) do
        for id, r in pairs(db.recipes or {}) do out.recipes[id] = out.recipes[id] or r end
        for prof, s in pairs(db.skill or {}) do
            local old = out.skill[prof]
            if type(s) == "table" and (not old or (tonumber(s.level) or 0) > (tonumber(old.level) or 0)) then
                out.skill[prof] = s
                from[prof] = db
            end
        end
    end
    for _, db in ipairs(dbs) do
        for id, r in pairs(db.unlearned or {}) do
            if not out.recipes[id] then out.unlearned[id] = out.unlearned[id] or r end
        end
    end
    for id, r in pairs(out.recipes) do
        local src = from[r.profession]
        local b = src and src.bounds and src.bounds[id]
        if not b then
            for _, db in ipairs(dbs) do b = b or (db.bounds and db.bounds[id]) end
        end
        out.bounds[id] = b
    end
    return out
end

-- Several price books (S.auctionator / S.neutral results) -> one: every scan day of every PC; on a day both
-- scanned, the lower low, the higher high and the larger count. Today's price is the one from the latest scan.
function Mg.markets(list)
    local ms = {}
    for _, m in ipairs(list or {}) do if type(m) == "table" then ms[#ms + 1] = m end end
    if #ms <= 1 then return ms[1] end
    local out = copy(ms[1])
    out.prices, out.vendor = {}, {}
    for _, m in ipairs(ms) do
        for id, v in pairs(m.vendor or {}) do out.vendor[id] = out.vendor[id] or v end
        for id, p in pairs(m.prices or {}) do
            local o = out.prices[id]
            if not o then
                o = { days = {}, byDay = {} }
                out.prices[id] = o
            end
            local last = p.days and p.days[#p.days]
            local mine = o.lastDay
            if p.now and (not mine or (last and last.day > mine) or (last and last.day == mine and (p.seenAt or 0) > (o.seenAt or 0))) then
                o.now, o.seenAt, o.lastDay, o.stale = p.now, p.seenAt, last and last.day or mine, p.stale
            end
            for _, d in ipairs(p.days or {}) do
                local e = o.byDay[d.day]
                if not e then
                    e = { day = d.day, low = d.low, high = d.high, available = d.available }
                    o.byDay[d.day] = e
                    o.days[#o.days + 1] = e
                else
                    if d.low and (not e.low or d.low < e.low) then e.low = d.low end
                    if d.high and (not e.high or d.high > e.high) then e.high = d.high end
                    if d.available and (not e.available or d.available > e.available) then e.available = d.available end
                end
            end
        end
    end
    for _, o in pairs(out.prices) do
        table.sort(o.days, function(a, b) return a.day < b.day end)
        o.byDay, o.lastDay = nil, nil
    end
    return out
end

-- Several StockpileDB tables, each with that PC's account rows ({ { stock, rows = { [guid] = row } } }) -> one:
-- for each character, the entry from the PC where it was last seen (what it holds now); unknown, the first PC's
function Mg.stockpiles(list)
    local srcs = {}
    for _, s in ipairs(list or {}) do if type(s) == "table" and type(s.stock) == "table" then srcs[#srcs + 1] = s end end
    if #srcs <= 1 then return srcs[1] and srcs[1].stock end
    local out = copy(srcs[1].stock)
    out.chars = {}
    local when = {}
    for _, s in ipairs(srcs) do
        local seen = {}
        for _, row in pairs(s.rows or {}) do
            if type(row) == "table" and row.name then
                seen[string.lower(row.name) .. "-" .. tostring(row.realm)] = row.lastSeen or 0
            end
        end
        for key, c in pairs(s.stock.chars or {}) do
            if type(c) == "table" then
                local t = seen[string.lower(tostring(c.name)) .. "-" .. tostring(c.realm)] or -1
                if not out.chars[key] or t > when[key] then
                    out.chars[key], when[key] = c, t
                end
            end
        end
    end
    return out
end

return Mg
