-- Core.lua against a stubbed client: what each game event writes
return function(H)
    local test, eq, truthy = H.test, H.eq, H.truthy
    local W = require("wow_mock")
    local function boot(opts) return W.boot(H.root, opts) end

    test("login: identity, a session, the zone, played time asked for quietly and backfilled", function()
        local ns, st = boot()
        local c = LogbookCharDB.char
        eq(c.name, "Azhariel"); eq(c.class, "PRIEST"); eq(c.race, "Scourge"); eq(c.level, 20)
        eq(c.guid, "Player-6800-00A90C3E"); eq(LogbookCharDB.since, st.now)
        eq(#LogbookCharDB.sessions, 1); eq(LogbookCharDB.sessions[1].how, "login")
        eq(W.rows("in")[1].args[1], "login"); eq(W.rows("zo")[1].args[1], "The Barrens")
        eq(st.playedAsked, 1)
        ChatFrame_DisplayTimePlayed(); eq(st.playedShown, nil, "Logbook's request doesn't print")
        st.now, st.clock = st.now + 10, st.clock + 10
        W.fire("TIME_PLAYED_MSG", 50010, 20)
        eq(W.rows("in")[1].played, 50000, "the login line gets the played time")
        eq(LogbookCharDB.sessions[1].played0, 50000)
        ChatFrame_DisplayTimePlayed(); eq(st.playedShown, 1, "a /played you type still prints")
        eq(LogbookDB.chars["Player-6800-00A90C3E"].played, 50010)
    end)

    test("a /reload starts a session marked reload", function()
        boot({ reload = true })
        eq(LogbookCharDB.sessions[1].how, "reload")
    end)

    test("first login copies MuddyBoots' counters once", function()
        boot({ muddy = { char = { first = { t = 5, level = 11 } }, counts = { xp = { all = 900, kill = 600 } } } })
        eq(LogbookCharDB.baseline.counts.xp.all, 900); eq(LogbookCharDB.baseline.first.level, 11)
        local saved = LogbookCharDB
        boot({ charDB = saved, muddy = { counts = { xp = { all = 5 } } } })
        eq(LogbookCharDB.baseline.counts.xp.all, 900, "not copied again")
    end)

    test("a kill: ki line with the mob from your target, XP with rested bonus", function()
        local _, st = boot()
        st.units.target = { name = "Bristleback Hunter", guid = "Creature-0-1-2-3-3258-0000", hostile = true,
            type = "Humanoid", level = 22 }
        W.fire("PLAYER_TARGET_CHANGED")
        W.fire("CHAT_MSG_COMBAT_XP_GAIN", "Bristleback Hunter dies, you gain 118 experience. (+59 exp Rested bonus)")
        st.xp = st.xp + 118
        W.fire("PLAYER_XP_UPDATE", "player")
        W.runTimers()
        local ki = W.rows("ki")[1]
        eq(ki.args[1], "Bristleback Hunter"); eq(ki.args[2], "3258"); eq(ki.args[3], "Humanoid"); eq(ki.args[5], "118")
        eq(ki.args[6], "22")
        local xp = W.rows("xp")[1]
        eq(xp.args[1], "118"); eq(xp.args[2], "kill"); eq(xp.args[3], "Bristleback Hunter")
        local c = LogbookCharDB.counts.xp
        eq(c.kill, 118); eq(c["kill:20"], 118); eq(c.rested, 59); eq(c.all, 118)
    end)

    test("XP across a level-up counts what finished the old level plus the new", function()
        local _, st = boot({ xp = 9900, xpMax = 10000 })
        st.level, st.xp, st.xpMax = 21, 150, 11000
        W.fire("PLAYER_LEVEL_UP", 21)
        W.fire("PLAYER_XP_UPDATE", "player")
        W.runTimers()
        eq(W.rows("xp")[1].args[1], "250"); eq(W.rows("lv")[1].args[1], "21")
        eq(LogbookCharDB.snap[21].money, 1000); eq(LogbookCharDB.snap[21].zone, "The Barrens")
        truthy(W.rows("ge")[1].args[2]:find("2489", 1, true), "gear at the ding")
    end)

    test("unexplained XP in a dungeon is dungeon XP", function()
        local _, st = boot()
        st.instance, st.instanceType, st.instanceName = true, "party", "Wailing Caverns"
        W.fire("ZONE_CHANGED_NEW_AREA")
        st.xp = st.xp + 300
        W.fire("PLAYER_XP_UPDATE", "player")
        W.runTimers()
        eq(W.rows("xp")[1].args[2], "dungeon")
        eq(W.rows("ie")[1].args[1], "Wailing Caverns")
        st.instance, st.instanceType, st.now = false, "none", st.now + 1800
        W.fire("ZONE_CHANGED_NEW_AREA")
        eq(W.rows("il")[1].args[2], "1800")
    end)

    test("a quest turn-in: qt line, its XP and its money", function()
        local _, st = boot()
        st.quests[3] = { "Stolen Silver", 21 }
        W.fire("QUEST_ACCEPTED", 3, 3281)
        eq(W.rows("qa")[1].args[2], "Stolen Silver"); eq(W.rows("qa")[1].args[3], "21")
        W.fire("QUEST_TURNED_IN", 3281, 1350, 1000)
        st.xp, st.money = st.xp + 1350, st.money + 1000
        W.fire("PLAYER_XP_UPDATE", "player"); W.fire("PLAYER_MONEY")
        W.runTimers()
        local qt = W.rows("qt")[1]
        eq(qt.args[1], "3281"); eq(qt.args[2], "1350"); eq(qt.args[3], "1000"); eq(qt.args[4], "Stolen Silver")
        eq(W.rows("xp")[1].args[2], "quest"); eq(W.rows("mn")[1].args[2], "quest")
        eq(LogbookCharDB.counts.quests.done, 1)
        W.fire("QUEST_REMOVED", 3281); W.runTimers()
        eq(#W.rows("qx"), 0, "turned in, not abandoned")
        st.quests[4] = { "Wanted: Lok'Tar", 25 }
        W.fire("QUEST_ACCEPTED", 4, 900)
        W.fire("QUEST_REMOVED", 900); W.runTimers()
        eq(W.rows("qx")[1].args[2], "Wanted: Lok'Tar"); eq(LogbookCharDB.counts.quests.abandoned, 1)
    end)

    test("retail quest and profession API: quest ID only, GetProfessions with gaps", function()
        local _, st = boot()
        C_QuestLog = { GetLogIndexForQuestID = function() return 2 end,
            GetInfo = function(i) return i == 2 and { title = "Raptor Thieves", level = 18 } or nil end }
        W.fire("QUEST_ACCEPTED", 869)
        eq(W.rows("qa")[1].args[1], "869"); eq(W.rows("qa")[1].args[2], "Raptor Thieves"); eq(W.rows("qa")[1].args[3], "18")
        GetNumSkillLines, GetSkillLineInfo = nil, nil
        GetProfessions = function() return 1, nil, nil, 3 end
        GetProfessionInfo = function(i) if i == 1 then return "Tailoring", 1, 90, 150 elseif i == 3 then return "Fishing", 1, 40, 75 end end
        W.fire("SKILL_LINES_CHANGED")
        local sk = W.rows("sk")
        eq(#sk, 2); eq(sk[1].args[1], "Tailoring"); eq(sk[2].args[1], "Fishing")
        C_QuestLog, GetProfessions, GetProfessionInfo = nil, nil, nil
    end)

    test("retail windows: AH item from mail is bought; a vendor after the mailbox is vendor, even without MAIL_CLOSED", function()
        local _, st = boot()
        GetMerchantItemInfo = nil
        C_MerchantFrame = { GetItemInfo = function(i) return { name = "Fine Thread", price = 100 } end }
        W.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17)
        st.inbox[1] = { sender = "Horde Auction House", subject = "Auction won: Cerulean Dye (2)",
            invoice = { kind = "buyer", item = "Cerulean Dye", player = "Kazuh Spellweaver" },
            items = { { "Cerulean Dye", 2 } } }
        TakeInboxItem(1, 1)
        W.fire("CHAT_MSG_LOOT", "You receive item: " .. W.link(249409, "Cerulean Dye", "1eff00") .. "x2.")
        eq(W.rows("ma")[1].args[1], "invoice"); eq(W.rows("ma")[1].args[2], "Kazuh Spellweaver")
        eq(W.rows("lo")[1].args[4], "bought")
        st.clock = st.clock + 30
        W.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5) -- the merchant; no MAIL_CLOSED ever came
        BuyMerchantItem(3, 1)
        st.money = st.money - 100; W.fire("PLAYER_MONEY")
        W.fire("CHAT_MSG_LOOT", "You receive item: " .. W.link(2321, "Fine Thread") .. ".")
        W.runTimers()
        local mn = W.rows("mn")
        eq(mn[1].args[2], "vendor"); eq(mn[1].args[3], "Fine Thread")
        eq(W.rows("lo")[2].args[4], "bought")
        W.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)
        st.clock = st.clock + 30
        st.money = st.money - 50; W.fire("PLAYER_MONEY"); W.runTimers()
        eq(W.rows("mn")[2].args[2], "other", "nothing open any more")
    end)

    test("money by source: loot line, vendor sale with the item, flight, repair", function()
        local _, st = boot()
        st.money = st.money + 25; W.fire("PLAYER_MONEY"); W.fire("CHAT_MSG_MONEY", "You loot 25 Copper"); W.runTimers()
        W.fire("MERCHANT_SHOW")
        st.bags = { ["0:1"] = { count = 3, link = W.link(5051, "Forked Tongue") } }
        C_Container.UseContainerItem(0, 1)
        st.money = st.money + 168; W.fire("PLAYER_MONEY"); W.runTimers()
        RepairAllItems()
        st.money = st.money - 40; W.fire("PLAYER_MONEY"); W.runTimers()
        W.fire("MERCHANT_CLOSED")
        st.clock = st.clock + 10
        W.fire("TAXIMAP_OPENED"); TakeTaxiNode(4); W.fire("TAXIMAP_CLOSED")
        st.money = st.money - 90; W.fire("PLAYER_MONEY"); W.runTimers()
        local mn = W.rows("mn")
        eq(mn[1].args[2], "loot")
        eq(mn[2].args[1], "168"); eq(mn[2].args[2], "vendor"); eq(mn[2].args[3], "Forked Tongue x3")
        eq(mn[3].args[2], "repair"); eq(LogbookCharDB.counts.character.repairCopper, 40)
        eq(mn[4].args[2], "flight"); eq(mn[4].args[3], "Node4")
    end)

    test("auction house: a post's deposit, a sale's invoice, an expiry", function()
        local _, st = boot()
        W.fire("AUCTION_HOUSE_SHOW")
        C_AuctionHouse.PostCommodity({ id = 2592, name = "Wool Cloth" }, 1, 20, 50)
        st.money = st.money - 60; W.fire("PLAYER_MONEY"); W.runTimers()
        W.fire("AUCTION_HOUSE_CLOSED")
        local ah = W.rows("ah")[1]
        eq(ah.args[1], "post"); eq(ah.args[2], "60"); eq(ah.args[3], "Wool Cloth x20")
        eq(W.rows("mn")[1].args[2], "auction")
        st.clock = st.clock + 10
        W.fire("MAIL_SHOW")
        st.inbox[1] = { sender = "Horde Auction House", subject = "Auction successful: Wool Cloth (20)", money = 950,
            invoice = { kind = "seller", item = "Wool Cloth", player = "Buyerguy" } }
        TakeInboxMoney(1)
        st.money = st.money + 950; W.fire("PLAYER_MONEY"); W.runTimers()
        local ma = W.rows("ma")[1]
        eq(ma.args[1], "invoice"); eq(ma.args[2], "Buyerguy"); eq(ma.args[3], "950"); eq(ma.args[4], "Wool Cloth x20")
        eq(W.rows("ah")[2].args[1], "sold")
        local mn = W.rows("mn")[2]
        eq(mn.args[2], "auction"); eq(mn.args[3], "Wool Cloth x20")
        W.fire("CHAT_MSG_SYSTEM", "Your auction of Tigerseye has expired.")
        eq(W.rows("ah")[3].args[1], "expired"); eq(W.rows("ah")[3].args[3], "Tigerseye")
        eq(LogbookCharDB.counts.auction.post, 1); eq(LogbookCharDB.counts.auction.sold, 1)
    end)

    test("loot: picked up, made (with the profession), from mail, gathered", function()
        local _, st = boot()
        local bow = W.link(4576, "Light Bow", "1eff00")
        W.fire("CHAT_MSG_LOOT", "You receive loot: " .. bow .. ".")
        st.tradeSkill = "Tailoring"; W.fire("TRADE_SKILL_SHOW")
        W.fire("CHAT_MSG_LOOT", "You create: " .. W.link(4240, "Woolen Bag") .. ".")
        W.fire("MAIL_SHOW")
        W.fire("CHAT_MSG_LOOT", "You receive item: " .. W.link(2592, "Wool Cloth") .. "x5.")
        W.fire("MAIL_CLOSED"); st.clock = st.clock + 10
        st.spells[2366] = "Herbalism" -- Forever's name for the herb-picking cast
        st.spells[1] = "LOGINEFFECT"
        W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 1)
        W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2366)
        W.fire("LOOT_OPENED")
        W.fire("CHAT_MSG_LOOT", "You receive loot: " .. W.link(765, "Silverleaf") .. "x2.")
        W.fire("LOOT_CLOSED")
        local lo = W.rows("lo")
        eq(lo[1].args[1], "4576"); eq(lo[1].args[2], "2"); eq(lo[1].args[4], "loot"); eq(lo[1].args[5], "Light Bow")
        eq(lo[2].args[4], "made"); eq(lo[3].args[4], "mail"); eq(lo[3].args[6], "5")
        local p = LogbookCharDB.counts.prof
        eq(p["made|Woolen Bag|Tailoring"], 1); eq(p["gathered|Silverleaf|Herbalism"], 2)
        eq(W.rows("ga")[1].args[1], "Herbalism"); eq(LogbookCharDB.counts.spells["Herbalism"], 1)
        eq(LogbookCharDB.counts.spells.LOGINEFFECT, nil)
    end)

    test("skills: professions listed at login, then a skill-up line", function()
        local _, st = boot({ skills = { { "Tailoring", 79, 150 }, { "Professions", 0, 0, header = true } } })
        local sk = W.rows("sk")
        eq(#sk, 1); eq(sk[1].args[1], "Tailoring"); eq(sk[1].args[2], "79"); eq(sk[1].args[3], "150")
        W.fire("CHAT_MSG_SKILL", "Your skill in Tailoring has increased to 80.")
        eq(W.rows("sk")[2].args[2], "80"); eq(W.rows("sk")[2].args[3], "150")
    end)

    test("a fight, a death to your target, and the run back", function()
        local _, st = boot()
        st.units.target = { name = "Dalaran Conjuror", guid = "Creature-0-1-2-3-1915-0000", hostile = true, level = 17,
            class = "elite" }
        st.combat = true
        W.fire("PLAYER_REGEN_DISABLED")
        st.hp = 5; W.fire("UNIT_HEALTH", "player")
        st.dead = true
        W.fire("PLAYER_DEAD")
        st.combat, st.clock = false, st.clock + 20
        W.fire("PLAYER_REGEN_ENABLED")
        local de = W.rows("de")[1]
        eq(de.args[1], "Dalaran Conjuror"); eq(de.args[2], "1915"); eq(de.args[5], "world"); eq(de.args[7], "17")
        eq(de.args[8], "elite")
        local c = LogbookCharDB.counts
        eq(c.deaths.total, 1); eq(c.deaths.world, 1); eq(c.fights.n, 1); eq(c.fights.died, 1)
        eq(c.deaths.lowHealth, 1); eq(c.deaths.closeCalls, nil, "you died: not a close call")
        st.dead, st.ghost = false, true; W.fire("PLAYER_ALIVE")
        st.ghost = false; W.fire("PLAYER_UNGHOST")
        eq(c.deaths["revive.corpse"], 1)
    end)

    test("the tick: activity per level, distance, trail; logout closes the session", function()
        local _, st = boot()
        st.ticker()
        st.now, st.speed, st.world, st.x = st.now + 5, 7, { 130, 200 }, 0.52
        st.ticker()
        st.now, st.speed, st.afk = st.now + 5, 0, true
        st.ticker()
        local c = LogbookCharDB.counts
        eq(c.activity.travel, 5); eq(c.activity["travel:20"], 5); eq(c.activity.afk, 5)
        eq(c.distance.foot, 30)
        eq(#LogbookCharDB.trail.chunks, 1); eq(LogbookCharDB.trail.chunks[1].n, 2)
        W.fire("PLAYER_LOGOUT")
        eq(W.rows("out")[1].kind, "out")
        eq(LogbookCharDB.sessions[1].last, st.now)
        eq(LogbookCharDB.trail.chunks[1].lx, nil)
        eq(LogbookDB.chars["Player-6800-00A90C3E"].money, 1000)
    end)

    test("secret values and missing functions leave fields empty, never an error", function()
        local _, st = boot()
        st.secrets["Secret Mob dies, you gain 10 experience."] = true
        W.fire("CHAT_MSG_COMBAT_XP_GAIN", "Secret Mob dies, you gain 10 experience.")
        eq(#W.rows("ki"), 0)
        C_Map = nil
        W.fire("ZONE_CHANGED_NEW_AREA")
        st.ticker()
        UnitPosition = nil
        st.ticker()
        W.fire("PLAYER_LOGOUT")
        eq(W.rows("out")[1].map, nil)
    end)

    test("damage meter: each finished fight read once, after combat, with the real killer", function()
        local old = { id = 3, seconds = 9, [0] = { sources = { { isLocalPlayer = true, totalAmount = 50 } } } }
        local _, st = boot({ meterSessions = { old } })
        eq(LogbookCharDB.meter.available, true)
        st.spells[585] = "Smite"
        st.combat = true
        W.fire("PLAYER_REGEN_DISABLED")
        st.meter.sessions[#st.meter.sessions + 1] = { id = 4, seconds = 12.4,
            [0] = { sources = { { isLocalPlayer = true, totalAmount = 360 } }, spells = { { spellID = 585, totalAmount = 360 } } },
            [7] = { sources = { { isLocalPlayer = true, totalAmount = 200 } },
                spells = { { spellID = 0, totalAmount = 200, creatureName = "Razormane Mystic", isDeadly = true } } },
            [2] = { sources = {} }, [10] = { sources = { { name = "Razormane Mystic" }, { name = "Razormane Hunter" } } } }
        st.combat = false
        W.fire("PLAYER_REGEN_ENABLED")
        W.runTimers()
        local fi = W.rows("fi")
        eq(#fi, 1, "the session from before login isn't counted")
        eq(fi[1].args[1], "12"); eq(fi[1].args[2], "360"); eq(fi[1].args[3], "200"); eq(fi[1].args[4], "0")
        eq(fi[1].args[5], "2"); eq(fi[1].args[6], "Razormane Mystic"); eq(fi[1].args[8], "Razormane Mystic")
        eq(fi[1].args[9], "Melee")
        local c = LogbookCharDB.counts
        eq(c.damage.done, 360); eq(c.damage["done:20"], 360); eq(c.damageBy.Smite, 360)
        eq(c.damageFrom["Razormane Mystic"], 200); eq(c.damage.bestDps, 30)
        W.fire("PLAYER_REGEN_DISABLED"); W.fire("PLAYER_REGEN_ENABLED"); W.runTimers()
        eq(#W.rows("fi"), 1, "a session is read once")
    end)

    test("damage meter: back in combat before the read waits for the next fight; secrets are skipped", function()
        local _, st = boot()
        local me = function(n) return { sources = { { isLocalPlayer = true, totalAmount = n } } } end
        st.meter.sessions[1] = { id = 1, seconds = 10, [0] = me(100) }
        W.fire("PLAYER_REGEN_DISABLED"); W.fire("PLAYER_REGEN_ENABLED")
        st.combat = true
        W.runTimers()
        eq(#W.rows("fi"), 0, "still in combat: secret, not read")
        st.meter.sessions[2] = { id = 2, seconds = 10, [0] = me(80) }
        st.secrets[80] = true
        st.combat = false
        W.fire("PLAYER_REGEN_ENABLED"); W.runTimers()
        eq(#W.rows("fi"), 1, "the first fight now; the second's secret damage reads as nothing")
        eq(LogbookCharDB.counts.damage.done, 100)
        C_DamageMeter = nil
        W.fire("PLAYER_REGEN_DISABLED"); W.fire("PLAYER_REGEN_ENABLED"); W.runTimers()
    end)

    test("damage meter missing: noted at login, fights still counted", function()
        local st = W.install()
        C_DamageMeter = nil
        local ns = {}
        for _, f in ipairs({ "Journal.lua", "Core.lua" }) do assert(loadfile(H.root .. f))("Logbook", ns) end
        W.fire("PLAYER_LOGIN"); W.fire("PLAYER_ENTERING_WORLD", true, false)
        eq(LogbookCharDB.meter.available, false)
        W.fire("PLAYER_REGEN_DISABLED"); W.fire("PLAYER_REGEN_ENABLED")
        eq(LogbookCharDB.counts.fights.n, 1)
        SlashCmdList.LOGBOOK()
        truthy(st.printed[#st.printed]:find("unavailable"))
    end)
end
