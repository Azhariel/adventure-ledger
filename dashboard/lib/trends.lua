-- AH trends: the reset setting, family grids, the sell/buy strip, the wanted list and the page data.
-- Pure functions: build.lua passes in what the engine wrote (market.lua) and what it read elsewhere.
local T = {}

-- MIN_N and MIN_CELLS mirror the engine's WEEK_MIN_N and WEEK_MIN_CELLS (market.py).
T.C = { MIN_N = 2, MIN_CELLS = 0.6, STRIP_PCT = 0.05, STRIP_MIN_HOURS = 2, STRIP_RUNS = 2 }

local DAYS = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }
local CELLS = 168

local function defaultReset(utcHourToLocal)
    local hour, shift = utcHourToLocal(15)
    return { dow = (1 + (shift or 0)) % 7, hour = hour }
end

-- "Tue 12", "Tue 12:00", "tuesday 12:00" -> { dow (Mon = 0), hour }, warning|nil.
function T.parseReset(text, utcHourToLocal)
    utcHourToLocal = utcHourToLocal or function(h) return h, 0 end
    if text == nil or text == "" then return defaultReset(utcHourToLocal), nil end
    local name, hh = tostring(text):match("^%s*(%a+)%s+(%d%d?)%f[%D]")
    local dow
    if name then
        name = name:lower()
        for i, d in ipairs(DAYS) do
            if name == d or name == d:sub(1, 3) then dow = i - 1 end
        end
    end
    local hour = hh and tonumber(hh)
    local rest = hh and tostring(text):match("^%s*%a+%s+%d%d?(.*)$") or ""
    local minutes = rest:match("^:(%d%d)%s*$")
    if dow and hour and hour <= 23 and (rest:match("^%s*$") or minutes) then
        return { dow = dow, hour = hour }, nil
    end
    return defaultReset(utcHourToLocal),
        'ah_reset: couldn\'t read "' .. tostring(text) .. '"; using Tue 12:00. Write it like: ah_reset = Tue 12:00'
end

-- Merges member week grids into one family grid, weighted by units sold (+1 so unsold cells still count).
-- Members pool their observations: any member cell with a price counts, and a family cell fills once the counted
-- members' observations there reach MIN_N together (each item sees about one per cell per week).
function T.familyWeek(members)
    if not members or #members == 0 then return nil end
    local f = { p = {}, s = {}, n = {}, members = 0, ownCount = 0 }
    local function usable(m, i)
        local mp, mn = m and m.p and m.p[i], m and m.n and m.n[i]
        return type(mp) == "number" and type(mn) == "number" and mn >= 1
    end
    for _, m in ipairs(members) do
        local any = false
        for i = 1, CELLS do
            if usable(m, i) then any = true break end
        end
        if any then
            f.members = f.members + 1
            if m.own == true then f.ownCount = f.ownCount + 1 end
        end
    end
    if f.members == 0 then return nil end
    local filled = 0
    for i = 1, CELLS do
        local sum, wsum, s, n = 0, 0, 0, 0
        for _, m in ipairs(members) do
            if usable(m, i) then
                local ms = (m.s and type(m.s[i]) == "number") and m.s[i] or 0
                sum = sum + m.p[i] * (ms + 1)
                wsum = wsum + ms + 1
                s, n = s + ms, n + m.n[i]
            end
        end
        if n >= T.C.MIN_N then
            f.p[i], f.s[i], f.n[i] = sum / wsum, s, n
            filled = filled + 1
        else
            f.p[i], f.s[i], f.n[i] = false, false, false
        end
    end
    f.enough = filled >= T.C.MIN_CELLS * CELLS
    return f
end

