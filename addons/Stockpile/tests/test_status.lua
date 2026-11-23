-- The /stockpile window: Stockpile's status, the window against fake widgets, and the slash commands around it
return function(H)
    local mock = require("wow_mock")
    local DAY = 86400

    local function boot(opts)
        opts = opts or {}
        opts.containers = opts.containers or { [0] = { n = 3, { 2592, 20 }, { 2589, 5 }, { 2592, 4 } } }
        opts.mail = opts.mail or { { { 2589, 10 } } }
        opts.db = opts.db or { version = 1, chars = {
            ["Bankalt-Deadheart"] = { name = "Bankalt", realm = "Deadheart", class = "MAGE",
                bags = {}, bank = { [2592] = 10, [4306] = 40 }, mail = {}, bankTime = 1700000000 - 3 * DAY },
        } }
        return mock.boot(H, opts)
    end

    local function find(status, title)
        for _, s in ipairs(status.sections) do
            if s.title == title then
                local rows = {}
                for _, r in ipairs(s.rows) do rows[r[1]] = r[2] end
                return rows
            end
        end
    end

    local function has(list, text)
        for _, l in ipairs(list or {}) do
            if tostring(l):find(text, 1, true) then return true end
        end
        return false
    end

    H.test("status: this character's key, realm, and what's in bags, bank and mail", function()
        local ns = boot()
        mock.frame:Fire("MAIL_SHOW")
        mock.containers[-1] = { n = 1, { 4306, 7 } }
        mock.frame:Fire("BANKFRAME_OPENED")
        local s = ns.Status()
        local me = find(s, "This character")
        H.eq(me.Key, "Azhariel-Deadheart")
        H.eq(me.Realm, "Deadheart")
        H.eq(me.Bags, "29 items (2 kinds)")
        H.eq(me.Bank, "7 items (1 kind)")
        H.eq(me.Mail, "10 items (1 kind)")
        H.truthy(tostring(me["Bank saved"]):find("now", 1, true), tostring(me["Bank saved"]))
        H.eq(#s.warnings, 0, "nothing missing")
        H.truthy(s.footer:find("/stockpile print", 1, true))
    end)

    H.test("status lists every tracked character with its total and when its bank was saved", function()
        local ns = boot()
        local all = find(ns.Status(), "All characters")
        H.truthy(all.Azhariel:find("29 items", 1, true), all.Azhariel)
        H.truthy(all.Azhariel:find("bank never saved", 1, true), all.Azhariel)
        H.truthy(all.Bankalt:find("50 items", 1, true), all.Bankalt)
        H.truthy(all.Bankalt:find("3 days ago", 1, true), all.Bankalt)
    end)

    H.test("status warns when this character's bank was never saved", function()
        local ns = boot()
        local s = ns.Status()
        H.truthy(has(s.warnings, "talk to a banker once"), s.warnings[1])
        H.eq(find(s, "This character")["Bank saved"], "never")
    end)

    H.test("status warns when there's no character key (no realm and no game rules to name one)", function()
        local ns = boot({ realm = "" })
        H.eq(ns.playerKey, nil)
        local s = ns.Status()
        H.truthy(has(s.warnings, "no realm"), s.warnings[1])
        H.eq(find(s, "This character").Key, "(none)")
    end)

    H.test("/stockpile toggles the window; /stockpile print sends the status to the chat", function()
        boot()
        local made = mock.useFakeWidgets()
        SlashCmdList.STOCKPILE("")
        local f = made.StockpileStatusFrame
        H.truthy(f, "the window is made on first use")
        H.truthy(f.shown, "and shown")
        local texts = {}
        for _, fs in ipairs(made.fonts) do if fs.text then texts[#texts + 1] = fs.text end end
        H.truthy(table.concat(texts, "\n"):find("Azhariel-Deadheart", 1, true), "the window shows the character")
        SlashCmdList.STOCKPILE("")
        H.eq(f.shown, false, "a second /stockpile closes it")
        mock.chat = {}
        SlashCmdList.STOCKPILE("print")
        H.truthy(#mock.chat > 3, "the status went to the chat")
        H.truthy(has(mock.chat, "Azhariel-Deadheart"))
    end)

    H.test("without frames, /stockpile prints the status instead", function()
        boot()
        mock.chat = {}
        SlashCmdList.STOCKPILE("")
        H.truthy(#mock.chat > 3)
        H.truthy(has(mock.chat, "This character"))
    end)

    H.test("the window keeps its place in StockpileDB.window, which survives the next load", function()
        local ns = boot()
        mock.useFakeWidgets()
        SlashCmdList.STOCKPILE("")
        H.truthy(type(StockpileDB.window) == "table", "made when the window is")
        StockpileDB.window.point = "TOP"
        local again = boot({ db = StockpileDB })
        H.eq(again.db.window.point, "TOP", "Store.Upgrade keeps it")
        H.truthy(ns ~= again)
    end)

    H.test("the item lookup, forget and help still work beside the window", function()
        boot()
        mock.useFakeWidgets()
        mock.chat = {}
        SlashCmdList.STOCKPILE("2592")
        H.truthy(mock.chat[1]:find("Item2592: 34", 1, true), mock.chat[1])
        SlashCmdList.STOCKPILE("help")
        H.truthy(has(mock.chat, "/stockpile [item link or id]"))
        SlashCmdList.STOCKPILE("forget Bankalt-Deadheart")
        H.eq(StockpileDB.chars["Bankalt-Deadheart"], nil)
    end)
end
