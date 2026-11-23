-- House keys: which auction house ("PvP Horde", "PvP Neutral") each price book describes.
-- Auctionator's book is keyed by ruleset only and the faction comes from the account's characters, or (Auctionator
-- 351 on Forever) by "<ruleset> <faction>"; Ledger Link records the side itself. Pure functions: build.lua passes in what it read.
local M = require("model")

local H = {}

function H.key(ruleset, side)
    return ruleset .. " " .. side
end

-- Characters usable for the faction rules, sorted by ruleset .. faction so every tie-break is deterministic.
local function usable(chars)
    local out = {}
    for _, c in ipairs(chars or {}) do
        local ruleset = M.ruleset(c.realm)   -- nil for a blank realm (GetRealmName() on Forever since 2026-11-21)
        if ruleset and c.faction then
            out[#out + 1] = { ruleset = ruleset, faction = c.faction }
        end
    end
    table.sort(out, function(a, b) return (a.ruleset .. a.faction) < (b.ruleset .. b.faction) end)
    return out
end

-- Most common value of field among sorted chars; the first in sort order wins a tie.
local function mostCommon(chars, field)
    local count, best, bestN = {}, nil, 0
    for _, c in ipairs(chars) do
        count[c[field]] = (count[c[field]] or 0) + 1
    end
    for _, c in ipairs(chars) do
        if count[c[field]] > bestN then best, bestN = c[field], count[c[field]] end
    end
    return best
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- The house an Auctionator book describes, or nil (after a warning) when it can't be told. Auctionator 351 keys
-- Forever books "<ruleset> <faction>"; older ones key by ruleset alone, so the account's characters tell the faction.
local function auctionatorHouse(ruleset, chars, warn)
    local keyRuleset, keyFaction = ruleset:match("^(.+) (%a+)$")
    if keyFaction == "Horde" or keyFaction == "Alliance" then
        return H.key(keyRuleset, keyFaction)
    end
    local seen, n, only = {}, 0, nil
    for _, c in ipairs(chars) do
        if c.ruleset == ruleset and not seen[c.faction] then
            seen[c.faction] = true; n = n + 1; only = c.faction
        end
    end
    local faction = only
    if n == 0 then faction = mostCommon(chars, "faction") end
    if n > 1 then
        warn("both factions play " .. ruleset .. ": faction prices come from Ledger Link's books only")
    elseif not faction then
        warn("Auctionator's " .. ruleset .. " book: this account has no characters to tell which faction it belongs to")
    else
        return H.key(ruleset, faction)
    end
    return nil
end

-- accounts: { { auctionator = {books}|nil, ledger = S.ledger result|nil, chars = { { realm, faction } } } }
-- Returns { [houseKey] = { priceBook, ... } }.
function H.collect(accounts, warn)
    warn = warn or function() end
    local out = {}
    local function add(key, book)
        out[key] = out[key] or {}
        out[key][#out[key] + 1] = book
    end
    for _, acc in ipairs(accounts or {}) do
        local chars = usable(acc.chars)
        if acc.auctionator and acc.auctionator.books then
            for _, ruleset in ipairs(sortedKeys(acc.auctionator.books)) do
                local key = auctionatorHouse(ruleset, chars, warn)
                if key then add(key, acc.auctionator.books[ruleset]) end
            end
        end
        if acc.ledger then
            for _, realm in ipairs(sortedKeys(acc.ledger.books)) do
                -- a blank realm (GetRealmName() on Forever since 2026-11-21): the account's ruleset
                local ruleset = M.ruleset(realm) or mostCommon(chars, "ruleset")
                for _, side in ipairs(sortedKeys(acc.ledger.books[realm])) do
                    if ruleset then
                        add(H.key(ruleset, side), acc.ledger.books[realm][side])
                    else
                        warn("Ledger Link's book without a realm: this account has no characters to tell which ruleset it belongs to")
                    end
                end
            end
            if acc.ledger.legacy then
                local ruleset = mostCommon(chars, "ruleset")
                if ruleset then
                    add(H.key(ruleset, "Neutral"), acc.ledger.legacy)
                else
                    warn("Ledger Link's legacy Neutral book: this account has no characters to tell which ruleset it belongs to")
                end
            end
        end
    end
    return out
end

-- The character's own house and the Neutral one of its ruleset; nil when the realm (or a blank one) or faction is missing.
function H.forChar(realm, faction)
    local ruleset = M.ruleset(realm)
    if not ruleset then return nil, nil end
    return faction and H.key(ruleset, faction) or nil, H.key(ruleset, "Neutral")
end

-- Houses of the most recently seen character with a realm (first row wins a tie).
function H.default(rows)
    local best
    for _, r in ipairs(rows or {}) do
        if M.ruleset(r.realm) and r.faction and (not best or (r.lastSeen or 0) > (best.lastSeen or 0)) then best = r end
    end
    if not best then return nil, nil end
    return H.forChar(best.realm, best.faction)
end

return H