local function best(runs)
    table.sort(runs, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.dow ~= b.dow then return a.dow < b.dow end
        return a.from < b.from
    end)
    local out = {}
    for i = 1, math.min(T.C.STRIP_RUNS, #runs) do
        out[i] = { dow = runs[i].dow, from = runs[i].from, to = runs[i].to }
    end
    return out
end

-- Best runs of cheap (buy) and pricey (sell) hours; nil when the grid isn't trustworthy.
function T.strip(week)
    if not week or (week.own ~= true and week.enough ~= true) then return nil end
    local sell, buy = {}, {}
    for dow = 0, 6 do
        for _, kind in ipairs({ "sell", "buy" }) do
            local runs = kind == "sell" and sell or buy
            local start, score = nil, 0
            local function close(h)
                if start and h - start >= T.C.STRIP_MIN_HOURS then
                    runs[#runs + 1] = { dow = dow, from = start, to = h, score = score }
                end
                start, score = nil, 0
            end
            for h = 0, 23 do
                local i = dow * 24 + h + 1
                local p, n = week.p and week.p[i], week.n and week.n[i]
                local hit = type(p) == "number" and type(n) == "number" and n >= T.C.MIN_N
                    and (kind == "sell" and p >= T.C.STRIP_PCT or kind == "buy" and p <= -T.C.STRIP_PCT)
                if hit then
                    start = start or h
                    score = score + math.abs(p)
                else
                    close(h)
                end
            end
            close(24)
        end
    end
    return { sell = best(sell), buy = best(buy) }
end

-- The wanted item ids: family members, plus owned and traded ids ({ [id] = true } sets).
function T.wantedIds(families, ownedIds, tradedIds)
    local ids = {}
    for _, f in ipairs(families or {}) do
        for _, id in ipairs(f.ids or {}) do ids[id] = true end
    end
    for id in pairs(ownedIds or {}) do ids[id] = true end
    for id in pairs(tradedIds or {}) do ids[id] = true end
    return ids
end

-- Sorted "key\tid\n" lines: the wanted ids (T.wantedIds) for every house key.
function T.wanted(families, ownedIds, tradedIds, houseKeys)
    local ids = T.wantedIds(families, ownedIds, tradedIds)
    local lines = {}
    for _, key in ipairs(houseKeys or {}) do
        for id in pairs(ids) do lines[#lines + 1] = key .. "\t" .. tostring(id) .. "\n" end
    end
    table.sort(lines)
    return table.concat(lines)
end

local ITEM_FIELDS = { "now", "market", "historical", "soldPerDay", "trend", "days", "shifted", "spark", "week",
    "hourly", "daily" }

-- result.trends: per house key, the engine's data trimmed to what the page uses, plus the family grids.
-- wanted (optional { [id] = true }, T.wantedIds): only those items are embedded; the page reads every other
-- item's numbers from the market tabs.
function T.page(apiByKey, families, nameOf, reset, defaultKey, wanted)
    local out = { reset = reset, default = defaultKey, stripRule = T.C, houses = {} }
    for key, h in pairs(apiByKey or {}) do
        local items = {}
        for id, it in pairs(h.items or {}) do
            local name = (wanted == nil or wanted[id]) and nameOf(id) or nil
            if name ~= nil then
                local e = { name = name }
                for _, k in ipairs(ITEM_FIELDS) do e[k] = it[k] end
                items[tostring(id)] = e
            end
        end
        local fams = {}
        for _, f in ipairs(families or {}) do
            local ids, members = {}, {}
            for _, id in ipairs(f.ids or {}) do
                local it = h.items and h.items[id]
                if it then
                    ids[#ids + 1] = id
                    if it.week then members[#members + 1] = it.week end
                end
            end
            fams[#fams + 1] = { key = f.key, label = f.label, week = T.familyWeek(members), ids = ids }
        end
        out.houses[key] = { id = h.id, latest = h.latest, first = h.first, snapshots = h.snapshots, ts = h.ts,
            seriesDays = h.seriesDays, sparkDays = h.sparkDays, week = h.week, families = fams, items = items }
    end
    return out
end

return T
