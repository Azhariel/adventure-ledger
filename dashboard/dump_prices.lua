-- Prints "itemID<TAB>price" for the prices saved in game, for fetcher.py --match to compare with Battle.net.
--   lua dump_prices.lua <wow folder> faction   Auctionator's book, items seen on its latest scan day
--   lua dump_prices.lua <wow folder> neutral   Ledger Link's Neutral book, every priced item
-- Uses the first account folder that has prices; nothing is merged.
local here = (debug.getinfo(1, "S").source:match("^@(.-)[^/\\]*$")) or ""
package.path = here .. "lib/?.lua;" .. package.path

local U = require("util")
local S = require("sources")

local wow, kind = arg[1], arg[2]
if not wow or (kind ~= "faction" and kind ~= "neutral") then
    io.stderr:write("usage: lua dump_prices.lua <wow folder> <faction|neutral>\n")
    os.exit(2)
end

-- item -> price for this account's SavedVariables, or nil when it has none
local function book(dir)
    local prices = {}
    if kind == "faction" then
        local env = U.loadSV(dir .. "/Auctionator.lua")
        local b = env and S.auctionator(env).prices or {}
        local latest = -1
        for _, e in pairs(b) do
            local last = e.days[#e.days]
            if last and last.day > latest then latest = last.day end
        end
        for id, e in pairs(b) do
            local last = e.days[#e.days]
            if last and last.day == latest and e.now then prices[id] = e.now end
        end
    else
        local n = S.neutral(U.loadSV(dir .. "/LedgerLink.lua"))
        for id, e in pairs(n and n.prices or {}) do
            if e.now then prices[id] = e.now end
        end
    end
    return next(prices) and prices or nil
end

local base = wow .. "/WTF/Account"
for _, account in ipairs(S.listDirs(base)) do
    local prices = book(base .. "/" .. account .. "/SavedVariables")
    if prices then
        local ids = {}
        for id in pairs(prices) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do io.write(id, "\t", string.format("%d", prices[id]), "\n") end
        break
    end
end
