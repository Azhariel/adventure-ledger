-- Model: turns the addons' saved data into the plain data the dashboard page draws.
-- Pure functions over tables (no file access), so every figure can be tested offline.
local S = require("sources")

local M = {}

M.PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Inscription = true, Jewelcrafting = true, Leatherworking = true, Mining = true, Skinning = true,
    Tailoring = true, Cooking = true, ["First Aid"] = true, Fishing = true,
}
M.ZONE_GAP = 600 -- seconds; longer gaps between events are time offline, not time in the zone

local function hours(seconds)
    return seconds and math.floor(seconds / 36) / 100 or nil
end

local function num(v)
    return tonumber(v) or 0
end

local function sortedPairsByValue(t, field, limit)
    local list = {}
    for k, v in pairs(t) do
        v.name = v.name or k
        list[#list + 1] = v
    end
    table.sort(list, function(a, b)
        if a[field] ~= b[field] then return a[field] > b[field] end
        return tostring(a.name) < tostring(b.name)
    end)
    if limit and #list > limit then
        for i = #list, limit + 1, -1 do list[i] = nil end
    end
    return list
end

----------------------------------------------------------------------------------------------------
-- Names

-- Builds a name lookup (id -> name) and reverse lookup (name -> id) from every source that knows item names.
function M.nameBook(base, haul, muddyEvents, mob)
    local names, byName = {}, {}
    for id, n in pairs(base or {}) do
        names[id] = n
        if type(n) == "string" and (not byName[n] or id < byName[n]) then byName[n] = id end
    end
    for id, item in pairs(haul and haul.current and haul.current.session and haul.current.session.items or {}) do
        local n = type(item.link) == "string" and item.link:match("%[(.-)%]")
        local numId = tonumber(id) or id
        if n then names[numId] = n; byName[n] = numId end
    end
    for _, r in pairs(mob and mob.recipes or {}) do
        if r.outputItemID and r.name then
            names[r.outputItemID] = names[r.outputItemID] or r.name
            byName[r.name] = byName[r.name] or r.outputItemID
        end
    end
    for _, e in ipairs(muddyEvents or {}) do
        if e.kind == "lo" and tonumber(e.args[1]) and e.args[5] and e.args[5] ~= "" then
            local numId = tonumber(e.args[1])
            names[numId] = e.args[5]
            byName[e.args[5]] = numId
        end
    end
    return function(id)
        return names[id] or ("Item #" .. tostring(id))
    end, function(name)
        return name and byName[name] or nil
    end
end

----------------------------------------------------------------------------------------------------
-- Leveling

-- Cumulative XP over played hours, and when each level was reached
function M.xpSeries(events)
    local series, levels, total = {}, {}, 0
    for _, e in ipairs(events) do
        if e.kind == "xp" and e.played then
            total = total + num(e.args[1])
            series[#series + 1] = { h = hours(e.played), xp = total }
        elseif e.kind == "lv" and e.played then
            levels[#levels + 1] = { level = num(e.args[1]), h = hours(e.played), t = e.t }
        end
    end
    return series, levels
end

-- Time spent in each level: from reaching it to reaching the next (the current one runs to `playedNow`).
-- startLevel/startPlayed: where the log begins (MuddyBoots' "first" record and its first played time).
function M.levelTimes(levels, startLevel, startPlayed, playedNow, currentLevel)
    local marks = {}
    if startLevel and startPlayed then
        marks[#marks + 1] = { level = startLevel, played = startPlayed }
    end
    for _, l in ipairs(levels) do
        marks[#marks + 1] = { level = l.level, played = l.h and l.h * 3600 }
    end
    local out = {}
    for i, m in ipairs(marks) do
        local nextMark = marks[i + 1]
        local stop = nextMark and nextMark.played or (m.level == currentLevel and playedNow) or nil
        if m.played and stop and stop >= m.played then
            out[#out + 1] = { level = m.level, seconds = math.floor(stop - m.played), current = nextMark == nil,
                partial = i == 1 and startLevel ~= nil }
        end
    end
    return out
end

-- XP by source, overall and per level, from MuddyBoots' counters ("quest", "quest:12", ...)
function M.xpBySource(counts)
    local totals, byLevel = {}, {}
    for key, v in pairs(counts or {}) do
        local source, level = key:match("^(%a+):(%d+)$")
        if source then
            level = tonumber(level)
            byLevel[level] = byLevel[level] or { level = level }
            byLevel[level][source] = (byLevel[level][source] or 0) + v
        elseif key ~= "all" then
            totals[key] = v
        end
    end
    local list = {}
    for _, row in pairs(byLevel) do list[#list + 1] = row end
    table.sort(list, function(a, b) return a.level < b.level end)
    return totals, list
end

----------------------------------------------------------------------------------------------------
-- Money

-- Money in and out over played hours, from MuddyBoots' "mn" lines (delta, src): every change to your gold,
-- quest rewards included (so "qt" money isn't added again). Returns
--   series = { { h, earned, spent } } (running totals), earned = { [src] = copper }, spent = { [src] = copper }
-- src: vendor | trainer | mail | auction | bank | trade | gossip | quest | flight | repair | loot | postage | respec | other
-- MuddyBoots sometimes tags an AH sale's gold "mail" (it arrives by mail): a "mail" gain with an AH invoice
-- ("ma" invoice) of the same copper logged within INVOICE_SECONDS counts as "auction". Each invoice is used once.
-- (Several sales opened at once are logged in a burst, so the invoice can be many lines away, but not seconds.)
M.INVOICE_SECONDS = 5
local INVOICE_SCAN = 40 -- lines either side to look at
function M.money(events)
    local series, earned, spent = {}, {}, {}
    local inTotal, outTotal = 0, 0
    local usedInvoice = {}
    local function isAHSale(i, delta)
        local t = events[i].t
        if not t then return false end
        for j = math.max(1, i - INVOICE_SCAN), math.min(#events, i + INVOICE_SCAN) do
            local m = events[j]
            if not usedInvoice[j] and m.kind == "ma" and m.args[1] == "invoice" and num(m.args[3]) == delta
                and m.t and math.abs(m.t - t) <= M.INVOICE_SECONDS then
                usedInvoice[j] = true
                return true
            end
        end
        return false
    end
    for i, e in ipairs(events) do
        if e.kind == "mn" then
            local delta, src = num(e.args[1]), (e.args[2] ~= "" and e.args[2]) or "other"
            if src == "mail" and delta > 0 and isAHSale(i, delta) then
                src = "auction"
            end
            if delta > 0 then
                earned[src] = (earned[src] or 0) + delta
                inTotal = inTotal + delta
            elseif delta < 0 then
                spent[src] = (spent[src] or 0) - delta
                outTotal = outTotal - delta
            end
            if delta ~= 0 and e.played then
                series[#series + 1] = { h = hours(e.played), earned = inTotal, spent = outTotal }
            end
        end
    end
    return series, earned, spent
end

-- { { source, copper } } largest first
local function ranked(t)
    local list = {}
    for k, v in pairs(t) do list[#list + 1] = { source = k, copper = v } end
    table.sort(list, function(a, b) return a.copper > b.copper or (a.copper == b.copper and a.source < b.source) end)
    return list
end
M.ranked = ranked

-- How gold on hand adds up: what you had when the log began, plus what it logged, against what you have now.
-- Each level-up has a snapshot of your gold (snaps[level].money, saved at the ding), so gold minus the money
-- logged so far gives the gold you started with; while every change is logged that figure stays put, and where
-- it moves, money changed without a log line. Returns nil without a gold figure, else
--   { now, logged (earned - spent), start (nil without a snapshot), startLevel, unrecorded (now - start - logged),
--     gaps = { { from, to (levels), copper (+ gold the log missed, - gold it counted that you never had) } } }
-- gaps of at least GAP_MIN copper, biggest first.
M.MONEY_GAP_MIN = 100
function M.moneyCheck(events, snaps, moneyNow)
    if not moneyNow then return nil end
    local net, marks = 0, {}
    for _, e in ipairs(events or {}) do
        if e.kind == "mn" then
            net = net + num(e.args[1])
        elseif e.kind == "lv" then
            local L = num(e.args[1])
            local s = snaps and snaps[L]
            if s and s.money then marks[#marks + 1] = { level = L, start = s.money - net } end
        end
    end
    local out = { now = moneyNow, logged = net, gaps = {} }
    local first = marks[1]
    if not first then return out end
    out.start, out.startLevel = first.start, first.level
    out.unrecorded = moneyNow - first.start - net
    for i = 2, #marks + 1 do
        local a, b = marks[i - 1], marks[i]
        -- after the last level-up, today's gold is the last mark
        local bStart, bLevel = b and b.start or (moneyNow - net), b and b.level or nil
        local d = bStart - a.start
        if math.abs(d) >= M.MONEY_GAP_MIN then
            out.gaps[#out.gaps + 1] = { from = a.level, to = bLevel, copper = d }
        end
    end
    table.sort(out.gaps, function(x, y) return math.abs(x.copper) > math.abs(y.copper) end)
    return out
end

-- Gold on hand at each level snapshot plus now
function M.moneySeries(snaps, playedNow, moneyNow)
    local list = {}
    for _, s in pairs(snaps or {}) do
        if s.played and s.money then
            list[#list + 1] = { h = hours(s.played), copper = s.money }
        end
    end
    if playedNow and moneyNow then
        list[#list + 1] = { h = hours(playedNow), copper = moneyNow }
    end
    table.sort(list, function(a, b) return a.h < b.h end)
    return list
end

local function parseItemQty(raw)
    if not raw or raw == "" then return nil, 1 end
    local name, cnt = raw:match("^(.+) x(%d+)$")
    if name and tonumber(cnt) and tonumber(cnt) > 0 then
        return name, tonumber(cnt)
    end
    return raw, 1
end
M.parseItemQty = parseItemQty

-- Auction house trades and per-item summary from MuddyBoots' "ah", "ma" (invoice) and "mn" (auction) lines.
-- Pairs sales with their mail invoices (buyer name), buyouts with their money lines and buyer invoices (seller name),
-- and batch deposits with their post line. Consecutive identical trades within 30s merge into one row.
function M.ahTrades(events, idOf)
    local usedMn, usedMa = {}, {}
    local raw = {}
    local lastPost

    local function findMn(i, sign, copper, what, maxDt)
        local t = events[i].t or 0
        local best
        for j = math.max(1, i - INVOICE_SCAN), math.min(#events, i + INVOICE_SCAN) do
            local m = events[j]
            if not usedMn[j] and m.kind == "mn" and m.t and math.abs(m.t - t) <= (maxDt or M.INVOICE_SECONDS) then
                local d, src, mw = num(m.args[1]), m.args[2] or "", m.args[3] or ""
                if d * sign > 0 and (src == "auction" or (sign > 0 and src == "mail"))
                    and (not copper or math.abs(d) == copper) then
                    if what and mw == what then
                        usedMn[j] = true
                        return math.abs(d), mw
                    elseif not best and (not what or mw == "" or sign > 0) then
                        best = j
                    end
                end
            end
        end
        if best then
            usedMn[best] = true
            return math.abs(num(events[best].args[1])), events[best].args[3] or ""
        end
        return nil
    end

    local function findInvoice(i, isSeller, copper, name, rawItem)
        local t = events[i].t or 0
        local maxDt = isSeller and M.INVOICE_SECONDS or 120
        local span = isSeller and INVOICE_SCAN or 80
        for j = math.max(1, i - (isSeller and span or 5)), math.min(#events, i + span) do
            local m = events[j]
            if not usedMa[j] and m.kind == "ma" and m.args[1] == "invoice" and m.t then
                local dt = m.t - t
                if (isSeller and math.abs(dt) <= maxDt) or (not isSeller and dt >= -2 and dt <= maxDt) then
                    local mc = tonumber(m.args[3])
                    local mi = m.args[4] or ""
                    if isSeller and mc == copper and (mi == rawItem or mi == name) then
                        usedMa[j] = true
                        local who = m.args[2]
                        return (who and who ~= "" and who ~= "?") and who or nil
                    elseif not isSeller and not mc and (mi == name or mi == rawItem) then
                        usedMa[j] = true
                        local who = m.args[2]
                        return (who and who ~= "" and who ~= "?") and who or nil
                    end
                end
            end
        end
        return nil
    end

    for i, e in ipairs(events or {}) do
        if e.kind == "ah" then
            local act = e.args[1] or ""
            local copper = tonumber(e.args[2])
            local rawItem = e.args[3] or ""
            local name, count = parseItemQty(rawItem)
            if act == "sold" and name then
                local got = findMn(i, 1, copper, rawItem)
                local who = findInvoice(i, true, copper, name, rawItem)
                -- Logbook before 2026-11-15 logged a sale on every open-all retry: a repeat with no gold of its
                -- own, seconds after the same sale, is that retry, not another sale
                local repeat_ = false
                if not got then
                    for k = #raw, 1, -1 do
                        local r = raw[k]
                        if r.t and e.t and e.t - r.t > M.INVOICE_SECONDS then break end
                        if r.act == "sold" and r.name == name and r.count == count and r.copper == (copper or 0) then
                            repeat_ = true
                            if who and not r.who then r.who = who end
                            break
                        end
                    end
                end
                if not repeat_ then
                    raw[#raw + 1] = { t = e.t, act = "sold", name = name, count = count, copper = copper or 0, who = who }
                end
            elseif (act == "buyout" or act == "bid") and name then
                local spent = findMn(i, -1, copper, rawItem)
                copper = copper or spent or 0
                local who = findInvoice(i, false, nil, name, rawItem)
                raw[#raw + 1] = { t = e.t, act = act, name = name, count = count, copper = copper, who = who }
            elseif act == "post" and name then
                local dep = findMn(i, -1, copper, rawItem, 3)
                copper = copper or dep or 0
                raw[#raw + 1] = { t = e.t, act = "post", name = name, count = count, copper = copper }
                lastPost = { t = e.t, name = name, deposit = copper }
            elseif act == "expired" and name then
                raw[#raw + 1] = { t = e.t, act = "expired", name = name, count = count, copper = 0 }
            end
        elseif e.kind == "mn" and not usedMn[i] and e.args[2] == "auction" then
            -- Batch deposits right after an ah|post have no item name on their mn line
            local d, what = num(e.args[1]), e.args[3] or ""
            if d < 0 and what == "" and lastPost and e.t and lastPost.t and (e.t - lastPost.t) <= 10 and -d == lastPost.deposit then
                usedMn[i] = true
                raw[#raw + 1] = { t = e.t, act = "post", name = lastPost.name, count = 1, copper = -d }
                lastPost.t = e.t
            end
        end
    end

    -- Any seller invoice or named auction money line that had no matching "ah" event
    for i, e in ipairs(events or {}) do
        if e.kind == "ma" and not usedMa[i] and e.args[1] == "invoice" and num(e.args[3]) > 0 then
            local copper = num(e.args[3])
            local name, count = parseItemQty(e.args[4] or "")
            if name then
                usedMa[i] = true
                findMn(i, 1, copper, e.args[4])
                local who = (e.args[2] and e.args[2] ~= "" and e.args[2] ~= "?") and e.args[2] or nil
                raw[#raw + 1] = { t = e.t, act = "sold", name = name, count = count, copper = copper, who = who }
            end
        elseif e.kind == "mn" and not usedMn[i] and e.args[2] == "auction" and (e.args[3] or "") ~= "" then
            local d = num(e.args[1])
            local name, count = parseItemQty(e.args[3])
            if name and d ~= 0 then
                usedMn[i] = true
                raw[#raw + 1] = { t = e.t, act = d > 0 and "sold" or "buyout", name = name, count = count, copper = math.abs(d) }
            end
        end
    end

    table.sort(raw, function(a, b) return (a.t or 0) < (b.t or 0) end)

    local totals = { sold = 0, soldCount = 0, bought = 0, boughtCount = 0, deposits = 0, postCount = 0, expiredCount = 0, net = 0 }
    local byName = {}
    local merged = {}

    for _, r in ipairs(raw) do
        local unit = r.count > 0 and math.floor(r.copper / r.count + 0.5) or 0
        local item = byName[r.name]
        if not item then
            item = { id = idOf and idOf(r.name) or nil, name = r.name, boughtCount = 0, boughtCopper = 0,
                soldCount = 0, soldCopper = 0, posts = 0, deposits = 0, expired = 0, last = r.t or 0 }
            byName[r.name] = item
        end
        item.last = math.max(item.last, r.t or 0)
        if r.act == "sold" then
            item.soldCount = item.soldCount + r.count
            item.soldCopper = item.soldCopper + r.copper
            totals.sold = totals.sold + r.copper
            totals.soldCount = totals.soldCount + r.count
        elseif r.act == "buyout" or r.act == "bid" then
            item.boughtCount = item.boughtCount + r.count
            item.boughtCopper = item.boughtCopper + r.copper
            totals.bought = totals.bought + r.copper
            totals.boughtCount = totals.boughtCount + r.count
        elseif r.act == "post" then
            item.posts = item.posts + r.count
            item.deposits = item.deposits + r.copper
            totals.deposits = totals.deposits + r.copper
            totals.postCount = totals.postCount + r.count
        elseif r.act == "expired" then
            item.expired = item.expired + r.count
            totals.expiredCount = totals.expiredCount + r.count
        end

        -- Merge bursts of the same action, item and unit price within 30s (even if another mail was looted in between)
        local target
        for j = #merged, math.max(1, #merged - 5), -1 do
            local m = merged[j]
            if (r.t or 0) - (m.t or 0) > 30 then break end
            if m.act == r.act and m.name == r.name and m.unit == unit then
                target = m
                break
            end
        end
        if target then
            target.t = r.t or target.t
            target.count = target.count + r.count
            target.copper = target.copper + r.copper
            target.unit = target.count > 0 and math.floor(target.copper / target.count + 0.5) or 0
            if r.who then
                target.who = target.who or {}
                local seen = false
                for _, w in ipairs(target.who) do if w == r.who then seen = true break end end
                if not seen then target.who[#target.who + 1] = r.who end
            end
        else
            merged[#merged + 1] = {
                t = r.t, act = r.act, id = item.id, name = r.name,
                count = r.count, unit = unit, copper = r.copper,
                who = r.who and { r.who } or nil,
            }
        end
    end

    totals.net = totals.sold - totals.bought - totals.deposits

    local items = {}
    for _, it in pairs(byName) do
        it.avgBuy = it.boughtCount > 0 and math.floor(it.boughtCopper / it.boughtCount + 0.5) or nil
        it.avgSell = it.soldCount > 0 and math.floor(it.soldCopper / it.soldCount + 0.5) or nil
        it.net = it.soldCopper - it.boughtCopper - it.deposits
        items[#items + 1] = it
    end
    table.sort(items, function(a, b)
        local va, vb = a.soldCopper + a.boughtCopper, b.soldCopper + b.boughtCopper
        if va ~= vb then return va > vb end
        if a.last ~= b.last then return a.last > b.last end
        return a.name < b.name
    end)

    local trades = {}
    for i = #merged, 1, -1 do trades[#trades + 1] = merged[i] end
    return { totals = totals, items = items, trades = trades }
end

----------------------------------------------------------------------------------------------------
-- Places, fights, quests, professions

-- Seconds per zone: the time between consecutive events goes to the zone you were in, unless the gap is
-- longer than ZONE_GAP (offline) or spans a logout.
function M.zoneTimes(events)
    local times, zone, last = {}, nil, nil
    for _, e in ipairs(events) do
        if last and zone and e.t - last <= M.ZONE_GAP then
            times[zone] = (times[zone] or 0) + (e.t - last)
        end
        if e.kind == "zo" and e.args[1] and e.args[1] ~= "" then
            zone = e.args[1]
        end
        -- A logout ends the stretch: time until the next login is offline
        if e.kind == "out" then
            last = nil
        else
            last = e.t
        end
    end
    local list = {}
    for name, sec in pairs(times) do list[#list + 1] = { name = name, seconds = sec } end
    table.sort(list, function(a, b) return a.seconds > b.seconds end)
    return list
end

-- Zone you were in at each event time (for deaths and quests)
local function zoneTracker(events)
    local zoneAt, zone = {}, nil
    for i, e in ipairs(events) do
        if e.kind == "zo" and e.args[1] ~= "" then zone = e.args[1] end
        zoneAt[i] = zone
    end
    return zoneAt
end

function M.fights(events, counts, limit)
    local byMob, total = {}, 0
    for _, e in ipairs(events) do
        if e.kind == "ki" and e.args[1] and e.args[1] ~= "" then
            local m = byMob[e.args[1]] or { name = e.args[1], npc = tonumber(e.args[2]), kills = 0, xp = 0, level = num(e.args[6]), type = e.args[3] }
            m.npc = m.npc or tonumber(e.args[2])
            m.kills = m.kills + 1
            m.xp = m.xp + num(e.args[5])
            byMob[e.args[1]] = m
            total = total + 1
        end
    end
    local f = counts or {}
    return {
        top = sortedPairsByValue(byMob, "kills", limit or 12),
        kills = total,
        fights = f.n, combatSeconds = f.sec, longest = f.longest, died = f.died,
    }
end

-- A death's fi line (Logbook, from the damage meter) comes within this many seconds of its de line
M.DEATH_METER_SECONDS = 20

function M.deaths(events)
    local zoneAt, levelNow, out = zoneTracker(events), nil, {}
    for i, e in ipairs(events) do
        if e.kind == "lv" then
            levelNow = num(e.args[1])
        elseif e.kind == "ge" then
            levelNow = levelNow or num(e.args[1])
        elseif e.kind == "de" then
            -- de: killer, npc, spell, env, place, boss, klevel, kclass, amount, byPlayer, inst
            local killer = e.args[1] ~= "" and e.args[1] or "?"
            out[#out + 1] = { t = e.t, killer = killer, npc = tonumber(e.args[2]), killerLevel = tonumber(e.args[7]),
                spell = e.args[3] ~= "" and e.args[3] or nil, env = e.args[4] ~= "" and e.args[4] or nil,
                place = e.args[5] ~= "world" and e.args[5] ~= "" and e.args[5] or nil,
                byPlayer = e.args[10] == "1", zone = zoneAt[i], level = levelNow }
        elseif e.kind == "fi" and (e.args[8] or "") ~= "" then
            -- the meter's killing blow replaces the guess (your last target) when it names someone else
            local d = out[#out]
            if d and d.t and e.t and e.t - d.t >= 0 and e.t - d.t <= M.DEATH_METER_SECONDS and not d.meter then
                if d.killer ~= e.args[8] then d.killer, d.npc, d.killerLevel, d.byPlayer = e.args[8], nil, nil, false end
                d.spell = (e.args[9] or "") ~= "" and e.args[9] or d.spell
                d.meter = true
            end
        end
    end
    return out
end

-- Flights: Logbook's "fl|from|to|copper|seconds|via" (via: stops, "A;B"), and MuddyBoots' older "tx|from|to|copper" (take-off) with the
-- "tl|to" (landing) after it. Totals, routes by use, and the trips newest first.
M.FLIGHT_MAX_SECONDS = 30 * 60 -- a landing later than this after a take-off isn't that flight's

function M.flights(events, limit)
    local trips, takeoff = {}, nil
    for _, e in ipairs(events) do
        if e.kind == "fl" and (e.args[2] or "") ~= "" then
            local via = {}
            for stop in (e.args[5] or ""):gmatch("[^;]+") do via[#via + 1] = stop end
            trips[#trips + 1] = { t = e.t, from = e.args[1] ~= "" and e.args[1] or nil, to = e.args[2],
                copper = tonumber(e.args[3]), seconds = tonumber(e.args[4]), via = #via > 0 and via or nil }
        elseif e.kind == "tx" and (e.args[2] or "") ~= "" then
            takeoff = { t = e.t, from = e.args[1] ~= "" and e.args[1] or nil, to = e.args[2], copper = tonumber(e.args[3]) }
        elseif e.kind == "tl" and takeoff then
            local sec = e.t and takeoff.t and e.t - takeoff.t
            if sec and sec >= 0 and sec <= M.FLIGHT_MAX_SECONDS and (e.args[1] == "" or e.args[1] == takeoff.to) then
                takeoff.seconds = sec
                trips[#trips + 1] = takeoff
            end
            takeoff = nil
        end
    end
    if #trips == 0 then return nil end
    local routes, byKey = {}, {}
    local total = { n = #trips, copper = 0, seconds = 0, longest = 0 }
    for _, r in ipairs(trips) do
        total.copper = total.copper + (r.copper or 0)
        total.seconds = total.seconds + (r.seconds or 0)
        if (r.seconds or 0) > total.longest then total.longest, total.longestTrip = r.seconds, r end
        local key = (r.from or "?") .. " > " .. (r.via and table.concat(r.via, " > ") .. " > " or "") .. r.to
        local route = byKey[key]
        if not route then
            route = { from = r.from, to = r.to, via = r.via, n = 0, copper = 0, seconds = 0, timed = 0 }
            byKey[key] = route
            routes[#routes + 1] = route
        end
        route.n = route.n + 1
        route.copper = route.copper + (r.copper or 0)
        if r.seconds then route.seconds, route.timed = route.seconds + r.seconds, route.timed + 1 end
        route.last = r.t
    end
    for _, route in ipairs(routes) do
        route.avgSeconds = route.timed > 0 and route.seconds / route.timed or nil
    end
    table.sort(routes, function(a, b) return a.n > b.n or (a.n == b.n and (a.last or 0) > (b.last or 0)) end)
    local recent = {}
    for i = #trips, math.max(1, #trips - (limit or 30) + 1), -1 do recent[#recent + 1] = trips[i] end
    total.routes, total.recent = routes, recent
    return total
end

-- Damage from Logbook's damage-meter counters: totals, DPS, per level, your spells, what hurts you
function M.damage(counts, limit)
    local d = counts.damage
    if type(d) ~= "table" or num(d.fights) == 0 then return nil end
    local function list(t)
        local out, total = {}, 0
        for k, v in pairs(t or {}) do
            if type(v) == "number" then out[#out + 1] = { name = k, amount = v }; total = total + v end
        end
        table.sort(out, function(a, b) return a.amount > b.amount or (a.amount == b.amount and a.name < b.name) end)
        for _, r in ipairs(out) do r.share = total > 0 and r.amount / total or 0 end
        while #out > (limit or 15) do table.remove(out) end
        return out
    end
    local byLevel = {}
    for k, v in pairs(d) do
        local lvl = type(k) == "string" and tonumber(k:match("^fights:(%d+)$"))
        if lvl and v > 0 then
            local sec = num(d["sec:" .. lvl])
            byLevel[#byLevel + 1] = { level = lvl, fights = v, seconds = sec, done = num(d["done:" .. lvl]),
                taken = num(d["taken:" .. lvl]), healed = num(d["healed:" .. lvl]),
                dps = sec > 0 and num(d["done:" .. lvl]) / sec or nil }
        end
    end
    table.sort(byLevel, function(a, b) return a.level < b.level end)
    local sec = num(d.sec)
    return {
        fights = num(d.fights), seconds = sec, done = num(d.done), taken = num(d.taken), healed = num(d.healed),
        dps = sec > 0 and num(d.done) / sec or nil, bestDps = d.bestDps, biggest = d.biggest,
        byLevel = byLevel, spells = list(counts.damageBy), from = list(counts.damageFrom),
    }
end

function M.quests(events)
    local zoneAt, out = zoneTracker(events), {}
    for i, e in ipairs(events) do
        if e.kind == "qt" then
            out[#out + 1] = { t = e.t, id = tonumber(e.args[1]), xp = num(e.args[2]), copper = num(e.args[3]),
                name = e.args[4] or "?", zone = zoneAt[i] }
        end
    end
    return out
end

-- Skill level over played hours for real professions (not weapon skills or languages)
function M.professions(events)
    local bySkill = {}
    for _, e in ipairs(events) do
        if e.kind == "sk" and M.PROFESSIONS[e.args[1]] then
            local list = bySkill[e.args[1]] or {}
            local level = num(e.args[2])
            if #list == 0 or list[#list].level ~= level then
                list[#list + 1] = { h = hours(e.played or 0), level = level, max = num(e.args[3]) }
            end
            bySkill[e.args[1]] = list
        end
    end
    local out = {}
    for name, points in pairs(bySkill) do
        out[#out + 1] = { name = name, points = points, level = points[#points].level, max = points[#points].max }
    end
    table.sort(out, function(a, b) return a.level > b.level end)
    return out
end

-- Logbook counts every gathering profession as "gathered"; MuddyBoots, whose counters it carries on, said
-- picked, mined or skinned. The profession's own verb wins so one item is one row.
M.GATHER_VERB = { Herbalism = "picked", Mining = "mined", Skinning = "skinned" }

-- "made|Woolen Bag|Tailoring" = 6 -> { verb, item, profession, count }, most first
function M.crafted(prof)
    local out, byKey = {}, {}
    for key, n in pairs(prof or {}) do
        local verb, item, p = key:match("^(%a+)|(.-)|(.*)$")
        if verb then
            if verb == "gathered" then verb = M.GATHER_VERB[p] or verb end
            local k = verb .. "|" .. item .. "|" .. p
            if byKey[k] then
                byKey[k].count = byKey[k].count + n
            else
                byKey[k] = { verb = verb, item = item, profession = p ~= "?" and p or nil, count = n }
                out[#out + 1] = byKey[k]
            end
        end
    end
    table.sort(out, function(a, b) return a.count > b.count or (a.count == b.count and a.item < b.item) end)
    return out
end

----------------------------------------------------------------------------------------------------
-- Inventory and market

-- Market value of the item: today's AH minimum (nil when the AH has never seen it)
local function marketPrice(market, id)
    local p = market.prices[id]
    return p and p.now or nil
end

-- One character's Stockpile counts valued at AH prices. Returns { items, total, byLocation, unpriced }.
function M.inventory(char, market, nameOf, limit)
    local items, total, unpriced = {}, 0, 0
    local byLocation = { bags = 0, bank = 0, mail = 0 }
    local counts = {}
    for _, loc in ipairs({ "bags", "bank", "mail" }) do
        for id, n in pairs(char and char[loc] or {}) do
            id = tonumber(id)
            if id then
                counts[id] = counts[id] or { bags = 0, bank = 0, mail = 0 }
                counts[id][loc] = n
            end
        end
    end
    for id, c in pairs(counts) do
        local n = c.bags + c.bank + c.mail
        local unit = marketPrice(market, id)
        local value = unit and unit * n or 0
        if unit then
            total = total + value
            for _, loc in ipairs({ "bags", "bank", "mail" }) do
                byLocation[loc] = byLocation[loc] + unit * c[loc]
            end
        else
            unpriced = unpriced + 1
        end
        items[#items + 1] = { id = id, name = nameOf(id), count = n, bags = c.bags, bank = c.bank, mail = c.mail,
            unit = unit, value = value }
    end
    table.sort(items, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.name < b.name
    end)
    local all = #items
    if limit and #items > limit then
        for i = #items, limit + 1, -1 do items[i] = nil end
    end
    return { items = items, total = total, byLocation = byLocation, unpriced = unpriced, kinds = all }
end

-- Price history (days with a price) for a set of items, newest last: { id, name, now, points = { {t, low, high} } }
function M.priceHistory(market, ids, nameOf, minDays)
    local out = {}
    for _, id in ipairs(ids) do
        local p = market.prices[id]
        if p and #p.days >= (minDays or 2) then
            local points = {}
            for _, d in ipairs(p.days) do
                points[#points + 1] = { t = S.dayToTime(d.day), low = d.low, high = d.high, available = d.available }
            end
            out[#out + 1] = { id = id, name = nameOf(id), now = p.now, points = points }
        end
    end
    return out
end

-- Top crafts by profit at saved prices, using Make or Buy's own planner (`P` = its Planner module).
-- Sale value is the AH price after the 5% cut (vendor sell prices aren't saved offline).
function M.crafts(P, recipes, market, nameOf, limit)
    if not (P and recipes) then
        return {}
    end
    local function price(id)
        local ah, vendor = marketPrice(market, id), market.vendor[id]
        if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
        if ah then return ah, "ah" end
        return nil
    end
    local index = P.IndexByOutput(recipes)
    local out = {}
    for _, recipe in pairs(recipes) do
        local plan = P.PlanRecipe(recipe, index, price)
        local ahUnit = marketPrice(market, recipe.outputItemID)
        local value = P.SaleValue(ahUnit, nil)
        if plan.complete and value then
            local profit = P.ProfitFromValue(value, plan.outputQty, plan.total)
            local reagents = {}
            if P.Expand then
                for _, l in ipairs((P.Expand(plan, 1))) do
                    reagents[#reagents + 1] = {
                        id = l.itemID,
                        name = nameOf(l.itemID),
                        depth = l.depth,
                        qty = l.qty,
                        method = l.method,
                        source = l.buySource,
                        unit = math.floor((l.unitCost or 0) + 0.5),
                        total = math.floor((l.unitCost or 0) * l.qty + 0.5),
                        buyTotal = (l.method == "craft" and l.buyPrice) and math.floor(l.buyPrice * l.qty + 0.5) or nil,
                    }
                end
            end
            local cost = math.floor(plan.total)
            local naiveCost = math.floor(plan.naiveTotal or plan.total)
            out[#out + 1] = {
                id = recipe.outputItemID,
                name = recipe.name or nameOf(recipe.outputItemID),
                outputQty = plan.outputQty,
                cost = cost,
                naiveCost = naiveCost,
                gross = ahUnit and math.floor(ahUnit * plan.outputQty) or nil,
                sale = math.floor(value * plan.outputQty),
                profit = profit,
                margin = cost > 0 and (profit / cost) or nil,
                profession = recipe.profession,
                ownReagents = P.UsesSubCrafts and P.UsesSubCrafts(plan) or false,
                reagents = reagents,
            }
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit or (a.profit == b.profit and a.name < b.name) end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- A whole character

-- data = { muddy = MuddyBootsCharDB, haul = HaulCharDB, mob = MakeOrBuyCharDB, stock = Stockpile char entry,
--          account = MuddyBootsDB.chars entry, market, names (base table), planner }
function M.character(data)
    local mb = data.muddy or {}
    local char, counts = mb.char or {}, mb.counts or {}
    local events = S.parseLog(mb.log)
    local nameOf, idOf = M.nameBook(data.names, data.haul, events, data.mob)
    local acc = data.account or {}

    local playedNow, lastSession = nil, nil
    for _, s in ipairs(mb.sessions or {}) do
        if s.played1 and (not playedNow or s.played1 > playedNow) then playedNow = s.played1 end
        lastSession = s
    end
    local firstPlayed
    for _, e in ipairs(events) do
        if e.played then firstPlayed = e.played break end
    end

    local xpSeries, levels = M.xpSeries(events)
    local xpTotals, xpByLevel = M.xpBySource(counts.xp)
    local moneyFlow, earned, spent = M.money(events)
    -- the highest level any source knows: the journal, the account row, or the last level-up logged
    local level = math.max(tonumber(char.level) or 0, tonumber(acc.level) or 0,
        levels[#levels] and levels[#levels].level or 0)
    if level == 0 then level = nil end
    local money = acc.money
    local inv = M.inventory(data.stock, data.market, nameOf)

    local activity = {}
    for k, v in pairs(counts.activity or {}) do
        if not k:find(":") then activity[k] = v end
    end

    local ownedIds = {}
    for _, item in ipairs(inv.items) do
        if item.unit then ownedIds[#ownedIds + 1] = item.id end
    end

    local restock
    if data.mob and data.mob.restock and next(data.mob.restock) then
        restock = {}
        for id, n in pairs(data.mob.restock) do
            local r = data.mob.recipes and data.mob.recipes[id]
            restock[#restock + 1] = { id = r and r.outputItemID, name = r and r.name or ("Recipe #" .. id), crafts = n }
        end
        table.sort(restock, function(a, b) return a.name < b.name end)
    end

    local haul
    local hs = data.haul and data.haul.current and data.haul.current.session
    if hs then
        local coin = num(hs.money and hs.money.loot) + num(hs.money and hs.money.quest)
        haul = { elapsed = hs.elapsed, coin = coin, items = hs.itemValue, xp = hs.xp, zone = hs.zone,
            perHour = (hs.elapsed or 0) >= 60 and math.floor((coin + num(hs.itemValue)) * 3600 / hs.elapsed) or nil,
            sessions = #(data.haul.history or {}) }
    end

    return {
        profile = {
            name = char.name or acc.name, realm = char.realm, class = char.class or acc.class, race = char.race,
            faction = char.faction or acc.faction, level = level, played = playedNow, money = money,
            zone = char.zone or (mb.snap and level and mb.snap[level] and mb.snap[level].zone) or (haul and haul.zone),
            journal = mb.source or (data.muddy and "MuddyBoots") or nil,
            firstSeen = char.first and char.first.t, lastSeen = acc.lastSeen or (lastSession and lastSession.last),
            sessions = #(mb.sessions or {}),
        },
        netWorth = { money = money or 0, items = inv.total, total = (money or 0) + inv.total },
        xp = { series = xpSeries, levels = levels, totals = xpTotals, byLevel = xpByLevel, all = counts.xp and counts.xp.all },
        levelTimes = M.levelTimes(levels, char.first and char.first.level, firstPlayed, playedNow, level),
        money = { flow = moneyFlow, earned = ranked(earned), spent = ranked(spent),
            onHand = M.moneySeries(mb.snap, playedNow, money), auction = counts.auction,
            check = M.moneyCheck(events, mb.snap, money),
            ahTrades = M.ahTrades(events, idOf) },
        activity = activity,
        distance = counts.distance,
        zones = M.zoneTimes(events),
        fights = M.fights(events, counts.fights),
        deaths = M.deaths(events),
        deathCounts = counts.deaths,
        damage = M.damage(counts),
        flights = M.flights(events),
        quests = M.quests(events),
        professions = M.professions(events),
        crafted = M.crafted(counts.prof),
        crafts = M.crafts(data.planner, data.mob and data.mob.recipes, data.market, nameOf, 12),
        restock = restock,
        inventory = inv,
        prices = M.priceHistory(data.market, ownedIds, nameOf, 2),
        haul = haul,
    }
end

----------------------------------------------------------------------------------------------------
-- Account (every character together)

-- WoW Forever has no realms: characters are "First Last" (Azhariel Deadheart) and play a ruleset (PvP). The game
-- API gives the first name only and an internal server name ending in the ruleset ("CAMWOW US2 Realm 2 PvP"); the
-- surname is only in each character's WTF folder name ("Azhariel-Deadheart").

-- { [lowercase first name] = surname } from folder names { { name, surname } }; a first name used by two
-- characters with different surnames maps to false (can't tell which saved entry is which).
function M.surnames(folders)
    local out = {}
    for _, f in ipairs(folders or {}) do
        local key = string.lower(f.name or "")
        if out[key] == nil then
            out[key] = f.surname
        elseif out[key] ~= f.surname then
            out[key] = false
        end
    end
    return out
end

-- "Azhariel" + surnames -> "Azhariel Deadheart" (just the first name when unknown or ambiguous)
function M.fullName(name, surnames)
    local last = name and surnames and surnames[string.lower(name)]
    return last and (name .. " " .. last) or name
end

-- Ruleset from the internal server name ("CAMWOW US2 Realm 2 PvP" -> "PvP"); other names are returned as they are
function M.ruleset(realm)
    if type(realm) ~= "string" then return nil end
    return realm:match("[Rr]ealm %d+ (.+)$") or realm
end

-- Key matching the same character across addons: "name-realm", case-insensitive name.
function M.charId(name, realm)
    return string.lower(tostring(name or "?")) .. "-" .. tostring(realm or "")
end

-- All characters of all accounts, side by side, with totals and a combined inventory.
-- groups: { { muddyChars = MuddyBootsDB.chars, stockChars = StockpileDB.chars, market = auctionator() } }
-- Characters come from MuddyBoots' account file (level, gold, played) and Stockpile (items); either is enough.
-- Returns { characters = rows sorted by net worth, totals, inventory = { items, kinds, unpriced } }.
function M.account(groups, nameOf, limit)
    local rows, byId, items = {}, {}, {}
    local function row(name, realm)
        local id = M.charId(name, realm)
        if not byId[id] then
            byId[id] = { id = id, name = name, realm = realm, money = nil, items = 0, unpriced = 0,
                byLocation = { bags = 0, bank = 0, mail = 0 } }
            rows[#rows + 1] = byId[id]
        end
        return byId[id]
    end
    for _, g in ipairs(groups or {}) do
        for _, c in pairs(g.muddyChars or {}) do
            if type(c) == "table" and c.name then
                local r = row(c.name, c.realm)
                r.level, r.class, r.race, r.faction = c.level, c.class, c.race, c.faction
                r.played, r.money, r.lastSeen = c.played, c.money, c.lastSeen
                r.faction = r.faction or c.faction
            end
        end
        for _, c in pairs(g.stockChars or {}) do
            if type(c) == "table" and c.name then
                local r = row(c.name, c.realm)
                r.class = r.class or c.class
                r.bankTime = c.bankTime
                local inv = M.inventory(c, g.market, nameOf)
                r.items, r.unpriced = inv.total, inv.unpriced
                r.byLocation = inv.byLocation
                for _, it in ipairs(inv.items) do
                    local a = items[it.id]
                    if not a then
                        a = { id = it.id, name = it.name, count = 0, unit = it.unit, value = 0, holders = {} }
                        items[it.id] = a
                    end
                    a.count = a.count + it.count
                    a.value = a.value + it.value
                    a.unit = a.unit or it.unit
                    a.holders[#a.holders + 1] = { name = c.name, count = it.count }
                end
            end
        end
    end

    local totals = { characters = #rows, money = 0, items = 0, netWorth = 0, played = 0, maxLevel = nil }
    for _, r in ipairs(rows) do
        r.netWorth = (r.money or 0) + r.items
        totals.money = totals.money + (r.money or 0)
        totals.items = totals.items + r.items
        totals.netWorth = totals.netWorth + r.netWorth
        totals.played = totals.played + num(r.played)
        if r.level and (not totals.maxLevel or r.level > totals.maxLevel) then totals.maxLevel = r.level end
    end
    table.sort(rows, function(a, b)
        if a.netWorth ~= b.netWorth then return a.netWorth > b.netWorth end
        return a.id < b.id
    end)

    local list, unpriced = {}, 0
    for _, a in pairs(items) do
        table.sort(a.holders, function(x, y)
            if x.count ~= y.count then return x.count > y.count end
            return x.name < y.name
        end)
        if not a.unit then unpriced = unpriced + 1 end
        list[#list + 1] = a
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.name < b.name
    end)
    local kinds = #list
    if limit and #list > limit then
        for i = #list, limit + 1, -1 do list[i] = nil end
    end
    return { characters = rows, totals = totals, inventory = { items = list, kinds = kinds, unpriced = unpriced } }
end

-- What the Live tab needs to estimate XP between saves: XP and level-up XP at the last save (Haul), when that save
-- was (the last MuddyBoots event), and the XP each creature gave on its latest kill (MuddyBoots "ki" lines:
-- name, npc, type, class, xp, level). Returns { cur, max, savedAt, mobs = { ["npcId"] = { name, xp, level, t } } }.
function M.xpState(events, haul)
    local s = haul and haul.current and haul.current.session or {}
    local out = { cur = num(s.lastXP), max = num(s.lastXPMax), savedAt = nil, mobs = {} }
    if out.max <= 0 then out.cur, out.max = nil, nil end
    for _, e in ipairs(events or {}) do
        out.savedAt = math.max(out.savedAt or e.t, e.t)
        if e.kind == "ki" then
            local npc, xp = tonumber(e.args[2]), num(e.args[5])
            if npc and xp > 0 then
                local key = tostring(npc)
                local m = out.mobs[key]
                if not m or e.t >= m.t then
                    out.mobs[key] = { name = e.args[1], xp = xp, level = num(e.args[6]), t = e.t }
                end
            end
        end
    end
    return out
end

-- Where the character has been, per map, from MuddyBoots' trail chunks. A chunk is { m = uiMapID, t = start time,
-- d = "dt,x,y[,flags];..." } with x, y in ten-thousandths of the map. Returns a list of
-- { map, n, first, last, pts = { x1, y1, x2, y2, ... } } (x, y in thousandths, flat to keep the page small), at most
-- maxPerMap points per map (evenly thinned), maps with the most points first.
function M.trails(trail, maxPerMap)
    maxPerMap = maxPerMap or 1500
    local byMap, order = {}, {}
    for _, c in ipairs(trail and trail.chunks or {}) do
        local m, t0 = tonumber(c.m), tonumber(c.t)
        if m and type(c.d) == "string" then
            local entry = byMap[m]
            if not entry then
                entry = { map = m, raw = {} }
                byMap[m] = entry
                order[#order + 1] = entry
            end
            for dt, x, y in c.d:gmatch("(%-?%d+),(%-?%d+),(%-?%d+)") do
                x, y = tonumber(x), tonumber(y)
                if x >= 0 and x <= 10000 and y >= 0 and y <= 10000 then
                    local raw = entry.raw
                    raw[#raw + 1] = { math.floor(x / 10 + 0.5), math.floor(y / 10 + 0.5) }
                    local at = t0 and (t0 + tonumber(dt)) or nil
                    if at then
                        entry.first = math.min(entry.first or at, at)
                        entry.last = math.max(entry.last or at, at)
                    end
                end
            end
        end
    end
    local out = {}
    for _, e in ipairs(order) do
        local n = #e.raw
        if n > 0 then
            local step = math.max(1, n / maxPerMap)
            local pts, i = {}, 1
            while i <= n do
                local p = e.raw[math.floor(i)]
                pts[#pts + 1] = p[1]
                pts[#pts + 1] = p[2]
                i = i + step
            end
            out[#out + 1] = { map = e.map, n = n, first = e.first, last = e.last, pts = pts }
        end
    end
    table.sort(out, function(a, b) return a.n > b.n end)
    return out
end

-- The Replay module's data: every trail point with its time and state, and the moments worth showing, each with
-- where it happened. { base, pts = { dt, map, x, y, f, ... }, moments = { { t, k, m, x, y, text, sub } } }:
-- t is seconds after base (the first point), x, y ten-thousandths of the map, f 0 on foot or mounted, 1 dead or a
-- ghost, 2 on a flight. Moment kinds k: lv level, de death, qt quest done, qa accepted, qx abandoned, zo zone,
-- ie / il dungeon in / out, fl flight, ga gathered, sk skill up, lo rare loot, ah AH sale, ki kill, pl / pe a player
-- you met / an enemy player, in / out login and logout.
M.REPLAY_FLAGS = { d = 1, g = 1, t = 2 }
local function replayMoment(e)
    local a = e.args
    local k = e.kind
    if k == "lv" then return "lv", "Level " .. (a[1] or "?") end
    if k == "de" then return "de", a[1] and a[1] ~= "" and ("Died to " .. a[1]) or "Died" end
    if k == "qt" then return "qt", a[4] or ("Quest " .. (a[1] or "")), "Quest done" .. (num(a[2]) > 0 and (", " .. a[2] .. " XP") or "") end
    if k == "qa" then return "qa", a[2] or ("Quest " .. (a[1] or "")), "Quest accepted" end
    if k == "qx" then return "qx", a[2] or ("Quest " .. (a[1] or "")), "Quest abandoned" end
    if k == "zo" and a[1] and a[1] ~= "" then return "zo", a[1] end
    if k == "ie" then return "ie", a[1] or "Dungeon", a[3] end
    if k == "il" then return "il", a[1] or "Dungeon", a[2] and (a[2] .. " s inside") end
    if k == "fl" then return "fl", a[2] or "?", a[1] and ("from " .. a[1]) end
    if k == "tx" then return "fl", a[2] or "?", a[1] and ("from " .. a[1]) end
    if k == "ga" then return "ga", (a[3] or "?") .. (num(a[4]) > 1 and (" x" .. a[4]) or ""), a[1] end
    if k == "sk" and a[1] and a[1] ~= "" and a[2] then return "sk", a[1] .. " " .. a[2] end
    if k == "lo" and num(a[2]) >= 3 then return "lo", a[5] or ("Item " .. (a[1] or "")), a[4] end
    if k == "ah" and a[1] == "sold" then return "ah", a[3] or "?", a[2] end
    if k == "ki" and a[1] and a[1] ~= "" then return "ki", a[1], a[4] ~= "normal" and a[4] or nil end
    if k == "pl" and a[1] and a[1] ~= "" then
        -- pl|name|realm|level|class|race|guild|how|spell: pe for an enemy player, pl for everyone else
        local how = a[7]
        local class = a[4] and a[4] ~= "" and (a[4]:sub(1, 1) .. a[4]:sub(2):lower()) or nil
        local bits = {}
        if num(a[3]) > 0 then bits[#bits + 1] = "level " .. a[3] end
        if class then bits[#bits + 1] = class end
        if a[6] and a[6] ~= "" then bits[#bits + 1] = "<" .. a[6] .. ">" end
        if a[8] and a[8] ~= "" then bits[#bits + 1] = a[8] end
        local verb = ({ buff = "Buffed ", attack = "Attacked ", enemy = "Enemy player ", group = "Grouped with " })[how] or "Met "
        return (how == "enemy" or how == "attack") and "pe" or "pl", verb .. a[1], table.concat(bits, ", ")
    end
    if k == "in" then return "in", a[1] == "reload" and "Reload" or "Logged in" end
    if k == "out" then return "out", "Logged out" end
    return nil
end

function M.replay(trail, events)
    local all = {}
    for _, c in ipairs(trail and trail.chunks or {}) do
        local m, t0 = tonumber(c.m), tonumber(c.t)
        if m and t0 and type(c.d) == "string" then
            for step in c.d:gmatch("[^;]+") do
                local dt, x, y, flag = step:match("^(%-?%d+),(%-?%d+),(%-?%d+),?(%a*)")
                x, y = tonumber(x), tonumber(y)
                if dt and x >= 0 and x <= 10000 and y >= 0 and y <= 10000 then
                    all[#all + 1] = { t0 + tonumber(dt), m, x, y, M.REPLAY_FLAGS[flag] or 0 }
                end
            end
        end
    end
    table.sort(all, function(a, b) return a[1] < b[1] end)
    local base = all[1] and all[1][1] or 0
    local pts = {}
    for _, p in ipairs(all) do
        pts[#pts + 1] = p[1] - base; pts[#pts + 1] = p[2]; pts[#pts + 1] = p[3]; pts[#pts + 1] = p[4]; pts[#pts + 1] = p[5]
    end
    local moments = {}
    for _, e in ipairs(events or {}) do
        local k, text, sub = replayMoment(e)
        if k and e.t >= base then
            -- an array with no holes (JSON): a line without a position has map 0, x and y -1
            moments[#moments + 1] = { e.t - base, k, e.map or 0, e.x or -1, e.y or -1, text, sub or "" }
        end
    end
    return { base = base, pts = pts, moments = moments }
end

-- The newest stretch of the trail with each point's time, unthinned, for the Live map's line for this session:
-- the combat log logs your position only when something happens to you, so the line is Logbook's 5-second trail
-- up to the last save, then the log's points. Points from `since` on, at most `limit` (the newest kept), as
-- { { map, pts = { t1, x1, y1, t2, ... } } } with x, y in ten-thousandths of the map, oldest first.
M.RECENT_TRAIL_SECONDS = 12 * 3600
M.RECENT_TRAIL_POINTS = 4000
function M.recentTrail(trail, since, limit)
    limit = limit or M.RECENT_TRAIL_POINTS
    local all = {}
    for _, c in ipairs(trail and trail.chunks or {}) do
        local m, t0 = tonumber(c.m), tonumber(c.t)
        if m and t0 and type(c.d) == "string" then
            for dt, x, y in c.d:gmatch("(%-?%d+),(%-?%d+),(%-?%d+)") do
                local t = t0 + tonumber(dt)
                x, y = tonumber(x), tonumber(y)
                if t >= since and x >= 0 and x <= 10000 and y >= 0 and y <= 10000 then
                    all[#all + 1] = { t, m, x, y }
                end
            end
        end
    end
    table.sort(all, function(a, b) return a[1] < b[1] end)
    local byMap, out = {}, {}
    for i = math.max(1, #all - limit + 1), #all do
        local p = all[i]
        local e = byMap[p[2]]
        if not e then
            e = { map = p[2], pts = {} }
            byMap[p[2]] = e
            out[#out + 1] = e
        end
        local pts = e.pts
        pts[#pts + 1] = p[1]; pts[#pts + 1] = p[3]; pts[#pts + 1] = p[4]
    end
    return out
end

return M
