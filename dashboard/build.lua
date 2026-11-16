-- Builds dashboard.html from your SavedVariables. Run after logging out (WoW only writes them on logout or
-- /reload):   lua build.lua            (or double-click build.bat, or `wowstats`)
-- Options:    lua build.lua <wow folder> <output file>
-- Paths come from ledger.cfg at the repo root (see ledger.cfg.example), or the LEDGER_WOW / LEDGER_DATA
-- environment variables: wow = your _forever_ folder; data = where the page, price logs and maps go (default
-- <repo>/data, which git ignores: it holds your characters' data).
-- this file's folder (also when the tests require it, where arg[0] is the test script)
local here = (debug.getinfo(1, "S").source:match("^@(.-)[^/\\]*$")) or ""
package.path = here .. "lib/?.lua;" .. package.path
local root = here .. "../"

local U = require("util")
local S = require("sources")
local M = require("model")
local I = require("insights")

local Build = {}

-- ledger.cfg: "key = value" lines, # comments
function Build.config(path)
    local cfg = {}
    local f = io.open(path or (root .. "ledger.cfg"), "r")
    if not f then return cfg end
    for line in f:lines() do
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and v ~= "" then cfg[k] = v end
        end
    end
    f:close()
    return cfg
end

-- The data folder (with a trailing slash), made if missing
function Build.dataDir(cfg)
    local d = (os.getenv("LEDGER_DATA") or (cfg and cfg.data) or (root .. "data")):gsub("[/\\]+$", "")
    if package.config:sub(1, 1) == "\\" then
        local w = d:gsub("/", "\\")
        os.execute('if not exist "' .. w .. '\\" mkdir "' .. w .. '"')
    else
        os.execute("mkdir -p '" .. d .. "'")
    end
    return d .. "/"
end

-- Loads Make or Buy's pure modules (planner, restock list) so the figures match the addon exactly.
-- Returns its ns ({ Planner, Restock }); a missing or broken file leaves that module out.
function Build.makeOrBuy(wow)
    local ns = {}
    for _, file in ipairs({ "Planner.lua", "Restock.lua" }) do
        local chunk = loadfile(wow .. "/Interface/AddOns/MakeOrBuy/" .. file)
        if chunk then pcall(chunk, "MakeOrBuy", ns) end
    end
    return ns
end

-- DropLab's Stats.lua (pure), or nil when the addon isn't installed
function Build.dropStats(wow)
    local chunk = loadfile(wow .. "/Interface/AddOns/DropLab/Stats.lua")
    if not chunk then return nil end
    local ns = {}
    local ok = pcall(chunk, "DropLab", ns)
    return ok and ns.Stats or nil
end

function Build.planner(wow)
    return Build.makeOrBuy(wow).Planner
end

-- Make or Buy's buy price: the cheaper of vendor and AH
local function priceFn(market)
    return function(id)
        local p = market.prices[id]
        local ah, vendor = p and p.now, market.vendor[id]
        if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
        if ah then return ah, "ah" end
        return nil
    end
end

-- { [itemID] = n } held in bags, bank and mail (a fresh table: Restock.Build consumes it)
local function heldMap(stockChar)
    local out = {}
    for _, loc in ipairs({ "bags", "bank", "mail" }) do
        for id, n in pairs(stockChar and stockChar[loc] or {}) do
            id = tonumber(id)
            if id then out[id] = (out[id] or 0) + n end
        end
    end
    return out
end

-- Every character folder: { account, realmDir, name, dir }
function Build.characters(wow, listDirs)
    listDirs = listDirs or S.listDirs
    local out = {}
    local base = wow .. "/WTF/Account"
    for _, account in ipairs(listDirs(base)) do
        for _, realmDir in ipairs(listDirs(base .. "/" .. account)) do
            if realmDir ~= "SavedVariables" then
                for _, name in ipairs(listDirs(base .. "/" .. account .. "/" .. realmDir)) do
                    local dir = base .. "/" .. account .. "/" .. realmDir .. "/" .. name .. "/SavedVariables"
                    out[#out + 1] = { account = account, realmDir = realmDir, name = name, dir = dir,
                        accountDir = base .. "/" .. account .. "/SavedVariables" }
                end
            end
        end
    end
    return out
end

local function sv(dir, file, global)
    local env = U.loadSV(dir .. "/" .. file)
    return env and env[global] or nil
end

-- The addons the page reads. Ours ship in addons/ (the repo's copy is what install.bat installs); the others
-- are checked for, and `tocs` are tried in order (Questie keeps one toc per client).
Build.OUR_ADDONS = { "Logbook", "LedgerLink", "MakeOrBuy", "Stockpile", "Haul", "DropLab" }
Build.OTHER_ADDONS = {
    { key = "Auctionator" },
    { key = "Questie", tocs = { "Questie_Forever", "Questie" } },
    { key = "QuestieDB", tocs = { "QuestieDB_Forever", "QuestieDB" } },
}

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- Each addon's version here (repo) and in WoW, the characters it's switched off on, and whether it has saved
-- anything yet: { { key, title, notes, ours, repo, installed, disabledOn = { names }, saved } }
function Build.addons(wow, folders, repoAddons)
    repoAddons = repoAddons or (root .. "addons")
    local function installed(key, tocs)
        for _, name in ipairs(tocs or { key }) do
            local m = S.tocMeta(wow .. "/Interface/AddOns/" .. key .. "/" .. name .. ".toc")
            if m then return m end
        end
    end
    local states = {}
    for _, c in ipairs(folders) do
        states[#states + 1] = { name = c.name:match("^[^-]+") or c.name,
            on = S.addonStates(U.readFile((c.dir:gsub("/SavedVariables$", "")) .. "/AddOns.txt")) }
    end
    local out = {}
    local function add(key, ours, tocs)
        local mine = ours and S.tocMeta(repoAddons .. "/" .. key .. "/" .. key .. ".toc") or nil
        local there = installed(key, tocs)
        local meta = mine or there or {}
        local row = { key = key, ours = ours, title = meta.Title or key, notes = meta.Notes,
            repo = mine and mine.Version, installed = there and there.Version, present = there ~= nil,
            disabledOn = {}, saved = false }
        local seen = {}
        for _, s in ipairs(states) do
            if s.on[key] == false and not seen[s.name] then
                seen[s.name] = true
                row.disabledOn[#row.disabledOn + 1] = s.name
            end
        end
        for _, c in ipairs(folders) do
            if exists(c.dir .. "/" .. key .. ".lua") or exists(c.accountDir .. "/" .. key .. ".lua") then
                row.saved = true
                break
            end
        end
        out[#out + 1] = row
    end
    for _, key in ipairs(Build.OUR_ADDONS) do add(key, true) end
    for _, a in ipairs(Build.OTHER_ADDONS) do add(a.key, false, a.tocs) end
    return out
end

-- uiMapID -> Wowhead zone id, read from zones.py (the live server's table, so there is one list):
-- the Replay module's map art for a zone the live server hasn't cached yet
function Build.zones(path)
    local text = U.readFile(path or (here .. "zones.py")) or ""
    local out = {}
    for ui, zone in text:gmatch("(%d+): %((%d+), \"") do out[ui] = tonumber(zone) end
    return out
end

-- Returns the dashboard data: { generated, characters = { ... } }
function Build.data(wow, opts)
    opts = opts or {}
    local names = opts.names or S.questieItemNames(wow .. "/Interface/AddOns/QuestieDB/QuestieDB_Forever.toc")
    local mobLib = Build.makeOrBuy(wow)
    local planner = mobLib.Planner
    local usesById = {}
    local markets, accounts, groups = {}, {}, {}
    local result = { generated = os.time(), characters = {} }

    local folders = {}
    local charDirs = Build.characters(wow, opts.listDirs)
    result.addons = Build.addons(wow, charDirs, opts.repoAddons)
    result.zones = Build.zones()
    for _, c in ipairs(charDirs) do
        local fname, fsurname = c.name:match("^([^-]+)-(.+)$")
        if fname then folders[#folders + 1] = { name = fname, surname = fsurname } end
        local acct = accounts[c.account]
        if not acct then
            local auction = U.loadSV(c.accountDir .. "/Auctionator.lua")
            acct = {
                market = S.auctionator(auction),
                stock = sv(c.accountDir, "Stockpile.lua", "StockpileDB"),
                muddy = sv(c.accountDir, "MuddyBoots.lua", "MuddyBootsDB"),
                logbook = sv(c.accountDir, "Logbook.lua", "LogbookDB"),
                droplab = sv(c.accountDir, "DropLab.lua", "DropLabDB"),
                neutral = S.neutral(U.loadSV(c.accountDir .. "/LedgerLink.lua")),
            }
            -- Neutral scans that reached Auctionator's book before Ledger Link kept them apart (neutral_days.txt)
            acct.market, acct.neutral = I.splitNeutralDays(acct.market, acct.neutral, opts.neutralDays)
            acct.chars = S.mergeAccountChars(acct.logbook, acct.muddy)
            accounts[c.account] = acct
            markets[#markets + 1] = acct.market
            groups[#groups + 1] = { muddyChars = acct.chars, stockChars = acct.stock and acct.stock.chars,
                market = acct.market, droplab = acct.droplab, neutral = acct.neutral }
        end
        -- the journey: Logbook (ours), with MuddyBoots' history from before Logbook started
        local muddy = S.mergeJournal(sv(c.dir, "Logbook.lua", "LogbookCharDB"), sv(c.dir, "MuddyBoots.lua", "MuddyBootsCharDB"))
        local haul = sv(c.dir, "Haul.lua", "HaulCharDB")
        local mob = sv(c.dir, "MakeOrBuy.lua", "MakeOrBuyCharDB")
        if muddy or haul or mob then
            local char = muddy and muddy.char or {}
            local stockChar
            for _, entry in pairs(acct.stock and acct.stock.chars or {}) do
                if entry.name == (char.name or c.name:match("^[^-]+")) and (not char.realm or entry.realm == char.realm) then
                    stockChar = entry
                end
            end
            local accountChar = char.guid and acct.chars and acct.chars[char.guid]
            local model = M.character({
                muddy = muddy, haul = haul, mob = mob, stock = stockChar, account = accountChar,
                market = acct.market, names = names, planner = planner,
            })
            model.profile.name = model.profile.name or c.name:match("^[^-]+")
            model.profile.realm = model.profile.realm or (stockChar and stockChar.realm)
                or (accountChar and accountChar.realm)
            model.id = M.charId(model.profile.name, model.profile.realm)
            model.profile.surname = fsurname
            model.profile.fullName = fsurname and (model.profile.name .. " " .. fsurname) or model.profile.name
            model.profile.ruleset = M.ruleset(model.profile.realm)
            model.key = c.account .. "/" .. c.name
            model.trails = M.trails(muddy and muddy.trail)
            model.recentTrail = M.recentTrail(muddy and muddy.trail, result.generated - M.RECENT_TRAIL_SECONDS)
            -- Play-session recaps (MuddyBoots joins a session per reload; I.playSessions merges them)
            local events = muddy and S.parseLog(muddy.log) or {}
            local nameOf, idOf = M.nameBook(names, haul, events, mob)
            model.recaps = muddy and I.recaps(muddy.sessions, events, acct.market, nameOf, 30, M.PROFESSIONS, idOf) or {}
            model.pace = muddy and I.playPace(muddy.sessions, result.generated) or nil
            model.playSpans = muddy and I.playSpans(muddy.sessions) or {}
            model.xpLive = M.xpState(events, haul)
            model.replay = muddy and M.replay(muddy.trail, events) or nil
            -- What this character crafts with, and what its restock list still needs after what it holds
            local shopping
            if mob and mob.recipes and mob.restock and next(mob.restock) and planner and mobLib.Restock then
                local ok, r = pcall(mobLib.Restock.Build, mob.restock, mob.recipes, planner.IndexByOutput(mob.recipes),
                    priceFn(acct.market), nil, heldMap(stockChar))
                shopping = ok and r and r.shopping or nil
            end
            local uses, needs = I.uses(mob and mob.recipes, shopping)
            usesById[model.id] = { uses = uses, needs = needs }
            result.characters[#result.characters + 1] = model
        end
    end
    table.sort(result.characters, function(a, b)
        return (a.profile.lastSeen or 0) > (b.profile.lastSeen or 0)
    end)
    -- Every character together (also alts with no detailed log yet)
    -- Names the characters' own logs learned (loot, Haul, recipes) beat "Item #id"
    local known = {}
    for _, c in ipairs(result.characters) do
        for _, it in ipairs(c.inventory.items or {}) do
            if not tostring(it.name):match("^Item #") then known[it.id] = it.name end
        end
    end
    result.account = M.account(groups, function(id)
        return names[id] or known[id] or ("Item #" .. tostring(id))
    end)
    local detailed = {}
    for _, c in ipairs(result.characters) do detailed[c.id] = true end
    local surnames = M.surnames(folders)
    for _, r in ipairs(result.account.characters) do
        r.detailed = detailed[r.id] or false
        r.fullName = M.fullName(r.name, surnames)
        r.ruleset = M.ruleset(r.realm)
    end
    for _, item in ipairs(result.account.inventory.items) do
        for _, h in ipairs(item.holders) do h.name = M.fullName(h.name, surnames) end
    end

    -- Everything every character holds, for the market's sell list and the mail suggestions
    local acctNameOf = function(id) return names[id] or known[id] or ("Item #" .. tostring(id)) end
    local owned, holders = {}, {}
    local rowsById = {}
    for _, r in ipairs(result.account.characters) do rowsById[r.id] = r end
    for _, g in ipairs(groups) do
        for _, sc in pairs(g.stockChars or {}) do
            if type(sc) == "table" and sc.name then
                local id = M.charId(sc.name, sc.realm)
                local row = rowsById[id]
                local who = row and row.fullName or sc.name
                local holds = {}
                for _, loc in ipairs({ "bags", "bank", "mail" }) do
                    for item, n in pairs(sc[loc] or {}) do
                        item = tonumber(item)
                        if item and n > 0 then
                            holds[item] = holds[item] or { bags = 0, bank = 0, mail = 0 }
                            holds[item][loc] = holds[item][loc] + n
                            local o = owned[item] or { count = 0, holders = {} }
                            owned[item] = o
                            o.count = o.count + n
                        end
                    end
                end
                for item, h in pairs(holds) do
                    local o = owned[item]
                    o.holders[#o.holders + 1] = who .. " " .. (h.bags + h.bank + h.mail)
                    o.where = o.where or {}
                    o.where[#o.where + 1] = { name = who, bags = h.bags, bank = h.bank, mail = h.mail }
                end
                local u = usesById[id] or {}
                holders[#holders + 1] = { id = id, name = who, faction = row and row.faction, holds = holds,
                    uses = u.uses, needs = u.needs }
            end
        end
    end
    -- Characters with recipes but no Stockpile entry can still receive
    local listed = {}
    for _, h in ipairs(holders) do listed[h.id] = true end
    for id, u in pairs(usesById) do
        if not listed[id] then
            local row = rowsById[id]
            holders[#holders + 1] = { id = id, name = row and row.fullName or id, faction = row and row.faction, holds = {},
                uses = u.uses, needs = u.needs }
        end
    end
    table.sort(holders, function(a, b) return a.id < b.id end)
    local market = groups[1] and groups[1].market or { prices = {}, vendor = {} }
    result.market = I.market(market, owned, acctNameOf)
    -- Market tab. opts.priceLog = { seen, last, append(lines) }: the dashboard's own price log (Build.run passes it)
    local seen, movedSeen = {}, {}
    if opts.priceLog then
        seen = opts.priceLog.seen
        -- logged points from the Neutral days belong to the Neutral book
        if opts.neutralDays and next(opts.neutralDays) then
            for id, list in pairs(seen) do
                local keep = {}
                for _, pt in ipairs(list) do
                    if opts.neutralDays[S.timeToDay(pt[1])] then
                        movedSeen[id] = movedSeen[id] or {}
                        table.insert(movedSeen[id], pt)
                    else
                        keep[#keep + 1] = pt
                    end
                end
                seen[id] = #keep > 0 and keep or nil
            end
        end
        local lines = I.priceLogLines(market, opts.priceLog.last, result.generated)
        if lines ~= "" then
            opts.priceLog.append(lines)
            for id, list in pairs((I.parsePriceLog(lines))) do
                seen[id] = seen[id] or {}
                for _, pt in ipairs(list) do table.insert(seen[id], pt) end
            end
        end
    end
    result.marketTab = I.marketTab(market, owned, acctNameOf, seen, S.dayToTime)
    -- The Neutral (goblin) auction house, from Ledger Link's own book: its own tab data, price log and comparison
    local neutral = groups[1] and groups[1].neutral
    if neutral then
        local nseen = {}
        if opts.neutralLog then
            nseen = opts.neutralLog.seen
            local lines = I.priceLogLines(neutral, opts.neutralLog.last, result.generated)
            if lines ~= "" then
                opts.neutralLog.append(lines)
                for id, list in pairs((I.parsePriceLog(lines))) do
                    nseen[id] = nseen[id] or {}
                    for _, pt in ipairs(list) do table.insert(nseen[id], pt) end
                end
            end
        end
        for id, list in pairs(movedSeen) do
            nseen[id] = nseen[id] or {}
            for _, pt in ipairs(list) do table.insert(nseen[id], pt) end
            table.sort(nseen[id], function(a, b) return a[1] < b[1] end)
        end
        result.neutralTab = I.marketTab(neutral, owned, acctNameOf, nseen, S.dayToTime)
        result.neutralTab.movedDays = {}
        for i, d in ipairs(neutral.movedDays or {}) do result.neutralTab.movedDays[i] = S.dayToTime(d) end
        result.neutralTab.last = neutral.last
        result.neutralTab.mode = neutral.mode
        result.neutralTab.visits = neutral.visits
        result.houses = I.compareHouses(market, neutral, acctNameOf, owned)
    end
    result.transfers = I.transfers(holders, acctNameOf, market)
    for i = #result.transfers, 41, -1 do result.transfers[i] = nil end
    -- Drop rates from your own kills (DropLab), drops valued at the AH price after the 5% cut
    local dropDB = groups[1] and groups[1].droplab
    if dropDB then
        local Stats = opts.dropStats or Build.dropStats(wow)
        result.drops = I.drops(dropDB, Stats, acctNameOf, function(id)
            local p = market.prices and market.prices[id]
            return p and p.now and math.floor(p.now * 0.95) or nil
        end, 25)
    end
    return result
end

function Build.html(template, data)
    local json = U.json(data)
    local page = template:gsub("/%*DATA%*/null", function() return json end)
    return page
end

function Build.run(wow, outFile, data)
    data = data or Build.dataDir(Build.config())
    local template = assert(U.readFile(here .. "template.html"), "template.html missing next to build.lua")
    local logPath = data .. "price_log.tsv"
    local function log(path)
        local seenL, lastL = I.parsePriceLog(U.readFile(path) or "")
        return { seen = seenL, last = lastL, append = function(lines)
            local f = io.open(path, "ab")
            if f then f:write(lines); f:close() end
        end }
    end
    local neutralDays = I.parseNeutralDays(U.readFile(data .. "neutral_days.txt"), S.timeToDay)
    local result = Build.data(wow, { priceLog = log(logPath), neutralLog = log(data .. "price_log_neutral.tsv"),
        neutralDays = neutralDays })
    U.writeFile(outFile, Build.html(template, result))
    return result
end

-- Run as a script (not when required by the tests)
if not package.loaded["build"] and arg and arg[0] and arg[0]:match("[^/\\]+$") == "build.lua" then
    local cfg = Build.config()
    local wow = arg[1] or os.getenv("LEDGER_WOW") or cfg.wow
    if not wow then
        io.stderr:write("Dashboard build failed: it doesn't know where WoW is. Copy ledger.cfg.example to ledger.cfg"
            .. " (repo root) and set wow = your _forever_ folder, or run: lua build.lua <wow folder> [output file]\n")
        os.exit(1)
    end
    local dir = Build.dataDir(cfg)
    local out = arg[2] or (dir .. "dashboard.html")
    local ok, data = pcall(Build.run, wow, out, dir)
    if not ok then
        io.stderr:write("Dashboard build failed: " .. tostring(data) .. "\n")
        os.exit(1)
    end
    local list = {}
    for _, c in ipairs(data.characters) do
        list[#list + 1] = (c.profile.fullName or c.profile.name or "?") .. " (" .. (c.profile.level or "?") .. ")"
    end
    print("Wrote " .. out .. " for " .. (#list > 0 and table.concat(list, ", ") or "no characters"))
end

return Build
