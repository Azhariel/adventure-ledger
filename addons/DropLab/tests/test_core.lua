-- Core.lua: integration tests with fake WoW, Make or Buy and WhereToFarm APIs (ISTQB techniques named per test)
return function(H)
    local W = require("wow_mock")
    local LINEN, WOOL = 2589, 2592

    local function chatHas(text)
        for _, line in ipairs(W.chat) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    -- Kill a mob: it dies as your target, the XP line arrives, then you loot it
    local function killAndLoot(frame, npcID, spawn, name, slots)
        local guid = W.guid(npcID, spawn)
        W.state.units.target = { guid = guid, name = name, dead = true }
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", name .. " dies, you gain 45 experience.")
        if slots then
            for _, s in ipairs(slots) do
                s.sources = { guid, s.qty or 1 }
            end
            W.loot(frame, slots)
        end
        return guid
    end

    H.test("Use case: kill and loot a camp; kills, drops, coin and name are recorded", function()
        local ns, frame = W.boot(H)
        for i = 1, 3 do
            W.state.clock = i * 30
            killAndLoot(frame, 1726, "S" .. i, "Defias Pillager", {
                { link = W.link(LINEN), qty = i == 2 and 2 or 1 },
                { money = true, qty = 25 },
            })
        end
        killAndLoot(frame, 1726, "S4", "Defias Pillager", nil) -- killed, never looted
        local m = DropLabDB.mobs[1726]
        H.eq(m.name, "Defias Pillager"); H.eq(m.kills, 4); H.eq(m.looted, 3)
        H.eq(m.items[LINEN].drops, 3); H.eq(m.items[LINEN].qty, 4); H.eq(m.money, 75)
        H.eq(m.paceN, 2, "3 kills 30 s apart; the 4th came at the same clock")
        H.eq(DropLabDB.names["Defias Pillager"], 1726)
    end)

    H.test("Kills of a mob you never targeted wait for its name (learned from a mouse-over)", function()
        local ns, frame = W.boot(H)
        W.state.units.target = nil
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 20 experience.")
        H.eq(DropLabDB.unnamed["Kobold Vermin"], 1)
        W.state.units.mouseover = { guid = W.guid(6), name = "Kobold Vermin" }
        frame:Fire("UPDATE_MOUSEOVER_UNIT")
        H.eq(DropLabDB.mobs[6].kills, 1); H.eq(DropLabDB.unnamed["Kobold Vermin"], nil)
    end)

    H.test("Equivalence partitions of loot that isn't counted: fishing, players, secret GUIDs", function()
        local ns, frame = W.boot(H)
        W.state.fishing = true
        W.loot(frame, { { link = W.link(6303), sources = { W.guid(9), 1 } } })
        W.state.fishing = false
        H.eq(DropLabDB.mobs[9], nil, "fishing")
        W.loot(frame, { { link = W.link(1), sources = { "Player-1-ABC", 1 } } })
        H.eq(next(DropLabDB.mobs), nil, "a player's corpse")
        local hidden = W.guid(10)
        W.state.secrets[hidden] = true
        W.loot(frame, { { link = W.link(1), sources = { hidden, 1 } } })
        H.eq(DropLabDB.mobs[10], nil, "secret GUID (dungeons)")
    end)

    H.test("Coin: the source's amount, else parsed from the slot text", function()
        local ns, frame = W.boot(H)
        W.loot(frame, { { money = true, text = "1 Silver\n5 Copper", sources = { W.guid(3, "A"), 0 } } })
        H.eq(DropLabDB.mobs[3].money, 105)
        H.eq(ns.ParseCoins("2 Gold 3 Copper"), 20003); H.eq(ns.ParseCoins("nothing"), nil)
    end)

    H.test("Skinning after looting goes to gathered, not drops", function()
        local ns, frame = W.boot(H)
        local guid = killAndLoot(frame, 2, "A", "Young Wolf", { { link = W.link(750) } })
        W.loot(frame, { { link = W.link(2318), sources = { guid, 2 } } })
        local m = DropLabDB.mobs[2]
        H.eq(m.items[2318], nil); H.eq(m.gather.opened, 1); H.eq(m.gather.items[2318].qty, 2)
    end)

    H.test("Mob tooltip: kills, value per kill and top drops; nothing for unknown mobs or when off", function()
        local ns, frame = W.boot(H, { sale = { [LINEN] = 100 } })
        for i = 1, 5 do
            killAndLoot(frame, 1726, "T" .. i, "Defias Pillager", { { link = W.link(LINEN) } })
        end
        local post = W.tooltipCalls[2]
        H.truthy(post, "hooked on PLAYER_LOGIN")
        post(GameTooltip, { guid = W.guid(1726, "Z") })
        H.truthy(W.tooltipLines[1]:find("5 kills, 100c per kill", 1, true), W.tooltipLines[1])
        H.truthy(W.tooltipLines[2]:find("Item2589", 1, true))
        H.truthy(W.tooltipLines[2]:find("100% (57-100%)", 1, true), W.tooltipLines[2])
        W.tooltipLines = {}
        post(GameTooltip, { guid = W.guid(999) })
        H.eq(#W.tooltipLines, 0, "unknown mob")
        SlashCmdList.DROPLAB("tooltip")
        post(GameTooltip, { guid = W.guid(1726) })
        H.eq(#W.tooltipLines, 0, "turned off")
    end)

    H.test("Mob tooltip: secret data guid or secret unit token is skipped without calling UnitGUID on it", function()
        local ns, frame = W.boot(H, { sale = { [LINEN] = 100 } })
        for i = 1, 5 do
            killAndLoot(frame, 1726, "T" .. i, "Defias Pillager", { { link = W.link(LINEN) } })
        end
        local post = W.tooltipCalls[2]
        local secretUnit = "nameplate1"
        W.state.secrets[secretUnit] = true
        W.state.units[secretUnit] = { guid = W.guid(1726, "S") }
        local guidCalls = 0
        local realGUID = UnitGUID
        -- Like the game: a secret token raises from addon (tainted) code.
        UnitGUID = function(u)
            guidCalls = guidCalls + 1
            if issecretvalue(u) then error("Secret values are only allowed during untainted execution") end
            return realGUID(u)
        end
        local tip = { AddLine = GameTooltip.AddLine, GetUnit = function() return "Pillager", secretUnit end }
        GameTooltip = tip
        W.tooltipLines = {}
        post(tip, {})
        H.eq(guidCalls, 0, "secret token never passed to UnitGUID")
        H.eq(#W.tooltipLines, 0, "no lines, no error")

        -- Normal token: falls back to UnitGUID and shows the lines.
        W.state.units.mouseover = { guid = W.guid(1726, "M") }
        tip.GetUnit = function() return "Pillager", "mouseover" end
        post(tip, {})
        H.eq(guidCalls, 1)
        H.truthy(W.tooltipLines[1] and W.tooltipLines[1]:find("5 kills", 1, true), tostring(W.tooltipLines[1]))

        -- UnitGUID raising for any other reason is contained too.
        UnitGUID = function() error("boom") end
        W.tooltipLines = {}
        post(tip, {})
        H.eq(#W.tooltipLines, 0)
        UnitGUID = realGUID
    end)

    H.test("/droplab <item>: your rate, per kill, buy price and Questie's rate", function()
        local ns, frame = W.boot(H, { buy = { [WOOL] = 150 }, questie = { [WOOL] = { { 1, 25 } } } })
        for i = 1, 4 do
            killAndLoot(frame, 1, "W" .. i, "Gnoll", i <= 2 and { { link = W.link(WOOL) } } or { { money = true, qty = 5 } })
        end
        W.chat = {}
        SlashCmdList.DROPLAB(W.link(WOOL))
        H.truthy(chatHas("(buy: 150c each)"), W.chat[1])
        H.truthy(chatHas("Gnoll: 50% (15-85%) over 4 kills, 0.50 per kill, Questie 25% (matches)"), W.chat[2])
        W.chat = {}
        SlashCmdList.DROPLAB("12345")
        H.truthy(chatHas("none of your kills dropped it yet"))
    end)

    H.test("/droplab: best mobs need 5 kills; /droplab target", function()
        local ns, frame = W.boot(H, { sale = { [LINEN] = 100 } })
        W.chat = {}
        SlashCmdList.DROPLAB("")
        H.truthy(chatHas("Not enough kills yet"))
        for i = 1, 5 do
            W.state.clock = i * 40
            killAndLoot(frame, 1726, "B" .. i, "Defias Pillager", { { link = W.link(LINEN) } })
        end
        W.chat = {}
        SlashCmdList.DROPLAB("")
        H.truthy(chatHas("Defias Pillager: 100c per kill over 5 kills"), W.chat[2])
        W.chat = {}
        W.state.units.target = { guid = W.guid(1726), name = "Defias Pillager" }
        SlashCmdList.DROPLAB("target")
        H.truthy(chatHas("DropLab:"), W.chat[1])
        W.state.units.target = nil
        W.chat = {}
        SlashCmdList.DROPLAB("target")
        H.truthy(chatHas("Target a creature first"))
    end)

    H.test("Public API: rates and mob summaries; unknown input gives nil or empty", function()
        local ns, frame = W.boot(H, { sale = { [LINEN] = 100 } })
        killAndLoot(frame, 1726, "A", "Defias Pillager", { { link = W.link(LINEN) } })
        local r = DropLab.API.GetItemRate(1726, LINEN)
        H.eq(r.drops, 1); H.eq(r.n, 1)
        H.eq(#DropLab.API.GetItemSources(LINEN), 1)
        H.eq(DropLab.API.GetMob(1726).name, "Defias Pillager")
        H.eq(DropLab.API.GetMob(2), nil); H.eq(DropLab.API.GetItemRate(2, LINEN), nil)
        H.eq(#DropLab.API.GetItemSources("x"), 0)
    end)

    H.test("Saved data: kept across a reload; a wrong version starts over", function()
        local saved = { version = 1, mobs = { [5] = { name = "X", kills = 3, looted = 2, money = 0, items = {} } },
            objects = {}, names = { X = 5 }, unnamed = {}, tooltip = false, lastKill = { npcID = 5, t = 1 } }
        W.boot(H, nil, saved)
        H.eq(DropLabDB.mobs[5].kills, 3); H.eq(DropLabDB.tooltip, false); H.eq(DropLabDB.lastKill, nil)
        W.boot(H, nil, { version = 0, mobs = { [5] = {} } })
        H.eq(DropLabDB.mobs[5], nil)
    end)

    H.test("Smoke: works without WhereToFarm", function()
        local ns, frame = W.boot(H, { noWhereToFarm = true })
        killAndLoot(frame, 1, "A", "Gnoll", { { link = W.link(WOOL) } })
        W.chat = {}
        SlashCmdList.DROPLAB(tostring(WOOL))
        H.truthy(chatHas("Gnoll: 100%"))
    end)

    H.test("Use case: dungeon with hidden unit names; kills wait, then the looted corpse's ID names the mob via Questie", function()
        local ns, frame = W.boot(H)
        LibQuestieDB = { Npc = { Get = function(id, field)
            if field == "name" and id == 11322 then return "Searing Blade Cultist" end
        end } }
        W.state.units.target = nil -- the game hides the unit
        for _ = 1, 3 do
            frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Searing Blade Cultist dies, you gain 45 experience.")
        end
        H.eq(DropLabDB.unnamed["Searing Blade Cultist"], 3, "kills wait under the name")
        W.loot(frame, { { link = W.link(LINEN), sources = { W.guid(11322, "C1"), 1 } } })
        local m = DropLabDB.mobs[11322]
        H.eq(m.name, "Searing Blade Cultist")
        H.eq(m.kills, 3, "waiting kills moved")
        H.eq(m.looted, 1)
        H.eq(DropLabDB.unnamed["Searing Blade Cultist"], nil)
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Searing Blade Cultist dies, you gain 45 experience.")
        H.eq(m.kills, 4, "later kills go straight to the mob")
        LibQuestieDB = nil
    end)

    H.test("Load: empty records are tidied and nameless mobs are named once Questie is there (after login)", function()
        local saved = { version = 1, objects = {}, names = {}, tooltip = true,
            unnamed = { ["Ragefire Trogg"] = 21 },
            mobs = { [15676] = { name = "Auctioneer Yarly", kills = 0, looted = 0, money = 0, items = {} },
                     [11318] = { kills = 0, looted = 2, money = 12, items = { [1] = { drops = 1, qty = 1 } } } } }
        local ns, frame = W.boot(H, nil, saved)
        H.eq(DropLabDB.mobs[15676], nil, "empty vendor record removed")
        H.eq(ns.NameMobs(), 0, "Questie not loaded yet: nothing named, no error")
        QuestieLoader = { _modules = { QuestieDB = { QueryNPCSingle = function(id, field)
            if id == 11318 and field == "name" then return "Ragefire Trogg" end
        end } } }
        H.eq(ns.NameMobs(), 1)
        H.eq(DropLabDB.mobs[11318].name, "Ragefire Trogg"); H.eq(DropLabDB.mobs[11318].kills, 21)
        QuestieLoader = nil
    end)
end
