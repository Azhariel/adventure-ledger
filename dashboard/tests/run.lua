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

test("inventory: valued at today's AH price, per location; unpriced items counted, not valued", function()
    local market = { prices = { [2592] = { now = 100, days = {} } }, vendor = {} }
    local inv = M.inventory({ bags = { [2592] = 3, [999] = 2 }, bank = { [2592] = 7 }, mail = {} }, market,
        function(id) return "I" .. id end)
    eq(inv.total, 1000); eq(inv.byLocation.bags, 300); eq(inv.byLocation.bank, 700)
    eq(inv.unpriced, 1); eq(inv.kinds, 2)
    eq(inv.items[1].name, "I2592"); eq(inv.items[1].count, 10); eq(inv.items[2].unit, nil)
    eq(M.inventory(nil, market, tostring).total, 0, "no Stockpile data")
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
    U.writeFile(acct .. "/SavedVariables/MuddyBoots.lua", 'MuddyBootsDB = { chars = { G1 = { name = "Hero", realm = "R", level = 12, money = 5000, lastSeen = 50 }, G2 = { name = "Alt", realm = "R", level = 3, money = 7, lastSeen = 40 } } }')
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
    local data = Build.data(wow, { names = { [2592] = "Wool Cloth" }, listDirs = listDirs,
        dropStats = Build.dropStats(wowDir()), repoAddons = repo })
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
    eq(r.moments[2][6], "Westfall Stew"); eq(r.moments[2][7], "450 XP")
    eq(r.moments[3][6], "Blue Thing"); eq(r.moments[4][2], "ki"); eq(r.moments[4][7], "")
    eq(r.moments[5][2], "out"); eq(r.moments[5][3], 0, "no position: map 0"); eq(r.moments[5][4], -1)
    eq(#M.replay(nil, nil).pts, 0)
    local p = M.replay(trail, S.parseLog({ "60|1|1|5|5|pl|Soren||22|SHAMAN|Tauren|Totem Pole|buff|Power Word: Fortitude",
        "61|1|1|5|5|pl|Grim||30|ROGUE|Human||enemy|", "62|1|1|5|5|pl|Dank||||||group|" })).moments
    eq(p[1][2], "pl"); eq(p[1][6], "Buffed Soren"); eq(p[1][7], "level 22, Shaman, <Totem Pole>, Power Word: Fortitude")
    eq(p[2][2], "pe"); eq(p[2][6], "Enemy player Grim"); eq(p[2][7], "level 30, Rogue")
    eq(p[3][6], "Grouped with Dank"); eq(p[3][7], "")
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

test("Neutral book: Ledger Link's saved prices read like Auctionator's; visits kept; nothing saved = nil", function()
    local env = { LedgerLinkDB = { neutralMode = "split", neutralLast = 500, visits = { { t = 400, kind = "neutral", zone = "Gadgetzan" } },
        neutral = { ["2447"] = { m = 40, t = 450, h = { ["2502"] = 60, ["2501"] = 45 }, l = { ["2502"] = 40 }, a = { ["2502"] = 9 } } } } }
    local n = S.neutral(env)
    eq(n.prices[2447].now, 40); eq(n.prices[2447].seenAt, 450)
    eq(n.prices[2447].days[1].day, 2501); eq(n.prices[2447].days[2].low, 40); eq(n.prices[2447].days[2].available, 9)
    eq(n.last, 500); eq(n.visits[1].zone, "Gadgetzan"); eq(n.mode, "split")
    eq(S.neutral(nil), nil); eq(S.neutral({ LedgerLinkDB = { enable = true } }), nil)
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
