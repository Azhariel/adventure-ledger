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
local Mg = require("merge")
local H = require("houses")
local R = require("reconcile")
local T = require("trends")
local Sg = require("signals")

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

-- Loads Make or Buy's pure modules (recipe data, planner, AH price checks, skill-ups, restock list) so the figures
-- match the addon exactly. Returns its ns ({ RecipeData, Planner, Market, Skill, Restock }); a missing or broken
-- file leaves that module out.
function Build.makeOrBuy(wow)
    local ns = {}
    for _, file in ipairs({ "Data/RecipeData.lua", "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua" }) do
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

-- Make or Buy's buy price: the cheaper of vendor and AH. AH is today's minimum, else the market value (a sold-out
-- item), the same buy price crafts use (model.lua buyPrice).
function Build.priceFn(market)
    return function(id)
        local p = market.prices[id]
        local ah, vendor = p and (p.now or p.market), market.vendor[id]
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

-- Every character folder: { account, realmDir, name, dir }. `wtf` (optional): a WTF folder to read instead of
-- the game's own (another PC's copy)
function Build.characters(wow, listDirs, wtf)
    listDirs = listDirs or S.listDirs
    local out = {}
    local base = (wtf or (wow .. "/WTF")) .. "/Account"
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

-- One saved table per folder that has it (this PC's first)
local function svs(dirs, file, global)
    local out = {}
    for _, d in ipairs(dirs) do
        local t = sv(d, file, global)
        if t then out[#out + 1] = t end
    end
    return out
end

-- Other PCs' WTF folders: each folder under data/pcs holding a WTF folder (a copy of that PC's _forever_\WTF)
-- or being one (it holds Account)
function Build.otherPCs(dataDir, listDirs)
    listDirs = listDirs or S.listDirs
    local out = {}
    local base = dataDir .. "pcs"
    for _, name in ipairs(listDirs(base)) do
        local root = base .. "/" .. name
        if #listDirs(root .. "/WTF/Account") > 0 then
            out[#out + 1] = { name = name, wtf = root .. "/WTF" }
        elseif #listDirs(root .. "/Account") > 0 then
            out[#out + 1] = { name = name, wtf = root }
        end
    end
    return out
end

-- This PC's character folders, each with the same character's folders on the other PCs (same realm folder and
-- name; a character only another PC has is added too): { account, realmDir, name, dir, accountDir,
-- dirs = { this PC's first }, accountDirs, pcs = n }
function Build.characterSets(wow, others, listDirs)
    local sets, byKey = {}, {}
    local function add(c, pc)
        local key = string.lower(c.realmDir .. "/" .. c.name)
        local set = byKey[key]
        if not set then
            set = { account = c.account, realmDir = c.realmDir, name = c.name, dir = c.dir, accountDir = c.accountDir,
                dirs = {}, accountDirs = {}, pcs = 0 }
            byKey[key] = set
            sets[#sets + 1] = set
        end
        set.dirs[#set.dirs + 1] = c.dir
        local seen = false
        for _, d in ipairs(set.accountDirs) do if d == c.accountDir then seen = true end end
        if not seen then set.accountDirs[#set.accountDirs + 1] = c.accountDir end
        set.pcs = set.pcs + 1
    end
    for _, c in ipairs(Build.characters(wow, listDirs)) do add(c) end
    for _, pc in ipairs(others or {}) do
        for _, c in ipairs(Build.characters(wow, listDirs, pc.wtf)) do add(c, pc) end
    end
    return sets
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

-- UTC hour h on this week's Tuesday (weeks start Monday) -> the local hour and the day shift (-1, 0, 1), for
-- ah_reset's default; this week's, so a summer-time zone gets today's offset. now: epoch (default os.time()).
function Build.thisTuesday(now)
    now = now or os.time()
    local u = os.date("!*t", now)
    return now - ((u.wday - 2) % 7 - 1) * 86400 - u.hour * 3600 - u.min * 60 - u.sec
end

function Build.utcHourToLocal(h, now)
    local t = os.date("*t", Build.thisTuesday(now) + h * 3600)
    return t.hour, t.wday - 3
end

-- Writes text to path through path .. ".tmp" and a rename, so a reader never sees half a file. os.rename won't
-- replace an existing file on Windows, so the target goes first. Returns true, or nil and the error.
function Build.writeAtomic(path, text)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(text)
    local cok, cerr = f:close()
    if not ok then os.remove(tmp); return nil, werr end
    if not cok then os.remove(tmp); return nil, cerr end
    os.remove(path)
    local rok, rerr = os.rename(tmp, path)
    if not rok then os.remove(tmp); return nil, rerr end
    return true
end

-- Returns the dashboard data: { generated, characters = { ... } }
function Build.data(wow, opts)
    opts = opts or {}
    local names = opts.names or S.questieItemNames(wow .. "/Interface/AddOns/QuestieDB/QuestieDB_Forever.toc")
    local mobLib = Build.makeOrBuy(wow)
    local planner = mobLib.Planner
    local usesById = {}
    local accounts, groups = {}, {}
    local result = { generated = os.time(), characters = {} }

    local folders = {}
    -- this PC's folders say which addons are installed and switched on; the journey also reads other PCs' copies
    result.addons = Build.addons(wow, Build.characters(wow, opts.listDirs), opts.repoAddons)
    result.zones = Build.zones()
    result.pcs = { "this PC" }
    for _, pc in ipairs(opts.otherPCs or {}) do result.pcs[#result.pcs + 1] = pc.name end
    result.warnings = {}
    local resetWarning
    result.reset, resetWarning = T.parseReset(opts.reset, Build.utcHourToLocal)
    if resetWarning then result.warnings[#result.warnings + 1] = resetWarning end
    local charDirs = Build.characterSets(wow, opts.otherPCs, opts.listDirs)
    -- every PC's account folder for each account
    local accountDirs = {}
    for _, c in ipairs(charDirs) do
        local list = accountDirs[c.account] or {}
        accountDirs[c.account] = list
        for _, d in ipairs(c.accountDirs) do
            local seen = false
            for _, x in ipairs(list) do if x == d then seen = true end end
            if not seen then list[#list + 1] = d end
        end
    end
    -- Every account first (every PC's copy of its folder): each character's market depends on all of them
    local houseAccts, ledgers, vendor, allChars, atrs = {}, {}, {}, {}, {}
    for _, c in ipairs(charDirs) do
        if not accounts[c.account] then
            local dirs = accountDirs[c.account]
            local stocks, logbooks, mine = {}, {}, {}
            for _, d in ipairs(dirs) do
                local env = U.loadSV(d .. "/Auctionator.lua")
                local atr = env and S.auctionator(env) or nil
                local ledger = S.ledger(U.loadSV(d .. "/LedgerLink.lua"))
                -- Auctionator's vendor prices aren't per house: one cache for every market
                for id, v in pairs(atr and atr.vendor or {}) do vendor[id] = vendor[id] or v end
                ledgers[#ledgers + 1] = ledger
                atrs[#atrs + 1] = atr
                mine[#mine + 1] = { auctionator = atr, ledger = ledger }
                local lbAcct = sv(d, "Logbook.lua", "LogbookDB")
                logbooks[#logbooks + 1] = lbAcct
                stocks[#stocks + 1] = { stock = sv(d, "Stockpile.lua", "StockpileDB"), rows = lbAcct and lbAcct.chars }
            end
            local acct = {
                stock = Mg.stockpiles(stocks),
                muddy = svs(dirs, "MuddyBoots.lua", "MuddyBootsDB")[1],
                logbook = Mg.logbookAccounts(logbooks),
                droplab = svs(dirs, "DropLab.lua", "DropLabDB")[1],
            }
            acct.chars = S.mergeAccountChars(acct.logbook, acct.muddy)
            -- rows in guid order, so ties between characters break the same way every build
            local guids, rows = {}, {}
            for guid in pairs(acct.chars or {}) do guids[#guids + 1] = guid end
            table.sort(guids)
            for i, guid in ipairs(guids) do rows[i] = acct.chars[guid]; allChars[#allChars + 1] = acct.chars[guid] end
            for _, h in ipairs(mine) do h.chars = rows; houseAccts[#houseAccts + 1] = h end
            accounts[c.account] = acct
            groups[#groups + 1] = { muddyChars = acct.chars, stockChars = acct.stock and acct.stock.chars,
                droplab = acct.droplab }
        end
    end

    -- Price books per auction house ("PvP Horde", "PvP Neutral"), never mixed across houses
    local warned = {}
    local raw = {}
    for key, list in pairs(H.collect(houseAccts, function(w)
        if not warned[w] then warned[w] = true; result.warnings[#result.warnings + 1] = w end
    end)) do
        local wrapped = {}
        for i, prices in ipairs(list) do wrapped[i] = { prices = prices, vendor = {} } end
        raw[key] = Mg.markets(wrapped)
    end
    -- The default pair (the last character played's houses) feeds the market pages
    local factionKey, neutralKey = H.default(allChars)
    -- No character with both realm and faction (old data, MuddyBoots rows only): the first faction house that has
    -- a book, so the market pages stay as they were
    local rawFaction, rawNeutral
    if not factionKey then
        local sides, neutrals = {}, {}
        for key in pairs(raw) do
            if key:match(" Neutral$") then neutrals[#neutrals + 1] = key else sides[#sides + 1] = key end
        end
        table.sort(sides); table.sort(neutrals)
        if sides[1] then
            factionKey, neutralKey = sides[1], H.key(sides[1]:match("^(.*) %S+$"), "Neutral")
        else
            -- not even one faction house can be told: Auctionator's largest book and Ledger Link's legacy Neutral
            -- book, as before houses existed (unkeyed, so never merged with API data)
            neutralKey = neutrals[1]
            local m = Mg.markets(atrs)
            rawFaction = m and { prices = m.prices, vendor = {} } or nil
            if not neutralKey then
                local legacy = {}
                for _, l in ipairs(ledgers) do
                    if l.legacy then legacy[#legacy + 1] = { prices = l.legacy, vendor = {} } end
                end
                rawNeutral = Mg.markets(legacy)
            end
        end
    end
    rawFaction = factionKey and raw[factionKey] or rawFaction
    rawNeutral = neutralKey and raw[neutralKey] or rawNeutral
    -- Neutral scans that reached Auctionator's book before Ledger Link kept them apart (neutral_days.txt)
    if rawFaction then
        rawFaction, rawNeutral = I.splitNeutralDays(rawFaction, rawNeutral, opts.neutralDays)
        if factionKey then raw[factionKey] = rawFaction end
        if neutralKey then raw[neutralKey] = rawNeutral end
    end
    -- Ledger Link's visits (every account, every PC) date Auctionator's day-only scans
    local visits, seenVisit, nlast, nmode = {}, {}, nil, nil
    for _, l in ipairs(ledgers) do
        for _, v in ipairs(l.visits) do
            local id = v.t .. "|" .. tostring(v.kind) .. "|" .. tostring(v.realm)
            if not seenVisit[id] then seenVisit[id] = true; visits[#visits + 1] = v end
        end
        if l.last and (not nlast or l.last > nlast) then nlast, nmode = l.last, l.mode end
        nmode = nmode or l.mode
    end
    table.sort(visits, function(a, b) return a.t < b.t end)
    -- scanAt for one house: its own ruleset and side's visits only
    local function scanAtFor(key)
        local ruleset, side = key:match("^(.*) (%S+)$")
        local kind = side == "Neutral" and "neutral" or "faction"
        return function(p) return R.scanAt(p, visits, ruleset, kind, S.dayToTime, S.timeToDay) end
    end
    -- The API's houses (market.lua), by key; a house without a snapshot time has no data
    local apiByKey = {}
    for _, h in pairs(type(opts.market) == "table" and type(opts.market.houses) == "table" and opts.market.houses or {}) do
        if type(h) == "table" and h.key and h.latest then apiByKey[h.key] = h end
    end
    -- Each house's book with the API's newer prices laid over it
    local keys, hasKey = {}, {}
    for key, book in pairs(raw) do
        if next(book.prices or {}) and not hasKey[key] then hasKey[key] = true; keys[#keys + 1] = key end
    end
    for key in pairs(apiByKey) do
        if not hasKey[key] then hasKey[key] = true; keys[#keys + 1] = key end
    end
    table.sort(keys)
    local merged = {}
    result.priceSources = {}
    for _, key in ipairs(keys) do
        local book, api, scanAt = raw[key], apiByKey[key], scanAtFor(key)
        local m = R.merge(book or { prices = {} }, api, scanAt)
        m.vendor = vendor
        merged[key] = m
        local latest
        for _, p in pairs(book and book.prices or {}) do
            local t = scanAt(p)
            if t and (not latest or t > latest) then latest = t end
        end
        result.priceSources[#result.priceSources + 1] = { key = key, apiAt = api and api.latest or nil, scanAt = latest,
            agreement = book and api and R.agreement(book, api, scanAt) or nil }
    end
    local market = factionKey and merged[factionKey] or rawFaction or { prices = {}, vendor = vendor }
    market.vendor = vendor
    -- The Neutral tab shows whenever Ledger Link is saving, also before its first Neutral scan (an empty raw book
    -- still carries the days the split looked at)
    local neutral = neutralKey and merged[neutralKey] or rawNeutral
    if not neutral and #ledgers > 0 then neutral = { prices = {}, vendor = vendor } end
    if neutral then
        neutral.vendor = vendor
        neutral.last, neutral.visits, neutral.mode = nlast, visits, nmode
    end
    for _, g in ipairs(groups) do g.market = market end
    -- A character's own faction house, empty when that house has no book and no API data (never another house's
    -- prices); the default pair's only when the house can't be told (no realm or faction)
    local function charMarket(realm, faction)
        local key = H.forChar(realm, faction)
        if not key then return market end
        return merged[key] or { prices = {}, vendor = vendor }
    end

    local marketValued = {}  -- character id -> true when its inventory was valued with API market values
    for _, c in ipairs(charDirs) do
        local fname, fsurname = c.name:match("^([^-]+)-(.+)$")
        if fname then folders[#folders + 1] = { name = fname, surname = fsurname } end
        local acct = accounts[c.account]
        -- the journey: Logbook (ours, every PC's copy merged), with MuddyBoots' history from before Logbook started
        local lb, shared = Mg.logbooks(svs(c.dirs, "Logbook.lua", "LogbookCharDB"))
        if shared > 0 then
            result.warnings[#result.warnings + 1] = c.name .. ": " .. shared .. " log lines are in more than one PC's"
                .. " copy (a file copied between PCs?), so its counters may be counted twice."
        end
        local muddy = S.mergeJournal(lb, svs(c.dirs, "MuddyBoots.lua", "MuddyBootsCharDB")[1])
        local haul = Mg.haul(svs(c.dirs, "Haul.lua", "HaulCharDB"))
        local mob = Mg.makeOrBuy(svs(c.dirs, "MakeOrBuy.lua", "MakeOrBuyCharDB"))
        if muddy or haul or mob then
            local char = muddy and muddy.char or {}
            local stockChar
            for _, entry in pairs(acct.stock and acct.stock.chars or {}) do
                if entry.name == (char.name or c.name:match("^[^-]+")) and (not char.realm or entry.realm == char.realm) then
                    stockChar = entry
                end
            end
            local accountChar = char.guid and acct.chars and acct.chars[char.guid]
            local charRealm = char.realm or (stockChar and stockChar.realm) or (accountChar and accountChar.realm)
            local charFaction = char.faction or (accountChar and accountChar.faction)
            local charMkt = charMarket(charRealm, charFaction)
            local model = M.character({
                muddy = muddy, haul = haul, mob = mob, stock = stockChar, account = accountChar,
                market = charMkt, names = names, planner = planner, mobLib = mobLib, now = result.generated,
            })
            model.profile.name = model.profile.name or c.name:match("^[^-]+")
            model.profile.realm = model.profile.realm or (stockChar and stockChar.realm)
                or (accountChar and accountChar.realm)
            model.id = M.charId(model.profile.name, model.profile.realm)
            model.profile.surname = fsurname
            model.profile.fullName = fsurname and (model.profile.name .. " " .. fsurname) or model.profile.name
            model.profile.ruleset = M.ruleset(model.profile.realm)
            model.key = c.account .. "/" .. c.name
            local houseFaction, houseNeutral = H.forChar(charRealm, charFaction)
            model.houses = { faction = houseFaction, neutral = houseNeutral }
            model.profile.pcs = c.pcs
            model.trails = M.trails(muddy and muddy.trail)
            model.recentTrail = M.recentTrail(muddy and muddy.trail, result.generated - M.RECENT_TRAIL_SECONDS)
            -- Play-session recaps (MuddyBoots joins a session per reload; I.playSessions merges them)
            local events = muddy and S.parseLog(muddy.log) or {}
            local nameOf, idOf = M.nameBook(names, haul, events, mob)
            model.recaps = muddy and I.recaps(muddy.sessions, events, charMkt, nameOf, 30, M.PROFESSIONS, idOf) or {}
            model.activityRates = I.activityRates(haul, events)
            model.pace = muddy and I.playPace(muddy.sessions, result.generated) or nil
            model.playSpans = muddy and I.playSpans(muddy.sessions) or {}
            model.xpLive = M.xpState(events, haul)
            model.replay = muddy and M.replay(muddy.trail, events) or nil
            -- What this character crafts with, and what its restock list still needs after what it holds
            local shopping
            if mob and mob.recipes and mob.restock and next(mob.restock) and planner and mobLib.Restock then
                local ok, r = pcall(mobLib.Restock.Build, mob.restock, mob.recipes, planner.IndexByOutput(mob.recipes),
                    Build.priceFn(charMkt), nil, heldMap(stockChar))
                shopping = ok and r and r.shopping or nil
            end
            local uses, needs = I.uses(mob and mob.recipes, shopping)
            usesById[model.id] = { uses = uses, needs = needs }
            result.characters[#result.characters + 1] = model
            marketValued[model.id] = charMkt.apiLatest ~= nil or nil
        end
    end
    table.sort(result.characters, function(a, b)
        return (a.profile.lastSeen or 0) > (b.profile.lastSeen or 0)
    end)
    -- Net worth over time. opts.worthLog = { seen, last, append(lines) }: the dashboard's own log (Build.run passes
    -- it); this build adds a point for each character whose gold or items changed
    local worthSeen = {}
    if opts.worthLog then
        worthSeen = opts.worthLog.seen
        local rows = {}
        for _, c in ipairs(result.characters) do
            rows[#rows + 1] = { id = c.id, gold = c.profile.money, items = c.netWorth.items, m = marketValued[c.id] }
        end
        local lines = I.worthLogLines(rows, opts.worthLog.last, result.generated)
        if lines ~= "" then
            opts.worthLog.append(lines)
            for id, list in pairs((I.parseWorthLog(lines))) do
                worthSeen[id] = worthSeen[id] or {}
                for _, pt in ipairs(list) do table.insert(worthSeen[id], pt) end
            end
        end
    end
    -- the page reads points as arrays: { t, gold, items, 1 when valued at market value }
    for _, c in ipairs(result.characters) do
        local pts = {}
        for i, pt in ipairs(worthSeen[c.id] or {}) do pts[i] = { pt[1], pt[2], pt[3], pt.m and 1 or nil } end
        c.worthLog = pts
    end
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
    end, nil, function(row) return charMarket(row.realm, row.faction) end)
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
        -- in-game scans only: the default pair's raw book, before the API's prices were laid over it
        local lines = I.priceLogLines(rawFaction, opts.priceLog.last, result.generated)
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
    if neutral then
        local nseen = {}
        if opts.neutralLog then
            nseen = opts.neutralLog.seen
            local lines = I.priceLogLines(rawNeutral, opts.neutralLog.last, result.generated)
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
    -- Mail to alts lists only what you asked for: restock lists (made by hand in game) here, and the mail list you
    -- build on the Crafting page. Make or Buy's in-game mailbox also suggests every reagent an alt's recipes use;
    -- on the page that guessed too much (herbs for a potion you never make), so those are left out.
    result.transfers = {}
    for _, t in ipairs(I.transfers(holders, acctNameOf, market)) do
        if t.reason == "restock" and #result.transfers < 40 then result.transfers[#result.transfers + 1] = t end
    end
    -- Trends: the API's houses with their family grids. opts.wanted(text): the items the engine should keep
    -- series for (market_wanted.tsv; Build.run passes it): families, what anyone holds or traded on the AH, per house
    local traded = {}
    for _, c in ipairs(result.characters) do
        for _, it in ipairs(c.money and c.money.ahTrades and c.money.ahTrades.items or {}) do
            if it.id then traded[it.id] = true end
        end
    end
    -- Deals (per house with API data) and Sell windows (holdings at each holder's own faction house). Their items
    -- are wanted too, so the drawer and the hour check have their grids
    if next(apiByKey) then
        local also = {}
        for id in pairs(traded) do also[id] = true end
        result.deals = {}
        -- the thresholds the page states in its hints, with the houses' cuts (a copy: Sg.C stays as it is)
        result.signalRule = { cut = I.CUT }
        for k, v in pairs(Sg.C) do result.signalRule[k] = v end
        for _, key in ipairs(keys) do
            if apiByKey[key] then
                local cut = key:match(" Neutral$") and I.CUT.neutral or I.CUT.faction
                local list = Sg.deals(merged[key], cut, acctNameOf, owned,
                    key == factionKey and result.market.buy or nil)
                result.deals[key] = list
                for i = 1, math.min(#list, Sg.C.WANTED_LIST) do also[list[i].id] = true end
            end
        end
        -- the faction house has no API data (only the other house does): its list is the scans' Buy low rows, so
        -- the page keeps showing it
        if factionKey and not result.deals[factionKey] then
            result.deals[factionKey] = Sg.deals(merged[factionKey] or market, I.CUT.faction, acctNameOf, owned,
                result.market.buy)
        end
        -- a holder's own faction house; nil (the default house) when its realm or faction can't be told
        local houseById = {}
        for _, r in ipairs(result.account.characters) do houseById[r.id] = (H.forChar(r.realm, r.faction)) end
        for _, c in ipairs(result.characters) do
            if c.id and c.houses then houseById[c.id] = c.houses.faction end
        end
        result.sellWindows = Sg.sellWindows(holders, function(id) return houseById[id] end, merged, acctNameOf,
            result.market.sell, factionKey)
        for _, r in ipairs(result.sellWindows) do also[r.id] = true end
        for _, id in ipairs(Sg.flipIds(result.houses)) do also[id] = true end
        traded = also
    end
    if next(apiByKey) then
        result.trends = T.page(apiByKey, I.FAMILIES, function(id) return names[id] or known[id] end, result.reset,
            factionKey, T.wantedIds(I.FAMILIES, owned, traded), owned)
    end
    if opts.wanted then
        local houseKeys, seenKey = {}, {}
        local function addKey(key)
            if key and not seenKey[key] then seenKey[key] = true; houseKeys[#houseKeys + 1] = key end
        end
        for key in pairs(apiByKey) do addKey(key) end
        for _, c in ipairs(result.characters) do addKey(c.houses.faction); addKey(c.houses.neutral) end
        table.sort(houseKeys)
        -- a locked or read-only market_wanted.tsv must not fail the page: the engine keeps the old list
        local ok, err = pcall(opts.wanted, T.wanted(I.FAMILIES, owned, traded, houseKeys))
        if not ok then
            result.warnings[#result.warnings + 1] = "couldn't write market_wanted.tsv (" .. tostring(err)
                .. "); the AH engine keeps the old list"
        end
    end
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
    local worthPath = data .. "networth_log.tsv"
    local worthSeen, worthLast = I.parseWorthLog(U.readFile(worthPath) or "")
    -- the market engine's output (market.py); missing or broken: in-game scans only
    local marketEnv = U.loadSV(data .. "market.lua")
    local wantedPath = data .. "market_wanted.tsv"
    local result = Build.data(wow, { priceLog = log(logPath), neutralLog = log(data .. "price_log_neutral.tsv"),
        neutralDays = neutralDays, otherPCs = Build.otherPCs(data), market = marketEnv and marketEnv.LedgerMarket,
        reset = Build.config().ah_reset,
        wanted = function(text)
            if (U.readFile(wantedPath) or "") ~= text then assert(Build.writeAtomic(wantedPath, text)) end
        end,
        worthLog = { seen = worthSeen, last = worthLast, append = function(lines)
            local f = io.open(worthPath, "ab")
            if f then f:write(lines); f:close() end
        end } })
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
    print("Wrote " .. out .. " for " .. (#list > 0 and table.concat(list, ", ") or "no characters")
        .. (#data.pcs > 1 and (", merging " .. table.concat(data.pcs, ", ")) or ""))
    for _, w in ipairs(data.warnings or {}) do print("Warning: " .. w) end
end

return Build
