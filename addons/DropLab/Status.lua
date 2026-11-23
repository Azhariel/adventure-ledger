-- Status: what DropLab has recorded, for the /droplab window (StatusWindow.lua).
local _, ns = ...
local Stats = ns.Stats

local TOP = 5   -- mobs under "Most killed"
local DROPS = 3 -- drops shown for your target

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Why values or names may be quietly wrong: missing price data, mobs Questie can't name, XP lines the game hid
local function warnings(db)
    local out = {}
    local mob = MakeOrBuy and MakeOrBuy.API
    if not (mob and mob.GetSaleValue) then
        out[#out + 1] = "Make or Buy isn't loaded: no prices, so kill values are unknown"
    elseif not (Auctionator and Auctionator.API and Auctionator.API.v1) then
        out[#out + 1] = "Auctionator isn't loaded: drops count at vendor price only, so kill values run low"
    end
    local nameless = #Stats.Nameless(db)
    if nameless > 0 and not ns.QuestieLoaded() then
        out[#out + 1] = nameless .. " mob(s) known only by ID: their names come from Questie's NPC data, which isn't"
            .. " loaded, so kills of them wait unmatched"
    end
    local hidden = ns.session.hidden
    if hidden > 0 then
        out[#out + 1] = "the game hid " .. hidden .. " XP line(s) this session: kills among them weren't counted"
    end
    return out
end

local function recorded(db)
    local kills, looted, items, unpriced = 0, 0, {}, 0
    for _, m in pairs(db.mobs) do
        kills, looted = kills + (m.kills or 0), looted + (m.looted or 0)
        for itemID in pairs(m.items or {}) do items[itemID] = true end
    end
    local waiting = 0
    for _, n in pairs(db.unnamed) do waiting = waiting + n end
    local priced = MakeOrBuy and MakeOrBuy.API and MakeOrBuy.API.GetSaleValue
    if priced then
        for itemID in pairs(items) do
            if not ns.SaleValue(itemID) then unpriced = unpriced + 1 end
        end
    end
    local opened = 0
    for _, o in pairs(db.objects) do opened = opened + (o.opened or 0) end
    local rows = { { "Mobs", count(db.mobs) }, { "Kills", kills }, { "Corpses looted", looted }, { "Items seen", count(items) } }
    if waiting > 0 then rows[#rows + 1] = { "Kills waiting for a name", waiting } end
    if unpriced > 0 then rows[#rows + 1] = { "Items with no price", unpriced } end
    if opened > 0 then rows[#rows + 1] = { "Nodes and chests opened", opened } end
    rows[#rows + 1] = { "Mob tooltip lines", db.tooltip and "on" or "off" }
    return rows
end

local function session(db)
    local s = ns.session
    local rows = { { "Kills", s.kills }, { "Corpses looted", s.loots } }
    if s.lastMob then rows[#rows + 1] = { "Last looted", ns.MobName(s.lastMob, db.mobs[s.lastMob]) } end
    return rows
end

-- Your target, when it's a creature: its record from MobFacts (the same figures as its tooltip)
local function target(db)
    local id, name = ns.CreatureOf("target")
    if not id then return nil end
    local f = ns.MobFacts(id, DROPS)
    local mob = db.mobs[id]
    local rows = { { "Name", (mob and mob.name) or name or ns.MobName(id) } }
    if not f then
        rows[#rows + 1] = { "Kills", "none recorded yet" }
        return rows
    end
    rows[#rows + 1] = { "Kills", f.sample .. (f.rough and " (rough)" or "") }
    if f.value then rows[#rows + 1] = { "Per kill", ns.Money(f.value) } end
    if f.perHour then rows[#rows + 1] = { "Per hour", ns.Money(f.perHour) } end
    for _, d in ipairs(f.drops) do rows[#rows + 1] = { d.name, d.rate } end
    return rows
end

local function mostKilled(db)
    local list = {}
    for id, m in pairs(db.mobs) do
        local n, basis = Stats.Kills(m)
        list[#list + 1] = { id = id, n = n, basis = basis, name = ns.MobName(id, m) }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.id < b.id
    end)
    local rows = {}
    for i = 1, math.min(TOP, #list) do
        rows[i] = { list[i].name, Stats.SampleText(list[i].n, list[i].basis) }
    end
    return rows
end

function ns.Status()
    local db = ns.db
    if not db then return { warnings = { "nothing loaded yet: DropLab starts at login" } } end
    local sections = {
        { title = "Recorded", rows = recorded(db) },
        { title = "This session", rows = session(db) },
    }
    local t = target(db)
    if t then sections[#sections + 1] = { title = "Your target", rows = t } end
    sections[#sections + 1] = { title = "Most killed", rows = mostKilled(db) }
    return { warnings = warnings(db), sections = sections,
        footer = "/droplab best · /droplab <item> · /droplab target · /droplab tooltip · /droplab print" }
end

local window = ns.StatusWindow.New({
    name = "DropLabStatusFrame", title = "DropLab",
    build = ns.Status,
    position = function()
        if not ns.db then return nil end
        ns.db.window = ns.db.window or {}
        return ns.db.window
    end,
})
ns.StatusWindowFrame = window

function ns.ShowStatus(msg)
    if (msg or ""):lower():match("^%s*print%s*$") then return window:Print() end
    window:Toggle()
end
