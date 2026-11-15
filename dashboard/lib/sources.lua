-- Readers for each addon's saved data, turning it into plain tables the model can use.
local U = require("util")
local CBOR = require("cbor")

local S = {}

-- Item names from QuestieDB's baked TOC ("## X-Item-<id>-S: <base64 CBOR>", field 1 = name).
-- Returns { [itemID] = name }. Missing file -> empty table.
function S.questieItemNames(tocPath)
    local names = {}
    local f = io.open(tocPath, "rb")
    if not f then
        return names
    end
    for line in f:lines() do
        local id, b64 = line:match("^## X%-Item%-(%d+)%-S: ([%w%+/=]+)")
        if id then
            local row = CBOR.decode(U.base64decode(b64))
            if type(row) == "table" and type(row[1]) == "string" then
                names[tonumber(id)] = row[1]
            end
        end
    end
    f:close()
    return names
end

-- Auctionator: { prices = { [itemID] = { now = copper, days = { { day, low, high, available } } } },
--               vendor = { [itemID] = copper } }. Uses the realm with most items.
S.SCAN_DAY_0 = os.time({ year = 2020, month = 1, day = 1, hour = 0 })

-- One Auctionator-shaped price book ({ [dbKey] = { l, h, a, m } }) as { [itemID] = { now, days, seenAt } }
function S.priceBook(book)
    local prices = {}
    for key, e in pairs(book or {}) do
        local id = tonumber(key)
        if id and type(e) == "table" then
            local days = {}
            for day, high in pairs(e.h or {}) do
                local d = tonumber(day)
                if d then
                    days[#days + 1] = { day = d, low = (e.l or {})[day] or high, high = high, available = (e.a or {})[day] }
                end
            end
            table.sort(days, function(a, b) return a.day < b.day end)
            prices[id] = { now = e.m, days = days, seenAt = e.t }
        end
    end
    return prices
end

function S.auctionator(env)
    local out = { prices = {}, vendor = {} }
    if not env then
        return out
    end
    local best, bestN
    for realm, data in pairs(env.AUCTIONATOR_PRICE_DATABASE or {}) do
        if realm ~= "__dbversion" then
            local db = type(data) == "string" and CBOR.decode(data) or data
            if type(db) == "table" then
                local n = 0
                for _ in pairs(db) do n = n + 1 end
                if not bestN or n > bestN then
                    best, bestN = db, n
                end
            end
        end
    end
    out.prices = S.priceBook(best)
    for key, price in pairs(env.AUCTIONATOR_VENDOR_PRICE_CACHE or {}) do
        local id = tonumber(key)
        if id and type(price) == "number" then
            out.vendor[id] = math.floor(price + 0.5)
        end
    end
    return out
end

-- Ledger Link's Neutral auction house book (LedgerLinkDB.neutral, kept apart from Auctionator's).
-- Returns { prices, vendor = {}, last, visits = { { t, kind, zone } }, mode } or nil when there's none.
function S.neutral(env)
    local d = env and env.LedgerLinkDB
    if type(d) ~= "table" then return nil end
    local prices = S.priceBook(d.neutral)
    local visits = {}
    for _, v in ipairs(d.visits or {}) do
        if type(v) == "table" and v.t then visits[#visits + 1] = { t = v.t, kind = v.kind, zone = v.zone } end
    end
    if not next(prices) and #visits == 0 then return nil end
    return { prices = prices, vendor = {}, last = d.neutralLast, visits = visits, mode = d.neutralMode }
end

function S.timeToDay(t)
    return math.floor((t - S.SCAN_DAY_0) / 86400)
end

function S.dayToTime(day)
    return S.SCAN_DAY_0 + day * 86400
end

-- MuddyBoots log line: "t|played|mapID|x|y|kind|args..."
function S.parseLogLine(line)
    local f = U.split(line, "|")
    local e = {
        t = tonumber(f[1]),
        played = tonumber(f[2]),
        map = tonumber(f[3]),
        x = tonumber(f[4]),
        y = tonumber(f[5]),
        kind = f[6] or "?",
        args = {},
    }
    for i = 7, #f do
        e.args[#e.args + 1] = f[i]
    end
    return e
end

function S.parseLog(log)
    local events = {}
    for _, line in ipairs(log or {}) do
        if type(line) == "string" then
            local e = S.parseLogLine(line)
            if e.t then
                events[#events + 1] = e
            end
        end
    end
    table.sort(events, function(a, b) return a.t < b.t end)
    return events
end

-- One character's journey from Logbook (ours) and MuddyBoots, in the shape the model reads (MuddyBoots' shape:
-- { char, counts, log, sessions, snap, trail }). Logbook takes over at lb.since: MuddyBoots' lines, sessions and
-- trail from before then are kept, the rest comes from Logbook. Counters are Logbook's plus the MuddyBoots
-- baseline it copied at its first login (records such as the longest fight take the larger). Either may be nil.
S.MAX_COUNTERS = { longest = true, hardest = true, bestDps = true, biggest = true }

local function lineTime(line)
    return type(line) == "string" and tonumber(line:match("^(%d+)")) or nil
end

function S.mergeJournal(lb, mb)
    if type(lb) ~= "table" then return mb end
    local since = tonumber(lb.since) or math.huge
    mb = type(mb) == "table" and mb or {}
    local out = { char = {}, counts = {}, log = {}, sessions = {}, snap = {}, trail = { v = 1, chunks = {} },
        since = lb.since, source = mb.log and "Logbook + MuddyBoots" or "Logbook" }
    for k, v in pairs(mb.char or {}) do out.char[k] = v end
    for k, v in pairs(lb.char or {}) do out.char[k] = v end
    -- levels never go down: an older Logbook could save level 1 from a logout to the character list
    out.char.level = math.max(tonumber(lb.char and lb.char.level) or 0, tonumber(mb.char and mb.char.level) or 0)
    if out.char.level == 0 then out.char.level = nil end
    out.char.first = (mb.char and mb.char.first) or (lb.baseline and lb.baseline.first) or (lb.char and lb.char.first)
    for _, line in ipairs(mb.log or {}) do
        local t = lineTime(line)
        if t and t < since then out.log[#out.log + 1] = line end
    end
    for _, line in ipairs(lb.log or {}) do out.log[#out.log + 1] = line end
    for _, s in ipairs(mb.sessions or {}) do
        if type(s) == "table" and (s.start or 0) < since then out.sessions[#out.sessions + 1] = s end
    end
    for _, s in ipairs(lb.sessions or {}) do out.sessions[#out.sessions + 1] = s end
    for lvl, s in pairs(mb.snap or {}) do out.snap[lvl] = s end
    for lvl, s in pairs(lb.snap or {}) do out.snap[lvl] = s end
    for _, c in ipairs(mb.trail and mb.trail.chunks or {}) do
        if type(c) == "table" and (tonumber(c.t) or 0) < since then out.trail.chunks[#out.trail.chunks + 1] = c end
    end
    for _, c in ipairs(lb.trail and lb.trail.chunks or {}) do out.trail.chunks[#out.trail.chunks + 1] = c end
    local function add(src)
        for group, list in pairs(src or {}) do
            if type(list) == "table" then
                local dst = out.counts[group] or {}
                out.counts[group] = dst
                for k, v in pairs(list) do
                    if type(v) == "number" then
                        if S.MAX_COUNTERS[k] then
                            dst[k] = math.max(dst[k] or v, v)
                        else
                            dst[k] = (dst[k] or 0) + v
                        end
                    end
                end
            end
        end
    end
    add(lb.baseline and lb.baseline.counts)
    add(lb.counts)
    return out
end

-- Every character's account row ({ [guid] = { name, realm, level, money, played, lastSeen, ... } }): Logbook's
-- where it has one (field by field, the newer row wins), MuddyBoots' otherwise
function S.mergeAccountChars(lbDB, mbDB)
    local out = {}
    for guid, c in pairs(mbDB and mbDB.chars or {}) do
        if type(c) == "table" then out[guid] = c end
    end
    for guid, c in pairs(lbDB and lbDB.chars or {}) do
        if type(c) == "table" then
            local old = out[guid]
            local level = math.max(tonumber(c.level) or 0, tonumber(old and old.level) or 0)
            if old and (old.lastSeen or 0) > (c.lastSeen or 0) then
                local row = {}
                for k, v in pairs(c) do row[k] = v end
                for k, v in pairs(old) do row[k] = v end
                out[guid] = row
            else
                local row = {}
                for k, v in pairs(old or {}) do row[k] = v end
                for k, v in pairs(c) do row[k] = v end
                out[guid] = row
            end
            if level > 0 then out[guid].level = level end
        end
    end
    return next(out) and out or nil
end

-- Lists the sub-directories of a folder (Windows `dir`, POSIX `ls` fallback). Overridable in tests.
function S.listDirs(path)
    local out = {}
    local windows = package.config:sub(1, 1) == "\\"
    local cmd = windows and ('dir "' .. path:gsub("/", "\\") .. '" /b /ad 2>nul')
        or ('find "' .. path .. '" -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; 2>/dev/null')
    local p = io.popen(cmd)
    if p then
        for name in p:lines() do
            if name ~= "" then out[#out + 1] = name end
        end
        p:close()
    end
    table.sort(out)
    return out
end

return S
