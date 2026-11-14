-- Market: how much to trust an AH price. Pure logic (no WoW calls).
--
-- Auctionator keeps one entry per scan day: the lowest price seen (minSeen) and how many were listed
-- (available). Today's price is compared with the median of earlier days:
--   spike - today is at least SPIKE x the usual price (one odd listing can make a loss look like a profit)
--   dip   - today is at most DIP x the usual price (good to buy, but it may not last for selling)
--   stale - the price is STALE_DAYS or more days old
--   thin  - LOW_SUPPLY or fewer listed at the last scan (they may be gone when you get there)
local _, ns = ...

local Market = {}
ns.Market = Market

Market.SPIKE = 1.5
Market.DIP = 0.6
Market.STALE_DAYS = 3
Market.LOW_SUPPLY = 2
Market.MIN_HISTORY = 3 -- earlier days needed before comparing
Market.HISTORY_DAYS = 14

local function median(values)
    table.sort(values)
    local n = #values
    if n % 2 == 1 then
        return values[(n + 1) / 2]
    end
    return (values[n / 2] + values[n / 2 + 1]) / 2
end

-- current: today's price (copper). history: Auctionator's GetPriceHistory list, newest first
-- ({ minSeen, maxSeen, available }). age: days since the last scan that saw it.
-- Returns { spike, dip, stale, thin, usual, ratio, age, available } (flags are true/nil).
function Market.Assess(current, history, age)
    local result = { age = age }
    if age and age >= Market.STALE_DAYS then
        result.stale = true
    end
    history = history or {}
    local latest = history[1]
    if latest and latest.available ~= nil then
        result.available = latest.available
        if latest.available <= Market.LOW_SUPPLY then
            result.thin = true
        end
    end
    local earlier = {}
    for i = 2, math.min(#history, Market.HISTORY_DAYS + 1) do
        local price = history[i].minSeen
        if price and price > 0 then
            earlier[#earlier + 1] = price
        end
    end
    if current and current > 0 and #earlier >= Market.MIN_HISTORY then
        result.usual = median(earlier)
        result.ratio = current / result.usual
        if result.ratio >= Market.SPIKE then
            result.spike = true
        elseif result.ratio <= Market.DIP then
            result.dip = true
        end
    end
    return result
end

-- True when a sale price shouldn't be trusted at face value
function Market.Risky(assessment)
    return assessment and (assessment.spike or assessment.stale or assessment.thin) and true or false
end

-- Short reasons for a tooltip, e.g. { "2.1x the usual 40c", "only 1 listed" }
function Market.Reasons(a, money)
    local reasons = {}
    if not a then
        return reasons
    end
    if a.spike or a.dip then
        reasons[#reasons + 1] = string.format("%.1fx the usual %s", a.ratio, money(a.usual))
    end
    if a.stale then
        reasons[#reasons + 1] = a.age .. " days old"
    end
    if a.thin then
        reasons[#reasons + 1] = a.available == 0 and "none listed at the last scan" or ("only " .. a.available .. " listed")
    end
    return reasons
end
