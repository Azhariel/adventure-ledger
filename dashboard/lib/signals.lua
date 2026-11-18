-- AH signals: deals (bought under the market value, resold after the cut) and sell windows (what you hold, priced
-- well over the market value at the house you'd sell it at), each per house from the API's market values.
-- Items the API has no market value for keep today's scan-based buy/sell rows (I.market), marked basis "scans".
-- Pure functions: build.lua passes in the merged books (R.merge), the holders and the legacy lists.
local Sg = {}

-- DEAL_BELOW / SELL_ABOVE / MIN_GAIN start from I.MARKET (buyBelow, sellAbove, minGain). *_MIN_SOLD: sales a
-- day the market must show. LIMIT: rows per list (and as many legacy rows). WANTED_LIST: deals per house whose
-- series the engine keeps. FLIP_MIN_LISTED: listings at both houses for a flip to be wanted (the page's GAP_MIN).
-- RISE / FALL / MOVER_*: the movers list.
-- Deals are stricter than I.MARKET's buy rule: on the API's data (Nov 2026) 0.70 and 2 sales a day made 784
-- deals at PvP Horde and 224 at PvP Neutral; 0.50 and 5 a day make about 200 and 75.
Sg.C = { DEAL_BELOW = 0.50, DEAL_MIN_SOLD = 5, MIN_GAIN = 50, SELL_ABOVE = 1.25, SELL_MIN_SOLD = 1, LIMIT = 25,
    RISE = 0.25, FALL = -0.20, MOVER_MIN_SOLD = 2, MOVER_LIMIT = 30, WANTED_LIST = 25, FLIP_MIN_LISTED = 5 }

local function num(v) return type(v) == "number" and v or nil end

local function trim(list, n)
    for i = #list, n + 1, -1 do list[i] = nil end
    return list
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- book: a merged book ({ prices = { [id] = entry } }). cut: the house's AH cut (I.CUT). owned: { [id] = { count } }
-- or nil. legacyBuy: I.market's buy list or nil (the default faction house only).
-- Returns the API rows { id, name, now, market, pct, soldPerDay, units, profit, perDay, nowFrom, nowAt, have,
-- basis = "api" } by profit per day, then the legacy rows (basis = "scans") for items without a market value.
function Sg.deals(book, cut, nameOf, owned, legacyBuy)
    local C, prices = Sg.C, book and book.prices or {}
    local api = {}
    for id, e in pairs(prices) do
        local now, market, sold = num(e.now), num(e.market), num(e.soldPerDay)
        if market and market > 0 and now and now > 0 and sold and now <= market * C.DEAL_BELOW
            and sold >= C.DEAL_MIN_SOLD then
            local profit = math.floor(market * (1 - cut)) - now
            if profit >= C.MIN_GAIN then
                local units = num(e.units) or 0
                api[#api + 1] = { id = id, name = nameOf(id), now = now, market = market, pct = 1 - now / market,
                    soldPerDay = sold, units = num(e.units), profit = profit, perDay = math.floor(profit * math.min(sold, units)),
                    nowFrom = e.nowFrom, nowAt = e.nowAt, have = owned and owned[id] and owned[id].count or 0,
                    basis = "api" }
            end
        end
    end
    table.sort(api, function(a, b)
        if a.perDay ~= b.perDay then return a.perDay > b.perDay end
        return a.id < b.id
    end)
    trim(api, C.LIMIT)
    local legacy = {}
    for _, r in ipairs(legacyBuy or {}) do
        local e = prices[r.id]
        if not (e and e.market) then
            local row = copy(r)
            row.basis = "scans"
            legacy[#legacy + 1] = row
        end
    end
    table.sort(legacy, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.id < b.id
    end)
    trim(legacy, C.LIMIT)
    for _, r in ipairs(legacy) do api[#api + 1] = r end
    return api
end

local function held(w) return (w.bags or 0) + (w.bank or 0) + (w.mail or 0) end

-- holders: { { id = charId, name, holds = { [item] = { bags, bank, mail } } } }. houseOf(charId): the faction house
-- key the character sells at, nil when it can't be told (then defaultKey, as the character pages do). books:
-- { [key] = merged book }. legacySell: I.market's sell list or nil (judged at defaultKey).
-- Returns { id, name, key, now, market, pct, soldPerDay, count, extra, where = { { name, bags, bank, mail } },
-- basis = "api" } by extra copper, then the legacy rows (key = defaultKey, basis = "scans").
function Sg.sellWindows(holders, houseOf, books, nameOf, legacySell, defaultKey)
    local C = Sg.C
    local byHouse = {}  -- key -> item -> where list
    for _, h in ipairs(holders or {}) do
        local key = houseOf(h.id) or defaultKey
        if key then
            local items = byHouse[key] or {}
            byHouse[key] = items
            for item, w in pairs(h.holds or {}) do
                if held(w) > 0 then
                    items[item] = items[item] or {}
                    table.insert(items[item], { name = h.name, bags = w.bags or 0, bank = w.bank or 0, mail = w.mail or 0 })
                end
            end
        end
    end
    local api = {}
    for key, items in pairs(byHouse) do
        local prices = books and books[key] and books[key].prices or {}
        for id, where in pairs(items) do
            local e = prices[id]
            local now, market, sold = e and num(e.now), e and num(e.market), e and num(e.soldPerDay)
            if market and market > 0 and now and now > 0 and sold and now >= market * C.SELL_ABOVE
                and now - market >= C.MIN_GAIN and sold >= C.SELL_MIN_SOLD then
                local count = 0
                for _, w in ipairs(where) do count = count + held(w) end
                table.sort(where, function(a, b)
                    if held(a) ~= held(b) then return held(a) > held(b) end
                    return a.name < b.name
                end)
                api[#api + 1] = { id = id, name = nameOf(id), key = key, now = now, market = market,
                    pct = now / market - 1, soldPerDay = sold, count = count, extra = (now - market) * count,
                    where = where, basis = "api" }
            end
        end
    end
    table.sort(api, function(a, b)
        if a.extra ~= b.extra then return a.extra > b.extra end
        if a.key ~= b.key then return a.key < b.key end
        return a.id < b.id
    end)
    trim(api, C.LIMIT)
    local prices = defaultKey and books and books[defaultKey] and books[defaultKey].prices or {}
    local n = 0
    for _, r in ipairs(legacySell or {}) do
        local e = prices[r.id]
        if n < C.LIMIT and not (e and e.market) then
            local row = copy(r)
            row.key, row.basis = defaultKey, "scans"
            api[#api + 1] = row
            n = n + 1
        end
    end
    return api
end

-- Ids of the best Faction <-> Neutral flips (I.compareHouses rows): a positive flip either way, FLIP_MIN_LISTED or
-- more listed at both houses, by the better of the two flips, at most WANTED_LIST. Their series are wanted too.
function Sg.flipIds(rows)
    local picked = {}
    for _, r in ipairs(rows or {}) do
        local best = math.max(r.toNeutral or 0, r.toFaction or 0)
        if best > 0 and (r.fListed or 0) >= Sg.C.FLIP_MIN_LISTED and (r.nListed or 0) >= Sg.C.FLIP_MIN_LISTED then
            picked[#picked + 1] = { id = r.id, best = best }
        end
    end
    table.sort(picked, function(a, b)
        if a.best ~= b.best then return a.best > b.best end
        return a.id < b.id
    end)
    local ids = {}
    for i = 1, math.min(#picked, Sg.C.WANTED_LIST) do ids[i] = picked[i].id end
    return ids
end

return Sg
