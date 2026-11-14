-- Component integration tests for Core.lua + API.lua: event-driven scanning of bags, bank and mail,
-- secret values, and the debounced change callback.
return function(H)
    local mock = require("wow_mock")

    local function bags()
        return {
            [0] = { n = 4, { 2592, 10 }, false, { 2592, 5 }, { 2589, 2 } },
            [1] = { n = 2, { 2592, 5 } },
            [5] = { n = 1, { 4306, 7 } }, -- reagent bag on clients that have one
        }
    end

    H.test("login creates the character and counts the backpack and bags", function()
        local ns = mock.boot(H, { containers = bags() })
        H.eq(ns.playerKey, "Azhariel-Deadheart")
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        H.eq(c.class, "PRIEST")
        H.eq(c.bags[2592], 20); H.eq(c.bags[2589], 2)
        H.eq(c.bags[4306], nil, "bag 5 is not a bag when NUM_TOTAL_EQUIPPED_BAG_SLOTS is missing")
    end)

    H.test("reagent bag (bag 5) is counted when the client has NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5", function()
        mock.boot(H, { containers = bags(), totalBags = 5 })
        H.eq(StockpileDB.chars["Azhariel-Deadheart"].bags[4306], 7)
    end)

    H.test("BAG_UPDATE_DELAYED rescans bags", function()
        mock.boot(H, { containers = bags() })
        mock.containers[1][1] = { 2592, 15 }
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        H.eq(StockpileDB.chars["Azhariel-Deadheart"].bags[2592], 30)
    end)

    H.test("bank is read only while open; the snapshot stays after closing", function()
        local containers = bags()
        containers[-1] = { n = 2, { 2592, 40 } }
        containers[6] = { n = 1, { 2589, 9 } } -- second bank bag; the first is bag 5 (NUM_BAG_SLOTS + 1)
        containers[5][1] = { 2589, 1 }
        mock.boot(H, { containers = containers })
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        mock.frame:Fire("PLAYERBANKSLOTS_CHANGED")
        H.eq(c.bank[2592], nil, "closed bank is not read")

        mock.frame:Fire("BANKFRAME_OPENED")
        H.eq(c.bank[2592], 40)
        H.eq(c.bank[2589], 10, "bank bags 5 and 6 counted")

        mock.frame:Fire("BANKFRAME_CLOSED")
        containers[-1][1] = { 2592, 1 }
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        H.eq(c.bank[2592], 40, "snapshot kept while closed")
    end)

    H.test("bank opened through the interaction manager (Banker) counts too; other interactions don't", function()
        local containers = bags()
        containers[-1] = { n = 1, { 2592, 3 } }
        local ns = mock.boot(H, { containers = containers })
        mock.frame:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
        H.eq(ns.bankOpen, false)
        mock.frame:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)
        H.eq(StockpileDB.chars["Azhariel-Deadheart"].bank[2592], 3)
        mock.frame:Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 8)
        H.eq(ns.bankOpen, false)
    end)

    H.test("newer clients: character bank tabs are read along with the old containers (absent ones are empty)", function()
        local containers = bags()
        containers[-1] = { n = 0 } -- a tab-based client has no old bank container
        containers[6] = { n = 1, { 2592, 2 } }
        containers[7] = { n = 1, { 2592, 3 } }
        local ns = mock.boot(H, { containers = containers,
            bagIndex = { Bank = -1, CharacterBankTab_1 = 6, CharacterBankTab_2 = 7 } })
        local ids = ns.BankIDs()
        H.eq(ids[1], 6); H.eq(ids[2], 7); H.eq(ids[3], -1)
        local seen = {}
        for _, id in ipairs(ids) do
            H.truthy(not seen[id], "no container read twice: " .. id)
            seen[id] = true
        end
        mock.frame:Fire("BANKFRAME_OPENED")
        H.eq(StockpileDB.chars["Azhariel-Deadheart"].bank[2592], 5)
    end)

    H.test("bank visit: saved time, one chat confirmation per session, rescan a moment later", function()
        local containers = bags()
        containers[-1] = { n = 2 } -- contents not arrived yet when the window opens
        containers[5] = nil -- no bank bags
        mock.boot(H, { containers = containers })
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        mock.chat = {}
        mock.frame:Fire("BANKFRAME_OPENED")
        H.eq(c.bankTime, mock.now)
        H.eq(mock.chat[1], "|cff88ccffStockpile|r: bank saved (it looks empty).")
        containers[-1][1] = { 2592, 40 }
        mock.runTimers() -- the delayed rescan
        H.eq(c.bank[2592], 40)
        mock.frame:Fire("BANKFRAME_CLOSED")
        mock.frame:Fire("BANKFRAME_OPENED")
        H.eq(#mock.chat, 1, "confirmed only once per session")
    end)

    H.test("bank closed before the delayed rescan: nothing is read", function()
        local containers = bags()
        containers[-1] = { n = 1, { 2592, 4 } }
        mock.boot(H, { containers = containers })
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        mock.frame:Fire("BANKFRAME_OPENED")
        mock.frame:Fire("BANKFRAME_CLOSED")
        containers[-1][1] = { 2592, 1 }
        mock.runTimers()
        H.eq(c.bank[2592], 4)
    end)

    H.test("mail attachments are counted on MAIL_INBOX_UPDATE", function()
        mock.boot(H, { mail = { { { 2592, 4 }, { 2589, 1 } }, { { 2592, 2 } } } })
        mock.frame:Fire("MAIL_INBOX_UPDATE")
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        H.eq(c.mail[2592], 6); H.eq(c.mail[2589], 1)
        mock.mail = {}
        mock.frame:Fire("MAIL_INBOX_UPDATE")
        H.eq(c.mail[2592], nil, "taken mail no longer counted")
    end)

    H.test("secret item IDs and counts are skipped, never saved", function()
        local containers = { [0] = { n = 3, { mock.SECRET, 5 }, { 2592, mock.SECRET }, { 2592, 1 } } }
        mock.boot(H, { containers = containers })
        local c = StockpileDB.chars["Azhariel-Deadheart"]
        H.eq(c.bags[2592], 1)
        for k, v in pairs(c.bags) do
            H.truthy(k ~= mock.SECRET and v ~= mock.SECRET, "no secret stored")
        end
    end)

    H.test("secret player name: no character is created and scanning does nothing", function()
        local ns = mock.boot(H, { name = mock.SECRET, containers = bags() })
        H.eq(ns.playerKey, nil)
        H.eq(next(StockpileDB.chars), nil)
    end)

    H.test("unknown events don't stop the addon from loading", function()
        mock.install({ unknownEvents = { PLAYERREAGENTBANKSLOTS_CHANGED = true,
            PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true } })
        local ns = H.load({ "Store.lua", "Core.lua", "API.lua", "Tooltip.lua" })
        H.truthy(mock.frame.events.BAG_UPDATE_DELAYED)
        H.truthy(ns.ScanBags)
    end)

    H.test("callback: one debounced call per burst, only when counts change", function()
        local ns = mock.boot(H, { containers = bags() })
        mock.runTimers()
        local calls, got = 0, nil
        Stockpile.API.RegisterCallback("MakeOrBuy", function(owner) calls = calls + 1; got = owner end)

        mock.frame:Fire("BAG_UPDATE_DELAYED")
        H.eq(#mock.timers, 0, "nothing changed, no callback")

        mock.containers[0][2] = { 2592, 1 }
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        mock.containers[0][2] = { 2592, 2 }
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        H.eq(#mock.timers, 1, "debounced")
        mock.runTimers()
        H.eq(calls, 1); H.eq(got, "MakeOrBuy")

        Stockpile.API.UnregisterCallback("MakeOrBuy")
        mock.containers[0][2] = false
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        mock.runTimers()
        H.eq(calls, 1, "unregistered")
        H.truthy(ns.callbacks.MakeOrBuy == nil)
    end)

    H.test("a failing callback is reported and doesn't block the others", function()
        mock.boot(H, { containers = bags() })
        mock.runTimers()
        local ok = false
        Stockpile.API.RegisterCallback("Bad", function() error("boom") end)
        Stockpile.API.RegisterCallback("Good", function() ok = true end)
        mock.containers[0][2] = { 1, 1 }
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        mock.runTimers()
        H.truthy(ok)
        H.truthy(tostring(mock.lastError):find("boom"))
    end)

    H.test("API contract: GetCount scopes, GetOwnedMap is a fresh copy", function()
        mock.boot(H, { containers = bags(), db = { version = 1, chars = {
            ["Bankalt-Deadheart"] = { name = "Bankalt", realm = "Deadheart", class = "MAGE",
                bags = {}, bank = { [2592] = 50 }, mail = {} },
        } } })
        local api = Stockpile.API
        H.eq(api.version, 1)
        local total, list = api.GetCount(2592)
        H.eq(total, 20, "default scope = character")
        H.eq(list[1].bags, 20); H.eq(list[1].bank, 0); H.eq(list[1].mail, 0); H.eq(list[1].total, 20)
        total, list = api.GetCount(2592, "realm")
        H.eq(total, 70); H.eq(#list, 2)
        H.eq(api.GetCount(2592, "bogus"), 20, "unknown scope = character")
        local map = api.GetOwnedMap("realm")
        H.eq(map[2592], 70)
        map[2592] = 1
        H.eq(api.GetOwnedMap("realm")[2592], 70)
        H.eq(api.GetCount("2592"), 0, "non-number id")
    end)

    H.test("API before login returns empty results instead of erroring", function()
        mock.boot(H, { noLogin = true })
        local total, list = Stockpile.API.GetCount(2592)
        H.eq(total, 0); H.eq(#list, 0)
        H.eq(next(Stockpile.API.GetOwnedMap()), nil)
    end)
end
