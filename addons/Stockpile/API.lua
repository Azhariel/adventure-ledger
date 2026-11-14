-- Public API for other addons (MakeOrBuy reads owned reagents through it).
--
--   Stockpile.API.version                    -> 1
--   Stockpile.API.GetCount(itemID, scope)     -> total, list
--       scope: "character" (default, current character) or "realm" (every character on its realm)
--       list:  { { name=, realm=, class=, bags=, bank=, mail=, total= }, ... } characters with any
--   Stockpile.API.GetOwnedMap(scope)          -> fresh { [itemID] = count }; safe to change
--   Stockpile.API.RegisterCallback(owner, fn) -- fn(owner) after counts change (debounced 0.3s)
--   Stockpile.API.UnregisterCallback(owner)
local _, ns = ...
local Store = ns.Store

local API = { version = 1 }

local function ready()
    return ns.db and ns.playerKey and ns.db.chars[ns.playerKey]
end

function API.GetCount(itemID, scope)
    if not ready() or type(itemID) ~= "number" then
        return 0, {}
    end
    return Store.Count(ns.db, itemID, scope == "realm" and "realm" or "character", ns.playerKey)
end

function API.GetOwnedMap(scope)
    if not ready() then
        return {}
    end
    return Store.OwnedMap(ns.db, scope == "realm" and "realm" or "character", ns.playerKey)
end

function API.RegisterCallback(owner, fn)
    if owner == nil or type(fn) ~= "function" then
        error("Stockpile.API.RegisterCallback(owner, fn): owner and function required", 2)
    end
    ns.callbacks[owner] = fn
end

function API.UnregisterCallback(owner)
    if owner ~= nil then
        ns.callbacks[owner] = nil
    end
end

Stockpile = Stockpile or {}
Stockpile.API = API
ns.API = API
