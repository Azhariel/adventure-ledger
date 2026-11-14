-- Stats.lua: component tests of the pure logic (ISTQB techniques named per test)
return function(H)
    local ns = H.load({ "Stats.lua" })
    local S = ns.Stats
    local function g(npc, spawn) return "Creature-0-1-2-3-" .. npc .. "-" .. (spawn or "A") end
    local function obj(id, spawn) return "GameObject-0-1-2-3-" .. id .. "-" .. (spawn or "A") end

    H.test("ParseGUID: equivalence partitions creature / vehicle / object / player / invalid", function()
        local k, id = S.ParseGUID("Creature-0-4170-0-12-1726-00004F2A1B")
        H.eq(k, "creature"); H.eq(id, 1726)
        k, id = S.ParseGUID("Vehicle-0-4170-0-12-300-00004F2A1B")
        H.eq(k, "creature"); H.eq(id, 300)
        k, id = S.ParseGUID("GameObject-0-4170-0-12-1731-00004F2A1B")
        H.eq(k, "object"); H.eq(id, 1731)
        H.eq(S.ParseGUID("Player-4170-0ABCDEF1"), nil)
        H.eq(S.ParseGUID(nil), nil)
        H.eq(S.ParseGUID("nonsense"), nil)
    end)

    H.test("XP lines: pattern from the client string; rested, group bonus and thousands separators", function()
        local p = S.XPPattern("%s dies, you gain %d experience.")
        local name, xp = S.ParseXP("Defias Pillager dies, you gain 45 experience.", p)
        H.eq(name, "Defias Pillager"); H.eq(xp, 45)
        name, xp = S.ParseXP("Murloc Scout dies, you gain 90 experience. (+45 exp Rested bonus)", p)
        H.eq(name, "Murloc Scout"); H.eq(xp, 90)
        name, xp = S.ParseXP("Ogre Mage dies, you gain 1,250 experience. (+120 group bonus)", p)
        H.eq(name, "Ogre Mage"); H.eq(xp, 1250)
        H.eq(S.ParseXP("You gain 300 experience.", p), nil, "quest XP is not a kill")
        H.eq(S.ParseXP("Kobold Miner dies, you gain 12 experience.", nil), "Kobold Miner", "built-in fallback")
        H.eq(S.XPPattern(nil), nil)
    end)

    H.test("Wilson range: boundary values n = 0, k = 0, k = n, and a known value (31 of 100)", function()
        local lo, hi = S.Wilson(0, 0)
        H.eq(lo, 0); H.eq(hi, 1)
        lo, hi = S.Wilson(0, 20)
        H.eq(lo, 0); H.truthy(hi > 0.1 and hi < 0.2, "0 of 20 still allows up to ~16%")
        lo, hi = S.Wilson(20, 20)
        H.truthy(math.abs(hi - 1) < 1e-12, "20 of 20 reaches 100%"); H.truthy(lo > 0.8 and lo < 0.9)
        lo, hi = S.Wilson(31, 100)
        H.truthy(math.abs(lo - 0.2278) < 5e-4, "lo " .. lo)
        H.truthy(math.abs(hi - 0.4063) < 5e-4, "hi " .. hi)
    end)

    H.test("Kills basis: decision table (XP kills vs looted corpses)", function()
        local cases = {
            { kills = 10, looted = 6, n = 10, basis = "kills" },
            { kills = 6, looted = 6, n = 6, basis = "kills" },
            { kills = 4, looted = 6, n = 6, basis = "looted" }, -- grey kills give no XP line
            { kills = 0, looted = 3, n = 3, basis = "looted" },
            { kills = 0, looted = 0, n = 0, basis = "looted" },
        }
        for i, c in ipairs(cases) do
            local n, basis = S.Kills({ kills = c.kills, looted = c.looted })
            H.eq(n, c.n, "case " .. i); H.eq(basis, c.basis, "case " .. i)
        end
    end)

    H.test("Loot: state-based test of one corpse opened, reopened, partly looted and skinned", function()
        local db, corpses = S.NewDB(), {}
        local c = g(1726, "X1")
        -- first window: 2 Linen Cloth, coin
        H.eq(S.RecordLoot(db, corpses, { { guid = c, itemID = 2589, qty = 2 }, { guid = c, money = 37 } }, 10), 1)
        local m = db.mobs[1726]
        H.eq(m.looted, 1); H.eq(m.items[2589].drops, 1); H.eq(m.items[2589].qty, 2); H.eq(m.money, 37)
        -- the same window again (LOOT_READY then LOOT_OPENED): nothing changes
        S.RecordLoot(db, corpses, { { guid = c, itemID = 2589, qty = 2 }, { guid = c, money = 37 } }, 10)
        H.eq(m.looted, 1); H.eq(m.items[2589].qty, 2); H.eq(m.money, 37)
        S.Close(corpses, { c })
        -- reopened with the cloth left behind (bags were full): not a gather, nothing new
        S.RecordLoot(db, corpses, { { guid = c, itemID = 2589, qty = 2 } }, 20)
        H.eq(m.gather, nil); H.eq(m.items[2589].qty, 2)
        S.Close(corpses, { c })
        -- skinned: only new items -> gather, not a drop
        S.RecordLoot(db, corpses, { { guid = c, itemID = 2318, qty = 1 } }, 30)
        H.eq(m.items[2318], nil, "leather isn't a drop")
        H.eq(m.gather.opened, 1); H.eq(m.gather.items[2318].qty, 1)
        S.RecordLoot(db, corpses, { { guid = c, itemID = 2318, qty = 1 } }, 31)
        H.eq(m.gather.opened, 1, "the same skinning window twice")
    end)

    H.test("Loot: a bigger stack on reopening adds the difference, not a second drop", function()
        local db, corpses = S.NewDB(), {}
        local c = g(5, "Y")
        S.RecordLoot(db, corpses, { { guid = c, itemID = 7, qty = 1 } }, 0)
        S.RecordLoot(db, corpses, { { guid = c, itemID = 7, qty = 3 } }, 0)
        H.eq(db.mobs[5].items[7].drops, 1); H.eq(db.mobs[5].items[7].qty, 3)
    end)

    H.test("Loot: area loot splits one slot between corpses; objects count opens, not kills", function()
        local db, corpses = S.NewDB(), {}
        local a, b = g(100, "A"), g(100, "B")
        H.eq(S.RecordLoot(db, corpses, {
            { guid = a, itemID = 1, qty = 1 }, { guid = b, itemID = 1, qty = 2 },
            { guid = obj(1731), itemID = 2770, qty = 3 },
            { guid = "Player-1-ABC", itemID = 9, qty = 1 }, -- ignored
        }, 0), 3)
        H.eq(db.mobs[100].looted, 2); H.eq(db.mobs[100].items[1].drops, 2); H.eq(db.mobs[100].items[1].qty, 3)
        H.eq(db.objects[1731].opened, 1); H.eq(db.objects[1731].items[2770].qty, 3)
    end)

    H.test("Kills: unknown names wait, then move to the mob once its name is learned", function()
        local db = S.NewDB()
        H.eq(S.RecordKill(db, "Gnoll Brute", nil, 0), nil)
        S.RecordKill(db, "Gnoll Brute", nil, 10)
        H.eq(db.unnamed["Gnoll Brute"], 2)
        S.Learn(db, "Gnoll Brute", 474)
        H.eq(db.unnamed["Gnoll Brute"], nil); H.eq(db.mobs[474].kills, 2); H.eq(db.mobs[474].name, "Gnoll Brute")
        H.eq(S.RecordKill(db, "Gnoll Brute", nil, 20), 474, "known name from now on")
        H.eq(db.mobs[474].kills, 3)
    end)

    H.test("Pace: boundary values at the 120 s gap, another mob in between resets", function()
        local db = S.NewDB()
        S.RecordKill(db, "A", 1, 0)
        S.RecordKill(db, "A", 1, 120) -- counts (on the boundary)
        S.RecordKill(db, "A", 1, 241) -- 121 s: doesn't
        H.eq(db.mobs[1].paceN, 1); H.eq(db.mobs[1].paceSum, 120)
        S.RecordKill(db, "B", 2, 250)
        S.RecordKill(db, "A", 1, 260) -- previous kill was another mob
        H.eq(db.mobs[1].paceN, 1)
    end)

    H.test("Kills per hour: boundary at MIN_PACE gaps (4 none, 5 shown)", function()
        H.eq(S.KillsPerHour({ paceN = 4, paceSum = 160 }), nil)
        H.near(S.KillsPerHour({ paceN = 5, paceSum = 200 }), 90) -- 40 s per kill
        H.eq(S.KillsPerHour({}), nil)
    end)

    H.test("Value per kill: priced items, unpriced items and coin", function()
        local mob = { kills = 10, looted = 8, money = 500, items = { [1] = { drops = 3, qty = 4 }, [2] = { drops = 1, qty = 1 } } }
        local v, unpriced = S.Value(mob, function(id) return id == 1 and 100 or nil end)
        H.near(v, (500 + 4 * 100) / 10); H.eq(unpriced, 1)
        H.eq(S.Value({ kills = 0, looted = 0, items = {} }, nil), nil)
    end)

    H.test("Item rate: drops capped at the sample, per kill and range", function()
        local r = S.ItemRate({ kills = 0, looted = 2, items = { [5] = { drops = 3, qty = 6 } } }, 5)
        H.eq(r.drops, 2, "can't drop more often than corpses opened"); H.eq(r.n, 2); H.eq(r.basis, "looted")
        r = S.ItemRate({ kills = 100, looted = 70, items = { [5] = { drops = 31, qty = 40 } } }, 5)
        H.near(r.rate, 0.31); H.near(r.perKill, 0.4); H.eq(r.basis, "kills")
        H.eq(S.ItemRate({ kills = 4, looted = 4, items = {} }, 9).drops, 0)
    end)

    H.test("For an item: a sure 30% ranks above a lucky 2 of 3", function()
        local db = S.NewDB()
        db.mobs[1] = { name = "Lucky", kills = 3, looted = 3, items = { [9] = { drops = 2, qty = 2 } } }
        db.mobs[2] = { name = "Sure", kills = 100, looted = 90, items = { [9] = { drops = 30, qty = 30 } } }
        db.mobs[3] = { name = "None", kills = 50, looted = 50, items = {} }
        local list = S.ForItem(db, 9)
        H.eq(#list, 2); H.eq(list[1].name, "Sure"); H.eq(list[2].name, "Lucky")
    end)

    H.test("Best: boundary at MIN_KILLS, sorted by value, per hour only with a pace", function()
        local db = S.NewDB()
        db.mobs[1] = { name = "Four", kills = 4, looted = 4, money = 9999, items = {} }
        db.mobs[2] = { name = "Five", kills = 5, looted = 5, money = 100, items = {} }
        db.mobs[3] = { name = "Rich", kills = 10, looted = 10, money = 1000, items = {}, paceN = 5, paceSum = 200 }
        local list = S.Best(db, nil)
        H.eq(#list, 2); H.eq(list[1].name, "Rich"); H.eq(list[2].name, "Five")
        H.near(list[1].value, 100); H.near(list[1].perHour, 100 * 90); H.eq(list[2].perHour, nil)
    end)

    H.test("Compare with a published rate: below, inside and above your range", function()
        H.eq(S.Compare(10, 0.2, 0.4), "higher", "you get more than the 10% listed")
        H.eq(S.Compare(30, 0.2, 0.4), "matches")
        H.eq(S.Compare(50, 0.2, 0.4), "lower")
        H.eq(S.Compare(nil, 0, 1), nil)
    end)

    H.test("Kills needed and text: boundary values", function()
        H.eq(S.KillsFor(0.5, 10), 20); H.eq(S.KillsFor(0.3, 1), 4); H.eq(S.KillsFor(0, 5), nil); H.eq(S.KillsFor(1, 0), nil)
        H.eq(S.Percent(0.3125), "31%"); H.eq(S.Percent(0.1), "10%"); H.eq(S.Percent(0.045), "4.5%")
        H.eq(S.Percent(0.0042), "0.42%"); H.eq(S.Percent(0), "0%"); H.eq(S.Percent(nil), "?")
        H.eq(S.RateText({ rate = 0.31, lo = 0.228, hi = 0.406 }), "31% (23-41%)")
        H.eq(S.SampleText(1, "kills"), "1 kill"); H.eq(S.SampleText(12, "looted"), "12 looted corpses")
    end)

    H.test("Prune: corpses older than the limit are forgotten", function()
        local corpses = { a = { t = 0 }, b = { t = 500 } }
        S.Prune(corpses, 1000, 900)
        H.eq(corpses.a, nil); H.truthy(corpses.b)
    end)

    H.test("Learn: a name with no kills or loot makes no mob record (hovering vendors)", function()
        local db = S.NewDB()
        S.Learn(db, "Auctioneer Yarly", 15676)
        H.eq(db.mobs[15676], nil, "no record")
        H.eq(db.names["Auctioneer Yarly"], 15676, "name still remembered")
        H.eq(S.RecordKill(db, "Auctioneer Yarly", nil, 0), 15676, "a later kill finds it")
        H.eq(db.mobs[15676].kills, 1)
        H.eq(db.mobs[15676].name, "Auctioneer Yarly")
    end)

    H.test("Tidy: removes empty records only (equivalence partitions: empty, kills, looted, items, gather)", function()
        local db = S.NewDB()
        db.mobs[1] = { kills = 0, looted = 0, money = 0, items = {} }
        db.mobs[2] = { kills = 1, looted = 0, money = 0, items = {} }
        db.mobs[3] = { kills = 0, looted = 1, money = 0, items = {} }
        db.mobs[4] = { kills = 0, looted = 0, money = 0, items = { [5] = { drops = 1, qty = 1 } } }
        db.mobs[5] = { kills = 0, looted = 0, money = 0, items = {}, gather = { opened = 1, items = {} } }
        H.eq(S.Tidy(db), 1)
        H.eq(db.mobs[1], nil)
        for id = 2, 5 do H.truthy(db.mobs[id], "kept " .. id) end
    end)

    H.test("Nameless: mobs known by corpse ID only, sorted", function()
        local db = S.NewDB()
        S.RecordLoot(db, {}, { { guid = "Creature-0-1-2-3-11322-A", itemID = 1, qty = 1 },
            { guid = "Creature-0-1-2-3-11318-B", itemID = 1, qty = 1 } }, 0)
        db.mobs[7] = { name = "Named", kills = 1, looted = 0, money = 0, items = {} }
        local list = S.Nameless(db)
        H.eq(#list, 2); H.eq(list[1], 11318); H.eq(list[2], 11322)
    end)
end
