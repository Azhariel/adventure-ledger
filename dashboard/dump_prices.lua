-- Prints "book<TAB>itemID<TAB>price" for the prices saved in game, for fetcher.py --match to compare with Battle.net.
-- The book is the ruleset ("PvP"), plus the side for Ledger Link's books ("PvP Horde"); the old unkeyed
-- Neutral book is "? Neutral".
--   lua dump_prices.lua <wow folder> faction   Auctionator's books (items seen on each one's latest scan day)
--                                              and Ledger Link's Horde/Alliance books
--   lua dump_prices.lua <wow folder> neutral   Ledger Link's Neutral books, every priced item
-- Uses the first account folder that has prices; nothing is merged, every book of it is printed.
local here = (debug.getinfo(1, "S").source:match("^@(.-)[^/\\]*$")) or ""
package.path = here .. "lib/?.lua;" .. package.path

local U = require("util")
local S = require("sources")
local M = require("model")

local wow, kind = arg[1], arg[2]
if not wow or (kind ~= "faction" and kind ~= "neutral") then
    io.stderr:write("usage: lua dump_prices.lua <wow folder> <faction|neutral>\n")
    os.exit(2)
end

-- { { label, { [item] = price } } } for this account's SavedVariables, or nil when it has none
local function books(dir)
    local out = {}
    local function add(label, prices)
        if next(prices) then out[#out + 1] = { label, prices } end
    end
    local function now(book)
        local prices = {}
        for id, e in pairs(book) do
            if e.now then prices[id] = e.now end
        end
        return prices
    end
    if kind == "faction" then
        local env = U.loadSV(dir .. "/Auctionator.lua")
        for realm, b in pairs(env and S.auctionator(env).books or {}) do
            local latest = -1
            for _, e in pairs(b) do
                local last = e.days[#e.days]
                if last and last.day > latest then latest = last.day end
            end
            local prices = {}
            for id, e in pairs(b) do
                local last = e.days[#e.days]
                if last and last.day == latest and e.now then prices[id] = e.now end
            end
            add(M.ruleset(realm), prices)
        end
    end
    local l = S.ledger(U.loadSV(dir .. "/LedgerLink.lua"))
    for realm, sides in pairs(l and l.books or {}) do
        for side, b in pairs(sides) do
            if (side == "Neutral") == (kind == "neutral") then add(M.ruleset(realm) .. " " .. side, now(b)) end
        end
    end
    if kind == "neutral" and l and l.legacy then add("? Neutral", now(l.legacy)) end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return #out > 0 and out or nil
end

local base = wow .. "/WTF/Account"
for _, account in ipairs(S.listDirs(base)) do
    local found = books(base .. "/" .. account .. "/SavedVariables")
    if found then
        for _, b in ipairs(found) do
            local ids = {}
            for id in pairs(b[2]) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do io.write(b[1], "\t", id, "\t", string.format("%d", b[2][id]), "\n") end
        end
        break
    end
end
