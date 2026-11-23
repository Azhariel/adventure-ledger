-- The /logbook window: the shared StatusWindow's lines, Logbook's status, and the window against fake widgets
return function(H)
    local test, eq, truthy = H.test, H.eq, H.truthy
    local W = require("wow_mock")
    local function boot(opts) return W.boot(H.root, opts) end

    local function find(status, title)
        for _, s in ipairs(status.sections) do
            if s.title == title then
                local rows = {}
                for _, r in ipairs(s.rows) do rows[r[1]] = r[2] end
                return rows
            end
        end
    end

    test("StatusWindow.Lines: warnings first, then each section with rows, then the footer; empty sections left out", function()
        local ns = boot()
        local lines = ns.StatusWindow.Lines({ warnings = { "careful" }, footer = "bye",
            sections = { { title = "A", rows = { { "x", 1 }, { "y", nil } } }, { title = "Empty", rows = {} } } })
        eq(#lines, 5)
        eq(lines[1].kind, "warn"); eq(lines[1].text, "careful")
        eq(lines[2].kind, "head"); eq(lines[2].text, "A")
        eq(lines[3].value, "1"); eq(lines[4].value, "", "a missing value shows as nothing")
        eq(lines[5].kind, "foot")
        local chat = ns.StatusWindow.ChatLines({ sections = { { title = "A", rows = { { "x", 1 } } } } })
        eq(#chat, 2); truthy(chat[2]:find("x:", 1, true))
    end)

    test("status: the character, this session's lines by kind, gold and XP, and the recent lines", function()
        local ns, st = boot()
        ns.Core.Log("ki", "Kolkar Outrunner", 3274, "Humanoid", "normal", 120, 14)
        ns.Core.Log("xp", 120, "kill", "Kolkar Outrunner")
        ns.Core.Log("mn", 125, "loot")
        ns.Core.Log("mn", -20, "repair")
        local s = ns.Status()
        local char = find(s, "Character")
        eq(char.Name, "Azhariel"); eq(char.Realm, "CAMWOW US2 Realm 2 PvP"); eq(char.Level, 20)
        local session = find(s, "This session")
        eq(session.Kills, 1); eq(session["XP gained"], 120); eq(session.Gold, "+1s 5c")
        truthy(find(s, "Recent")["now"] or next(find(s, "Recent")), "the newest lines are listed")
        eq(#s.warnings, 0, "nothing missing")
    end)

    test("status warns when no realm or ruleset is saved: the dashboard can't place the auction house", function()
        local ns = boot({ realm = "" })
        local s = ns.Status()
        eq(find(s, "Character").Realm, "(none)")
        truthy(s.warnings[1] and s.warnings[1]:find("auction house", 1, true))
    end)

    test("/logbook toggles the window; /logbook print sends the status to the chat", function()
        local ns, st = boot()
        local made = W.useFakeWidgets()
        SlashCmdList.LOGBOOK("")
        local f = made.LogbookStatusFrame
        truthy(f, "the window is made on first use")
        truthy(f.shown, "and shown")
        local texts = {}
        for _, fs in ipairs(made.fonts) do if fs.text then texts[#texts + 1] = fs.text end end
        truthy(table.concat(texts, "\n"):find("Azhariel", 1, true), "the window shows the character")
        SlashCmdList.LOGBOOK("")
        eq(f.shown, false, "a second /logbook closes it")
        local before = #st.printed
        SlashCmdList.LOGBOOK("print")
        truthy(#st.printed > before + 3, "the status went to the chat")
    end)

    test("without frames (CreateFrame fails), /logbook prints the status instead", function()
        local _, st = boot()
        CreateFrame = function() error("no frames") end
        local before = #st.printed
        SlashCmdList.LOGBOOK("")
        truthy(#st.printed > before + 3)
    end)
end
