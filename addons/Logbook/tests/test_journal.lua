-- Journal.lua: the pure half (lines, counters, XP and money attribution, trail, parsers)
return function(H)
    local test, eq, truthy = H.test, H.eq, H.truthy
    local ns = {}
    assert(loadfile(H.root .. "Journal.lua"))("Logbook", ns)
    local J = ns.Journal

    test("a line has six fixed fields, escapes |, and drops trailing empty fields", function()
        eq(J.Line(1794000000, 5000, 1413, 5199, 2992, "mn", 168, "vendor", "Forked Tongue"),
            "1794000000|5000|1413|5199|2992|mn|168|vendor|Forked Tongue")
        eq(J.Line(1, nil, nil, nil, nil, "out"), "1|||||out")
        eq(J.Line(1, 2, 3, 4, 5, "ki", "A|B", nil, "Beast", nil, nil), "1|2|3|4|5|ki|A/B||Beast")
        eq(J.Line(1, 2.5, 3, 4, 5, "xp", 10), "1|2.500|3|4|5|xp|10")
    end)

    test("the log keeps at most MAX_LOG lines, dropping the oldest", function()
        local db = J.NewChar(1)
        local keep = J.MAX_LOG
        J.MAX_LOG = 40
        for i = 1, 41 do J.Add(db, tostring(i)) end
        J.MAX_LOG = keep
        eq(#db.log, 39); eq(db.log[1], "3"); eq(db.log[#db.log], "41")
    end)

    test("played is filled in for lines logged before it was known", function()
        local db = J.NewChar(1)
        db.log = { "100|90|1|2|3|xp|5", "200||1|2|3|in|login", "260|||||zo|Mulgore" }
        J.BackfillPlayed(db, 2, function(t) return 1000 + t end)
        eq(db.log[1], "100|90|1|2|3|xp|5"); eq(db.log[2], "200|1200|1|2|3|in|login"); eq(db.log[3], "260|1260||||zo|Mulgore")
    end)

    test("counters: total and per level; records keep the maximum", function()
        local c = {}
        J.Count(c, "kill", 100, 12); J.Count(c, "kill", 50, 13); J.Count(c, "kill", 5)
        eq(c.kill, 155); eq(c["kill:12"], 100); eq(c["kill:13"], 50)
        J.Max(c, "longest", 30); J.Max(c, "longest", 10); eq(c.longest, 30)
    end)

    test("baseline keeps MuddyBoots' numeric counters and first record", function()
        local b = J.Baseline({ char = { first = { t = 5, level = 11 } },
            counts = { xp = { all = 10, ["kill:11"] = 4 }, fights = { n = 2, bestFight = {} } } }, 99)
        eq(b.from, "MuddyBoots"); eq(b.at, 99); eq(b.counts.xp.all, 10); eq(b.counts.xp["kill:11"], 4)
        eq(b.counts.fights.n, 2); eq(b.counts.fights.bestFight, nil); eq(b.first.level, 11)
        eq(J.Baseline(nil, 1), nil); eq(J.Baseline({}, 1), nil)
    end)

    test("XP: kill hints take their amount, the rest goes to the open hint, then the fallback", function()
        local p = J.NewPending()
        J.Hint(p, { source = "kill", amount = 120, detail = "Boar", rested = 60 }, 10)
        J.Hint(p, { source = "kill", amount = 80, detail = "Boar" }, 10)
        J.Delta(p, 250)
        local out = J.FlushXP(p, 10.3)
        eq(#out, 3); eq(out[1].amount, 120); eq(out[1].rested, 60); eq(out[2].amount, 80)
        eq(out[3].amount, 50); eq(out[3].source, "other")
        J.Delta(p, 70)
        eq(J.FlushXP(p, 11, "dungeon")[1].source, "dungeon")
    end)

    test("XP: a hint that comes before its change waits; stale hints are dropped", function()
        local p = J.NewPending()
        J.Hint(p, { source = "quest", amount = 900, detail = "A New Plague" }, 10)
        eq(#J.FlushXP(p, 10.4), 0)
        J.Delta(p, 900)
        local out = J.FlushXP(p, 10.8)
        eq(out[1].source, "quest"); eq(out[1].detail, "A New Plague")
        J.Hint(p, { source = "kill", amount = 5 }, 10)
        J.FlushXP(p, 20)
        eq(#p.hints, 0)
    end)

    test("money: an exact hint beats a same-direction one, which beats the open window", function()
        local hints = { { source = "vendor", sign = 1, at = 1 }, { source = "quest", amount = 500, at = 1 } }
        local src = J.MoneySource(500, hints, { merchant = true }, 1)
        eq(src, "quest")
        eq((J.MoneySource(30, hints, { merchant = true }, 1)), "vendor")
        eq((J.MoneySource(30, hints, { merchant = true }, 1)), "vendor", "hints are used once")
        eq((J.MoneySource(-30, {}, { auction = true, merchant = true }, 1)), "auction")
        eq((J.MoneySource(-5, {}, {}, 1)), "other")
        local repair = { { source = "repair", sign = -1, at = 1 } }
        eq((J.MoneySource(40, repair, {}, 1)), "other", "a hint for spending doesn't explain a gain")
    end)

    test("trail: points per map in chunks, small moves skipped, a new map starts a chunk", function()
        local tr = { chunks = {} }
        truthy(J.TrailPoint(tr, 100, 1413, 5000, 5000))
        eq(J.TrailPoint(tr, 105, 1413, 5003, 5004), false)
        truthy(J.TrailPoint(tr, 110, 1413, 5100, 5000, "d"))
        truthy(J.TrailPoint(tr, 120, 1412, 100, 200))
        eq(#tr.chunks, 2); eq(tr.chunks[1].d, "0,5000,5000,w;10,5100,5000,d"); eq(tr.chunks[1].n, 2)
        J.TrailForSave(tr)
        eq(tr.chunks[1].lx, nil)
    end)

    test("skills: only changes are reported", function()
        local cache = {}
        eq(#J.SkillChanges(cache, { { name = "Tailoring", rank = 79, max = 150 } }), 1)
        eq(#J.SkillChanges(cache, { { name = "Tailoring", rank = 79, max = 150 } }), 0)
        eq(#J.SkillChanges(cache, { { name = "Tailoring", rank = 80, max = 150 } }), 1)
    end)

    test("fights: count, seconds, longest; low health and close calls", function()
        local counts = J.Tidy({}).counts
        J.EndFight(counts, { start = 10, minHealth = 0.5 }, 40)
        J.EndFight(counts, { start = 50, minHealth = 0.08 }, 60)
        J.EndFight(counts, { start = 70, minHealth = 0 }, 75, true)
        eq(counts.fights.n, 3); eq(counts.fights.sec, 45); eq(counts.fights.longest, 30); eq(counts.fights.died, 1)
        eq(counts.deaths.lowHealth, 2); eq(counts.deaths.closeCalls, 1)
    end)

    test("activity: afk and death first, then combat, moving, dungeon, town, idle", function()
        eq(J.Activity({ afk = true, combat = true }), "afk")
        eq(J.Activity({ dead = true, combat = true }), "dead")
        eq(J.Activity({ combat = true, moving = true }), "combat")
        eq(J.Activity({ moving = true }), "travel")
        eq(J.Activity({ instance = true }), "dungeon")
        eq(J.Activity({ resting = true }), "town")
        eq(J.Activity({}), "idle")
    end)

    test("parsers: kill XP with rested bonus, discovery, loot lines, links, GUIDs, mail subjects", function()
        local kill = J.FormatToPattern("%s dies, you gain %d experience.")
        local n, xp, rested = J.ParseKillXP("Bristleback Hunter dies, you gain 118 experience. (+59 exp Rested bonus)", kill)
        eq(n, "Bristleback Hunter"); eq(xp, 118); eq(rested, 59)
        n, xp, rested = J.ParseKillXP("Kobold Vermin dies, you gain 45 experience.", nil)
        eq(n, "Kobold Vermin"); eq(xp, 45); eq(rested, nil)
        local z, dxp = J.ParseDiscover("Discovered Crusader Outpost: 70 experience gained", J.FormatToPattern("Discovered %s: %d experience gained"))
        eq(z, "Crusader Outpost"); eq(dxp, 70)
        local link = "|cff1eff00|Hitem:4576::::::::|h[Light Bow]|h|r"
        local l, c, how = J.ParseLoot("You receive loot: " .. link .. "x3.", { { J.FormatToPattern("You receive loot: %sx%d."), "loot", true } })
        eq(l, link); eq(c, 3); eq(how, "loot")
        l, c, how = J.ParseLoot("You create: " .. link .. ".", nil)
        eq(c, 1); eq(how, "created")
        local id, name, q = J.ParseItemLink(link)
        eq(id, 4576); eq(name, "Light Bow"); eq(q, 2)
        local kind, npc = J.ParseGUID("Creature-0-5250-0-27-1866-00002A8D6B")
        eq(kind, "creature"); eq(npc, 1866)
        local item, cnt = J.ParseMailSubject("Auction successful: Wool Cloth (20)")
        eq(item, "Wool Cloth"); eq(cnt, 20)
        eq(J.ItemQty("Wool Cloth", 20), "Wool Cloth x20"); eq(J.ItemQty("Tigerseye", 1), "Tigerseye")
    end)
end
