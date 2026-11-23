-- The /droplab window: DropLab's status as data, the window against fake widgets, and the slash commands around it
return function(H)
    local test, eq, truthy = H.test, H.eq, H.truthy
    local W = require("wow_mock")
    local LINEN, WOOL = 2589, 2592

    local function find(status, title)
        for _, s in ipairs(status.sections) do
            if s.title == title then
                local rows = {}
                for _, r in ipairs(s.rows) do rows[r[1]] = r[2] end
                return rows, s.rows
            end
        end
    end

    local function chatHas(text)
        for _, line in ipairs(W.chat) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    local function warned(status, text)
        for _, w in ipairs(status.warnings) do
            if w:find(text, 1, true) then return true end
        end
        return false
    end

    local function killAndLoot(frame, npcID, spawn, name, slots)
        local guid = W.guid(npcID, spawn)
        W.state.units.target = { guid = guid, name = name, dead = true }
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", name .. " dies, you gain 45 experience.")
        if slots then
            for _, s in ipairs(slots) do s.sources = { guid, s.qty or 1 } end
            W.loot(frame, slots)
        end
        W.state.units.target = nil
        return guid
    end

    -- 5 Defias Pillagers (linen each), 2 Gnolls (wool), 1 Kobold killed but not looted, 1 kill of a name never met
    local function camp(opts)
        local ns, frame = W.boot(H, opts or { sale = { [LINEN] = 100 } })
        for i = 1, 5 do
            killAndLoot(frame, 1726, "P" .. i, "Defias Pillager", { { link = W.link(LINEN) } })
        end
        for i = 1, 2 do
            killAndLoot(frame, 1, "G" .. i, "Gnoll", { { link = W.link(WOOL) }, { money = true, qty = 10 } })
        end
        killAndLoot(frame, 3, "K1", "Kobold", nil)
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Murloc dies, you gain 45 experience.")
        return ns, frame
    end

    test("status: what's recorded, this session, and the most killed mobs", function()
        local ns = camp()
        local s = ns.Status()
        local rec = find(s, "Recorded")
        eq(rec["Mobs"], 3); eq(rec["Kills"], 8); eq(rec["Corpses looted"], 7); eq(rec["Items seen"], 2)
        eq(rec["Kills waiting for a name"], 1, "the Murloc's XP line has no ID yet")
        eq(rec["Items with no price"], 1, "wool has no sale value")
        local session = find(s, "This session")
        eq(session["Kills"], 9, "every XP line, named or not")
        eq(session["Corpses looted"], 7)
        eq(session["Last looted"], "Gnoll")
        local _, top = find(s, "Most killed")
        eq(top[1][1], "Defias Pillager"); eq(top[1][2], "5 kills")
        eq(top[2][1], "Gnoll")
        eq(#top, 3)
        eq(find(s, "Your target"), nil, "no target, no section")
        eq(#s.warnings, 0, "nothing missing")
        truthy(s.footer:find("/droplab target", 1, true))
    end)

    test("status: most killed stops at five", function()
        local ns, frame = W.boot(H)
        for id = 1, 7 do
            for i = 1, id do killAndLoot(frame, id, "S" .. id .. i, "Mob" .. id, nil) end
        end
        local _, top = find(ns.Status(), "Most killed")
        eq(#top, 5); eq(top[1][1], "Mob7"); eq(top[5][1], "Mob3")
    end)

    test("status: your target's kills, value and top drops; an unknown target says so", function()
        local ns = camp()
        W.state.units.target = { guid = W.guid(1726, "P9"), name = "Defias Pillager" }
        local t, rows = find(ns.Status(), "Your target")
        eq(t["Name"], "Defias Pillager")
        eq(t["Kills"], "5 kills")
        eq(t["Per kill"], "100c")
        eq(t["Item2589"], "100%", "the drop with its rate")
        truthy(#rows <= 3 + 3 + 2, "a few drops only")
        W.state.units.target = { guid = W.guid(999), name = "Stranger" }
        t = find(ns.Status(), "Your target")
        eq(t["Name"], "Stranger"); eq(t["Kills"], "none recorded yet")
        W.state.units.target = { guid = "Player-1-0000AAAA", name = "Someone", player = true }
        eq(find(ns.Status(), "Your target"), nil, "players aren't mobs")
    end)

    test("warnings: no Make or Buy means no values; no Auctionator means vendor prices only", function()
        local ns = camp()
        MakeOrBuy = nil
        truthy(warned(ns.Status(), "Make or Buy"), "no price source")
        local ns2 = camp({ sale = { [LINEN] = 100 }, noAuctionator = true })
        truthy(warned(ns2.Status(), "Auctionator"), "no AH prices")
    end)

    test("warnings: mobs known only by ID without Questie, and XP lines the game hid", function()
        local ns, frame = W.boot(H)
        LibQuestieDB, QuestieLoader = nil, nil
        W.loot(frame, { { link = W.link(LINEN), sources = { W.guid(11322, "D1"), 1 } } }) -- a dungeon corpse
        local hidden = "Searing Blade Cultist dies, you gain 300 experience."
        W.state.secrets[hidden] = true
        frame:Fire("CHAT_MSG_COMBAT_XP_GAIN", hidden)
        local s = ns.Status()
        truthy(warned(s, "Questie"), "the nameless mob")
        truthy(warned(s, "hid 1 XP line"), "the hidden kill")
        eq(find(s, "Most killed") ~= nil, true, "the nameless mob still listed")
    end)

    test("/droplab toggles the window; /droplab print sends the status to the chat", function()
        local ns = camp()
        local made = W.useFakeWidgets()
        SlashCmdList.DROPLAB("")
        local f = made.DropLabStatusFrame
        truthy(f, "the window is made on first use")
        truthy(f.shown, "and shown")
        local texts = {}
        for _, fs in ipairs(made.fonts) do if fs.text then texts[#texts + 1] = fs.text end end
        truthy(table.concat(texts, "\n"):find("Defias Pillager", 1, true), "the window shows the most killed")
        SlashCmdList.DROPLAB("")
        eq(f.shown, false, "a second /droplab closes it")
        W.chat = {}
        SlashCmdList.DROPLAB("print")
        truthy(#W.chat > 5, "the status went to the chat")
        truthy(chatHas("Most killed"))
        eq(DropLabDB.window ~= nil, true, "the window's place is saved in DropLabDB")
    end)

    test("without frames, /droplab prints the status instead", function()
        camp()
        W.chat = {}
        SlashCmdList.DROPLAB("")
        truthy(#W.chat > 5)
        truthy(chatHas("Recorded"))
    end)

    test("the other subcommands are unchanged; the best list moved to /droplab best; help lists them", function()
        local ns, frame = camp()
        W.chat = {}
        SlashCmdList.DROPLAB("best")
        truthy(chatHas("Defias Pillager: 100c per kill over 5 kills"))
        W.chat = {}
        SlashCmdList.DROPLAB(tostring(LINEN))
        truthy(chatHas("Defias Pillager: 100%"))
        W.chat = {}
        SlashCmdList.DROPLAB("tooltip")
        eq(DropLabDB.tooltip, false)
        W.chat = {}
        SlashCmdList.DROPLAB("help")
        truthy(chatHas("/droplab best"), "help names the best list")
        truthy(chatHas("/droplab print"))
    end)

    test("the window's saved place survives a reload", function()
        local saved = { version = 1, mobs = {}, objects = {}, names = {}, unnamed = {},
            window = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 10, y = -20 } }
        W.boot(H, nil, saved)
        eq(DropLabDB.window.point, "TOPLEFT"); eq(DropLabDB.window.x, 10)
    end)
end
