-- Offline tests for the dashboard builder.   Usage (from the Dashboard folder):  lua tests/run.lua
-- Techniques (ISTQB): equivalence partitioning and boundary values for the decoders (each CBOR length size,
-- each float width), decision tables for the money and zone rules, state-based tests over event sequences,
-- and an end-to-end test that builds the page from fixture SavedVariables.
local root = (arg and arg[0] or ""):match("^(.-)tests[/\\]run%.lua$") or ""
package.path = root .. "lib/?.lua;" .. root .. "?.lua;" .. package.path

local U = require("util")
local CBOR = require("cbor")
local S = require("sources")
local M = require("model")
local I = require("insights")

-- The WoW folder, for the tests that run the real Make or Buy and DropLab code: LEDGER_WOW or ledger.cfg
local function wowDir()
    return os.getenv("LEDGER_WOW") or require("build").config().wow or (root .. "..")
end

local tests, failed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(a, b, msg)
    if a ~= b then error((msg and (msg .. ": ") or "") .. "expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
local function near(a, b, msg) if math.abs(a - b) > 1e-6 then error((msg or "") .. " expected ~" .. b .. ", got " .. tostring(a), 2) end end
local hex = function(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

----------------------------------------------------------------------------------------------------
-- Decoders

test("CBOR integers at each length boundary (RFC 8949 vectors)", function()
    eq(CBOR.decode(hex("00")), 0); eq(CBOR.decode(hex("17")), 23)
    eq(CBOR.decode(hex("1818")), 24); eq(CBOR.decode(hex("18ff")), 255)
    eq(CBOR.decode(hex("190100")), 256); eq(CBOR.decode(hex("1a000f4240")), 1000000)
    eq(CBOR.decode(hex("1b000000e8d4a51000")), 1000000000000)
    eq(CBOR.decode(hex("20")), -1); eq(CBOR.decode(hex("3863")), -100)
end)

test("CBOR floats: half, single, double; booleans and null", function()
    eq(CBOR.decode(hex("f93c00")), 1.0); eq(CBOR.decode(hex("f9c400")), -4.0)
    near(CBOR.decode(hex("fa47c35000")), 100000.0)
    near(CBOR.decode(hex("fb3ff199999999999a")), 1.1)
    eq(CBOR.decode(hex("f4")), false); eq(CBOR.decode(hex("f5")), true); eq(CBOR.decode(hex("f6")), nil)
end)

test("CBOR strings, arrays, maps, nesting and indefinite lengths", function()
    eq(CBOR.decode(hex("6449455446")), "IETF")
    eq(CBOR.decode(hex("4401020304")), "\1\2\3\4")
    local a = CBOR.decode(hex("8301820203820405"))
    eq(a[1], 1); eq(a[2][2], 3); eq(a[3][1], 4)
    local m = CBOR.decode(hex("a26161016162820203"))
    eq(m.a, 1); eq(m.b[2], 3)
    local ind = CBOR.decode(hex("9f018202039f0405ffff"))
    eq(#ind, 3); eq(ind[3][2], 5)
    eq(CBOR.decode(hex("7f657374726561646d696e67ff")), "streaming")
end)

test("CBOR: Auctionator-shaped entry with byte-string keys", function()
    -- { "15115" = { m = 1000, h = { "2502" = 1000 } } } as WoW writes it (keys as byte strings)
    local raw = hex("a1" .. "4531353131350" .. "5"):sub(1, 0) -- placeholder (built below)
    raw = string.char(0xa1) .. string.char(0x45) .. "15115" .. string.char(0xa2) .. string.char(0x41) .. "m" .. string.char(0x19, 0x03, 0xe8)
        .. string.char(0x41) .. "h" .. string.char(0xa1) .. string.char(0x44) .. "2502" .. string.char(0x19, 0x03, 0xe8)
    local db = CBOR.decode(raw)
    eq(db["15115"].m, 1000); eq(db["15115"].h["2502"], 1000)
end)

test("CBOR: truncated or empty input returns nil and an error, never throws", function()
    local v, err = CBOR.decode(hex("8301"))
    eq(v, nil); truthy(err)
    eq(CBOR.decode(""), nil); eq(CBOR.decode(nil), nil)
end)

test("base64 decoding with and without padding", function()
    eq(U.base64decode("TWFu"), "Man"); eq(U.base64decode("TWE="), "Ma"); eq(U.base64decode("TQ=="), "M")
    eq(U.base64decode("TQ"), "M", "missing padding")
end)

test("JSON: escaping, arrays vs objects, integers vs floats, no </script> break-out", function()
    eq(U.json({ 1, 2, 3 }), "[1,2,3]")
    eq(U.json({}), "[]")
    eq(U.json({ b = 1, a = "x" }), '{"a":"x","b":1}')
    eq(U.json('say "hi"\n'), '"say \\"hi\\"\\n"')
    eq(U.json("</script>"), '"<\\/script>"')
    eq(U.json(1.5), "1.5"); eq(U.json(3.0), "3"); eq(U.json(0 / 0), "null")
    eq(U.json({ [1] = 1, [3] = 3 }), '{"1":1,"3":3}', "sparse table is an object")
end)

test("loadSV reads files containing byte 0x1A (Windows text mode would stop there)", function()
    local path = os.tmpname()
    U.writeFile(path, 'DB = { s = "a\26b", n = 5 }\n')
    local env = U.loadSV(path)
    os.remove(path)
    eq(env.DB.n, 5); eq(env.DB.s, "a\26b")
    eq(U.loadSV(path), nil, "missing file")
end)

test("Questie names: base64 CBOR rows; other lines and chunked values ignored", function()
    local path = os.tmpname()
    local row = string.char(0xa2, 0x01, 0x4f) .. "Compact Shotgun" .. string.char(0x09, 0x0d)
    local b64 = "pwFPQ29tcGFjdCBTaG90Z3VuCQ0KCAsDDAINA0FwBA==" -- real row from QuestieDB
    U.writeFile(path, "## Title: QuestieDB\n## X-Item-4577-S: " .. b64 .. "\n## X-Item-9-S: ~3~\n## X-Item-4577-3: iBkH\n")
    local names = S.questieItemNames(path)
    os.remove(path)
    eq(names[4577], "Compact Shotgun"); eq(names[9], nil)
    truthy(#row > 0)
end)

test("Auctionator: largest realm wins; days sorted; vendor cache rounded", function()
    local env = { AUCTIONATOR_PRICE_DATABASE = { __dbversion = 8,
        Small = { ["1"] = { m = 5, h = { ["10"] = 5 } } },
        Big = { ["2592"] = { m = 109, h = { ["2502"] = 109, ["2501"] = 209 }, l = { ["2501"] = 150 } }, ["2589"] = { m = 23, h = { ["2502"] = 23 } } } },
        AUCTIONATOR_VENDOR_PRICE_CACHE = { ["2321"] = 99.6 } }
    local a = S.auctionator(env)
    eq(a.prices[1], nil, "smaller realm ignored")
    eq(a.prices[2592].now, 109)
    eq(a.prices[2592].days[1].day, 2501); eq(a.prices[2592].days[1].low, 150); eq(a.prices[2592].days[2].low, 109)
    eq(a.vendor[2321], 100)
    eq(S.dayToTime(1) - S.dayToTime(0), 86400)
end)

test("log lines: fields, empty fields kept in place, missing played time", function()
    local e = S.parseLogLine("1794021095|36553|1420|1124|6322|de|Tarnished Zealot|259433|||world||11|normal|21")
    eq(e.t, 1794021095); eq(e.played, 36553); eq(e.map, 1420); eq(e.kind, "de")
    eq(e.args[1], "Tarnished Zealot"); eq(e.args[3], ""); eq(e.args[5], "world"); eq(e.args[7], "11")
    local f = S.parseLogLine("1794011432|||||pc|e718c2")
    eq(f.played, nil); eq(f.kind, "pc"); eq(f.args[1], "e718c2")
end)

----------------------------------------------------------------------------------------------------
-- Model

local function ev(lines)
    return S.parseLog(lines)
end

test("money decision table: earnings, spending and zero deltas by source", function()
    local series, earned, spent = M.money(ev({
        "100|10|1|1|1|mn|16|loot", "101|11|1|1|1|mn|500|quest|A quest", "102|12|1|1|1|mn|-800|trainer|Smite",
        "103|13|1|1|1|mn|0|vendor", "104|14|1|1|1|mn|250|", "105|15|1|1|1|qt|1|0|500|A quest",
    }))
    eq(earned.loot, 16); eq(earned.quest, 500, "qt money not added a second time"); eq(earned.other, 250, "missing source")
    eq(spent.trainer, 800); eq(earned.vendor, nil, "zero delta ignored")
    eq(#series, 4); eq(series[4].earned, 766); eq(series[4].spent, 800)
    local r = M.ranked(earned)
    eq(r[1].source, "quest"); eq(r[#r].source, "loot")
end)

test("money: mail gold matching an AH invoice counts as auction (decision table, time boundary)", function()
    -- a burst of 3 sales: the invoice is 8 lines before its "mail" gold, same second (real log, 2026-11-08)
    local _, burst = M.money(ev({
        "500|1|1|1|1|ma|invoice|?|3899|Frilled Lichen", "500|1|1|1|1|ah|sold|3899|Frilled Lichen",
        "500|1|1|1|1|mn|476|auction|Frilled Lichen", "500|1|1|1|1|ah|sold|476|Swiftthistle",
        "500|1|1|1|1|ma|invoice||476|Swiftthistle", "501|1|1|1|1|ma|invoice|?|218|Waylaid Crate",
        "501|1|1|1|1|mn|218|auction|Waylaid Crate", "501|1|1|1|1|ah|sold|218|Waylaid Crate",
        "501|1|1|1|1|mn|3899|mail",
    }))
    eq(burst.auction, 4593); eq(burst.mail, nil)

    local lines = {
        "100|10|1|1|1|ma|invoice||1145|Woolen Bag", -- AH invoice
        "101|11|1|1|1|mn|1145|mail",                -- same amount: an AH sale
        "102|12|1|1|1|ma|take|Verity|2000|Wool Cloth",
        "103|13|1|1|1|mn|2000|mail",                -- a letter with gold: stays mail
        "104|14|1|1|1|mn|530|auction",              -- already auction
        "105|15|1|1|1|ma|invoice||530|Bolt",
        "106|16|1|1|1|mn|-30|mail",                 -- postage paid: spending stays mail
        "200|17|1|1|1|ma|invoice||700|Edge",
        "205|18|1|1|1|mn|700|mail",                 -- exactly INVOICE_SECONDS later: matched
        "205|19|1|1|1|mn|700|mail",                 -- same amount again: invoice already used, stays mail
        "300|20|1|1|1|ma|invoice||900|Late",
        "306|21|1|1|1|mn|900|mail",                 -- INVOICE_SECONDS + 1 later: stays mail
    }
    local _, earned, spent = M.money(ev(lines))
    eq(earned.auction, 1145 + 530 + 700)
    eq(earned.mail, 2000 + 700 + 900)
    eq(spent.mail, 30)
end)

test("money check (state-based): starting gold from the first level snapshot, and where unlogged money changed", function()
    local events = S.parseLog({
        "10|1|1|1|1|mn|100|loot", "20|1|1|1|1|lv|12",          -- had 400 at the start: 500 at level 12
        "30|1|1|1|1|mn|-50|vendor", "40|1|1|1|1|lv|13",        -- 450: every change logged
        "50|1|1|1|1|mn|300|mail", "60|1|1|1|1|lv|14",          -- 600, not 750: 150 the log counted that never came
        "70|1|1|1|1|mn|99|loot",                               -- 699 if nothing else changed
    })
    local snaps = { [12] = { money = 500 }, [13] = { money = 450 }, [14] = { money = 600 } }
    local c = M.moneyCheck(events, snaps, 699)
    eq(c.logged, 449); eq(c.start, 400); eq(c.startLevel, 12)
    eq(c.unrecorded, 699 - 400 - 449, "-150")
    eq(#c.gaps, 1); eq(c.gaps[1].from, 13); eq(c.gaps[1].to, 14); eq(c.gaps[1].copper, -150)
    local after = M.moneyCheck(events, snaps, 899)
    eq(after.gaps[1].from, 14); eq(after.gaps[1].to, nil, "since the last level-up"); eq(after.gaps[1].copper, 200)
    local wobble = M.moneyCheck(events, snaps, 649)
    eq(#wobble.gaps, 1, "50 copper since level 14 is under GAP_MIN"); eq(wobble.gaps[1].copper, -150)
    -- the play the log never saw, matched to the gap it falls in
    local holes = M.unloggedPlay({
        { start = 0, last = 25, played0 = 0, played1 = 25 },
        { start = 45, last = 55, played0 = 25 + 299, played1 = 334 },     -- 299 s: a loading screen
        { start = 58, last = 65, played0 = 334 + 3600, played1 = 3941 },  -- an hour played elsewhere, between 55 and 58
    })
    eq(#holes, 1); eq(holes[1].from, 55); eq(holes[1].to, 58); eq(holes[1].seconds, 3600)
    local matched = M.moneyCheck(events, snaps, 699, holes)
    eq(#matched.gaps[1].unlogged, 1, "levels 13 to 14 (t 40 to 60) hold the hole at 55-58")
    eq(#M.moneyCheck(events, snaps, 699, { { from = 70, to = 80, seconds = 900 } }).gaps[1].unlogged, 0, "after level 14: not that gap's")
    local none = M.moneyCheck(events, nil, 500)
    eq(none.start, nil); eq(none.logged, 449); eq(#none.gaps, 0)
    eq(M.moneyCheck(events, snaps, nil), nil, "no gold figure")
end)

test("zone time: gaps up to ZONE_GAP count, longer gaps and logouts don't (boundaries)", function()
    local z = M.zoneTimes(ev({
        "1000|||||zo|Tirisfal", "1600|||||sz|A", -- 600 s: exactly the limit, counted
        "2201|||||sz|B",                         -- 601 s: offline gap, not counted
        "2300|||||out", "2400|||||in|login",     -- logout: the 100 s gap isn't counted
        "2500|||||zo|Undercity", "2560|||||sz|C",
    }))
    eq(z[1].name, "Tirisfal"); eq(z[1].seconds, 600 + 99 + 100, "600 + 2201->2300 + 2400->2500")
    eq(z[2].name, "Undercity"); eq(z[2].seconds, 60)
end)

test("level times: partial first level, finished levels, current level runs to now", function()
    local _, levels = M.xpSeries(ev({ "1|3600|1|1|1|lv|12", "2|7200|1|1|1|lv|13" }))
    local lt = M.levelTimes(levels, 11, 1800, 9000, 13)
    eq(#lt, 3)
    eq(lt[1].level, 11); eq(lt[1].seconds, 1800); eq(lt[1].partial, true)
    eq(lt[2].level, 12); eq(lt[2].seconds, 3600); eq(lt[2].current, false)
    eq(lt[3].level, 13); eq(lt[3].seconds, 1800); eq(lt[3].current, true)
end)

test("XP series accumulates; sources split into totals and per level", function()
    local series = M.xpSeries(ev({ "1|36|1|1|1|xp|100|kill|Wolf", "2|72|1|1|1|xp|50|quest|Q" }))
    eq(series[2].xp, 150); eq(series[1].h, 0.01)
    local totals, byLevel = M.xpBySource({ all = 999, quest = 10, kill = 5, ["quest:12"] = 7, ["kill:12"] = 2, ["quest:11"] = 3 })
    eq(totals.all, nil, "the 'all' counter isn't a source"); eq(totals.quest, 10)
    eq(byLevel[1].level, 11); eq(byLevel[2].quest, 7); eq(byLevel[2].kill, 2)
end)

test("deaths: killer, killer level, environment cause, zone and level at the time (state)", function()
    local d = M.deaths(ev({
        "1|||||zo|Tirisfal", "2|||||ge|11|0,0|login", "3|||||de|Tarnished Zealot|259433|||world||11|normal|21",
        "4|||||lv|12", "5|||||zo|Silverpine", "6|||||de|?|||falling|world||||0",
    }))
    eq(#d, 2)
    eq(d[1].killer, "Tarnished Zealot"); eq(d[1].killerLevel, 11); eq(d[1].zone, "Tirisfal"); eq(d[1].level, 11)
    eq(d[2].killer, "?"); eq(d[2].env, "falling"); eq(d[2].zone, "Silverpine"); eq(d[2].level, 12)
end)

test("deaths: the damage meter's killing blow replaces the last-target guess", function()
    local d = M.deaths(ev({
        "100|||||de|Razormane Hunter|3265||||world||14|normal|",
        "101|||||fi|12|360|200|0|2|Razormane Mystic|150|Razormane Mystic|Lightning Bolt",
        "200|||||de|Boar|3098||||world||10|normal|",
        "240|||||fi|5|10|20|0|1|Boar|20|Boar|Melee",
        "300|||||de|Kobold|1||||world||5|normal|",
        "301|||||fi|5|10|20|0|1|Kobold|20||",
    }))
    eq(d[1].killer, "Razormane Mystic"); eq(d[1].npc, nil); eq(d[1].spell, "Lightning Bolt"); truthy(d[1].meter)
    eq(d[2].killer, "Boar"); eq(d[2].meter, nil, "a fight line too long after the death isn't joined")
    eq(d[3].killer, "Kobold"); eq(d[3].npc, 1); eq(d[3].meter, nil, "no killer named: the guess stays")
end)

test("damage: totals, DPS, per level, spells and attackers by share", function()
    local dm = M.damage({
        damage = { fights = 3, sec = 40, done = 1200, taken = 300, healed = 60, bestDps = 45, biggest = 700,
            ["fights:20"] = 2, ["sec:20"] = 30, ["done:20"] = 900, ["taken:20"] = 200, ["healed:20"] = 60,
            ["fights:21"] = 1, ["sec:21"] = 10, ["done:21"] = 300, ["taken:21"] = 100 },
        damageBy = { Smite = 900, Melee = 300 }, damageFrom = { Boar = 100, Shaman = 200 },
    })
    eq(dm.fights, 3); eq(dm.dps, 30); eq(dm.bestDps, 45)
    eq(#dm.byLevel, 2); eq(dm.byLevel[1].level, 20); eq(dm.byLevel[1].dps, 30); eq(dm.byLevel[2].healed, 0)
    eq(dm.spells[1].name, "Smite"); eq(dm.spells[1].share, 0.75); eq(dm.from[1].name, "Shaman")
    eq(M.damage({ damage = {} }), nil); eq(M.damage({}), nil)
    local merged = S.mergeJournal({ since = 1, counts = { damage = { bestDps = 40, done = 5 } },
        baseline = { counts = { damage = { bestDps = 50, done = 7 } } } }, nil)
    eq(merged.counts.damage.bestDps, 50, "best DPS is a record, not a sum"); eq(merged.counts.damage.done, 12)
end)

test("professions: only real professions, one point per change, dropped skills kept as 0", function()
    local p = M.professions(ev({
        "1|0|1|1|1|sk|Tailoring|1|75", "2|36|1|1|1|sk|Tailoring|1|75", "3|72|1|1|1|sk|Tailoring|2|75",
        "4|72|1|1|1|sk|Maces|5|65", "5|72|1|1|1|sk|Language: Orcish|300|300", "6|80|1|1|1|sk|Cooking|20|75",
    }))
    eq(#p, 2)
    eq(p[1].name, "Cooking"); eq(p[2].name, "Tailoring")
    eq(#p[2].points, 2, "repeated level not added"); eq(p[2].level, 2)
end)

test("crafted counters parse verb, item and profession; '?' profession becomes nil", function()
    local c = M.crafted({ ["made|Woolen Bag|Tailoring"] = 6, ["made|Crispy Bat Wing|?"] = 1, ["bad"] = 3 })
    eq(#c, 2); eq(c[1].item, "Woolen Bag"); eq(c[1].count, 6); eq(c[2].profession, nil)
end)

test("crafted: Logbook's 'gathered' joins MuddyBoots' picked / mined / skinned row; other professions keep it", function()
    local c = M.crafted({ ["picked|Briarthorn|Herbalism"] = 54, ["gathered|Briarthorn|Herbalism"] = 20,
        ["gathered|Copper Ore|Mining"] = 3, ["gathered|Odd Thing|Archaeology"] = 1 })
    eq(#c, 3); eq(c[1].verb, "picked"); eq(c[1].item, "Briarthorn"); eq(c[1].count, 74)
    eq(c[2].verb, "mined"); eq(c[2].count, 3); eq(c[3].verb, "gathered")
end)

test("inventory: valued at today's AH price, per location; unpriced items counted, not valued", function()
    local market = { prices = { [2592] = { now = 100, days = {} } }, vendor = {} }
    local inv = M.inventory({ bags = { [2592] = 3, [999] = 2 }, bank = { [2592] = 7 }, mail = {} }, market,
        function(id) return "I" .. id end)
    eq(inv.total, 1000); eq(inv.byLocation.bags, 300); eq(inv.byLocation.bank, 700)
    eq(inv.unpriced, 1); eq(inv.kinds, 2)
    eq(inv.items[1].name, "I2592"); eq(inv.items[1].count, 10); eq(inv.items[2].unit, nil)
    eq(M.inventory(nil, market, tostring).total, 0, "no Stockpile data")
end)

test("valuation: held items at market value, reagents at now", function()
    local Build = require("build")
    local P = Build.planner(wowDir())
    truthy(P, "planner found")
    local recipes = { [1] = { recipeID = 1, name = "Thing", outputItemID = 50, outputQty = 1, reagents = { { itemID = 1, qty = 2 } } } }
    local function mk(withMarket)
        return { prices = { [1] = { now = 100, market = withMarket and 80 or nil }, [50] = { now = 1000, market = withMarket and 900 or nil } }, vendor = {} }
    end
    local held = { bags = { [1] = 3 }, bank = {}, mail = {} }
    eq(M.inventory(held, mk(true), tostring).items[1].unit, 80, "held: market first")
    eq(M.inventory(held, mk(false), tostring).items[1].unit, 100, "no market: now")
    eq(M.crafts(P, recipes, mk(true), tostring, 10)[1].cost, 200, "reagents cost now (100 each)")
    eq(M.crafts(P, recipes, mk(true), tostring, 10)[1].gross, 900, "product valued at market")
    eq(M.crafts(P, recipes, mk(false), tostring, 10)[1].cost, 200)
    eq(M.crafts(P, recipes, mk(false), tostring, 10)[1].gross, 1000)
end)

test("worth log: m flag written, parsed, and old lines still read", function()
    eq(I.worthLogLines({ { id = "a", gold = 1, items = 2, m = true } }, {}, 5), "5\ta\t1\t2\tm\n")
    local seen = I.parseWorthLog("5\ta\t1\t2\tm\n")
    eq(seen.a[1].m, true)
    seen = I.parseWorthLog("4\ta\t1\t2\n")
    eq(seen.a[1].m, nil); eq(#seen.a, 1)
end)

test("worth log: switching to market value alone writes a line", function()
    local last = { a = { 4, 1, 2 } }
    eq(I.worthLogLines({ { id = "a", gold = 1, items = 2, m = true } }, last, 9), "9\ta\t1\t2\tm\n")
    eq(I.worthLogLines({ { id = "a", gold = 1, items = 2 } }, last, 9), "", "unchanged without m")
    eq(I.worthLogLines({ { id = "a", gold = 1, items = 2, m = true } }, { a = { 4, 1, 2, m = true } }, 9), "", "unchanged with m")
end)

test("crafts use Make or Buy's real planner: crafting bolts beats buying them, and includes reagent tree", function()
    local Build = require("build")
    local P = Build.planner(wowDir())
    truthy(P, "MakeOrBuy/Planner.lua found in the WoW folder (ledger.cfg: wow = ...)")
    local recipes = {
        [2964] = { recipeID = 2964, name = "Bolt of Woolen Cloth", outputItemID = 2997, outputQty = 1, reagents = { { itemID = 2592, qty = 3 } } },
        [3757] = { recipeID = 3757, name = "Woolen Bag", outputItemID = 4241, outputQty = 1,
            reagents = { { itemID = 2997, qty = 3 }, { itemID = 2321, qty = 1 } } },
    }
    local market = { prices = { [2592] = { now = 51 }, [2997] = { now = 600 }, [4241] = { now = 900 } }, vendor = { [2321] = 100 } }
    local list = M.crafts(P, recipes, market, tostring, 10)
    local bag
    for _, r in ipairs(list) do if r.name == "Woolen Bag" then bag = r end end
    eq(bag.cost, 559); eq(bag.naiveCost, 1900); eq(bag.gross, 900); eq(bag.sale, math.floor(900 * 0.95))
    eq(bag.profit, math.floor(900 * 0.95 - 559)); near(bag.margin, bag.profit / 559); eq(bag.ownReagents, true)
    eq(#bag.reagents, 3, "bolts -> wool cloth + fine thread")
    eq(bag.reagents[1].id, 2997); eq(bag.reagents[1].method, "craft"); eq(bag.reagents[1].qty, 3); eq(bag.reagents[1].buyTotal, 1800)
    eq(bag.reagents[2].id, 2592); eq(bag.reagents[2].depth, 1); eq(bag.reagents[2].qty, 9); eq(bag.reagents[2].unit, 51); eq(bag.reagents[2].total, 459)
    eq(bag.reagents[3].id, 2321); eq(bag.reagents[3].source, "vendor"); eq(bag.reagents[3].unit, 100)
    eq(#M.crafts(nil, recipes, market, tostring), 0, "no planner: no crafts")
    eq(bag.pay, nil, "nothing held given: no pay figure")
    -- holding 1 bolt and 4 wool cloth: 2 bolts to craft = 6 cloth, 4 held, 2 bought; thread from the vendor
    local held = { [2997] = 1, [2592] = 4 }
    local mine
    for _, r in ipairs(M.crafts(P, recipes, market, tostring, nil, { have = held })) do if r.name == "Woolen Bag" then mine = r end end
    eq(mine.owned, 5); eq(mine.pay, 2 * 51 + 100); eq(mine.cost, 559, "cost stays the market cost")
    eq(#mine.used, 2); eq(mine.used[1].id, 2997); eq(mine.used[1].count, 1); eq(mine.used[2].id, 2592); eq(mine.used[2].count, 4)
    eq(held[2592], 4, "the caller's holdings aren't used up")
end)

test("sale check with Make or Buy's real Market: listed, days listed, spike / thin / stale against its usual price", function()
    local Market = require("build").makeOrBuy(wowDir()).Market
    truthy(Market, "MakeOrBuy/Market.lua found in the WoW folder")
    local days = function(lows, lastAvail)
        local out = {}
        for i, low in ipairs(lows) do out[i] = { day = 100 + i, low = low, high = low, available = i == #lows and lastAvail or 20 } end
        return out
    end
    local market = { prices = {
        [1] = { now = 100, days = days({ 100, 100, 100, 100 }, 15) },       -- steady, well listed
        [2] = { now = 300, days = days({ 100, 100, 100, 300 }, 1) },        -- 3x the usual and 1 listed
        [3] = { now = 100, days = days({ 100, 100, 100, 100 }, 15) },       -- the same, but checked 4 days later
    } }
    local ok = M.saleCheck(market, 1, Market, 104)
    eq(ok.listed, 15); eq(ok.days, 4); eq(ok.usual, 100); eq(ok.age, 0); eq(ok.risky, false)
    local hot = M.saleCheck(market, 2, Market, 104)
    eq(hot.spike, true); eq(hot.thin, true); eq(hot.risky, true); near(hot.ratio, 3)
    local old = M.saleCheck(market, 3, Market, 107)
    eq(old.age, 3); eq(old.stale, true); eq(old.risky, true)
    eq(M.saleCheck(market, 99, Market, 104), nil, "never on the AH")
    eq(M.saleCheck(market, 1, nil, nil).listed, 15, "without Make or Buy: just the book's figures")
end)

test("skill routes with Make or Buy's real Skill: cheapest recipe per stretch, a recipe joins once it's learnable", function()
    local real = require("build").makeOrBuy(wowDir())
    truthy(real.Skill, "MakeOrBuy/Skill.lua found in the WoW folder")
    -- recipe 1 (learn 40) is orange until 65; recipe 2 (learn 60) is cheaper but needs skill 60
    local lib = { Planner = real.Planner, Skill = real.Skill, RecipeData = { [197] = { [1] = { 40 }, [2] = { 60 } } } }
    local mob = {
        skill = { [197] = { level = 50, max = 75 }, [185] = { level = 75, max = 75 } },
        recipes = {
            [1] = { recipeID = 1, name = "Pricey", profession = 197, outputItemID = 20, outputQty = 1, reagents = { { itemID = 10, qty = 1 } } },
            [2] = { recipeID = 2, name = "Cheap", profession = 197, outputItemID = 21, outputQty = 1, reagents = { { itemID = 11, qty = 1 } } },
            [3] = { recipeID = 3, name = "Stew", profession = 185, outputItemID = 22, outputQty = 1, reagents = { { itemID = 11, qty = 1 } } },
        },
    }
    local market = { prices = { [10] = { now = 100 }, [11] = { now = 50 } }, vendor = {} }
    local routes = M.skillRoutes(lib, mob, market, tostring)
    eq(#routes, 1, "cooking is capped: no route"); local r = routes[1]
    eq(r.profession, "Tailoring"); eq(r.level, 50); eq(r.max, 75)
    eq(#r.segments, 2)
    eq(r.segments[1].name, "Pricey"); eq(r.segments[1].from, 50); eq(r.segments[1].to, 60); eq(r.segments[1].crafts, 10); eq(r.segments[1].cost, 1000)
    eq(r.segments[2].name, "Cheap"); eq(r.segments[2].from, 60); eq(r.segments[2].to, 75); eq(r.segments[2].crafts, 15)
    eq(r.crafts, 25); eq(r.cost, 1000 + 750); eq(r.net, 1750, "nothing sells: net = cost")
    eq(#r.next, 1, "only the learnable recipe gives a point at 50"); eq(r.next[1].name, "Pricey"); eq(r.next[1].chance, 1)
    eq(#M.skillRoutes(nil, mob, market, tostring), 0, "without Make or Buy: nothing")
    -- "orange at 99" can't be right with a cap of 75: ignored, so recipe 1 goes yellow at 65 as its learn skill says
    mob.bounds = { [1] = { y = { 100, real.Skill.UNBOUNDED } } }
    local fixed = M.skillRoutes(lib, mob, market, tostring)[1]
    eq(fixed.segments[1].crafts, 10, "still orange from 50 to 60")
    mob.bounds[1] = { y = { 0, 55 } } -- seen yellow at 55: real, so it costs more crafts per point
    truthy(M.skillRoutes(lib, mob, market, tostring)[1].segments[1].crafts > 10)
end)

test("held: bags, bank and mail together, string ids made numbers, zero counts dropped", function()
    local h = M.held({ bags = { [1] = 2, ["7"] = 1 }, bank = { [1] = 3 }, mail = { [9] = 0 } })
    eq(h[1], 5); eq(h[7], 1); eq(h[9], nil); eq(next(M.held(nil)), nil)
end)

test("ahTrades: buyouts paired with money & mail invoices, batch deposits, burst sales merged, per-item ledger", function()
    local events = S.parseLog({
        -- Buy 5x Cerulean Dye (commodity buyout has empty copper on ah|buyout, copper on mn, seller on later ma|invoice)
        "100|0|1|0|0|mn|-24985|auction|Cerulean Dye x5",
        "100|0|1|0|0|ah|buyout||Cerulean Dye x5",
        "120|0|1|0|0|ma|invoice|Allchimist||Cerulean Dye",
        -- Batch post 2x Woolen Reagent Bag (first has ah|post + named mn, second has unnamed mn)
        "200|0|1|0|0|ah|post|250|Woolen Reagent Bag",
        "200|0|1|0|0|mn|-250|auction|Woolen Reagent Bag",
        "201|0|1|0|0|mn|-250|auction",
        -- Looting 2x sold Woolen Reagent Bag interleaved with another sale within 30s
        "300|0|1|0|0|ah|sold|6900|Woolen Reagent Bag",
        "300|0|1|0|0|ma|invoice|BuyerOne|6900|Woolen Reagent Bag",
        "300|0|1|0|0|mn|6900|auction|Woolen Reagent Bag",
        "302|0|1|0|0|ah|sold|500|Linen Cloth",
        "302|0|1|0|0|ma|invoice|OtherBuyer|500|Linen Cloth",
        "302|0|1|0|0|mn|500|auction|Linen Cloth",
        "305|0|1|0|0|ah|sold|6900|Woolen Reagent Bag",
        "305|0|1|0|0|ma|invoice|BuyerTwo|6900|Woolen Reagent Bag",
        "305|0|1|0|0|mn|6900|auction|Woolen Reagent Bag",
        -- Expired auction
        "400|0|1|0|0|ah|expired||Linen Cloth",
    })
    local idMap = { ["Cerulean Dye"] = 249409, ["Woolen Reagent Bag"] = 253667 }
    local ah = M.ahTrades(events, function(n) return idMap[n] end)
    eq(ah.totals.bought, 24985); eq(ah.totals.deposits, 500); eq(ah.totals.sold, 14300)
    eq(ah.totals.net, 14300 - 24985 - 500)
    eq(ah.totals.boughtCount, 5); eq(ah.totals.soldCount, 3)
    -- Trades are newest first: expired (400), 2x Woolen Reagent Bag sold merged (300/305, updated t=305), Linen sold (302), 2x post merged (200/201), 5x buyout (100)
    eq(#ah.trades, 5)
    local bagSale, dyeBuy, bagPost
    for _, tr in ipairs(ah.trades) do
        if tr.act == "sold" and tr.name == "Woolen Reagent Bag" then bagSale = tr end
        if tr.act == "buyout" and tr.name == "Cerulean Dye" then dyeBuy = tr end
        if tr.act == "post" and tr.name == "Woolen Reagent Bag" then bagPost = tr end
    end
    eq(bagSale.count, 2); eq(bagSale.copper, 13800); eq(bagSale.unit, 6900); eq(bagSale.id, 253667)
    eq(bagSale.who[1], "BuyerOne"); eq(bagSale.who[2], "BuyerTwo")
    eq(dyeBuy.count, 5); eq(dyeBuy.copper, 24985); eq(dyeBuy.unit, 4997); eq(dyeBuy.who[1], "Allchimist")
    eq(bagPost.count, 2); eq(bagPost.copper, 500)
    local byName = {}
    for _, it in ipairs(ah.items) do byName[it.name] = it end
    eq(byName["Woolen Reagent Bag"].soldCount, 2); eq(byName["Woolen Reagent Bag"].avgSell, 6900)
    eq(byName["Woolen Reagent Bag"].deposits, 500); eq(byName["Woolen Reagent Bag"].net, 13800 - 500)
    eq(byName["Cerulean Dye"].boughtCount, 5); eq(byName["Cerulean Dye"].avgBuy, 4997)
end)

----------------------------------------------------------------------------------------------------
-- Account view (every character together)

local function acctFixture()
    local market = { prices = { [2589] = { now = 10, days = {} }, [2592] = { now = 100, days = {} } }, vendor = {} }
    return { {
        market = market,
        -- Equivalence classes: in both addons (Main), MuddyBoots only (Fresh), Stockpile only (Mule)
        muddyChars = {
            G1 = { name = "Main", realm = "R", level = 20, class = "PRIEST", played = 3600, money = 1000, lastSeen = 9 },
            G2 = { name = "Fresh", realm = "R", level = 1, class = "MAGE", played = 60, money = 0, lastSeen = 5 },
        },
        stockChars = {
            ["Main-R"] = { name = "Main", realm = "R", bags = { [2589] = 10 }, bank = { [2592] = 2 }, mail = {} },
            ["Mule-R"] = { name = "Mule", realm = "R", class = "WARRIOR", bags = { [2589] = 30, [999] = 1 }, bank = {}, mail = {} },
        },
    } }
end

test("account: characters from MuddyBoots, Stockpile or both appear once each, with totals", function()
    local a = M.account(acctFixture(), function(id) return "I" .. id end)
    eq(#a.characters, 3)
    local by = {}
    for _, r in ipairs(a.characters) do by[r.name] = r end
    eq(by.Main.items, 300, "10 x 10c + 2 x 100c"); eq(by.Main.netWorth, 1300); eq(by.Main.byLocation.bank, 200)
    eq(by.Fresh.items, 0); eq(by.Fresh.netWorth, 0); eq(by.Fresh.level, 1)
    eq(by.Mule.money, nil, "gold unknown without MuddyBoots"); eq(by.Mule.items, 300); eq(by.Mule.class, "WARRIOR")
    eq(by.Mule.unpriced, 1)
    eq(a.totals.characters, 3); eq(a.totals.money, 1000); eq(a.totals.items, 600); eq(a.totals.netWorth, 1600)
    eq(a.totals.played, 3660); eq(a.totals.maxLevel, 20)
    eq(a.characters[1].name, "Main", "richest first"); eq(a.characters[3].name, "Fresh")
end)

test("account: combined inventory sums every holder, biggest holder first; unpriced items counted", function()
    local a = M.account(acctFixture(), function(id) return "I" .. id end)
    local inv = a.inventory
    eq(inv.kinds, 3); eq(inv.unpriced, 1)
    local wool = inv.items[1]
    eq(wool.id, 2589); eq(wool.count, 40); eq(wool.value, 400)
    eq(wool.holders[1].name, "Mule"); eq(wool.holders[1].count, 30); eq(wool.holders[2].name, "Main")
    eq(inv.items[3].id, 999, "unpriced last"); eq(inv.items[3].value, 0)
    eq(#M.account(acctFixture(), tostring, 1).inventory.items, 1, "limit")
end)

test("account: same name on two realms stays two characters; name case doesn't split one", function()
    local groups = { { market = { prices = {}, vendor = {} },
        muddyChars = { A = { name = "Twin", realm = "R1", money = 1 }, B = { name = "Twin", realm = "R2", money = 2 } },
        stockChars = { x = { name = "twin", realm = "R1", bags = {}, bank = {}, mail = {} } } } }
    local a = M.account(groups, tostring)
    eq(#a.characters, 2)
    eq(M.charId("Twin", "R1"), M.charId("twin", "R1"))
end)

test("full names (decision table): surname from the WTF folder; unknown or ambiguous first names stay first-name only", function()
    local s = M.surnames({ { name = "Azhariel", surname = "Deadheart" }, { name = "Twin", surname = "Oak" },
        { name = "Twin", surname = "Ash" }, { name = "Dup", surname = "Same" }, { name = "Dup", surname = "Same" } })
    eq(M.fullName("Azhariel", s), "Azhariel Deadheart")
    eq(M.fullName("azhariel", s), "azhariel Deadheart", "any case")
    eq(M.fullName("Twin", s), "Twin", "two surnames for one first name: ambiguous")
    eq(M.fullName("Dup", s), "Dup Same", "the same folder twice isn't ambiguous")
    eq(M.fullName("Nofolder", s), "Nofolder")
    eq(M.fullName(nil, s), nil)
end)

test("ruleset from the internal server name; any other name is kept as is", function()
    eq(M.ruleset("CAMWOW US2 Realm 2 PvP"), "PvP")
    eq(M.ruleset("CAMWOW US1 Realm 10 PvE"), "PvE")
    eq(M.ruleset("Hardcore"), "Hardcore")
    eq(M.ruleset(nil), nil)
end)

test("account: no addon data at all gives an empty, zeroed summary", function()
    local a = M.account({}, tostring)
    eq(#a.characters, 0); eq(a.totals.netWorth, 0); eq(a.totals.maxLevel, nil); eq(a.inventory.kinds, 0)
end)

----------------------------------------------------------------------------------------------------
-- Insights: market

local function priced(now, lows) -- an Auctionator item: lows per scan day, oldest first (last = today)
    local days = {}
    for i, low in ipairs(lows) do days[i] = { day = 100 + i, low = low, high = low, available = 5 } end
    return { now = now, days = days }
end
local idName = function(id) return "I" .. id end

test("median: odd, even and empty lists", function()
    eq(I.median({ 5, 1, 3 }), 3); eq(I.median({ 4, 1, 3, 2 }), 2.5); eq(I.median({}), nil)
end)

test("usual price ignores the latest scan day and counts earlier days", function()
    local usual, n = I.usualPrice(priced(10, { 100, 300, 200, 10 }))
    eq(usual, 200); eq(n, 3)
    local u1, n1 = I.usualPrice(priced(10, { 10 }))
    eq(u1, nil); eq(n1, 0)
end)

test("market buy signal (boundary values): 70% of usual buys, 71% doesn't; a tiny gain is noise", function()
    local market = { vendor = {}, prices = {
        [1] = priced(700, { 1000, 1000, 700 }),  -- exactly 70%: buy
        [2] = priced(710, { 1000, 1000, 710 }),  -- 71%: no
        [3] = priced(70, { 100, 100, 70 }),      -- 70% but saves only 30c: under minGain
        [4] = priced(100, { 1000, 100 }),        -- only one earlier day: not enough history
    } }
    local m = I.market(market, nil, idName)
    eq(#m.buy, 1); eq(m.buy[1].id, 1); near(m.buy[1].pct, 0.3); eq(m.buy[1].available, 5)
    eq(m.ready, true); eq(m.scanDays, 3)
end)

test("market sell signal: only items you own, at 125% of usual or more, largest extra first", function()
    local market = { vendor = {}, prices = {
        [1] = priced(1250, { 1000, 1000, 1250 }), -- 125%: sell
        [2] = priced(1240, { 1000, 1000, 1240 }), -- 124%: no
        [3] = priced(2000, { 1000, 1000, 2000 }), -- 200% but not owned
        [4] = priced(3000, { 1000, 1000, 3000 }), -- 300%, owned
    } }
    local owned = { [1] = { count = 10, holders = { "A 10" } }, [2] = { count = 1, holders = {} }, [4] = { count = 1, holders = { "B 1" } } }
    local m = I.market(market, owned, idName)
    eq(#m.sell, 2); eq(m.sell[1].id, 1, "10 x 250 extra beats 1 x 2000"); eq(m.sell[1].extra, 2500); eq(m.sell[2].id, 4)
    eq(#m.buy, 0)
    eq(#m.sell[2].where, 0, "no per-character counts: an empty list")
end)

test("market sell signal: where each character holds it, the biggest holder first", function()
    local market = { vendor = {}, prices = { [1] = priced(1250, { 1000, 1000, 1250 }) } }
    local owned = { [1] = { count = 12, holders = { "Alt 2", "Main 10" }, where = {
        { name = "Alt", bags = 0, bank = 0, mail = 2 }, { name = "Main", bags = 4, bank = 6, mail = 0 } } } }
    local w = I.market(market, owned, idName).sell[1].where
    eq(w[1].name, "Main"); eq(w[1].bags, 4); eq(w[1].bank, 6); eq(w[2].name, "Alt"); eq(w[2].mail, 2)
    eq(owned[1].where[1].name, "Alt", "the caller's list isn't reordered")
end)

test("market with two scan days isn't ready and suggests nothing", function()
    local m = I.market({ vendor = {}, prices = { [1] = priced(1, { 1000, 1 }) } }, nil, idName)
    eq(m.ready, false); eq(m.scanDays, 2); eq(#m.buy, 0)
end)

----------------------------------------------------------------------------------------------------
-- Insights: session recaps

test("play sessions: pieces 30 minutes apart join, 30 minutes and 1 second split (boundary values)", function()
    local s = I.playSessions({
        { start = 5801, last = 6000, played0 = 100, played1 = 1100 },     -- given out of order on purpose; 1801 after 4000: splits
        { start = 1000, last = 2000, played0 = 0, played1 = 1000 },
        { start = 3800, last = 4000, played0 = 1000, played1 = 1100 },     -- 1800 after 2000: joins
        { start = 6000 + 1801, last = 9000, played0 = 1100, played1 = 2300 }, -- 1801 after 6000: splits
    })
    eq(#s, 3)
    eq(s[1].start, 1000); eq(s[1].finish, 4000); eq(s[1].played, 1100); eq(s[1].pieces, 2)
    eq(s[2].start, 5801); eq(s[3].played, 1200)
end)

test("play pace: played hours per day over the last 14 days; a younger character over its own age (boundaries)", function()
    local D, now = 86400, 100 * 86400
    local pieces = {
        { start = now - 15 * D, played0 = 0, played1 = 99999 },          -- before the window
        { start = now - 14 * D, played0 = 0, played1 = 3600 * 7 },      -- exactly at its start: counts
        { start = now - 1 * D, played0 = 100, played1 = 100 + 3600 * 7 },
    }
    local p = I.playPace(pieces, now)
    eq(p.days, 14); near(p.hoursPerDay, 1); eq(p.played, 3600 * 14)
    local young = I.playPace({ { start = now - 2 * D, played0 = 0, played1 = 3600 * 6 } }, now)
    eq(young.days, 2); near(young.hoursPerDay, 3)
    local fresh = I.playPace({ { start = now - 600, played0 = 0, played1 = 3600 } }, now)
    eq(fresh.days, 1, "under a day counts as one"); near(fresh.hoursPerDay, 1)
    eq(I.playPace({ { start = now - 20 * D, played0 = 0, played1 = 50 } }, now), nil, "no play lately")
    eq(I.playPace(nil, now), nil)
end)

test("gold per hour by activity (decision table): each Haul session labelled by what Logbook saw in it", function()
    local haul = { history = {
        { start = 1000, duration = 3600, loot = 100, quest = 0, items = 900, xp = 50 },     -- gathering
        { start = 10000, duration = 1800, loot = 20, quest = 500, items = 80, xp = 3000 },  -- questing
        { start = 20000, duration = 3600, loot = 400, quest = 0, items = 1600, xp = 9000 }, -- grinding
        { start = 30000, duration = 599, loot = 999, quest = 0, items = 0, xp = 0 },        -- under 10 minutes
        { start = 40000, duration = 900, loot = 0, quest = 0, items = 0, xp = 0 },          -- other
    }, current = { session = { start = 50000, elapsed = 1800, money = { loot = 50, quest = 0 }, itemValue = 950, xp = 10 } } }
    local lines = {}
    for i = 1, 6 do lines[#lines + 1] = (1000 + i * 10) .. "|1|1|1|1|ga|Herbalism|765|Silverleaf|1" end
    lines[#lines + 1] = "1100|1|1|1|1|ki|Boar|1|Beast|normal|20|5"
    lines[#lines + 1] = "4700|1|1|1|1|ga|Herbalism|765|Silverleaf|1" -- after the first session's span: not counted
    lines[#lines + 1] = "10100|1|1|1|1|ki|Wolf|2|Beast|normal|40|8"; lines[#lines + 1] = "10101|1|1|1|1|xp|40|kill|Wolf"
    lines[#lines + 1] = "10200|1|1|1|1|qt|5|300|500|Stew"; lines[#lines + 1] = "10201|1|1|1|1|xp|300|quest|Stew"
    lines[#lines + 1] = "20100|1|1|1|1|ki|Wolf|2|Beast|normal|40|8"; lines[#lines + 1] = "20101|1|1|1|1|xp|40|kill|Wolf"
    lines[#lines + 1] = "20200|1|1|1|1|qt|5|30|0|Talk"; lines[#lines + 1] = "20201|1|1|1|1|xp|30|quest|Talk"
    for i = 1, 5 do lines[#lines + 1] = (50000 + i) .. "|1|1|1|1|ga|Mining|2770|Copper Ore|2" end
    local r = I.activityRates(haul, S.parseLog(lines))
    eq(r.sessions, 5, "the 599-second session is left out")
    eq(#r.rows, 4); eq(r.rows[1].activity, "gathering"); eq(r.rows[2].activity, "questing")
    eq(r.rows[3].activity, "grinding"); eq(r.rows[4].activity, "other")
    eq(r.rows[1].sessions, 2, "the first session and the one in progress"); eq(r.rows[1].seconds, 5400)
    eq(r.rows[1].value, 100 + 900 + 50 + 950); eq(r.rows[1].perHour, math.floor(2000 * 3600 / 5400))
    eq(r.rows[2].value, 600); eq(r.rows[2].perHour, 1200); eq(r.rows[2].xpPerHour, 6000)
    eq(r.rows[3].perHour, 2000, "grinding: 2000 in an hour")
    eq(I.activityRates(nil, {}), nil); eq(I.activityRates({ history = {} }, {}), nil)
end)

test("play spans: start to last event per piece, oldest first; pieces without an end left out", function()
    local s = I.playSpans({ { start = 50, last = 80 }, { start = 10, last = 20 }, { start = 90 }, { start = 95, last = 95 } })
    eq(table.concat(s, ","), "10,20,50,80")
end)

test("recap (state-based): zone carried in from before, loot by source, skills from the earlier rank, newest first", function()
    local ev = S.parseLog({
        "10|0|1|0|0|zo|Tirisfal Glades",
        "20|0|1|0|0|sk|Tailoring|50|75",
        "30|0|1|0|0|sk|Swords|10|75",
        -- session 1: 100..200
        "110|0|1|0|0|xp|300|kill|Wolf",
        "120|0|1|0|0|ki|Wolf|1|Beast|normal|30|5",
        "121|0|1|0|0|ki|Wolf|1|Beast|normal|30|5",
        "122|0|1|0|0|ki|Bat|2|Beast|normal|30|5",
        "130|0|1|0|0|mn|500|loot",
        "131|0|1|0|0|mn|-200|vendor",
        "140|0|1|0|0|lo|10|2|1|loot|Green Sword|1",
        "141|0|1|0|0|lo|11|2|2|made|Woolen Bag|0",
        "142|0|1|0|0|lo|12|2|1|mail|Mailed Thing|0",
        "150|0|1|0|0|sk|Tailoring|52|75",
        "151|0|1|0|0|sk|Swords|11|75",
        "160|0|1|0|0|zo|Silverpine Forest",
        "170|0|1|0|0|qt|5|400|100|Rats",
        "180|0|1|0|0|lv|10",
        "185|0|1|0|0|mn|-200|auction|Fine Thread x2",
        "185|0|1|0|0|ah|buyout|200|Fine Thread x2",
        "190|0|1|0|0|ah|sold|950|Woolen Bag",
        "190|0|1|0|0|mn|950|auction|Woolen Bag",
        -- between sessions
        "300|0|1|0|0|zo|Undercity",
        -- session 2: 5000..6000
        "5100|0|1|0|0|de|Gnoll|3||||5|WARRIOR|10|0|",
    })
    local market = { prices = { [10] = { now = 1000 } }, vendor = {} }
    local r = I.recaps({ { start = 100, last = 200, played0 = 0, played1 = 100 }, { start = 5000, last = 6000, played0 = 100, played1 = 1100 } },
        ev, market, idName, nil, { Tailoring = true }, function(n) return n == "Woolen Bag" and 4241 or nil end)
    eq(#r, 2)
    local new, old = r[1], r[2]
    eq(new.start, 5000); eq(new.zones[1], "Undercity", "zone from between sessions"); eq(new.deaths[1], "Gnoll"); eq(new.xp, 0)
    eq(old.zones[1], "Tirisfal Glades"); eq(old.zones[2], "Silverpine Forest")
    eq(old.xp, 300); eq(old.levels[1], 10); eq(old.earned, 1450); eq(old.spent, 400)
    eq(old.kills, 3); eq(old.topMob.name, "Wolf"); eq(old.topMob.n, 2); eq(old.quests[1], "Rats")
    eq(#old.loot, 1); eq(old.loot[1].name, "Green Sword"); eq(old.loot[1].value, 1000)
    eq(#old.made, 1); eq(old.made[1].count, 2)
    eq(#old.ahSold, 1); eq(old.ahSold[1].name, "Woolen Bag"); eq(old.ahSold[1].copper, 950); eq(old.ahSold[1].id, 4241)
    eq(#old.ahBought, 1); eq(old.ahBought[1].name, "Fine Thread"); eq(old.ahBought[1].count, 2); eq(old.ahBought[1].copper, 200)
    eq(#old.skills, 1, "weapon skills left out"); eq(old.skills[1].from, 50); eq(old.skills[1].to, 52)
    eq(#I.recaps({ { start = 100, last = 200 }, { start = 5000, last = 6000 } }, ev, market, idName, 1), 1, "limit")
end)

----------------------------------------------------------------------------------------------------
-- Insights: mail to your alts

test("uses: reagents of known recipes; needs: the restock shopping list", function()
    local uses, needs = I.uses({ [1] = { reagents = { { itemID = 2589, qty = 2 } } } }, { { itemID = 2592, qty = 5 }, { itemID = 2592, qty = 1 } })
    eq(uses[2589], true); eq(uses[2592], true); eq(needs[2592], 6); eq(needs[2589], nil)
end)

test("transfers (decision table): who holds, who uses, own use, faction, restock first", function()
    local market = { prices = { [1] = { now = 10 }, [2] = { now = 1000 }, [3] = { now = 5 } }, vendor = {} }
    local chars = {
        { name = "Mule", faction = "Horde", holds = { [1] = { bags = 30, bank = 0, mail = 0 }, [2] = { bags = 0, bank = 4, mail = 0 },
            [3] = { bags = 9, bank = 0, mail = 0 } } },
        { name = "Tailor", faction = "Horde", uses = { [1] = true, [2] = true }, needs = { [1] = 20 },
            holds = { [2] = { bags = 1, bank = 0, mail = 0 } } },
        { name = "Ally", faction = "Alliance", uses = { [3] = true } },
    }
    local t = I.transfers(chars, idName, market)
    eq(#t, 2, "item 3: other faction; Tailor's own item 2 stays with Tailor")
    eq(t[1].id, 1); eq(t[1].reason, "restock"); eq(t[1].count, 20, "capped at the need"); eq(t[1].need, 20); eq(t[1].to, "Tailor")
    eq(t[2].id, 2); eq(t[2].reason, "crafting"); eq(t[2].count, 4); eq(t[2].bank, 4); eq(t[2].from, "Mule")
    eq(#I.transfers({ chars[1] }, idName, market), 0, "nobody to send to")
end)

test("drops: DropLab's real Stats; ranked mobs by value first, then the rest by kills; no data gives nil", function()
    local Build = require("build")
    local Stats = Build.dropStats(wowDir())
    truthy(Stats, "DropLab/Stats.lua found in the WoW folder (ledger.cfg: wow = ...)")
    local db = { mobs = {
        [1] = { name = "Cheap", kills = 10, looted = 10, money = 100, items = { [2592] = { drops = 5, qty = 5 } } },
        [2] = { name = "Rich", kills = 5, looted = 5, money = 0, items = { [2592] = { drops = 5, qty = 10 } },
            paceN = 5, paceSum = 200 },
        [3] = { name = "Few", kills = 4, looted = 4, money = 99999, items = {} },
        [4] = { kills = 0, looted = 2, money = 0, items = {} },
        [5] = { name = "Never", kills = 0, looted = 0, money = 0, items = {} },
    } }
    local d = I.drops(db, Stats, function(id) return "I" .. id end, function(id) return id == 2592 and 100 or nil end, 25)
    eq(d.tracked, 4, "a mob with no kills isn't tracked"); eq(d.kills, 21); eq(d.minKills, 5)
    eq(d.mobs[1].name, "Rich"); near(d.mobs[1].value, 200); near(d.mobs[1].perHour, 200 * 90)
    eq(d.mobs[2].name, "Cheap"); near(d.mobs[2].value, (100 + 500) / 10); eq(d.mobs[2].perHour, nil)
    eq(d.mobs[3].name, "Few"); eq(d.mobs[3].ranked, false, "boundary: 4 kills")
    eq(d.mobs[4].name, "NPC #4"); eq(d.mobs[4].basis, "looted")
    eq(d.mobs[2].drops[1].id, 2592); eq(d.mobs[2].drops[1].name, "I2592"); near(d.mobs[2].drops[1].rate, 0.5)
    truthy(d.mobs[2].drops[1].lo < 0.5 and d.mobs[2].drops[1].hi > 0.5)
    eq(#I.drops(db, Stats, tostring, nil, 2).mobs, 2, "limit")
    eq(I.drops(nil, Stats, tostring, nil), nil)
end)

----------------------------------------------------------------------------------------------------
-- End to end

test("end to end: fixture SavedVariables -> one character with every section, embedded in the page", function()
    local Build = require("build")
    local dir = os.tmpname():gsub("[^/\\]+$", "") .. "dash_fixture_" .. os.time()
    local wow = dir
    local windows = package.config:sub(1, 1) == "\\"
    local function mkdir(p)
        if windows then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') else os.execute('mkdir -p "' .. p .. '"') end
    end
    local acct = wow .. "/WTF/Account/ACC"
    local charSV = acct .. "/91/Hero-Realm/SavedVariables"
    mkdir(charSV); mkdir(acct .. "/SavedVariables")
    U.writeFile(acct .. "/SavedVariables/Stockpile.lua", 'StockpileDB = { version = 1, chars = { ["Hero-R"] = { name = "Hero", realm = "R", bags = { [2592] = 4 }, bank = {}, mail = {} }, ["Alt-R"] = { name = "Alt", realm = "R", bags = { [2592] = 1 }, bank = {}, mail = {} } } }')
    U.writeFile(acct .. "/SavedVariables/MuddyBoots.lua", 'MuddyBootsDB = { chars = { G1 = { name = "Hero", realm = "R", faction = "Horde", level = 12, money = 5000, lastSeen = 50 }, G2 = { name = "Alt", realm = "R", faction = "Horde", level = 3, money = 7, lastSeen = 40 } } }')
    U.writeFile(acct .. "/SavedVariables/Auctionator.lua", 'AUCTIONATOR_PRICE_DATABASE = { __dbversion = 8, R = { ["2592"] = { m = 100, h = { ["2500"] = 120, ["2501"] = 100 } } } }')
    U.writeFile(charSV .. "/MuddyBoots.lua", [[MuddyBootsCharDB = { char = { name = "Hero", realm = "R", guid = "G1", level = 12, class = "PRIEST",
        first = { level = 11 } }, sessions = { { start = 5, played0 = 3500, played1 = 7200, last = 50 } },
        counts = { xp = { all = 300, kill = 100, quest = 200 } },
        log = { "10|3600|1|1|1|zo|Elwynn", "20|3610|1|1|1|xp|100|kill|Wolf", "30|3620|1|1|1|mn|50|loot", "40|5400|1|1|1|lv|12" } }]])
    -- addons: Logbook installed one version behind the repo's, DropLab switched off for Hero, Questie's own toc
    local repo = dir .. "/repo"
    mkdir(repo .. "/Logbook"); mkdir(wow .. "/Interface/AddOns/Logbook"); mkdir(wow .. "/Interface/AddOns/Questie")
    U.writeFile(repo .. "/Logbook/Logbook.toc", "## Title: Logbook\n## Notes: Your journey.\n## Version: 0.2.0\n\nCore.lua\n")
    U.writeFile(wow .. "/Interface/AddOns/Logbook/Logbook.toc", "## Version: 0.1.0\n")
    U.writeFile(wow .. "/Interface/AddOns/Questie/Questie_Forever.toc", "## Title: Questie|cFF00FF00 v12.9.0|r\n## Version: 12.9.0\n")
    U.writeFile(acct .. "/91/Hero-Realm/AddOns.txt", "DropLab: disabled\nLogbook: enabled\n")
    U.writeFile(acct .. "/SavedVariables/DropLab.lua", 'DropLabDB = { version = 1, mobs = { [1] = { name = "Gnoll", kills = 6, looted = 5, money = 60, items = { [2592] = { drops = 3, qty = 3 } } } } }')
    local listDirs = function(p)
        if p:match("/WTF/Account$") then return { "ACC" } end
        if p:match("/ACC$") then return { "91", "SavedVariables" } end
        if p:match("/91$") then return { "Hero-Realm" } end
        return {}
    end
    local appended = {}
    local data = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs,
        dropStats = Build.dropStats(wowDir()), repoAddons = repo,
        worthLog = { seen = { ["hero-R"] = { { 1, 4000, 0 } } }, last = { ["hero-R"] = { 1, 4000, 0 } },
            append = function(lines) appended[#appended + 1] = lines end } })
    eq(#appended, 1, "gold changed since the logged point")
    truthy(appended[1]:find("\thero%-R\t5000\t400\n"), "gold 5000, 4 Wool Cloth at 100: " .. appended[1])
    eq(#data.characters[1].worthLog, 2, "the logged point and this build's")
    local byKey = {}
    for _, r in ipairs(data.addons) do byKey[r.key] = r end
    eq(byKey.Logbook.repo, "0.2.0"); eq(byKey.Logbook.installed, "0.1.0"); eq(byKey.Logbook.notes, "Your journey.")
    eq(byKey.Logbook.ours, true); eq(byKey.Logbook.saved, false, "no Logbook file in the fixture")
    eq(byKey.DropLab.present, false); eq(byKey.DropLab.disabledOn[1], "Hero"); eq(byKey.DropLab.saved, true)
    eq(byKey.Questie.installed, "12.9.0"); eq(byKey.Questie.title, "Questie v12.9.0", "colour codes stripped")
    eq(byKey.Auctionator.present, false); eq(byKey.Auctionator.saved, true); eq(byKey.Auctionator.ours, false)
    eq(data.drops.mobs[1].name, "Gnoll"); eq(data.drops.mobs[1].drops[1].name, "Wool Cloth")
    near(data.drops.mobs[1].value, (60 + 3 * 95) / 6, "AH 100 after the 5% cut")
    eq(#data.characters, 1)
    local c = data.characters[1]
    eq(c.profile.name, "Hero"); eq(c.profile.money, 5000); eq(c.profile.played, 7200)
    eq(c.inventory.items[1].name, "Wool Cloth"); eq(c.netWorth.total, 5400)
    eq(c.money.earned[1].copper, 50); eq(c.zones[1].name, "Elwynn")
    eq(#c.prices, 1, "owned item with 2 days of prices")
    eq(c.levelTimes[#c.levelTimes].current, true)
    -- The alt has no character folder: it's in the account view only, without a detailed page
    eq(c.id, M.charId("Hero", "R"))
    local rows = data.account.characters
    eq(#rows, 2); eq(rows[1].name, "Hero"); eq(rows[1].detailed, true)
    eq(rows[2].name, "Alt"); eq(rows[2].detailed, false); eq(rows[2].netWorth, 107)
    eq(data.account.totals.netWorth, 5507)
    -- Saved realm "R" is shown by its folder name "Realm", also for the alt without a folder
    -- Folder "Hero-Realm" = first name Hero, surname Realm; the alt has no folder, so no surname
    eq(c.profile.fullName, "Hero Realm"); eq(c.profile.ruleset, "R")
    eq(rows[1].fullName, "Hero Realm"); eq(rows[2].fullName, "Alt"); eq(rows[2].ruleset, "R")
    eq(data.account.inventory.items[1].name, "Wool Cloth"); eq(data.account.inventory.items[1].count, 5)
    eq(#c.recaps, 1, "one play session"); eq(c.recaps[1].xp, 100); eq(c.recaps[1].zones[1], "Elwynn")
    eq(data.market.scanDays, 2); eq(data.market.ready, false)
    eq(type(data.transfers), "table")
    local page = Build.html("<script>const DATA = /*DATA*/null;</script>", data)
    truthy(page:find('"name":"Hero"', 1, true), "data embedded")
    truthy(not page:find("/*DATA*/", 1, true), "placeholder replaced")
    eq(data.marketTab.items["2592"].now, 100, "no market data: the scan's price, as before")
    eq(data.trends, nil, "no market data: no Trends")
    truthy(data.reset and data.reset.dow and data.reset.hour, "the reset is there without API data too")
    -- The API's newer snapshot of R Horde. Ledger Link saw a faction visit at 10:00 on the last scan day (when
    -- Auctionator's price was taken) and a Neutral one at 20:00, which must not stamp the faction book's scan.
    local day = S.dayToTime(2501)
    U.writeFile(acct .. "/SavedVariables/LedgerLink.lua", ([[LedgerLinkDB = { visits = {
        { t = %d, kind = "faction", realm = "R", faction = "Horde" }, { t = %d, kind = "neutral", realm = "R" } } }]])
        :format(day + 10 * 3600, day + 20 * 3600))
    -- the wanted list also takes what any character holds (Alt's Mining Pick) or sold on the AH (Hero's Woolen Bag)
    U.writeFile(acct .. "/SavedVariables/Stockpile.lua", 'StockpileDB = { version = 1, chars = { ["Hero-R"] = { name = "Hero", realm = "R", bags = { [2592] = 4 }, bank = {}, mail = {} }, ["Alt-R"] = { name = "Alt", realm = "R", bags = { [2592] = 1, [2901] = 1 }, bank = {}, mail = {} } } }')
    U.writeFile(charSV .. "/MuddyBoots.lua", [[MuddyBootsCharDB = { char = { name = "Hero", realm = "R", guid = "G1", level = 12, class = "PRIEST",
        first = { level = 11 } }, sessions = { { start = 5, played0 = 3500, played1 = 7200, last = 50 } },
        counts = { xp = { all = 300, kill = 100, quest = 200 } },
        log = { "10|3600|1|1|1|zo|Elwynn", "20|3610|1|1|1|xp|100|kill|Wolf", "30|3620|1|1|1|mn|50|loot", "40|5400|1|1|1|lv|12",
            "45|5405|1|1|1|ah|sold|950|Woolen Bag", "45|5405|1|1|1|mn|950|auction|Woolen Bag" } }]])
    local logged, wanted = {}, {}
    local api = Build.data(wow, { names = { [2592] = "Wool Cloth", [4241] = "Woolen Bag", [2901] = "Mining Pick", [12345] = "Nobody's Item" }, listDirs = listDirs, repoAddons = repo,
        market = { houses = { [113] = { id = 113, key = "R Horde", latest = day + 15 * 3600,
            items = { [2592] = { now = 90, market = 95, spark = { 88, 90, false }, hourly = { min = { 80 }, market = { 85 } } }, [12345] = { now = 1, spark = { 1 } },
                [2901] = { now = 40, spark = { 40 } }, [4241] = { now = 30, spark = { 30 } } },
        recent = {} } } },
        priceLog = { seen = {}, last = {}, append = function(lines) logged[#logged + 1] = lines end },
        reset = "Wed 9", wanted = function(text) wanted[#wanted + 1] = text end })
    local th = api.trends and api.trends.houses["R Horde"]
    truthy(th, "Trends for the API's house")
    eq(#th.families, #I.FAMILIES); eq(th.families[3].key, "cloth"); eq(th.families[3].ids[1], 2592)
    eq(th.items["2592"].name, "Wool Cloth"); eq(th.items["2592"].spark[2], 90); eq(th.items["2592"].spark[3], false)
    eq(th.items["12345"], nil, "an engine item nobody wants isn't embedded")
    truthy(th.items["2901"], "an item held but in no family is embedded")
    truthy(th.items["4241"], "an item only traded at the AH is embedded")
    eq(th.items["2592"].hourly.min[1], 80, "a held item keeps its hourly series")
    eq(api.trends.default, "R Horde")
    eq(api.reset.dow, 2, "Wed"); eq(api.reset.hour, 9); eq(api.trends.reset, api.reset)
    eq(#wanted, 1, "one wanted list per build")
    truthy(wanted[1]:find("R Horde\t2592\n", 1, true), "the held item is wanted: " .. wanted[1]:sub(1, 80))
    truthy(wanted[1]:find("R Horde\t2901\n", 1, true), "an alt's held item is wanted")
    truthy(wanted[1]:find("R Horde\t4241\n", 1, true), "an item sold on the AH is wanted")
    truthy(wanted[1]:find("R Horde\t2447\n", 1, true), "a family member is wanted")
    truthy(wanted[1]:find("R Neutral\t2592\n", 1, true), "the character's Neutral house too")
    eq(api.characters[1].houses.faction, "R Horde"); eq(api.characters[1].houses.neutral, "R Neutral")
    eq(api.marketTab.items["2592"].now, 90, "the snapshot is newer than the 10:00 scan")
    eq(api.marketTab.items["2592"].nowFrom, "api"); eq(api.marketTab.items["2592"].market, 95)
    eq(#logged, 1); truthy(logged[1]:find("\t2592\t100\n"), "the log keeps the scan: " .. logged[1])
    truthy(not logged[1]:find("\t90\n"), "API prices never reach the price log")
    eq(#api.priceSources, 1, "R Neutral has no book and no API data"); eq(api.priceSources[1].key, "R Horde")
    eq(api.priceSources[1].apiAt, day + 15 * 3600); eq(api.priceSources[1].scanAt, day + 10 * 3600)
    eq(api.account.characters[1].items, 380, "the account rows use the merged market value: 4 Wool Cloth at 95")
    eq(api.characters[1].inventory.items[1].unit, 95, "held items are valued at market value, not the lowest price")
    -- a market_wanted.tsv that can't be written (locked, read-only) is a warning, never a failed build
    local locked = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs, repoAddons = repo,
        market = { houses = { [113] = { id = 113, key = "R Horde", latest = day + 15 * 3600,
            items = { [2592] = { now = 90, market = 95 } }, recent = {} } } },
        priceLog = { seen = {}, last = {}, append = function() end },
        wanted = function() error("market_wanted.tsv: Permission denied") end })
    truthy(locked.trends, "the page still builds")
    local warned = false
    for _, w in ipairs(locked.warnings) do warned = warned or w:find("market_wanted.tsv", 1, true) ~= nil end
    truthy(warned, "a warning names the wanted file")
    if windows then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" 2>nul') else os.execute('rm -rf "' .. dir .. '"') end
end)

test("AddOns.txt: switched off, on, and unlisted (enabled)", function()
    local on = S.addonStates("Logbook: enabled\r\nDropLab: disabled\r\n!BugGrabber: enabled")
    eq(on.Logbook, true); eq(on.DropLab, false); eq(on["!BugGrabber"], true); eq(on.Haul, nil)
    eq(next(S.addonStates(nil)), nil)
end)

test("toc header: stops at the file list, skips baked item data, missing file is nil", function()
    local path = os.tmpname()
    U.writeFile(path, "## Interface: 16001\n## X-Item-25-S: AAAA\n## Version: 1.2\n# a comment\nCore.lua\n## Late: no\n")
    local m = S.tocMeta(path)
    os.remove(path)
    eq(m.Version, "1.2"); eq(m.Interface, "16001"); eq(m["X-Item-25-S"], nil); eq(m.Late, nil)
    eq(S.tocMeta(path), nil)
end)

test("a character folder without any of our addons' files is skipped", function()
    local Build = require("build")
    local data = Build.data("Z:/nowhere", { names = {}, listDirs = function(p)
        if p:match("Account$") then return { "A" } end
        if p:match("/A$") then return { "R" } end
        if p:match("/R$") then return { "Nobody" } end
        return {}
    end })
    eq(#data.characters, 0)
end)

----------------------------------------------------------------------------------------------------
test("replay: timed points with their state, and the moments worth showing with where they happened", function()
    local trail = { chunks = {
        { m = 1, t = 100, d = "0,10,20,w;5,11,21,d;10,10001,5" },
        { m = 2, t = 50, d = "0,30,40,t" },
    } }
    local events = S.parseLog({
        "40|1|2|30|40|lv|5", "60|1|2|31|41|de|Hogger|448|||world||10|elite", "70|1|2|1|1|xp|5|kill|Wolf",
        "80|1|1|5|5|qt|12|450|0|Westfall Stew", "90|1|1|5|5|lo|2|2||loot|Grey Thing|1",
        "95|1|1|5|5|lo|3|3||loot|Blue Thing|1", "96|1|1|5|5|ki|Wolf|299|Beast|normal|20|5", "97|||||out",
    })
    local r = M.replay(trail, events)
    eq(r.base, 50, "the first point")
    eq(table.concat(r.pts, ","), "0,2,30,40,2,50,1,10,20,0,55,1,11,21,1", "time order; flight and ghost flags; off-map dropped")
    eq(#r.moments, 5, "before base, XP lines and common loot left out")
    eq(r.moments[1][2], "de"); eq(r.moments[1][6], "Died to Hogger"); eq(r.moments[1][1], 10); eq(r.moments[1][3], 2)
    eq(r.moments[2][6], "Westfall Stew"); eq(r.moments[2][7], "Quest done, 450 XP")
    local q = M.replay(trail, S.parseLog({ "60|1|1|5|5|qa|7|Ordanus|27", "61|1|1|5|5|qx|8|Blueleaf Tubers", "62|1|1|5|5|qt|9|0|0|Talk" })).moments
    eq(q[1][7], "Quest accepted"); eq(q[2][7], "Quest abandoned"); eq(q[3][7], "Quest done", "no XP: no XP figure")
    eq(r.moments[3][6], "Blue Thing"); eq(r.moments[4][2], "ki"); eq(r.moments[4][7], "")
    eq(r.moments[5][2], "out"); eq(r.moments[5][3], 0, "no position: map 0"); eq(r.moments[5][4], -1)
    eq(#M.replay(nil, nil).pts, 0)
    local p = M.replay(trail, S.parseLog({ "60|1|1|5|5|pl|Soren||22|SHAMAN|Tauren|Totem Pole|buff|Power Word: Fortitude",
        "61|1|1|5|5|pl|Grim||30|ROGUE|Human||enemy|", "62|1|1|5|5|pl|Dank||||||group|" })).moments
    eq(p[1][2], "pl"); eq(p[1][6], "Buffed Soren"); eq(p[1][7], "level 22, Shaman, <Totem Pole>, Power Word: Fortitude")
    eq(p[2][2], "pe"); eq(p[2][6], "Enemy player Grim"); eq(p[2][7], "level 30, Rogue")
    eq(p[3][6], "Grouped with Dank"); eq(p[3][7], "")
end)

test("restock buy price: the cheaper of vendor and AH, where AH is now else market (as for crafts)", function()
    local price = require("build").priceFn({ prices = { [1] = { now = 40, market = 50 }, [2] = { market = 50 },
        [3] = { market = 50 } }, vendor = { [3] = 30 } })
    local v, src = price(1); eq(v, 40); eq(src, "ah")
    v, src = price(2); eq(v, 50); eq(src, "ah")     -- sold out now: priced at its market value, not skipped
    v, src = price(3); eq(v, 30); eq(src, "vendor")
    eq(price(4), nil)
end)

test("zones for map art: read from the live server's zones.py", function()
    local z = require("build").zones()
    eq(z["1442"], 406); eq(z["1413"], 17)
end)

test("recent trail: timed points from `since` on, per map in time order, newest kept at the cap", function()
    local trail = { chunks = {
        { m = 1, t = 100, d = "0,10,20,w;5,11,21;10,10001,5" },
        { m = 2, t = 200, d = "0,30,40" },
        { m = 1, t = 300, d = "0,12,22;5,13,23,t" },
    } }
    local out = M.recentTrail(trail, 105)
    eq(#out, 2); eq(out[1].map, 1); eq(out[2].map, 2)
    eq(table.concat(out[1].pts, ","), "105,11,21,300,12,22,305,13,23", "before since and off the map dropped")
    eq(table.concat(out[2].pts, ","), "200,30,40")
    local capped = M.recentTrail(trail, 0, 2)
    eq(#capped, 1); eq(table.concat(capped[1].pts, ","), "300,12,22,305,13,23")
    eq(#M.recentTrail(nil, 0), 0)
end)

test("trails: points grouped by map, scaled to thousandths, thinned to the cap, out-of-map points dropped", function()
    local trail = { chunks = {
        { m = 1421, t = 100, d = "0,6728,549,w;5,6730,551,-;10,10001,5000" },
        { m = 1420, t = 200, d = "0,5000,5000" },
        { m = 1421, t = 300, d = "0,1000,2000;7,1004,2004,c" },
    } }
    local out = M.trails(trail)
    eq(#out, 2); eq(out[1].map, 1421); eq(out[1].n, 4)
    eq(out[1].pts[1], 673); eq(out[1].pts[2], 55); eq(out[1].first, 100); eq(out[1].last, 307)
    eq(out[2].map, 1420); eq(#out[2].pts, 2)
    local many = {}
    for i = 0, 99 do many[#many + 1] = i .. "," .. (i * 10) .. ",5000" end
    local thin = M.trails({ chunks = { { m = 1, t = 0, d = table.concat(many, ";") } } }, 10)
    eq(#thin[1].pts, 20, "10 points kept"); eq(thin[1].n, 100)
    eq(#M.trails(nil), 0)
end)

test("marketTab: launch low, change, supply; families, owned by value, risers and fallers", function()
    local day = function(d) return d * 100 end
    local market = { prices = {
        [2447] = { now = 25, days = { { day = 1, low = 12, high = 20, available = 4800 }, { day = 2, low = 39, high = 39, available = 4300 },
            { day = 3, low = 25, high = 25, available = 2400 } } },          -- Peacebloom: low 12, now 25 (+108%), supply -50%
        [765] = { now = 17, days = { { day = 1, low = 15, high = 15, available = 5200 }, { day = 3, low = 17, high = 17, available = 6900 } } },
        [9999] = { now = 100, days = { { day = 1, low = 400, high = 900, available = 50 }, { day = 3, low = 100, high = 100, available = 60 } } },
        [7777] = { now = 7500, days = { { day = 1, low = 1, high = 1, available = 30 }, { day = 3, low = 7500, high = 7500, available = 30 } } }, -- a 1c listing isn't a launch price
        [8888] = { now = 5, days = { { day = 1, low = 1, high = 1, available = 99 }, { day = 3, low = 5, high = 5, available = 99 } } }, -- too cheap to list
    } }
    local owned = { [2447] = { count = 200, holders = { "Azhariel Deadheart 200" } }, [765] = { count = 10, holders = {} } }
    local out = I.marketTab(market, owned, function(id) return "Item " .. id end, { [2447] = { { 5, 30 } } }, day)
    eq(#out.days, 3); eq(out.days[1], 100)
    local pb = out.items["2447"]
    eq(pb.low, 12); eq(pb.peak, 39); eq(pb.have, 200); eq(pb.seen[1][2], 30)
    near(pb.change, 25 / 12 - 1); near(pb.supply, 2400 / 4800 - 1)
    eq(#pb.days, 3); eq(pb.days[2][4], 4300)
    eq(out.owned[1], 2447, "most valuable holding first"); eq(out.owned[2], 765)
    eq(out.families[1].key, "herbs"); eq(out.families[1].ids[1], 2447)
    eq(out.rising[1], 2447); eq(#out.rising, 1, "9999 fell, 8888 under the price floor, 7777's low under 10c")
    eq(out.items["9999"].peak, 400, "peak = highest daily low, not the 900 listing")
    eq(out.falling[1], 9999); truthy(out.items["9999"], "movers are included")
    truthy(out.items["8888"], "all priced items are included in marketTab catalog")
    eq(#out.families, 6, "herbs, ore, cloth, leather, enchanting, elemental")
end)

test("net worth log: parse per character, and append only characters whose gold or items changed", function()
    local seen, last = I.parseWorthLog("100\thero-r\t500\t200\n150\talt-r\t7\t0\r\n200\thero-r\t600\t200\nbroken line\n")
    eq(#seen["hero-r"], 2); eq(seen["hero-r"][2][2], 600); eq(last["hero-r"][1], 200); eq(last["alt-r"][3], 0)
    local lines = I.worthLogLines({
        { id = "hero-r", gold = 600, items = 200.4 },  -- same after rounding: nothing
        { id = "alt-r", gold = 7, items = 30 },        -- items changed
        { id = "new-r", gold = 1, items = 0 },         -- first point
        { id = "nogold-r", items = 50 },               -- gold unknown: skipped
    }, last, 300)
    eq(lines, "300\talt-r\t7\t30\n300\tnew-r\t1\t0\n")
    eq(I.worthLogLines({ { id = "x", gold = 1 } }, nil, 5), "5\tx\t1\t0\n", "no log yet")
end)

test("price log: parse, and append only prices that changed", function()
    local seen, last = I.parsePriceLog("100\t2447\t12\n200\t2447\t25\n200\t765\t15\n")
    eq(#seen[2447], 2); eq(seen[2447][2][2], 25); eq(last[2447], 25); eq(last[765], 15)
    local lines = I.priceLogLines({ prices = { [2447] = { now = 25 }, [765] = { now = 17 }, [1] = { now = 0 } } }, last, 300)
    eq(lines, "300\t765\t17\n")
    eq(I.priceLogLines({ prices = {} }, {}, 1), "")
end)

test("xpState: XP at the save from Haul, save time = last event, each creature's latest kill XP", function()
    local events = {
        { t = 100, kind = "ki", args = { "Gray Bear", "2351", "Beast", "normal", "180", "21" } },
        { t = 200, kind = "ki", args = { "Gray Bear", "2351", "Beast", "normal", "161", "22" } },
        { t = 150, kind = "ki", args = { "Forest Moss Creeper", "2350", "Beast", "normal", "154", "21" } },
        { t = 250, kind = "ki", args = { "Training Dummy", "999", "Mechanical", "normal", "0", "1" } },
        { t = 300, kind = "out", args = {} },
    }
    local s = M.xpState(events, { current = { session = { lastXP = 17779, lastXPMax = 21300 } } })
    eq(s.cur, 17779); eq(s.max, 21300); eq(s.savedAt, 300)
    eq(s.mobs["2351"].xp, 161, "latest kill wins"); eq(s.mobs["2350"].name, "Forest Moss Creeper")
    eq(s.mobs["999"], nil, "no-XP kills are skipped")
    local none = M.xpState({}, nil)
    eq(none.cur, nil); eq(none.max, nil); eq(none.savedAt, nil)
end)

test("S.auctionator keeps every realm's book; S.ledger reads books, legacy and tagged visits", function()
    local a = S.auctionator({ AUCTIONATOR_PRICE_DATABASE = { __dbversion = 8,
        PvP = { ["2592"] = { m = 100, h = { ["2500"] = 100 } } }, Normal = { ["765"] = { m = 5, h = { ["2500"] = 5 } } } } })
    eq(a.books.PvP[2592].now, 100); eq(a.books.Normal[765].now, 5)
    local l = S.ledger({ LedgerLinkDB = { books = { PvP = { Neutral = { ["2447"] = { m = 7, t = 9, h = { ["2500"] = 7 } } } } },
        neutral = { ["765"] = { m = 3, h = { ["2500"] = 3 } } },
        visits = { { t = 1, kind = "neutral", realm = "PvP", faction = "Horde" }, { t = 2, kind = "faction" } } } })
    eq(l.books.PvP.Neutral[2447].seenAt, 9); eq(l.legacy[765].now, 3)
    eq(l.visits[1].realm, "PvP"); eq(l.visits[2].realm, nil)
    eq(S.ledger({ LedgerLinkDB = {} }), nil)
end)

test("S.ledger: the legacy Neutral book reads like Auctionator's; mode, last and visits kept; nothing saved = nil", function()
    local env = { LedgerLinkDB = { neutralMode = "split", neutralLast = 500, visits = { { t = 400, kind = "neutral", zone = "Gadgetzan" } },
        neutral = { ["2447"] = { m = 40, t = 450, h = { ["2502"] = 60, ["2501"] = 45 }, l = { ["2502"] = 40 }, a = { ["2502"] = 9 } } } } }
    local n = S.ledger(env)
    eq(n.legacy[2447].now, 40); eq(n.legacy[2447].seenAt, 450)
    eq(n.legacy[2447].days[1].day, 2501); eq(n.legacy[2447].days[2].low, 40); eq(n.legacy[2447].days[2].available, 9)
    eq(n.last, 500); eq(n.visits[1].zone, "Gadgetzan"); eq(n.mode, "split")
    eq(S.ledger(nil), nil); eq(S.ledger({ LedgerLinkDB = { enable = true } }), nil)
end)

test("compareHouses: spread and both flips after each house's cut, biggest gap first", function()
    local faction = { prices = { [1] = { now = 100, days = { { day = 1, available = 40 } } }, [2] = { now = 1000 }, [3] = { now = 50 }, [4] = { now = 0 } } }
    local neutral = { prices = { [1] = { now = 200, seenAt = 9 }, [2] = { now = 900 }, [4] = { now = 10 }, [5] = { now = 10 } } }
    local out = I.compareHouses(faction, neutral, function(id) return "Item " .. id end, { [1] = { count = 3 } })
    eq(#out, 2, "only items priced at both houses")
    eq(out[1].id, 1); near(out[1].spread, 1.0); eq(out[1].toNeutral, 70, "200 less 15% = 170, minus the 100 paid")
    eq(out[1].toFaction, -105); eq(out[1].have, 3); eq(out[1].neutralAt, 9); eq(out[1].fListed, 40); eq(out[1].nListed, nil)
    eq(out[2].id, 2); near(out[2].spread, -0.1); eq(out[2].toFaction, 50, "1000 less 5% = 950, minus 900")
end)

test("splitNeutralDays: Neutral days leave the faction book; a Neutral 'now' falls back and is marked stale", function()
    local market = { prices = {
        [1] = { now = 90, days = { { day = 10, low = 20, high = 25 }, { day = 11, low = 80, high = 90 } } },  -- last day neutral
        [2] = { now = 30, days = { { day = 11, low = 70, high = 70 }, { day = 12, low = 30, high = 30 } } },  -- rescanned after
        [3] = { now = 50, days = { { day = 11, low = 50, high = 50 } } },                                     -- only seen at neutral
        [4] = { now = 5, days = { { day = 10, low = 5, high = 5 } } },
    } }
    local m, n = I.splitNeutralDays(market, nil, { [11] = true })
    eq(#m.prices[1].days, 1); eq(m.prices[1].now, 20); eq(m.prices[1].stale, true)
    eq(n.prices[1].now, 90); eq(n.prices[1].days[1].day, 11)
    eq(m.prices[2].now, 30); eq(m.prices[2].stale, nil); eq(n.prices[2].now, 70, "neutral now = its own day's low")
    eq(m.prices[3], nil, "nothing left at faction"); eq(n.prices[3].now, 50)
    eq(#m.prices[4].days, 1); eq(n.prices[4], nil)
    eq(n.movedDays[1], 11); eq(n.prices[3].stale, true, "moved prices aren't logged as new Neutral scans")
    eq(I.priceLogLines(n, {}, 1), "")
    eq(I.priceLogLines(m, {}, 1):find("\t1\t", 1, true), nil, "stale prices aren't logged")
    local same = I.splitNeutralDays(market, nil, {}); eq(same, market)
end)

test("parseNeutralDays: dates to scan days, comments ignored", function()
    local d = I.parseNeutralDays("# note 2026-01-01\n2026-11-13\r\n\n2026-11-14 # also\n", S.timeToDay)
    local k = S.timeToDay(os.time({ year = 2026, month = 11, day = 13, hour = 12 }))
    eq(d[k], true); eq(d[k + 1], true); eq(d[S.timeToDay(os.time({ year = 2026, month = 1, day = 1, hour = 12 }))], nil)
end)

----------------------------------------------------------------------------------------------------
-- Logbook with MuddyBoots' history

test("mergeJournal: MuddyBoots before Logbook's start, Logbook after; counters add on the baseline", function()
    local mb = { char = { name = "Azhariel", first = { t = 50, level = 11 } },
        log = { "100|10|1|2|3|xp|5|kill|Boar", "300|30|1|2|3|xp|7|kill|Boar" },
        sessions = { { start = 90, last = 120 }, { start = 290, last = 320 } },
        snap = { [11] = { played = 1, money = 5 }, [12] = { played = 2, money = 9 } },
        trail = { chunks = { { m = 1, t = 95, d = "0,1,1" }, { m = 1, t = 295, d = "0,2,2" } } },
        counts = { xp = { all = 999 } } }
    local lb = { since = 200, char = { name = "Azhariel", level = 12, zone = "Mulgore" },
        log = { "250|25|1|2|3|xp|9|quest|Q" }, sessions = { { start = 240, last = 260 } },
        snap = { [12] = { played = 3, money = 11 } }, trail = { chunks = { { m = 1, t = 245, d = "0,3,3" } } },
        baseline = { counts = { xp = { all = 12, kill = 12 }, fights = { longest = 40 } } },
        counts = { xp = { all = 9, quest = 9 }, fights = { longest = 30, n = 2 } } }
    local j = S.mergeJournal(lb, mb)
    eq(#j.log, 2); eq(j.log[1]:sub(1, 3), "100"); eq(j.log[2]:sub(1, 3), "250")
    eq(#j.sessions, 2); eq(#j.trail.chunks, 2); eq(j.snap[11].money, 5); eq(j.snap[12].money, 11)
    eq(j.char.first.level, 11); eq(j.char.zone, "Mulgore"); eq(j.char.level, 12)
    eq(j.counts.xp.all, 21, "baseline + Logbook, not MuddyBoots' own total"); eq(j.counts.xp.quest, 9)
    eq(j.counts.fights.longest, 40); eq(j.counts.fights.n, 2)
    eq(S.mergeJournal(nil, mb), mb)
    local alone = S.mergeJournal(lb, nil)
    eq(#alone.log, 1); eq(alone.source, "Logbook")
end)

test("mergeAccountChars: the newer row wins, field by field", function()
    local rows = S.mergeAccountChars(
        { chars = { g1 = { name = "A", money = 50, lastSeen = 200 }, g3 = { name = "C", lastSeen = 1 } } },
        { chars = { g1 = { name = "A", money = 10, lastSeen = 100, hardcore = false }, g2 = { name = "B" } } })
    eq(rows.g1.money, 50); eq(rows.g1.hardcore, false); eq(rows.g2.name, "B"); eq(rows.g3.name, "C")
    eq(S.mergeAccountChars(nil, nil), nil)
end)

test("flights: Logbook's fl lines and MuddyBoots' take-off and landing, by route", function()
    local f = M.flights(ev({
        "100|||||tx|Undercity, Tirisfal|The Sepulcher, Silverpine Forest|99", "210|||||tl|The Sepulcher, Silverpine Forest",
        "300|||||tx|The Sepulcher, Silverpine Forest|Undercity, Tirisfal|99", "305|||||in|reload",
        "4000|||||tl|Undercity, Tirisfal",
        "5000|||||fl|Undercity, Tirisfal|The Sepulcher, Silverpine Forest|99|100",
        "6000|||||fl|Thunder Bluff, Mulgore|Ratchet, The Barrens|330|",
    }))
    eq(f.n, 3, "a landing an hour after take-off isn't that flight"); eq(f.copper, 528); eq(f.seconds, 210)
    eq(f.longest, 110); eq(f.longestTrip.to, "The Sepulcher, Silverpine Forest")
    eq(f.routes[1].n, 2); eq(f.routes[1].avgSeconds, 105); eq(f.routes[2].avgSeconds, nil)
    eq(f.recent[1].to, "Ratchet, The Barrens")
    eq(M.flights(ev({ "1|||||in|login" })), nil)
end)

test("flights: stops on the way, and a route with a stop counted apart from the direct one", function()
    local f = M.flights(ev({
        "100|||||fl|Sun Rock Retreat, Stonetalon Mountains|Zoram'gar Outpost, Ashenvale|540|380|Crossroads, The Barrens",
        "200|||||fl|Sun Rock Retreat, Stonetalon Mountains|Zoram'gar Outpost, Ashenvale|320|378",
    }))
    eq(f.recent[1].via, nil); eq(f.recent[2].via[1], "Crossroads, The Barrens")
    eq(#f.routes, 2)
    local stopped = f.routes[1].via and f.routes[1] or f.routes[2]
    eq(stopped.via[1], "Crossroads, The Barrens"); eq(stopped.copper, 540)
end)

test("mergeJournal: MuddyBoots' flights stay until Logbook's first flight, in time order", function()
    local mb = { log = { "50|||||tx|A|B|10", "60|||||tl|B", "150|||||tx|B|A|10", "160|||||tl|A", "170|||||mn|5|loot",
        "400|||||tx|A|B|10", "410|||||tl|B" } }
    local lb = { since = 100, log = { "120|||||in|login", "155|||||mn|-10|flight|A", "300|||||fl|A|B|10|9" } }
    local out = S.mergeJournal(lb, mb).log
    eq(#out, 7)
    eq(out[3], "120|||||in|login"); eq(out[4], "150|||||tx|B|A|10"); eq(out[6], "160|||||tl|A")
    eq(out[7], "300|||||fl|A|B|10|9", "after Logbook's first flight, Logbook's lines only")
end)

test("AH trades: open-all retries logged by an older Logbook count as one sale", function()
    local ah = M.ahTrades(ev({
        "100|||||ma|invoice|?|7090|Woolen Reagent Bag", "100|||||ah|sold|7090|Woolen Reagent Bag",
        "101|||||ma|invoice|Buyer|7090|Woolen Reagent Bag", "101|||||ah|sold|7090|Woolen Reagent Bag",
        "101|||||mn|7090|auction|Woolen Reagent Bag",
        "200|||||ah|sold|7090|Woolen Reagent Bag", "200|||||mn|7090|auction|Woolen Reagent Bag",
    }))
    eq(ah.totals.soldCount, 2); eq(ah.totals.sold, 14180)
end)

test("journal: Logbook's copy of MuddyBoots' history stands in for MuddyBoots' file", function()
    local old = { char = { name = "Hero", first = { t = 5, level = 1 } }, log = { "10|1|1|1|1|zo|Elwynn", "150|4|1|1|1|tx|A|B|50" },
        sessions = { { start = 10, last = 20 } }, trail = { v = 1, chunks = { { m = 1, t = 10, d = "0,1,1" } } }, snap = { [2] = { t = 12 } } }
    local lb = { since = 100, char = { name = "Hero", level = 3 }, log = { "200|9|1|1|1|zo|Westfall" },
        sessions = { { start = 200, last = 300 } }, trail = { v = 1, chunks = {} }, snap = {}, counts = {} }
    local withFile = S.mergeJournal(lb, old)
    lb.history = old
    local withCopy = S.mergeJournal(lb, nil)
    eq(#withCopy.log, #withFile.log); eq(withCopy.log[1], "10|1|1|1|1|zo|Elwynn"); eq(withCopy.log[3], "200|9|1|1|1|zo|Westfall")
    eq(#withCopy.sessions, 2); eq(#withCopy.trail.chunks, 1); eq(withCopy.snap[2].t, 12); eq(withCopy.char.first.t, 5)
    eq(S.mergeJournal(lb, { log = { "11|1|1|1|1|zo|Duskwood" } }).log[1], "11|1|1|1|1|zo|Duskwood", "MuddyBoots' file wins")
end)

test("level: the highest any source knows, never a newer row's stale level 1", function()
    local rows = S.mergeAccountChars({ chars = { d = { name = "Des", level = 1, money = 0, lastSeen = 300 } } },
        { chars = { d = { name = "Des", level = 5, money = 267, lastSeen = 200 } } })
    eq(rows.d.level, 5); eq(rows.d.money, 0, "other fields: the newer row still wins")
    local mb = S.mergeJournal({ since = 1, char = { level = 1 } }, { char = { level = 5 } })
    eq(mb.char.level, 5)
    local c = M.character({ muddy = { char = { level = 1 }, log = { "10|100|1|1|1|lv|4", "20|200|1|1|1|lv|5" } } })
    eq(c.profile.level, 5, "from the last level-up logged")
end)

----------------------------------------------------------------------------------------------------
-- Several PCs

local Mg = require("merge")

test("merge logbooks (state-based): lines in time order, sessions, counters added, records kept, newest char", function()
    local A = { since = 100, baseline = { counts = { xp = { kill = 1000 } } }, char = { name = "Hero", level = 5, zone = "Elwynn", first = { level = 1 } },
        log = { "110|1|1|1|1|mn|50|loot", "120|1|1|1|1|lv|5" },
        sessions = { { start = 105, last = 125, played0 = 0, played1 = 20, how = "login" } },
        counts = { xp = { kill = 10 }, fights = { longest = 30, n = 4 } },
        snap = { [5] = { t = 120, money = 50 } }, trail = { chunks = { { m = 1, t = 106, d = "0,1,1" } } } }
    local B = { since = 200, char = { name = "Hero", level = 6, zone = "Westfall" },
        log = { "210|1|1|1|1|mn|-20|vendor", "220|1|1|1|1|lv|6" },
        sessions = { { start = 205, last = 225, played0 = 20, played1 = 40, how = "login" } },
        counts = { xp = { kill = 5 }, fights = { longest = 40, n = 2 } },
        snap = { [6] = { t = 220, money = 30 } }, trail = { chunks = { { m = 1, t = 206, d = "0,2,2" } } } }
    local m, shared = Mg.logbooks({ B, A })
    eq(shared, 0); eq(m.since, 100); eq(m.baseline, A.baseline, "the baseline counts once, from the PC that started first")
    eq(table.concat(m.log, ";"), table.concat({ A.log[1], A.log[2], B.log[1], B.log[2] }, ";"))
    eq(#m.sessions, 2); eq(m.sessions[1].start, 105)
    eq(m.counts.xp.kill, 15); eq(m.counts.fights.n, 6); eq(m.counts.fights.longest, 40, "a record: the higher")
    eq(m.snap[5].money, 50); eq(m.snap[6].money, 30); eq(#m.trail.chunks, 2)
    eq(m.char.zone, "Westfall", "from the PC that played last"); eq(m.char.level, 6); eq(m.char.first.level, 1)
    -- through mergeJournal as the build does: baseline + both PCs' own counts
    eq(S.mergeJournal(m, nil).counts.xp.kill, 1015)
    -- a file copied between PCs: the shared lines and sessions count once, and the overlap is reported
    local copied = { since = 100, log = { A.log[1], A.log[2], "300|1|1|1|1|lv|7" }, sessions = { A.sessions[1] }, counts = {} }
    local m2, shared2 = Mg.logbooks({ A, copied })
    eq(shared2, 2); eq(#m2.log, 3); eq(#m2.sessions, 1)
    -- the same line twice in one file is two real events (two identical sales in one second): both kept, none shared
    local twice = "130|1|1|1|1|ah|sold|290|Page 7"
    local R = { since = 100, log = { twice, twice }, counts = {} }
    local m3, shared3 = Mg.logbooks({ R, B })
    eq(shared3, 0); eq(#m3.log, 4); eq(m3.log[1], twice); eq(m3.log[2], twice)
    -- a copy of that file on another PC: each line counts as often as the copy that has it most, the overlap is shared
    local m4, shared4 = Mg.logbooks({ R, { since = 100, log = { twice, twice, twice }, counts = {} } })
    eq(shared4, 2); eq(#m4.log, 3)
    local one, none = Mg.logbooks({ A })
    eq(one, A, "one PC: untouched"); eq(none, 0); eq(Mg.logbooks({}), nil)
end)

test("merge account rows, Haul, Make or Buy, prices and Stockpile across PCs", function()
    local acc = Mg.logbookAccounts({ { chars = { g = { name = "Hero", money = 5, lastSeen = 10 } } },
        { chars = { g = { name = "Hero", money = 9, lastSeen = 20 }, h = { name = "Alt", lastSeen = 1 } } } })
    eq(acc.chars.g.money, 9, "the row seen last"); eq(acc.chars.h.name, "Alt")

    local haul = Mg.haul({ { history = { { start = 30 }, { start = 10 } }, current = { session = { start = 40 } } },
        { history = { { start = 20 }, { start = 10 } }, current = { session = { start = 50 } } } })
    eq(#haul.history, 3, "a repeated start once"); eq(haul.history[1].start, 30, "newest first"); eq(haul.current.session.start, 50)

    local mob = Mg.makeOrBuy({
        { recipes = { [1] = { profession = 197 } }, skill = { [197] = { level = 60, max = 75 } }, bounds = { [1] = { y = { 0, 60 } } }, restock = { [1] = 2 } },
        { recipes = { [1] = { profession = 197 }, [2] = { profession = 185 } }, skill = { [197] = { level = 90, max = 150 }, [185] = { level = 5, max = 75 } },
          bounds = { [1] = { y = { 0, 85 } } } } })
    eq(mob.skill[197].level, 90); eq(mob.skill[185].level, 5); truthy(mob.recipes[2])
    eq(mob.bounds[1].y[2], 85, "colours from the PC with the higher skill"); eq(mob.restock[1], 2, "the rest from the first")

    local prices = Mg.markets({
        { prices = { [7] = { now = 100, days = { { day = 1, low = 100, high = 120, available = 5 }, { day = 2, low = 90, high = 95, available = 3 } } } }, vendor = { [8] = 4 } },
        { prices = { [7] = { now = 70, days = { { day = 2, low = 80, high = 99, available = 9 }, { day = 3, low = 70, high = 70, available = 2 } } } }, vendor = {} } })
    local p = prices.prices[7]
    eq(#p.days, 3); eq(p.days[2].low, 80); eq(p.days[2].high, 99); eq(p.days[2].available, 9); eq(p.now, 70, "the latest scan's price")
    eq(prices.vendor[8], 4)

    local stock = Mg.stockpiles({
        { stock = { chars = { ["Hero-R"] = { name = "Hero", realm = "R", bags = { [1] = 1 } } } }, rows = { g = { name = "Hero", realm = "R", lastSeen = 10 } } },
        { stock = { chars = { ["Hero-R"] = { name = "Hero", realm = "R", bags = { [1] = 9 } } } }, rows = { g = { name = "Hero", realm = "R", lastSeen = 20 } } } })
    eq(stock.chars["Hero-R"].bags[1], 9, "what it holds on the PC where it was seen last")
end)

test("end to end: another PC's WTF in data/pcs adds its sessions, money and play to the same character", function()
    local Build = require("build")
    local dir = os.tmpname():gsub("[^/\\]+$", "") .. "dash_pcs_" .. os.time()
    local windows = package.config:sub(1, 1) == "\\"
    local function mkdir(p)
        if windows then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') else os.execute('mkdir -p "' .. p .. '"') end
    end
    local wow, data = dir .. "/wow", dir .. "/data/"
    local here = wow .. "/WTF/Account/ACC/91/Hero-Realm/SavedVariables"
    local there = data .. "pcs/laptop/WTF/Account/ACC/91/Hero-Realm/SavedVariables"
    mkdir(here); mkdir(there); mkdir(wow .. "/WTF/Account/ACC/SavedVariables"); mkdir(data .. "pcs/laptop/WTF/Account/ACC/SavedVariables")
    U.writeFile(here .. "/Logbook.lua", [[LogbookCharDB = { since = 10, char = { name = "Hero", realm = "R", guid = "G1", level = 12 },
        sessions = { { start = 10, last = 50, played0 = 0, played1 = 40 }, { start = 300, last = 340, played0 = 3640, played1 = 3680 } },
        counts = { xp = { kill = 100 } }, log = { "20|1|1|1|1|mn|500|loot", "310|1|1|1|1|mn|50|loot" } }]])
    U.writeFile(there .. "/Logbook.lua", [[LogbookCharDB = { since = 100, char = { name = "Hero", realm = "R", guid = "G1", level = 12 },
        sessions = { { start = 100, last = 3700, played0 = 40, played1 = 3640 } },
        counts = { xp = { kill = 30 } }, log = { "200|1|1|1|1|mn|-200|trainer" } }]])
    local listDirs = function(p)
        p = p:gsub("\\", "/")
        if p:match("/data/pcs$") then return { "laptop" } end
        if p:match("/WTF/Account$") then return { "ACC" } end
        if p:match("/ACC$") then return { "91", "SavedVariables" } end
        if p:match("/91$") then return { "Hero-Realm" } end
        return {}
    end
    local others = Build.otherPCs(data, listDirs)
    eq(#others, 1); eq(others[1].name, "laptop")
    local d = Build.data(wow, { names = {}, listDirs = listDirs, otherPCs = others, repoAddons = dir .. "/none" })
    eq(#d.characters, 1); eq(d.pcs[2], "laptop")
    local c = d.characters[1]
    eq(c.profile.pcs, 2); eq(c.profile.sessions, 3, "both PCs' pieces")
    eq(#c.profile.unlogged, 0, "the laptop's hour is no longer a hole")
    local earned, spent = 0, 0
    for _, r in ipairs(c.money.earned) do earned = earned + r.copper end
    for _, r in ipairs(c.money.spent) do spent = spent + r.copper end
    eq(earned, 550); eq(spent, 200, "the trainer visit on the laptop")
    eq(c.xp.totals.kill, 130)
    if windows then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" 2>nul') else os.execute('rm -rf "' .. dir .. '"') end
end)

test("two rulesets: each character uses its own house", function()
    local Build = require("build")
    local dir = os.tmpname():gsub("[^/\\]+$", "") .. "dash_rulesets_" .. os.time()
    local windows = package.config:sub(1, 1) == "\\"
    local function mkdir(p)
        if windows then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') else os.execute('mkdir -p "' .. p .. '"') end
    end
    local acct = dir .. "/WTF/Account/ACC"
    mkdir(acct .. "/SavedVariables"); mkdir(acct .. "/91/Hero-Realm/SavedVariables")
    U.writeFile(acct .. "/SavedVariables/Stockpile.lua", 'StockpileDB = { version = 1, chars = { ["Hero-PvP"] = { name = "Hero", realm = "PvP", bags = { [2592] = 1 }, bank = {}, mail = {} }, ["Alt-Normal"] = { name = "Alt", realm = "Normal", bags = { [2592] = 1 }, bank = {}, mail = {} }, ["Third-Hardcore"] = { name = "Third", realm = "Hardcore", bags = { [2592] = 1 }, bank = {}, mail = {} } } }')
    U.writeFile(acct .. "/SavedVariables/MuddyBoots.lua", 'MuddyBootsDB = { chars = { G1 = { name = "Hero", realm = "PvP", faction = "Horde", level = 12, lastSeen = 50 }, G2 = { name = "Alt", realm = "Normal", faction = "Alliance", level = 3, lastSeen = 40 }, G3 = { name = "Third", realm = "Hardcore", faction = "Horde", level = 1, lastSeen = 30 } } }')
    U.writeFile(acct .. "/SavedVariables/Auctionator.lua", 'AUCTIONATOR_PRICE_DATABASE = { __dbversion = 8, PvP = { ["2592"] = { m = 100, h = { ["2500"] = 100 } } }, Normal = { ["2592"] = { m = 300, h = { ["2500"] = 300 } } } }')
    local listDirs = function(p)
        if p:match("/WTF/Account$") then return { "ACC" } end
        if p:match("/ACC$") then return { "91", "SavedVariables" } end
        if p:match("/91$") then return { "Hero-Realm" } end
        return {}
    end
    local data = Build.data(dir, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs, repoAddons = dir .. "/none" })
    local byName = {}
    for _, r in ipairs(data.account.characters) do byName[r.name] = r end
    eq(byName.Hero.items, 100, "PvP Horde's book"); eq(byName.Alt.items, 300, "Normal Alliance's book")
    eq(byName.Third.items, 0, "Hardcore Horde has no book: an empty market, never another house's")
    eq(data.marketTab.items["2592"].now, 100, "the default pair is the last character played: PvP Horde")
    eq(#data.priceSources, 2); eq(data.priceSources[1].key, "Normal Alliance"); eq(data.priceSources[2].key, "PvP Horde")
    if windows then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" 2>nul') else os.execute('rm -rf "' .. dir .. '"') end
end)

test("market.lua broken file: the page is still written", function()
    local Build = require("build")
    local dir = os.tmpname():gsub("[^/\\]+$", "") .. "dash_badmarket_" .. os.time()
    local windows = package.config:sub(1, 1) == "\\"
    if windows then os.execute('mkdir "' .. (dir .. "/data"):gsub("/", "\\") .. '" 2>nul') else os.execute('mkdir -p "' .. dir .. '/data"') end
    U.writeFile(dir .. "/data/market.lua", "garbage(")
    local out = dir .. "/data/dashboard.html"
    local data = Build.run(dir .. "/wow", out, dir .. "/data/")
    truthy(U.readFile(out), "page written")
    eq(#data.priceSources, 0)
    if windows then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" 2>nul') else os.execute('rm -rf "' .. dir .. '"') end
end)

-- One account folder with the given account-wide SavedVariables ({ [file] = source }); returns the WoW folder,
-- listDirs and a cleanup function
local function accountFixture(tag, files)
    local dir = os.tmpname():gsub("[^/\\]+$", "") .. "dash_" .. tag .. "_" .. os.time()
    local windows = package.config:sub(1, 1) == "\\"
    local acct = dir .. "/WTF/Account/ACC"
    for _, p in ipairs({ acct .. "/SavedVariables", acct .. "/91/Hero-Realm/SavedVariables" }) do
        if windows then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') else os.execute('mkdir -p "' .. p .. '"') end
    end
    for file, src in pairs(files) do U.writeFile(acct .. "/SavedVariables/" .. file, src) end
    local listDirs = function(p)
        if p:match("/WTF/Account$") then return { "ACC" } end
        if p:match("/ACC$") then return { "91", "SavedVariables" } end
        if p:match("/91$") then return { "Hero-Realm" } end
        return {}
    end
    return dir, listDirs, function()
        if windows then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" 2>nul') else os.execute('rm -rf "' .. dir .. '"') end
    end
end

test("no character with a faction: the market pages stay as they were", function()
    local Build = require("build")
    local files = {
        ["Stockpile.lua"] = 'StockpileDB = { version = 1, chars = { ["Hero-R"] = { name = "Hero", realm = "R", bags = { [2592] = 4 }, bank = {}, mail = {} } } }',
        ["MuddyBoots.lua"] = 'MuddyBootsDB = { chars = { G1 = { name = "Hero", realm = "R", level = 12, money = 5000, lastSeen = 50 } } }',
        ["Auctionator.lua"] = 'AUCTIONATOR_PRICE_DATABASE = { __dbversion = 8, R = { ["2592"] = { m = 100, h = { ["2500"] = 120, ["2501"] = 100 } } } }',
        ["LedgerLink.lua"] = 'LedgerLinkDB = { neutral = { ["2592"] = { m = 80, h = { ["2501"] = 80 } } } }',
    }
    local wow, listDirs, cleanup = accountFixture("nofaction", files)
    local data = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs, repoAddons = wow .. "/none" })
    eq(data.market.scanDays, 2); eq(data.marketTab.items["2592"].now, 100, "Auctionator's book, as before houses")
    eq(data.account.characters[1].items, 400)
    eq(data.neutralTab.items["2592"].now, 80, "Ledger Link's legacy Neutral book")
    eq(#data.priceSources, 0, "no house can be told")
    cleanup()
    -- Ledger Link's own books name their side: one faction house there is the default pair, with its Neutral
    files["LedgerLink.lua"] = 'LedgerLinkDB = { books = { R = { Horde = { ["2592"] = { m = 110, t = 9, h = { ["2501"] = 110 } } },'
        .. ' Neutral = { ["2592"] = { m = 70, t = 9, h = { ["2501"] = 70 } } } } } }'
    wow, listDirs, cleanup = accountFixture("onehouse", files)
    data = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs, repoAddons = wow .. "/none" })
    eq(data.marketTab.items["2592"].now, 110, "R Horde from Ledger Link"); eq(data.neutralTab.items["2592"].now, 70)
    cleanup()
end)

test("Neutral price log keeps the scan when the API is newer", function()
    local Build = require("build")
    local day = S.dayToTime(2501)
    local wow, listDirs, cleanup = accountFixture("neutrallog", {
        ["MuddyBoots.lua"] = 'MuddyBootsDB = { chars = { G1 = { name = "Hero", realm = "R", faction = "Horde", level = 12, lastSeen = 50 } } }',
        ["LedgerLink.lua"] = ('LedgerLinkDB = { books = { R = { Neutral = { ["2592"] = { m = 80, t = %d, h = { ["2501"] = 80 } } } } } }')
            :format(day + 3600),
    })
    local logged = {}
    local data = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs, repoAddons = wow .. "/none",
        market = { houses = { [116] = { id = 116, key = "R Neutral", latest = day + 2 * 3600, items = { [2592] = { now = 60 } }, recent = {} } } },
        neutralLog = { seen = {}, last = {}, append = function(lines) logged[#logged + 1] = lines end } })
    eq(data.neutralTab.items["2592"].now, 60, "the newer snapshot"); eq(data.neutralTab.items["2592"].nowFrom, "api")
    eq(#logged, 1); truthy(logged[1]:find("\t2592\t80\n"), "the log keeps the scan: " .. logged[1])
    truthy(not logged[1]:find("\t60\n"), "API prices never reach the Neutral log")
    cleanup()
end)

test("houses: books keyed by ruleset and side; legacy Neutral follows the account's ruleset", function()
    local H = require("houses")
    local book = function(p) return { [2592] = { now = p, days = {} } } end
    local warned = {}
    local got = H.collect({ {
        auctionator = { books = { PvP = book(100) } },
        ledger = { books = { PvP = { Neutral = book(90), Horde = book(101) } }, legacy = book(80) },
        chars = { { realm = "CAMWOW US2 Realm 2 PvP", faction = "Horde" } } } }, function(w) warned[#warned + 1] = w end)
    eq(#got["PvP Horde"], 2); eq(#got["PvP Neutral"], 2); eq(#warned, 0)
    eq(select(1, H.forChar("CAMWOW US2 Realm 2 PvP", "Horde")), "PvP Horde")
    eq(select(2, H.forChar("CAMWOW US2 Realm 2 PvP", "Horde")), "PvP Neutral")
end)

test("houses: both factions on one ruleset skip Auctionator's book and warn", function()
    local H = require("houses")
    local warned = {}
    local got = H.collect({ { auctionator = { books = { PvP = { [1] = { now = 1, days = {} } } } },
        chars = { { realm = "PvP", faction = "Horde" }, { realm = "PvP", faction = "Alliance" } } } },
        function(w) warned[#warned + 1] = w end)
    eq(got["PvP Horde"], nil); eq(#warned, 1)
end)

test("houses: default pair is the last character played", function()
    local H = require("houses")
    local f, n = H.default({ { realm = "PvP", faction = "Horde", lastSeen = 5 }, { realm = "Normal", faction = "Alliance", lastSeen = 9 } })
    eq(f, "Normal Alliance"); eq(n, "Normal Neutral")
end)

test("houses: fallbacks, nil inputs, ties and accounts without characters", function()
    local H = require("houses")
    local book = { [1] = { now = 1, days = {} } }
    local warned = {}
    local warn = function(w) warned[#warned + 1] = w end
    -- no character on the ruleset: the account's most common faction
    local got = H.collect({ { auctionator = { books = { Normal = book } },
        chars = { { realm = "PvP", faction = "Horde" }, { realm = "PvP", faction = "Horde" }, { realm = "PvP", faction = "Alliance" } } } }, warn)
    truthy(got["Normal Horde"]); eq(#warned, 0)
    -- tie: the character sorting first by ruleset .. faction decides
    got = H.collect({ { auctionator = { books = { Normal = book } },
        chars = { { realm = "PvP", faction = "Horde" }, { realm = "PvP", faction = "Alliance" } } } }, warn)
    truthy(got["Normal Alliance"])
    -- characters without realm or faction are ignored; nil auctionator and nil ledger are fine
    got = H.collect({ { chars = { { realm = nil, faction = "Horde" }, { realm = "PvP" } } }, { auctionator = { books = {} } } }, warn)
    eq(next(got), nil); eq(#warned, 0)
    -- no characters: Auctionator's book and the legacy book are skipped, one warning each
    got = H.collect({ { auctionator = { books = { PvP = book } }, ledger = { books = {}, legacy = book }, chars = {} } }, warn)
    eq(next(got), nil); eq(#warned, 2)
    -- forChar and default with missing data
    local f, n = H.forChar("PvP", nil); eq(f, nil); eq(n, "PvP Neutral")
    f, n = H.forChar(nil, "Horde"); eq(f, nil); eq(n, nil)
    f, n = H.default({ { realm = "PvP", lastSeen = 3 }, { faction = "Horde", lastSeen = 4 } }); eq(f, nil); eq(n, nil)
    f = H.default({ { realm = "A", faction = "Horde", lastSeen = 5 }, { realm = "B", faction = "Horde", lastSeen = 5 } })
    eq(f, "A Horde", "a tie goes to the first row")
end)

----------------------------------------------------------------------------------------------------
-- Reconciliation of scans with API snapshots

local R = require("reconcile")

test("reconcile: newer API snapshot wins; an item the API lacks keeps its scan", function()
    local book = { vendor = { [1] = 5 }, last = 7, prices = {
        [1] = { now = 100, seenAt = 1000, days = { { day = 1 } } },
        [3] = { now = 70, seenAt = 1000, days = {} } } }
    local api = { latest = 2000, items = { [1] = { now = 90, market = 95, units = 4 }, [2] = { market = 50 } } }
    local m = R.merge(book, api, function(p) return p.seenAt end)
    eq(m.prices[1].now, 90); eq(m.prices[1].nowFrom, "api"); eq(m.prices[1].nowAt, 2000)
    eq(m.prices[1].market, 95); eq(m.prices[1].units, 4); eq(m.prices[1].seenAt, 1000)
    truthy(m.prices[2]); eq(m.prices[2].now, nil); eq(#m.prices[2].days, 0); eq(m.prices[2].market, 50)
    eq(m.prices[3].now, 70, "no API data for it: the scan's price"); eq(m.prices[3].nowFrom, "scan")
    eq(m.prices[3].nowAt, 1000)
    eq(m.vendor, book.vendor); eq(m.last, 7); eq(m.apiLatest, 2000)
    eq(book.prices[1].now, 100, "the book is not mutated"); eq(book.prices[1].market, nil)
end)

test("reconcile: newer scan wins over an older snapshot", function()
    local book = { prices = { [1] = { now = 100, seenAt = 3000, days = {} } } }
    local api = { latest = 2000, items = { [1] = { now = 90, market = 95 } } }
    local m = R.merge(book, api, function(p) return p.seenAt end)
    eq(m.prices[1].now, 100); eq(m.prices[1].nowFrom, "scan"); eq(m.prices[1].nowAt, 3000); eq(m.prices[1].market, 95)
end)

test("reconcile: no api returns the book unchanged (same table)", function()
    local book = { prices = {} }
    eq(R.merge(book, nil, function() end), book)
    eq(R.merge(book, { items = {} }, function() end), book, "an api without a snapshot time is no api")
    local ab = { prices = { [1] = { now = 100, seenAt = 5000, days = { { day = 2000 } } } } }
    local snaps = { { t = 5100, min = { [1] = 100 } } }
    local atSeen = function(p) return p.seenAt end
    eq(R.agreement(ab, { recent = snaps }, atSeen), nil, "no snapshot time: the guard is the only reason")
    truthy(R.agreement(ab, { latest = 5100, recent = snaps }, atSeen), "with latest the same data agrees")
end)

test("reconcile: boundaries (tie, listed without now, no scan time)", function()
    local at = function(p) return p.seenAt end
    local book = { prices = { [1] = { now = 100, seenAt = 2000, days = {} }, [2] = { now = 70, seenAt = 1000, days = {} },
        [3] = { now = 60, days = {} } } }
    local api = { latest = 2000, items = { [1] = { now = 90, market = 95 }, [2] = { market = 50 }, [3] = { now = 55 } } }
    local m = R.merge(book, api, at)
    eq(m.prices[1].now, 100, "a tie keeps the scan"); eq(m.prices[1].nowFrom, "scan")
    eq(m.prices[2].now, nil); eq(m.prices[2].nowFrom, "api"); eq(m.prices[2].market, 50)
    eq(m.prices[3].now, 55, "no scan time: the api wins"); eq(m.prices[3].nowFrom, "api")
end)

test("reconcile: Auctionator day stamped by the last faction visit of that day", function()
    local D, h = 2000, 3600
    local base = S.dayToTime(D)
    local p = { days = { { day = D } } }
    local visits = {
        { t = base + 10 * h, kind = "faction" },
        { t = base + 12 * h, kind = "neutral" },
        { t = base + 11 * h, kind = "faction", realm = "CAMWOW US2 Realm 2 PvP" },
        { t = base + 13 * h, kind = "faction", realm = "CAMWOW US2 Realm 1 Normal" },
        { t = base - 2 * h, kind = "faction" } }
    eq(R.scanAt(p, visits, "PvP", "faction", S.dayToTime, S.timeToDay), base + 11 * h)
    eq(R.scanAt(p, {}, "PvP", "faction", S.dayToTime, S.timeToDay), S.dayToTime(D + 1) - 1)
    eq(R.scanAt({ days = {} }, visits, "PvP", "faction", S.dayToTime, S.timeToDay), nil)
    eq(R.scanAt({ seenAt = 42, days = {} }, visits, "PvP", "faction", S.dayToTime, S.timeToDay), 42)
    eq(R.scanAt(p, { { t = base + 9 * h, kind = "faction" } }, "PvP", "faction", S.dayToTime, S.timeToDay), base + 9 * h, "no realm counts")
end)

test("reconcile: agreement against the nearest recent snapshot", function()
    local h = 3600
    local t0 = S.dayToTime(2000)
    local scan = t0 + 19 * h + 41 * 60
    local at = function(p) return p.seenAt end
    local book = { prices = {
        [1] = { now = 100, seenAt = scan, days = { { day = 2000 } } },
        [2] = { now = 200, seenAt = scan - 60, days = { { day = 2000 } } },
        [3] = { now = 1000, seenAt = scan - 120, days = { { day = 2000 } } },
        [4] = { now = 5, seenAt = scan - 86400, days = { { day = 1999 } } } } }
    local api = { latest = scan, recent = {
        { t = t0 + 19 * h + 24 * 60, min = { [1] = 100, [2] = 200, [3] = 1040, [4] = 5 } },
        { t = t0 + 15 * h, min = { [1] = 1 } } } }
    local a = R.agreement(book, api, at)
    eq(a.apiAt, t0 + 19 * h + 24 * 60); eq(a.scanAt, scan)
    eq(a.shared, 3); eq(a.exact, 2); eq(a.near, 3)
    local far = { latest = scan, recent = { { t = scan - 2 * h, min = { [1] = 100 } }, { t = scan + 2 * h, min = { [1] = 100 } } } }
    eq(R.agreement(book, far, at), nil, "2 hours away: no match figure")
    local at89 = R.agreement(book, { latest = scan, recent = { { t = scan + 89 * 60, min = { [1] = 100 } } } }, at)
    eq(at89 and at89.apiAt, scan + 89 * 60, "89 minutes: close enough")
    eq(R.agreement(book, { latest = scan, recent = { { t = scan - 91 * 60, min = { [1] = 100 } } } }, at), nil, "91 minutes: too far")
    eq(R.agreement(book, { latest = scan, recent = { { t = scan, min = { [9] = 1 } } } }, at), nil, "no shared items")
end)

local TR = require("trends")
local function grid(fill) local g = { p = {}, s = {}, n = {} } for i = 1, 168 do g.p[i], g.s[i], g.n[i] = false, false, false end if fill then fill(g) end return g end
local function cell(dow, hour) return dow * 24 + hour + 1 end

test("trends.parseReset: default, names, hours and bad text", function()
    local d = TR.parseReset(nil, function(h) return h - 3, 0 end)
    eq(d.dow, 1); eq(d.hour, 12)
    local d2, w2 = TR.parseReset("", function(h) return h - 3, 0 end)
    eq(d2.hour, 12); eq(w2, nil)
    local w = TR.parseReset("wed 9"); eq(w.dow, 2); eq(w.hour, 9)
    local s = TR.parseReset("Sunday 23:00"); eq(s.dow, 6); eq(s.hour, 23)
    local t = TR.parseReset("Tue 12:00"); eq(t.dow, 1); eq(t.hour, 12)
    local x, warn = TR.parseReset("x", function(h) return h - 3, 0 end)
    eq(x.dow, 1); eq(x.hour, 12)
    eq(warn, 'ah_reset: couldn\'t read "x"; using Tue 12:00. Write it like: ah_reset = Tue 12:00')
    local y, warn2 = TR.parseReset("x", function(h) return 7, -1 end)
    eq(y.dow, 0); eq(y.hour, 7)
    eq(warn2, 'ah_reset: couldn\'t read "x"; using Mon 07:00. Write it like: ah_reset = Tue 12:00',
        "the warning names the computed default")
end)

test("trends.parseReset: minutes must be :00", function()
    local warm = function(h) return h - 3, 0 end
    local a, wa = TR.parseReset("Tue 12", warm); eq(a.hour, 12); eq(wa, nil)
    local b, wb = TR.parseReset("Tue 12:00", warm); eq(b.hour, 12); eq(wb, nil)
    for _, bad in ipairs({ "Tue 12:30", "Tue 12:99", "Tue 12:0", "Tue 24" }) do
        local r, w = TR.parseReset(bad, warm)
        eq(r.dow, 1); eq(r.hour, 12)
        eq(w, 'ah_reset: couldn\'t read "' .. bad .. '"; using Tue 12:00. Write it like: ah_reset = Tue 12:00', bad)
    end
end)

test("trends.parseReset: default wraps the day", function()
    local d = TR.parseReset(nil, function(h) return 23, -1 end)
    eq(d.dow, 0); eq(d.hour, 23)
    local e = TR.parseReset(nil, function(h) return 1, 1 end)
    eq(e.dow, 2); eq(e.hour, 1)
    local f = TR.parseReset(nil, function(h) return 23, 6 - 7 end)
    eq(f.dow, 0)
end)

test("trends.familyWeek: weighted by units sold", function()
    local a = grid(function(g) local i = cell(0, 0); g.p[i], g.s[i], g.n[i] = 0.10, 9, 3 end)
    local b = grid(function(g) local i = cell(0, 0); g.p[i], g.s[i], g.n[i] = -0.10, 0, 3 end)
    local f = TR.familyWeek({ a, b })
    near(f.p[1], (0.10 * 10 - 0.10 * 1) / 11); eq(f.s[1], 9); eq(f.n[1], 6)
    eq(f.p[2], false); eq(f.members, 2)
end)

test("trends.familyWeek: members pool their observations; a cell fills at MIN_N in total", function()
    local a = grid(function(g) g.p[1], g.s[1], g.n[1] = 0.1, 1, 3 end)
    local low = grid(function(g) g.p[2], g.s[2], g.n[2] = 0.1, 1, 1 end)
    local f = TR.familyWeek({ a, low })
    eq(f.p[2], false, "a lone member with n=1 in a cell does not fill it")
    eq(f.enough, false); eq(f.members, 2, "a member with one numeric cell counts")
    local low2 = grid(function(g) g.p[2], g.s[2], g.n[2] = 0.3, 3, 1 end)
    local two = TR.familyWeek({ low, low2 })
    near(two.p[2], (0.1 * 2 + 0.3 * 4) / 6, "two members with n=1 each fill it")
    eq(two.s[2], 4); eq(two.n[2], 2); eq(two.members, 2)
    eq(two.p[1], false)
    local empty = grid(); empty.own = true
    local g = TR.familyWeek({ a, empty })
    eq(g.members, 1); eq(g.ownCount, 0)
    eq(TR.familyWeek({ empty, grid() }), nil)
    local lone = TR.familyWeek({ empty, low })
    eq(lone.members, 1); eq(lone.p[2], false)
    eq(TR.familyWeek({}), nil)
    local own = grid(function(g) g.p[1], g.s[1], g.n[1] = 0.1, 1, 3 end); own.own = true
    eq(TR.familyWeek({ own, empty }).ownCount, 1)
end)

test("trends.strip: best sell and buy runs", function()
    local g = grid(function(g)
        for h = 19, 22 do local i = cell(1, h); g.p[i], g.s[i], g.n[i] = 0.08, 1, 3 end
        for h = 4, 8 do local i = cell(6, h); g.p[i], g.s[i], g.n[i] = -0.07, 1, 3 end
    end)
    g.own = true
    local s = TR.strip(g)
    eq(#s.sell, 1); eq(s.sell[1].dow, 1); eq(s.sell[1].from, 19); eq(s.sell[1].to, 23)
    eq(#s.buy, 1); eq(s.buy[1].dow, 6); eq(s.buy[1].from, 4); eq(s.buy[1].to, 9)
end)

test("trends.strip: runs carry across midnight and the week's end", function()
    local g = grid(function(g)
        for _, c in ipairs({ cell(0, 23), cell(1, 0) }) do g.p[c], g.s[c], g.n[c] = 0.10, 1, 3 end
        for _, c in ipairs({ cell(6, 22), cell(6, 23), cell(0, 0) }) do g.p[c], g.s[c], g.n[c] = -0.10, 1, 3 end
    end)
    g.own = true
    local s = TR.strip(g)
    eq(#s.sell, 1); eq(s.sell[1].dow, 0); eq(s.sell[1].from, 23); eq(s.sell[1].to, 25)
    eq(#s.buy, 1); eq(s.buy[1].dow, 6); eq(s.buy[1].from, 22); eq(s.buy[1].to, 25)
    local all = grid(function(g) for i = 1, 168 do g.p[i], g.s[i], g.n[i] = 0.10, 1, 3 end end)
    all.own = true
    local w = TR.strip(all)
    eq(#w.sell, 1); eq(w.sell[1].dow, 0); eq(w.sell[1].from, 0); eq(w.sell[1].to, 168); eq(#w.buy, 0)
end)

test("trends.strip: a miss splits a run, and a lone hour is no run", function()
    local g = grid(function(g)
        for _, h in ipairs({ 19, 20, 22, 23 }) do local i = cell(1, h); g.p[i], g.s[i], g.n[i] = 0.08, 1, 3 end
        local lone = cell(3, 12); g.p[lone], g.s[lone], g.n[lone] = 0.2, 1, 3
    end)
    g.own = true
    local s = TR.strip(g)
    eq(#s.sell, 2); eq(s.sell[1].from, 19); eq(s.sell[1].to, 21); eq(s.sell[2].from, 22); eq(s.sell[2].to, 24)
    eq(#s.buy, 0)
    local one = grid(function(g) local i = cell(3, 12); g.p[i], g.s[i], g.n[i] = 0.2, 1, 3 end)
    one.own = true
    eq(#TR.strip(one).sell, 0)
end)

test("trends.strip: only the strongest STRIP_RUNS runs are kept", function()
    local g = grid(function(g)
        for d = 0, 3 do
            for _, h in ipairs({ 10, 11 }) do local i = cell(d * 2, h); g.p[i], g.s[i], g.n[i] = 0.05 + 0.01 * d, 1, 3 end
        end
    end)
    g.own = true
    local s = TR.strip(g)
    eq(#s.sell, 2); eq(s.sell[1].dow, 6); eq(s.sell[2].dow, 4)
end)

test("trends.strip: nil below the cell share", function()
    local g = grid(); g.own = false; g.enough = false
    eq(TR.strip(g), nil)
end)

test("utcHourToLocal: from this week's Tuesday (Monday first), so the offset is the current one", function()
    local Build = require("build")
    local tueJan, tueJul = 1704153600, 1720483200  -- Tue 2 Jan 2024 and Tue 9 Jul 2024, 00:00 UTC
    local function expect(tue, h)
        local t = os.date("*t", tue + h * 3600)
        return t.hour, t.wday - 3
    end
    for _, c in ipairs({ { tueJan + 5 * 3600, tueJan }, { tueJan - 86400 + 60, tueJan }, { tueJan + 5 * 86400, tueJan },
        { tueJul + 86400 + 7, tueJul } }) do
        local h, s = Build.utcHourToLocal(15, c[1])
        local eh, es = expect(c[2], 15)
        eq(h, eh); eq(s, es)
    end
    local h, s = Build.utcHourToLocal(15)
    truthy(h >= 0 and h <= 23 and s >= -1 and s <= 1, "now by default")
end)

test("trends.wanted: byte-identical regardless of insertion order", function()
    local f1 = { { key = "a", label = "A", ids = { 3, 1, 2 } } }
    local f2 = { { key = "a", label = "A", ids = { 2, 3, 1 } } }
    local x = TR.wanted(f1, { [9] = true, [5] = true }, { [5] = true, [7] = true }, { "PvP Horde", "PvP Neutral" })
    local y = TR.wanted(f2, { [5] = true, [9] = true }, { [7] = true, [5] = true }, { "PvP Neutral", "PvP Horde" })
    eq(x, y)
    local n = 0 for _ in x:gmatch("\n") do n = n + 1 end
    eq(n, 12)
end)

test("trends.wantedIds: families, owned and traded; wanted() lists the same ids", function()
    local w = TR.wantedIds({ { key = "a", ids = { 1, 2 } } }, { [3] = true }, { [4] = true })
    eq(w[1], true); eq(w[2], true); eq(w[3], true); eq(w[4], true); eq(w[5], nil)
end)

test("trends.page: only wanted items are embedded, with their spark", function()
    local api = { ["PvP Horde"] = { id = 113, key = "PvP Horde", latest = 5,
        items = { [1] = { now = 10, spark = { 1, 2 } }, [3] = { now = 7, spark = { 3 } } } } }
    local r = TR.page(api, { { key = "f", label = "F", ids = { 3 } } }, tostring, { dow = 1, hour = 12 }, "PvP Horde",
        { [1] = true })
    local h = r.houses["PvP Horde"]
    eq(h.items["1"].spark[2], 2); eq(h.items["3"], nil, "not wanted: no summary, no spark")
    eq(h.families[1].ids[1], 3, "family ids still list the house's members")
end)

test("trends.page: hourly only for held items, the best HOURLY_MAX sellers", function()
    local items = {}
    for id = 1, 5 do
        items[id] = { now = id, soldPerDay = id, spark = { id }, week = { own = true }, daily = { market = { id } },
            hourly = { min = { id }, market = { id } } }
    end
    local api = { ["PvP Horde"] = { id = 113, key = "PvP Horde", latest = 5, items = items } }
    eq(TR.C.HOURLY_MAX, 60)
    local saved = TR.C.HOURLY_MAX
    TR.C.HOURLY_MAX = 2
    local ok, r = pcall(TR.page, api, { { key = "f", label = "F", ids = { 1 } } }, tostring, { dow = 1, hour = 12 },
        "PvP Horde", { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }, { [2] = true, [3] = true, [4] = true })
    TR.C.HOURLY_MAX = saved
    assert(ok, r)
    local h = r.houses["PvP Horde"]
    eq(h.items["4"].hourly.min[1], 4, "held, best seller"); eq(h.items["3"].hourly.market[1], 3)
    eq(h.items["2"].hourly, nil, "held but past the cap")
    eq(h.items["1"].hourly, nil, "family member: no hourly"); eq(h.items["5"].hourly, nil, "traded only: no hourly")
    for id = 1, 5 do
        local e = h.items[tostring(id)]
        eq(e.daily.market[1], id); eq(e.spark[1], id); eq(e.week.own, true)
    end
    local none = TR.page(api, {}, tostring, { dow = 1, hour = 12 }, "PvP Horde", nil)
    eq(none.houses["PvP Horde"].items["5"].hourly, nil, "no held set: no hourly")
end)

test("trends.page: unknown items skipped, false holes survive", function()
    local week = { listings = {}, sold = {} }
    for i = 1, 168 do week.listings[i], week.sold[i] = false, false end
    local api = { ["PvP Horde"] = { id = 113, key = "PvP Horde", latest = 5, first = 1, snapshots = 2, ts = { 1, 2 },
        seriesDays = { "2026-01-01" }, sparkDays = { "2026-01-01" }, week = week,
        items = { [1] = { units = 1, listings = 1, now = 10, soldPerDay = 0, days = 3, spark = { false, 5 }, junk = 1 } } } }
    local fams = { { key = "f", label = "F", ids = { 1, 2 } } }
    local r = TR.page(api, fams, function(id) return id == 1 and "One" or nil end, { dow = 1, hour = 12 }, "PvP Horde")
    local h = r.houses["PvP Horde"]
    eq(h.id, 113); eq(h.items["1"].name, "One"); eq(h.items["2"], nil); eq(h.items["1"].junk, nil)
    eq(#h.families[1].ids, 1); eq(r.default, "PvP Horde"); eq(r.stripRule.MIN_N, 2)
    local js = U.json(h.items["1"].spark)
    eq(js, "[false,5]")
end)

test("Build.thisTuesday: the Tuesday of the Monday-first week", function()
    local Build = require("build")
    eq(Build.thisTuesday(1704708000), 1704758400, "Mon 8 Jan")
    eq(Build.thisTuesday(1704841200), 1704758400, "Tue 9 Jan 23:00")
    eq(Build.thisTuesday(1705273200), 1704758400, "Sun 14 Jan 23:00")
end)

test("trends.wanted: ids sort as numbers", function()
    local lines = {}
    for l in TR.wanted({}, { [9] = true, [10] = true, [100] = true }, {}, { "PvP Horde" }):gmatch("[^\n]+") do lines[#lines + 1] = l end
    eq(lines[1], "PvP Horde\t9"); eq(lines[2], "PvP Horde\t10"); eq(lines[3], "PvP Horde\t100")
end)

test("Build.writeAtomic: through a temp file, replacing an existing target", function()
    local Build = require("build")
    local path = os.tmpname()
    os.remove(path)
    truthy(Build.writeAtomic(path, "one\n")); eq(U.readFile(path), "one\n")
    truthy(Build.writeAtomic(path, "two\n")); eq(U.readFile(path), "two\n", "replaced")
    eq(io.open(path .. ".tmp", "rb"), nil, "no temp file left")
    os.remove(path)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        print("  ok   " .. t.name)
    else
        failed = failed + 1
        print("  FAIL " .. t.name .. "\n       " .. tostring(err))
    end
end
print(string.format("\n%d passed, %d failed", #tests - failed, failed))
if failed > 0 then os.exit(1) end
