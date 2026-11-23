-- Offline tests for Ledger Link.   Usage (from the LedgerLink folder):  lua tests/run.lua
-- The game API is stubbed: LoggingCombat keeps a flag and counts calls; print is captured.
local root = (arg and arg[0] or ""):match("^(.-)tests[/\\]run%.lua$") or ""

local tests, failed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(a, b, msg)
    if a ~= b then error((msg and (msg .. ": ") or "") .. "expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Fresh addon with a stubbed client; returns the module and the stub state
local function load(opts)
    opts = opts or {}
    local st = { on = opts.on or false, sets = 0, printed = {}, tickers = {} }
    _G.LedgerLinkDB = opts.db
    _G.LoggingCombat = function(v)
        if opts.protected then error("protected") end
        if v ~= nil then st.sets = st.sets + 1; st.on = v and true or false end
        return st.on
    end
    _G.print = function(s) st.printed[#st.printed + 1] = s end
    _G.SlashCmdList = {}
    _G.time = os.time
    _G.GetRealmName = opts.realm or function() return "PvP" end
    _G.UnitFactionGroup = opts.faction or function() return "Horde" end
    _G.Auctionator = opts.auctionator -- tests that need it stub it after load
    _G.DEFAULT_CHAT_FRAME = nil
    _G.C_Timer = {
        After = function(_, fn) fn() end,
        NewTicker = function(sec, fn)
            local t = { sec = sec, fn = fn, Cancel = function(self) self.cancelled = true end }
            st.tickers[#st.tickers + 1] = t
            return t
        end,
    }
    local handlers = {}
    _G.CreateFrame = function()
        return { RegisterEvent = function() end, SetScript = function(_, _, fn) handlers.event = fn end }
    end
    local ns = {}
    for _, f in ipairs({ "Core.lua", "StatusWindow.lua", "Status.lua" }) do
        assert(loadfile(root .. f))("LedgerLink", ns)
    end
    st.fire = function() handlers.event() end
    st.ns = ns
    return ns.LedgerLink, st
end

test("logging off at login: switched on once, with one message", function()
    local L, st = load()
    st.fire()
    eq(st.on, true); eq(st.sets, 1); eq(#st.printed, 1)
    st.fire() -- a /reload: already on, nothing to do
    eq(st.sets, 1); eq(#st.printed, 1)
end)

test("already on, disabled, or quiet: no switch or no message", function()
    local _, st = load({ on = true }); st.fire(); eq(st.sets, 0)
    local _, st2 = load({ db = { enable = false } }); st2.fire(); eq(st2.on, false)
    local _, st3 = load({ db = { quiet = true } }); st3.fire(); eq(st3.on, true); eq(#st3.printed, 0)
end)

test("a protected LoggingCombat never breaks the addon", function()
    local L, st = load({ protected = true })
    st.fire()
    eq(L.Ensure(), false)
end)

test("on/off commands still switch and say so", function()
    local L, st = load()
    st.fire()
    local n = #st.printed
    L.Command("off"); eq(LedgerLinkDB.enable, false)
    eq(#st.printed, n + 1); eq(st.printed[#st.printed]:find("won't switch", 1, true) ~= nil, true)
    L.Command("on"); eq(LedgerLinkDB.enable, true)
    eq(st.printed[#st.printed]:find("at every login", 1, true) ~= nil, true)
    L.Command("neutral both"); eq(LedgerLinkDB.neutralMode, "both")
    eq(st.printed[#st.printed]:find("0 items in the Neutral book", 1, true) ~= nil, true)
end)

-- A stub Auctionator whose Database records what reaches it
local function stubAuctionator()
    local got = {}
    _G.Auctionator = { Database = { SetPrice = function(self, key, price, avail) got[#got + 1] = { key, price, avail } end } }
    return got
end
local function at(mapID, sub, zone)
    _G.C_Map = { GetBestMapForUnit = function() return mapID end }
    _G.GetSubZoneText = function() return sub or "" end
    _G.GetZoneText = function() return zone or "" end
end

test("neutral AH: detected by map id, then by English zone name; capitals aren't", function()
    local L = load()
    at(1446); eq(L.IsNeutralHere(), true)
    at(1453, "Trade District", "Stormwind City"); eq(L.IsNeutralHere(), false)
    at(nil, "Booty Bay", "Stranglethorn Vale"); eq(L.IsNeutralHere(), true)
end)

test("neutral AH: Forever's goblin AH outside the Crossroads (the Barrens) counts", function()
    local L = load()
    at(1413); eq(L.IsNeutralHere(), true)
    at(nil, "", "The Barrens"); eq(L.IsNeutralHere(), true)
    at(1411, "Valley of Strength", "Orgrimmar"); eq(L.IsNeutralHere(), false)
end)

test("neutral AH, split: prices go to the Neutral book only; faction AH goes to Auctionator", function()
    local L = load()
    local got = stubAuctionator()
    at(1446); L.OnAuctionShow(1794200000)
    Auctionator.Database:SetPrice("2447", 500, 12)
    Auctionator.Database:SetPrice("2447", 400, 3)
    eq(#got, 0, "Auctionator untouched")
    local e = LedgerLinkDB.books.PvP.Neutral["2447"]
    local day = tostring(math.floor((os.time() - os.time({ year = 2020, month = 1, day = 1, hour = 0 })) / 86400))
    eq(e.m, 400); eq(e.h[day], 500); eq(e.l[day], 400); eq(e.a[day], 12)
    eq(LedgerLinkDB.visits[1].kind, "neutral")
    at(1453, "", "Stormwind City"); L.OnAuctionShow(1794200100)
    Auctionator.Database:SetPrice("2447", 300, 40)
    eq(#got, 1); eq(got[1][2], 300)
    eq(LedgerLinkDB.books.PvP.Neutral["2447"].m, 400, "faction scan leaves the Neutral book alone")
    L.HookAuctionator(); Auctionator.Database:SetPrice("765", 10, 1)
    eq(#got, 2, "hooked once: no double wrapping")
end)

test("neutral AH, both and off modes", function()
    local L = load({ db = { neutralMode = "both" } })
    local got = stubAuctionator()
    at(1434); L.OnAuctionShow()
    Auctionator.Database:SetPrice("2447", 500, 1)
    eq(#got, 1); eq(LedgerLinkDB.books.PvP.Neutral["2447"].m, 500)
    L.Command("neutral off"); eq(LedgerLinkDB.neutralMode, "off")
    Auctionator.Database:SetPrice("765", 50, 1)
    eq(#got, 2); eq(LedgerLinkDB.books.PvP.Neutral["765"], nil)
end)

test("books: neutral and faction scans land under realm and side; visits carry both", function()
    local L = load(); local got = stubAuctionator()
    at(1446); L.OnAuctionShow(1794200000)
    Auctionator.Database:SetPrice("2447", 400, 3)
    eq(#got, 0); eq(LedgerLinkDB.books.PvP.Neutral["2447"].m, 400)
    eq(LedgerLinkDB.visits[1].realm, "PvP"); eq(LedgerLinkDB.visits[1].faction, "Horde")
    at(1411, "", "Orgrimmar"); L.OnAuctionShow(1794200100)
    Auctionator.Database:SetPrice("2447", 300, 40)
    eq(#got, 1, "faction scan still reaches Auctionator")
    eq(LedgerLinkDB.books.PvP.Horde["2447"].m, 300)
    eq(LedgerLinkDB.books.PvP.Neutral["2447"].m, 400)
end)

test("blank realm (Forever client, 2026-11-21): books and visits go under the ruleset from the game rules", function()
    _G.Enum = { GameRule = { PvPRuleset = 1, RPRuleset = 2, HardcoreRuleset = 3 } }
    _G.C_GameRules = { IsGameRuleActive = function(rule) return rule == 1 end }
    local L = load({ realm = function() return "" end }); stubAuctionator()
    at(1446); L.OnAuctionShow(1794200000)
    Auctionator.Database:SetPrice("2447", 400, 3)
    eq(LedgerLinkDB.books.PvP.Neutral["2447"].m, 400)
    eq(LedgerLinkDB.books[""], nil)
    eq(LedgerLinkDB.visits[1].realm, "PvP")
    _G.Enum, _G.C_GameRules = nil, nil
end)

test("migration: the old unkeyed Neutral book moves under this realm once", function()
    local L, st = load({ db = { neutral = { ["765"] = { l = {}, h = { ["2500"] = 9 }, a = {}, m = 9, t = 5 } } } })
    st.fire()
    eq(LedgerLinkDB.neutral, nil); eq(LedgerLinkDB.books.PvP.Neutral["765"].m, 9)
    st.fire(); eq(LedgerLinkDB.books.PvP.Neutral["765"].m, 9, "idempotent")
end)

test("migration: merging into an existing book keeps the newer price and unions the days", function()
    local L, st = load({ db = {
        neutral = { ["1"] = { l = { ["10"] = 5 }, h = { ["10"] = 20, ["11"] = 7 }, a = { ["10"] = 2 }, m = 7, t = 100 } },
        books = { PvP = { Neutral = { ["1"] = { l = { ["10"] = 8 }, h = { ["10"] = 15 }, a = { ["10"] = 6 }, m = 9, t = 50 } } } } } })
    st.fire()
    local e = LedgerLinkDB.books.PvP.Neutral["1"]
    eq(e.m, 7); eq(e.t, 100); eq(e.l["10"], 5); eq(e.h["10"], 20); eq(e.a["10"], 6); eq(e.h["11"], 7)
end)

test("a faction scan leaves the Neutral last-scan time alone", function()
    local L = load(); stubAuctionator()
    at(1446); L.OnAuctionShow(1794200000)
    Auctionator.Database:SetPrice("2447", 400, 3)
    local last = LedgerLinkDB.neutralLast
    eq(last ~= nil, true)
    at(1411, "", "Orgrimmar"); L.OnAuctionShow(1794200100)
    Auctionator.Database:SetPrice("2447", 300, 40)
    eq(LedgerLinkDB.neutralLast, last)
end)

assert(loadfile(root .. "tests/test_status.lua"))()({ test = test, eq = eq, load = load,
    stubAuctionator = stubAuctionator, at = at })

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        io.write("  ok   " .. t.name .. "\n")
    else
        failed = failed + 1
        io.write("  FAIL " .. t.name .. "\n       " .. tostring(err) .. "\n")
    end
end
io.write(string.format("\n%d passed, %d failed\n", #tests - failed, failed))
if failed > 0 then os.exit(1) end
