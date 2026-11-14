-- Alts: which items in your bags your other characters craft with, so the mailbox can send them over.
-- Pure logic (no WoW calls). Each character publishes a profile to the account-wide MakeOrBuyDB when it logs
-- in and out (Core.lua); the mailbox panel (MailPanel.lua) compares the alts' profiles with your bags.
local _, ns = ...

local Alts = {}
ns.Alts = Alts

-- uses:  { [itemID] = true } every reagent of a known recipe
-- needs: { [itemID] = qty } what the restock list still has to buy (shopping list from Restock.Build)
function Alts.Profile(recipes, shopping)
    local uses, needs = {}, {}
    for _, recipe in pairs(recipes or {}) do
        for _, r in ipairs(recipe.reagents or {}) do
            if r.itemID then uses[r.itemID] = true end
        end
    end
    for _, e in ipairs(shopping or {}) do
        if e.itemID and (e.qty or 0) > 0 then
            needs[e.itemID] = (needs[e.itemID] or 0) + e.qty
            uses[e.itemID] = true
        end
    end
    return uses, needs
end

-- The name to type in the mail's To: box. WoW Forever names are "First Surname"; the client writes them
-- like name-realm ("Azhariel-Deadheart"), the realm part being the surname.
function Alts.Recipient(profile)
    if profile.surname and profile.surname ~= "" then
        return profile.name .. "-" .. profile.surname
    end
    return profile.name
end

function Alts.DisplayName(profile)
    if profile.surname and profile.surname ~= "" then
        return profile.name .. " " .. profile.surname
    end
    return profile.name
end

-- me:    this character's key (GUID) and profile (its own uses win: nothing it crafts with is suggested away)
-- chars: MakeOrBuyDB.chars { [key] = profile { name, surname, faction, uses, needs } }
-- bags:  { [itemID] = count } mailable items in your bags
-- Returns { { key, profile, itemID, have, need (nil = uses it, no number), give, reason } } with restock needs
-- first, then by character and item ID. `give` = what to attach: the need (capped at what you have) or all.
function Alts.Suggest(meKey, mine, chars, bags)
    local out = {}
    mine = mine or {}
    for key, p in pairs(chars or {}) do
        if key ~= meKey and type(p) == "table" and p.name and (not mine.faction or not p.faction or p.faction == mine.faction) then
            for itemID, have in pairs(bags or {}) do
                local ownUse = (mine.uses and mine.uses[itemID]) or (mine.needs and mine.needs[itemID])
                if have > 0 and not ownUse and p.uses and p.uses[itemID] then
                    local need = p.needs and p.needs[itemID]
                    out[#out + 1] = { key = key, profile = p, itemID = itemID, have = have, need = need,
                        give = need and math.min(need, have) or have, reason = need and "restock" or "crafting" }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.reason == "restock") ~= (b.reason == "restock") then return a.reason == "restock" end
        local na, nb = Alts.DisplayName(a.profile), Alts.DisplayName(b.profile)
        if na ~= nb then return na < nb end
        return a.itemID < b.itemID
    end)
    return out
end

-- Which bag stacks to attach to send `want` of an item, as whole stacks (splitting needs a free bag slot and
-- isn't done) and at most `slots` of them. Each step takes the smallest stack that covers what's still
-- missing, or else the largest one, so the overshoot stays small. stacks: { { bag, slot, count } }.
-- Returns picked stacks (in pick order) and the total they hold.
function Alts.PickStacks(stacks, want, slots)
    local left = {}
    for i, s in ipairs(stacks or {}) do left[i] = s end
    table.sort(left, function(a, b)
        if a.count ~= b.count then return a.count < b.count end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
    local picked, total = {}, 0
    while total < want and #picked < (slots or 12) and #left > 0 do
        local missing, at = want - total, #left
        for i, s in ipairs(left) do
            if s.count >= missing then at = i break end
        end
        local s = table.remove(left, at)
        picked[#picked + 1] = s
        total = total + s.count
    end
    return picked, total
end

return Alts
