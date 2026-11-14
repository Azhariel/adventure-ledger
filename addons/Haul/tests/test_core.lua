-- Component integration tests for Core.lua: events -> session, with faked game and Auctionator APIs.
return function(H)
    local mock = require("wow_mock")

    local function money(frame, amount)
        mock.state.money = mock.state.money + amount
        frame:Fire("PLAYER_MONEY")
    end

    H.test("login starts a session with the current zone and an empty saved DB", function()
        local ns = mock.boot(H)
        H.truthy(ns.session)
        H.eq(ns.session.zone, "Elwynn Forest")
        H.eq(#HaulCharDB.history, 0)
        H.truthy(mock.ticker, "1s ticker started")
    end)

    H.test("coin with the loot window open counts once, its chat line adds nothing", function()
        local ns, f = mock.boot(H)
        f:Fire("LOOT_OPENED")
        money(f, 120)
        f:Fire("CHAT_MSG_MONEY", "You loot 1 Silver 20 Copper")
        f:Fire("LOOT_CLOSED")
        H.eq(ns.session.money.loot, 120)
    end)

    H.test("auto-loot: money change and chat line pair up in either order within 1s", function()
        local ns, f = mock.boot(H)
        money(f, 50)                     -- change first, line follows
        mock.state.clock = 0.4
        f:Fire("CHAT_MSG_MONEY", "x")
        mock.state.clock = 5
        f:Fire("CHAT_MSG_MONEY", "y")    -- line first, change follows
        mock.state.clock = 5.9
        money(f, 30)
        H.eq(ns.session.money.loot, 80)
    end)

    H.test("money without a loot line (vendor sale outside a window, refund) is not income", function()
        local ns, f = mock.boot(H)
        money(f, 500)
        mock.state.clock = 2             -- the line arrives too late: boundary just past 1s
        f:Fire("CHAT_MSG_MONEY", "x")
        H.eq(ns.session.money.loot, 0)
        money(f, -100)
        H.eq(ns.session.money.loot, 0)
    end)

    H.test("money while a merchant or mailbox is open is ignored", function()
        local ns, f = mock.boot(H)
        f:Fire("MERCHANT_SHOW")
        f:Fire("LOOT_OPENED")
        money(f, 300)
        f:Fire("MERCHANT_CLOSED")
        money(f, 40)
        H.eq(ns.session.money.loot, 40)
    end)

    H.test("quest money comes from QUEST_TURNED_IN; its money change is not counted as loot", function()
        local ns, f = mock.boot(H)
        f:Fire("QUEST_TURNED_IN", 123, 450, 75)
        money(f, 75)
        H.eq(ns.session.money.quest, 75)
        H.eq(ns.session.money.loot, 0)
    end)

    H.test("looted and pushed items are valued at the higher of AH after cut and vendor", function()
        local ns, f = mock.boot(H, { ah = { [2592] = 100 }, items = { [2592] = 10, [4306] = 60 } })
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(2592) .. "x3.")
        f:Fire("CHAT_MSG_LOOT", "You receive item: " .. mock.link(4306) .. ".")
        H.eq(ns.session.items[2592].count, 3)
        H.eq(ns.session.itemValue, 3 * 95 + 60)
    end)

    H.test("crafted items and other players' loot are ignored", function()
        local ns, f = mock.boot(H, { items = { [2997] = 100 } })
        f:Fire("CHAT_MSG_LOOT", "You create: " .. mock.link(2997) .. ".")
        f:Fire("CHAT_MSG_LOOT", "Bob receives loot: " .. mock.link(2997) .. ".")
        H.eq(ns.session.itemValue, 0)
        H.eq(next(ns.session.items), nil)
    end)

    H.test("items bought from a vendor (pushed while the merchant is open) are not income", function()
        local ns, f = mock.boot(H, { items = { [159] = 1 } })
        f:Fire("MERCHANT_SHOW")
        f:Fire("CHAT_MSG_LOOT", "You receive item: " .. mock.link(159) .. "x5.")
        H.eq(next(ns.session.items), nil)
    end)

    H.test("secret event arguments are skipped", function()
        local ns, f = mock.boot(H, { items = { [2592] = 10 } })
        local text = "You receive loot: " .. mock.link(2592) .. "."
        mock.state.secrets[text] = true
        mock.state.secrets[77] = true
        f:Fire("CHAT_MSG_LOOT", text)
        f:Fire("QUEST_TURNED_IN", 1, 0, 77)
        H.eq(ns.session.itemValue, 0)
        H.eq(ns.session.money.quest, 0)
    end)

    H.test("uncached item is requested, recorded as pending, then valued on GET_ITEM_INFO_RECEIVED", function()
        local ns, f = mock.boot(H, { items = { [4306] = 60 }, uncached = { [4306] = true } })
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(4306) .. "x2.")
        H.eq(mock.requested[1], 4306)
        H.eq(ns.session.itemValue, 0)
        mock.state.uncached[4306] = nil
        f:Fire("GET_ITEM_INFO_RECEIVED", 4306, true)
        H.eq(ns.session.itemValue, 120)
    end)

    H.test("XP updates and a level-up roll over into the session total", function()
        local ns, f = mock.boot(H, { xp = 900, xpMax = 1000, level = 10 })
        mock.state.xp = 950
        f:Fire("PLAYER_XP_UPDATE", "player")
        mock.state.xp, mock.state.xpMax, mock.state.level = 30, 1200, 11
        f:Fire("PLAYER_XP_UPDATE", "player")
        H.eq(ns.session.xp, 130, "50 + (1000 - 950) + 30")
    end)

    H.test("AFK flag pauses (excluding the idle lead), clearing it resumes", function()
        local ns, f = mock.boot(H)
        mock.state.now = 1000 + 900
        mock.state.afk = true
        f:Fire("PLAYER_FLAGS_CHANGED", "player")
        H.eq(ns.session.pauseReason, "afk")
        H.eq(ns.Session.Elapsed(ns.session, 5000), 600)
        mock.state.afk = false
        mock.state.now = 5000
        f:Fire("PLAYER_FLAGS_CHANGED", "player")
        H.eq(ns.session.pauseReason, nil)
        H.eq(ns.Session.Elapsed(ns.session, 5060), 660)
    end)

    H.test("nothing is counted while paused, and XP earned meanwhile isn't counted later", function()
        local ns, f = mock.boot(H, { items = { [2592] = 10 } })
        SlashCmdList.HAUL("pause")
        f:Fire("LOOT_OPENED")
        money(f, 99)
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(2592) .. ".")
        mock.state.xp = 500
        f:Fire("PLAYER_XP_UPDATE", "player")
        SlashCmdList.HAUL("resume")
        mock.state.xp = 520
        f:Fire("PLAYER_XP_UPDATE", "player")
        H.eq(ns.session.money.loot, 0); H.eq(ns.session.itemValue, 0)
        H.eq(ns.session.xp, 20)
    end)

    H.test("/reload within 10 minutes resumes the same session without counting the gap", function()
        local ns, f = mock.boot(H)
        f:Fire("LOOT_OPENED"); money(f, 10); f:Fire("LOOT_CLOSED")
        mock.state.now = 1600
        f:Fire("PLAYER_LOGOUT")
        local saved = HaulCharDB
        local ns2 = mock.boot(H, { now = 1600 + 600 }, saved) -- boundary: exactly the resume window
        H.eq(ns2.session.money.loot, 10, "same session")
        H.eq(ns2.Session.Elapsed(ns2.session, 2200), 600)
        H.eq(#HaulCharDB.history, 0)
    end)

    H.test("login after more than 10 minutes archives the old session and starts a new one", function()
        local ns, f = mock.boot(H)
        f:Fire("LOOT_OPENED"); money(f, 10); f:Fire("LOOT_CLOSED")
        mock.state.now = 1600
        f:Fire("PLAYER_LOGOUT")
        local saved = HaulCharDB
        local ns2 = mock.boot(H, { now = 1600 + 601 }, saved)
        H.eq(ns2.session.money.loot, 0)
        H.eq(#HaulCharDB.history, 1)
        H.eq(HaulCharDB.history[1].loot, 10)
        H.eq(HaulCharDB.history[1].duration, 600)
    end)

    H.test("/haul reset archives; /haul history prints it; unknown command prints usage", function()
        local ns, f = mock.boot(H)
        f:Fire("QUEST_TURNED_IN", 1, 0, 500)
        mock.state.now = 1000 + 1800
        SlashCmdList.HAUL("reset")
        H.eq(#HaulCharDB.history, 1)
        H.eq(ns.session.money.quest, 0)
        SlashCmdList.HAUL("history")
        H.truthy(mock.chat[#mock.chat]:find("0:30  500c  %(1000c/h%)"), mock.chat[#mock.chat])
        SlashCmdList.HAUL("help")
        H.truthy(mock.chat[#mock.chat]:find("/haul reset"), mock.chat[#mock.chat])
    end)

    H.test("formatting helpers: duration, ETA, short numbers, rate rounding", function()
        local ns = mock.boot(H)
        H.eq(ns.Duration(0), "0:00"); H.eq(ns.Duration(3725), "1:02")
        H.eq(ns.Eta(1), "1m"); H.eq(ns.Eta(1500), "25m"); H.eq(ns.Eta(3600), "1h 00m")
        H.eq(ns.Short(999), "999"); H.eq(ns.Short(12345), "12.3k"); H.eq(ns.Short(2500000), "2.5m")
        H.eq(ns.Rate(12345), "12300c/h"); H.eq(ns.Rate(nil), "--")
    end)
end
