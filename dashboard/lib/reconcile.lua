-- Reconciliation of in-game scans (Auctionator, Ledger Link) with the API snapshots. Both describe the same
-- auction house at different moments; the newer one decides the current price. Pure functions: build.lua passes
-- in the book, the visits and the engine's house table.
local M = require("model")

local R = {}

-- When the book's price was scanned (epoch seconds). Ledger Link stamps the exact time (seenAt). Auctionator only
-- knows the day, so take the last visit of that side on that day (the scan happens while you stand at the AH);
-- without one, the end of the day, which never claims to be newer than it could be.
function R.scanAt(p, visits, ruleset, kind, dayToTime, timeToDay)
    if p.seenAt then return p.seenAt end
    local last = p.days and p.days[#p.days]
    if not last then return nil end
    local day, best = last.day, nil
    for _, v in ipairs(visits or {}) do
        if v.kind == kind and (v.realm == nil or M.ruleset(v.realm) == ruleset)
            and timeToDay(v.t) == day and (best == nil or v.t > best) then
            best = v.t
        end
    end
    return best or (dayToTime(day + 1) - 1)
end

local FROM_API = { "market", "historical", "soldPerDay", "trend", "units", "listings", "shifted" }

-- The book with the API's market data laid over it. api == nil: the book itself, untouched.
-- scanAt(p) -> time of that entry's scan (a closure over R.scanAt).
function R.merge(book, api, scanAt)
    if not api or not api.latest then return book end
    local out = { prices = {}, vendor = book.vendor, apiLatest = api.latest }
    for k, v in pairs(book) do
        if out[k] == nil and k ~= "prices" then out[k] = v end
    end
    local ids = {}
    for id in pairs(book.prices or {}) do ids[id] = true end
    for id in pairs(api.items or {}) do ids[id] = true end
    for id in pairs(ids) do
        local p, item = book.prices and book.prices[id], api.items and api.items[id]
        local e = {}
        for k, v in pairs(p or {}) do e[k] = v end
        -- read-only: shared with the raw book (the price logs are written from it)
        e.days = p and p.days or {}
        for _, f in ipairs(FROM_API) do e[f] = item and item[f] or nil end
        e.apiDays = item and item.days or nil
        local at = p and scanAt(p) or nil
        if api.latest > (at or -math.huge) then
            -- a newer snapshot that doesn't list the item means it sold out since the scan
            e.now, e.nowFrom, e.nowAt = item and item.now or nil, "api", api.latest
        else
            e.now, e.nowFrom, e.nowAt = p and p.now or nil, "scan", at
        end
        out.prices[id] = e
    end
    return out
end

-- How well the latest scan matches the API snapshot nearest in time (within 3 hours): { scanAt, apiAt, shared,
-- exact, near } (near includes exact: within 5%, like fetcher.match_score), or nil when nothing can be compared.
function R.agreement(book, api, scanAt)
    if not api or not api.latest or not api.recent then return nil end
    local day = nil
    for _, p in pairs(book.prices or {}) do
        local l = p.days and p.days[#p.days]
        if l and (day == nil or l.day > day) then day = l.day end
    end
    if not day then return nil end
    local set, at = {}, nil
    for id, p in pairs(book.prices) do
        local l = p.days and p.days[#p.days]
        if l and l.day == day and p.now then
            set[id] = p.now
            local t = scanAt(p)
            if t and (at == nil or t > at) then at = t end
        end
    end
    if not at then return nil end
    local snap, gap = nil, 3 * 3600 + 1
    for _, s in ipairs(api.recent) do
        local d = math.abs(s.t - at)
        if d < gap then snap, gap = s, d end
    end
    if not snap then return nil end
    local shared, exact, nearly = 0, 0, 0
    for id, scan in pairs(set) do
        local a = snap.min and snap.min[id]
        if a then
            shared = shared + 1
            if a == scan then exact = exact + 1 end
            if math.abs(a - scan) <= scan * 0.05 then nearly = nearly + 1 end
        end
    end
    if shared == 0 then return nil end
    return { scanAt = at, apiAt = snap.t, shared = shared, exact = exact, near = nearly }
end

return R
