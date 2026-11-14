-- Insights: market deals, play-session recaps and items to mail between your characters.
-- Pure functions over the tables the readers produce (no file access), so every figure can be tested offline.
local I = {}

local function num(v)
    return tonumber(v) or 0
end

local function median(list)
    if #list == 0 then return nil end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    local mid = math.floor(#s / 2)
    if #s % 2 == 1 then return s[mid + 1] end
    return (s[mid] + s[mid + 1]) / 2
end
I.median = median

----------------------------------------------------------------------------------------------------
-- Market: buy low, sell high

I.MARKET = {
    minHistory = 2,   -- earlier scan days needed before an item's "usual" price means anything
    buyBelow = 0.70,  -- buy signal: today's price at or under 70% of usual
    sellAbove = 1.25, -- sell signal: today's price at or over 125% of usual
    minGain = 50,     -- copper per item; smaller differences are noise
    limit = 15,
}

-- An item's usual price: the median of the lowest price seen on each earlier scan day (every day but the
-- item's latest). Returns usual, number of earlier days; nil when there's no earlier day.
function I.usualPrice(p)
    local days = p and p.days or {}
    local lows = {}
    for i = 1, #days - 1 do
        local low = days[i].low or days[i].high
        if low and low > 0 then lows[#lows + 1] = low end
    end
    return median(lows), #lows
end

-- market: sources.auctionator() result. owned: { [itemID] = { count, holders } } over all characters (or nil).
-- Returns { scanDays, ready (enough history for any signal), buy = { ... }, sell = { ... } }
--   buy:  { id, name, now, usual, pct (fraction below usual), available, days }  biggest discount first
--   sell: { id, name, now, usual, pct (fraction above), count, extra ((now - usual) * count), holders, days }
function I.market(market, owned, nameOf, cfg)
    cfg = cfg or I.MARKET
    local out = { buy = {}, sell = {}, scanDays = 0, ready = false }
    local allDays = {}
    for id, p in pairs(market and market.prices or {}) do
        for _, d in ipairs(p.days) do allDays[d.day] = true end
        local now = p.now
        local usual, n = I.usualPrice(p)
        if n >= cfg.minHistory then out.ready = true end
        if now and now > 0 and usual and n >= cfg.minHistory then
            local last = p.days[#p.days]
            if now <= usual * cfg.buyBelow and usual - now >= cfg.minGain then
                out.buy[#out.buy + 1] = { id = id, name = nameOf(id), now = now, usual = usual,
                    pct = 1 - now / usual, available = last and last.available, days = n + 1 }
            end
            local have = owned and owned[id]
            if have and have.count > 0 and now >= usual * cfg.sellAbove and now - usual >= cfg.minGain then
                out.sell[#out.sell + 1] = { id = id, name = nameOf(id), now = now, usual = usual,
                    pct = now / usual - 1, count = have.count, extra = (now - usual) * have.count,
                    holders = have.holders, days = n + 1 }
            end
        end
    end
    for _ in pairs(allDays) do out.scanDays = out.scanDays + 1 end
    table.sort(out.buy, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.id < b.id
    end)
    table.sort(out.sell, function(a, b)
        if a.extra ~= b.extra then return a.extra > b.extra end
        return a.id < b.id
    end)
    for _, list in ipairs({ out.buy, out.sell }) do
        for i = #list, cfg.limit + 1, -1 do list[i] = nil end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Session recaps

I.SESSION_GAP = 1800 -- seconds; MuddyBoots pieces (one per reload) closer than this are one play session

-- Joins MuddyBoots' session pieces into play sessions: { start, finish, played, pieces } oldest first.
function I.playSessions(pieces, gap)
    gap = gap or I.SESSION_GAP
    local list = {}
    for _, s in ipairs(pieces or {}) do
        if s.start and s.last then list[#list + 1] = s end
    end
    table.sort(list, function(a, b) return a.start < b.start end)
    local out, cur = {}, nil
    for _, s in ipairs(list) do
        local played = math.max(0, num(s.played1) - num(s.played0))
        if cur and s.start - cur.finish <= gap then
            cur.finish = math.max(cur.finish, s.last)
            cur.played = cur.played + played
            cur.pieces = cur.pieces + 1
        else
            cur = { start = s.start, finish = s.last, played = played, pieces = 1 }
            out[#out + 1] = cur
        end
    end
    return out
end

local QUALITY_MIN = 2 -- loot worth naming: green or better, or anything with an AH value
local LOOT_HOW = { loot = true, roll = true, quest = true } -- found or earned; "made" is listed apart; mail/trade aren't new

local function parseItemQty(raw)
    if not raw or raw == "" then return nil, 1 end
    local name, cnt = raw:match("^(.+) x(%d+)$")
    if name and tonumber(cnt) and tonumber(cnt) > 0 then
        return name, tonumber(cnt)
    end
    return raw, 1
end

-- One recap per play session, newest first. events: parsed MuddyBoots log (sorted by time).
-- Each: { start, finish, played, xp, levels = { n }, earned, spent, kills, topMob, quests = { name },
--         deaths = { killer }, zones = { name }, loot = { { id, name, count, quality, value } },
--         made = { ... }, ahSold = { ... }, ahBought = { ... }, skills = { { name, from, to } } }
-- professions: { [skill name] = true } to report (weapon skills and languages are left out)
function I.recaps(pieces, events, market, nameOf, limit, professions, idOf)
    local sessions = I.playSessions(pieces)
    local out = {}
    local zone
    local rankNow = {} -- last known rank per skill, carried across sessions
    local usedBuyMn = {}
    local function seeSkill(e)
        if e.kind == "sk" and e.args[1] and e.args[1] ~= "" then rankNow[e.args[1]] = num(e.args[2]) end
    end
    local idx = 1
    for _, s in ipairs(sessions) do
        local r = { start = s.start, finish = s.finish, played = s.played, xp = 0, levels = {}, earned = 0, spent = 0,
            kills = 0, quests = {}, deaths = {}, zones = {}, loot = {}, made = {}, ahSold = {}, ahBought = {}, skills = {} }
        local mobs, zoneSeen, lootBy, madeBy, soldBy, boughtBy, skillBy = {}, {}, {}, {}, {}, {}, {}
        local function visit(z)
            if z and z ~= "" and not zoneSeen[z] then
                zoneSeen[z] = true
                r.zones[#r.zones + 1] = z
            end
        end
        -- events before this session only move the zone along
        while events[idx] and events[idx].t < s.start do
            local e = events[idx]
            if e.kind == "zo" and e.args[1] ~= "" then zone = e.args[1] end
            seeSkill(e)
            idx = idx + 1
        end
        visit(zone)
        while events[idx] and events[idx].t <= s.finish do
            local e, a = events[idx], events[idx].args
            if e.kind == "zo" then
                if a[1] ~= "" then zone = a[1] end
                visit(zone)
            elseif e.kind == "xp" then
                r.xp = r.xp + num(a[1])
            elseif e.kind == "lv" then
                r.levels[#r.levels + 1] = num(a[1])
            elseif e.kind == "mn" then
                local d = num(a[1])
                if d > 0 then r.earned = r.earned + d else r.spent = r.spent - d end
            elseif e.kind == "ki" then
                r.kills = r.kills + 1
                if a[1] and a[1] ~= "" then mobs[a[1]] = (mobs[a[1]] or 0) + 1 end
            elseif e.kind == "qt" then
                r.quests[#r.quests + 1] = a[4] ~= "" and a[4] or ("Quest #" .. tostring(a[1]))
            elseif e.kind == "de" then
                r.deaths[#r.deaths + 1] = a[1] ~= "" and a[1] or (a[4] ~= "" and a[4]) or "?"
            elseif e.kind == "lo" then
                local id = tonumber(a[1])
                local by = (a[4] == "made" and madeBy) or (LOOT_HOW[a[4]] and lootBy) or nil
                if id and by then
                    local l = by[id]
                    if not l then
                        l = { id = id, name = (a[5] ~= "" and a[5]) or nameOf(id), count = 0, quality = num(a[2]) }
                        by[id] = l
                    end
                    l.count = l.count + math.max(1, num(a[3]))
                end
            elseif e.kind == "ah" then
                local act, raw = a[1] or "", a[3] or ""
                local name, cnt = parseItemQty(raw)
                local c = num(a[2])
                if act == "sold" and name and c > 0 then
                    local entry = soldBy[name] or { id = idOf and idOf(name) or nil, name = name, count = 0, copper = 0 }
                    soldBy[name] = entry
                    entry.count = entry.count + cnt
                    entry.copper = entry.copper + c
                elseif (act == "buyout" or act == "bid") and name then
                    if c == 0 then
                        for j = math.max(1, idx - 20), math.min(#events, idx + 20) do
                            local m = events[j]
                            if not usedBuyMn[j] and m.kind == "mn" and m.args[2] == "auction" and num(m.args[1]) < 0
                                and math.abs((m.t or 0) - (e.t or 0)) <= 5 and ((m.args[3] or "") == raw or (m.args[3] or "") == "") then
                                usedBuyMn[j] = true
                                c = -num(m.args[1])
                                break
                            end
                        end
                    end
                    local entry = boughtBy[name] or { id = idOf and idOf(name) or nil, name = name, count = 0, copper = 0 }
                    boughtBy[name] = entry
                    entry.count = entry.count + cnt
                    entry.copper = entry.copper + c
                end
            elseif e.kind == "sk" and a[1] and a[1] ~= "" and num(a[2]) > 0
                and (not professions or professions[a[1]]) then
                local k = skillBy[a[1]]
                if not k then
                    -- from: the rank before this session; a skill seen for the first time starts here
                    k = { name = a[1], from = rankNow[a[1]] or num(a[2]), to = num(a[2]) }
                    skillBy[a[1]] = k
                    r.skills[#r.skills + 1] = k
                end
                k.to = num(a[2])
            end
            seeSkill(e)
            idx = idx + 1
        end
        local best
        for name, n in pairs(mobs) do
            if not best or n > best.n or (n == best.n and name < best.name) then best = { name = name, n = n } end
        end
        r.topMob = best
        for id, l in pairs(lootBy) do
            local p = market and market.prices[id]
            l.value = p and p.now and p.now * l.count or nil
            if l.quality >= QUALITY_MIN or l.value then r.loot[#r.loot + 1] = l end
        end
        table.sort(r.loot, function(a, b)
            local va, vb = a.value or -1, b.value or -1
            if va ~= vb then return va > vb end
            if a.quality ~= b.quality then return a.quality > b.quality end
            return a.id < b.id
        end)
        for i = #r.loot, 6, -1 do r.loot[i] = nil end
        for _, l in pairs(madeBy) do r.made[#r.made + 1] = l end
        table.sort(r.made, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
        local sortCopper = function(a, b) return a.copper > b.copper or (a.copper == b.copper and a.name < b.name) end
        for _, l in pairs(soldBy) do r.ahSold[#r.ahSold + 1] = l end
        for _, l in pairs(boughtBy) do r.ahBought[#r.ahBought + 1] = l end
        table.sort(r.ahSold, sortCopper)
        table.sort(r.ahBought, sortCopper)
        -- only skills that went up
        for i = #r.skills, 1, -1 do
            if r.skills[i].to <= r.skills[i].from then table.remove(r.skills, i) end
        end
        table.sort(r.skills, function(a, b) return a.to - a.from > b.to - b.from or (a.to - a.from == b.to - b.from and a.name < b.name) end)
        out[#out + 1] = r
    end
    -- newest first
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    if limit then
        for i = #rev, limit + 1, -1 do rev[i] = nil end
    end
    return rev
end

----------------------------------------------------------------------------------------------------
-- Mail to your alts

-- What each character uses: reagents of its known recipes, and how many its restock list still needs.
-- recipes: MakeOrBuy's { [recipeID] = { reagents = { { itemID, qty } } } }; shopping: Restock.Build().shopping
function I.uses(recipes, shopping)
    local uses, needs = {}, {}
    for _, r in pairs(recipes or {}) do
        for _, g in ipairs(r.reagents or {}) do
            if g.itemID then uses[g.itemID] = true end
        end
    end
    for _, e in ipairs(shopping or {}) do
        if e.itemID and e.qty and e.qty > 0 then
            needs[e.itemID] = (needs[e.itemID] or 0) + e.qty
            uses[e.itemID] = true
        end
    end
    return uses, needs
end

-- chars: { { id, name, faction, holds = { [itemID] = { bags, bank, mail } }, uses, needs } }
-- Suggests mailing items a character holds to another character (same faction) who uses them. A character's
-- own use wins: nothing it needs itself is suggested away. Returns { { from, to, id, name, count, bags, bank,
-- need, reason ("restock" | "crafting"), value } } restock needs first, then by value.
function I.transfers(chars, nameOf, market)
    local out = {}
    for _, from in ipairs(chars or {}) do
        for id, h in pairs(from.holds or {}) do
            local count = num(h.bags) + num(h.bank) + num(h.mail)
            local mine = (from.uses and from.uses[id]) or (from.needs and from.needs[id])
            if count > 0 and not mine then
                for _, to in ipairs(chars) do
                    if to ~= from and to.uses and to.uses[id] and (not from.faction or not to.faction or from.faction == to.faction) then
                        local need = to.needs and to.needs[id]
                        local give = need and math.min(need, count) or count
                        local p = market and market.prices[id]
                        out[#out + 1] = { from = from.name, to = to.name, id = id, name = nameOf(id), count = give,
                            bags = num(h.bags), bank = num(h.bank), need = need, reason = need and "restock" or "crafting",
                            value = p and p.now and p.now * give or nil }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.reason == "restock") ~= (b.reason == "restock") then return a.reason == "restock" end
        local va, vb = a.value or -1, b.value or -1
        if va ~= vb then return va > vb end
        if a.name ~= b.name then return a.name < b.name end
        return a.to < b.to
    end)
    return out
end

-- DropLab's saved data as a table of mobs: the ones with Stats.MIN_KILLS or more first, by value per kill, then
-- the rest by kills. Stats = DropLab's own Stats.lua (the same maths as in game). price(id) = what selling one
-- brings. Returns nil without data, else { mobs = { { name, npcID, n, basis, value, unpriced, killsPerHour,
-- perHour, ranked, drops = { { name, rate, lo, hi, perKill } } } }, tracked, kills, minKills }
function I.drops(db, Stats, nameOf, price, limit)
    if type(db) ~= "table" or type(db.mobs) ~= "table" or not Stats then
        return nil
    end
    local rows, kills, tracked = {}, 0, 0
    for npcID, mob in pairs(db.mobs) do
        local n, basis = Stats.Kills(mob)
        if n > 0 then
            tracked = tracked + 1
            kills = kills + n
            local value, unpriced = Stats.Value(mob, price)
            local kph = Stats.KillsPerHour(mob)
            local drops = {}
            for i, r in ipairs(Stats.Drops(mob)) do
                if i > 5 then break end
                drops[i] = { id = r.itemID, name = nameOf(r.itemID), rate = r.rate, lo = r.lo, hi = r.hi, perKill = r.perKill }
            end
            rows[#rows + 1] = { name = mob.name or ("NPC #" .. npcID), npcID = npcID, n = n, basis = basis,
                value = value or 0, unpriced = unpriced, killsPerHour = kph, perHour = kph and value and value * kph or nil,
                ranked = n >= Stats.MIN_KILLS, drops = drops }
        end
    end
    table.sort(rows, function(a, b)
        if a.ranked ~= b.ranked then return a.ranked end
        if a.ranked and a.value ~= b.value then return a.value > b.value end
        if a.n ~= b.n then return a.n > b.n end
        return a.npcID < b.npcID
    end)
    for i = #rows, (limit or 25) + 1, -1 do rows[i] = nil end
    return { mobs = rows, tracked = tracked, kills = kills, minKills = Stats.MIN_KILLS }
end

----------------------------------------------------------------------------------------------------
-- Market tab: price history of what you hold, of whole trade-goods families, and of the biggest movers

-- Item ids per family (classic). Names come from QuestieDB, so a wrong id shows up as a wrong name on the page.
I.FAMILIES = {
    { key = "herbs", label = "Herbs", ids = { 2447, 765, 2449, 785, 2450, 2452, 2453, 3820, 3369, 3355, 3356, 3357,
        3818, 3821, 3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846, 8153, 13463, 13464, 13465, 13466, 13467,
        13468 } },
    { key = "ore", label = "Ore, bars and stone", ids = { 2770, 2771, 2772, 2775, 2776, 3858, 7911, 10620, 2840, 3576,
        2841, 3575, 3859, 3860, 12359, 2835, 2836, 2838, 7912, 12365 } },
    { key = "cloth", label = "Cloth", ids = { 2589, 2592, 4306, 4338, 14047, 14256, 2996, 2997, 4305, 4339, 14048 } },
    { key = "leather", label = "Leather and hides", ids = { 2934, 2318, 2319, 4234, 4304, 8170, 783, 4232, 4235, 8169,
        8171 } },
    { key = "enchanting", label = "Enchanting", ids = { 10940, 11083, 11137, 11176, 16204, 10938, 10939, 10998, 11082,
        11134, 11135, 11174, 11175, 16202, 16203, 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344, 20725 } },
    { key = "elemental", label = "Elemental and gems", ids = { 7067, 7068, 7069, 7070, 7075, 7076, 7077, 7078, 7079,
        7080, 7082, 12803, 12808, 7972, 5498, 5500, 7971, 13926, 774, 818, 1210, 1206, 1529, 1705, 3864, 7909, 7910,
        12361, 12363, 12364, 12799, 12800 } },
}
I.MOVERS = { limit = 30, minNow = 20, minLow = 10, minAvailable = 20, minRise = 0.5 }

-- One item's figures: launch low (lowest daily low), peak (highest daily low: a one-off high listing isn't a price
-- anyone paid), change of today's price against the low, supply now vs the first day
local function itemStats(p)
    local days = p.days or {}
    local low, peak
    for _, d in ipairs(days) do
        local l = d.low or d.high
        if l and l > 0 then low = math.min(low or l, l) end
        if l and l > 0 then peak = math.max(peak or l, l) end
    end
    local first, last = days[1], days[#days]
    local supply
    if first and last and first ~= last and (first.available or 0) > 0 and last.available then
        supply = last.available / first.available - 1
    end
    local now = p.now
    return {
        low = low, peak = peak, now = now,
        change = (now and low and low > 0) and (now / low - 1) or nil,
        supply = supply, available = last and last.available,
    }
end
I.itemStats = itemStats

-- market: S.auctionator(); owned: { [id] = { count, holders = { "Name 12", ... } } }; nameOf(id);
-- seen: { [id] = { { t, price }, ... } } (the dashboard's own price log); dayToTime(day) -> epoch.
-- Returns { days = { epoch... }, families = { { key, label, ids } }, items = { [tostring(id)] = { ... } },
--           owned = { ids by value }, rising = { ids }, falling = { ids } }.
function I.marketTab(market, owned, nameOf, seen, dayToTime, cfg)
    cfg = cfg or I.MOVERS
    local prices = market and market.prices or {}
    local out = { days = {}, families = {}, items = {}, owned = {}, rising = {}, falling = {} }
    local allDays, include = {}, {}
    for _, p in pairs(prices) do
        for _, d in ipairs(p.days or {}) do allDays[d.day] = true end
    end
    for day in pairs(allDays) do out.days[#out.days + 1] = dayToTime(day) end
    table.sort(out.days)

    local function add(id) include[id] = true end
    for id, p in pairs(prices) do
        if (p.now and p.now > 0) or #(p.days or {}) > 0 then add(id) end
    end
    for _, f in ipairs(I.FAMILIES) do
        local ids = {}
        for _, id in ipairs(f.ids) do
            if prices[id] then ids[#ids + 1] = id; add(id) end
        end
        out.families[#out.families + 1] = { key = f.key, label = f.label, ids = ids }
    end
    local ownedList = {}
    for id, o in pairs(owned or {}) do
        local p = prices[id]
        if p and p.now and o.count > 0 then
            add(id)
            ownedList[#ownedList + 1] = { id = id, value = p.now * o.count }
        end
    end
    table.sort(ownedList, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.id < b.id end)
    for i, r in ipairs(ownedList) do out.owned[i] = r.id end

    -- Movers: up the most from their launch low, and down the most from their peak (with enough on sale to matter)
    local up, down = {}, {}
    for id, p in pairs(prices) do
        local s = itemStats(p)
        if #(p.days or {}) >= 2 and s.now and s.now >= cfg.minNow and (s.available or 0) >= cfg.minAvailable then
            if s.change and s.change >= cfg.minRise and (s.low or 0) >= cfg.minLow then up[#up + 1] = { id = id, v = s.change } end
            if s.peak and s.peak > 0 and s.now < s.peak then
                local drop = 1 - s.now / s.peak
                if drop >= 0.3 then down[#down + 1] = { id = id, v = drop } end
            end
        end
    end
    local function top(list, dest)
        table.sort(list, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
        for i = 1, math.min(cfg.limit, #list) do dest[i] = list[i].id; add(list[i].id) end
    end
    top(up, out.rising)
    top(down, out.falling)

    for id in pairs(include) do
        local p = prices[id]
        local s = itemStats(p)
        local days = {}
        for _, d in ipairs(p.days or {}) do
            days[#days + 1] = { dayToTime(d.day), d.low or d.high, d.high or d.low, d.available }
        end
        local o = owned and owned[id]
        out.items[tostring(id)] = {
            id = id, name = nameOf(id), now = s.now, low = s.low, peak = s.peak, change = s.change,
            supply = s.supply, available = s.available, days = days,
            seen = seen and seen[id] or nil,
            have = o and o.count or 0, holders = o and o.holders or nil,
        }
    end
    return out
end

-- The dashboard's own price log: a line "time<TAB>itemID<TAB>price" each time an item's price changed between
-- builds (Auctionator keeps one low/high per day; this keeps every scan you /reload after).
function I.parsePriceLog(text)
    local seen, last = {}, {}
    for t, id, price in (text or ""):gmatch("(%d+)\t(%d+)\t(%d+)") do
        t, id, price = tonumber(t), tonumber(id), tonumber(price)
        local list = seen[id]
        if not list then list = {}; seen[id] = list end
        list[#list + 1] = { t, price }
        last[id] = price
    end
    return seen, last
end

-- Lines to append for prices that differ from the log's last value for that item
function I.priceLogLines(market, last, now)
    local lines, ids = {}, {}
    for id, p in pairs(market and market.prices or {}) do
        if p.now and p.now > 0 and not p.stale and last[id] ~= p.now then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        lines[#lines + 1] = string.format("%d\t%d\t%d\n", now, id, market.prices[id].now)
    end
    return table.concat(lines)
end

----------------------------------------------------------------------------------------------------
-- Faction vs Neutral auction house

-- Classic auction house cut on a sale: 5% at your faction's house, 15% at the neutral (goblin) one
I.CUT = { faction = 0.05, neutral = 0.15 }

-- Items priced at both houses. Returns { { id, name, faction, neutral, spread (neutral / faction - 1),
-- toNeutral (buy at faction, sell at neutral: copper per item after the 15% cut), toFaction (the reverse, after
-- 5%), have, neutralAt (when Ledger Link last saw it) } }, biggest gap first.
function I.compareHouses(faction, neutral, nameOf, owned)
    local out = {}
    local fp = faction and faction.prices or {}
    for id, n in pairs(neutral and neutral.prices or {}) do
        local f = fp[id]
        if f and f.now and f.now > 0 and n.now and n.now > 0 then
            local o = owned and owned[id]
            out[#out + 1] = { id = id, name = nameOf(id), faction = f.now, neutral = n.now,
                spread = n.now / f.now - 1,
                toNeutral = math.floor(n.now * (1 - I.CUT.neutral)) - f.now,
                toFaction = math.floor(f.now * (1 - I.CUT.faction)) - n.now,
                have = o and o.count or 0, neutralAt = n.seenAt,
                fListed = f.days and #f.days > 0 and f.days[#f.days].available or nil,
                nListed = n.days and #n.days > 0 and n.days[#n.days].available or nil }
        end
    end
    table.sort(out, function(a, b)
        local ga, gb = math.abs(a.spread), math.abs(b.spread)
        if ga ~= gb then return ga > gb end
        return a.id < b.id
    end)
    return out
end

-- Scan days that were Neutral auction house scans saved into Auctionator's (faction) book, from before Ledger
-- Link kept them apart. days = { [scanDay] = true }. Moves those days out of market into neutral (made when
-- missing). An item whose latest price came from such a day falls back to its last faction day's low and is
-- marked stale (so the price log doesn't record it as a fresh observation). Returns market, neutral.
function I.splitNeutralDays(market, neutral, days)
    if not market or not days or not next(days) then return market, neutral end
    neutral = neutral or { prices = {}, vendor = {}, visits = {} }
    local moved = {}
    for d in pairs(days) do moved[#moved + 1] = d end
    table.sort(moved)
    neutral.movedDays = moved
    for id, p in pairs(market.prices) do
        local keep, out = {}, {}
        for _, d in ipairs(p.days or {}) do
            if days[d.day] then out[#out + 1] = d else keep[#keep + 1] = d end
        end
        if #out > 0 then
            local lastWasNeutral = days[p.days[#p.days].day]
            local n = neutral.prices[id]
            if not n then n = { days = {} }; neutral.prices[id] = n end
            local have = {}
            for _, d in ipairs(n.days) do have[d.day] = true end
            for _, d in ipairs(out) do if not have[d.day] then n.days[#n.days + 1] = d end end
            table.sort(n.days, function(a, b) return a.day < b.day end)
            if lastWasNeutral then
                if not n.now then n.now = p.now end
                local prev = keep[#keep]
                p.now = prev and prev.low or nil
                p.stale = true
            end
            if not n.now then n.now = n.days[#n.days].low end
            if not n.seenAt then n.stale = true end -- an old day's price, not a scan Ledger Link saw
            p.days = keep
            if #keep == 0 then market.prices[id] = nil end
        end
    end
    return market, neutral
end

-- "2026-11-13" lines (# comments allowed) as { [scanDay] = true }; dayOf(epoch) -> scan day
function I.parseNeutralDays(text, dayOf)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local y, m, d = line:gsub("#.*", ""):match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if y then out[dayOf(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))] = true end
    end
    return out
end

return I
