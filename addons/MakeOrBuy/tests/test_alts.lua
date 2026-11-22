-- Unit tests for Alts.lua (pure) and component tests for the profile Core.lua publishes and the mailbox panel.
-- Techniques (ISTQB): decision tables (who gets an item), boundary values (stack picking), state transitions
-- (mail open -> attach -> sent), and a smoke test of MailPanel.lua with fake widgets.
return function(H)
    local mock = require("wow_mock")
    local Alts = H.load({ "Alts.lua" }).Alts

    local function profile(name, surname, faction, uses, needs)
        return { name = name, surname = surname, faction = faction, uses = uses or {}, needs = needs or {} }
    end

    H.test("Profile: reagents of known recipes are used; the restock shopping list adds needs", function()
        local uses, needs = Alts.Profile({ [1] = { reagents = { { itemID = 2589, qty = 2 }, { itemID = 2320, qty = 1 } } } },
            { { itemID = 2592, qty = 4 }, { itemID = 2592, qty = 2 }, { itemID = 9, qty = 0 } })
        H.truthy(uses[2589]); H.truthy(uses[2320]); H.truthy(uses[2592], "restock items count as used")
        H.eq(needs[2592], 6); H.eq(needs[9], nil, "zero isn't a need"); H.eq(needs[2589], nil)
        local u, n = Alts.Profile(nil, nil)
        H.eq(next(u), nil); H.eq(next(n), nil)
    end)

    H.test("Recipient and display name: Forever's First-Surname, or the first name alone", function()
        H.eq(Alts.Recipient(profile("Azhariel", "Deadheart")), "Azhariel-Deadheart")
        H.eq(Alts.DisplayName(profile("Azhariel", "Deadheart")), "Azhariel Deadheart")
        H.eq(Alts.Recipient(profile("Bob")), "Bob")
        H.eq(Alts.Recipient(profile("Bob", "")), "Bob")
    end)

    H.test("Suggest (decision table): other character, same faction, uses it, and you don't", function()
        local chars = {
            me = profile("Me", "A", "Horde", { [3] = true }),
            tailor = profile("Tai", "Lor", "Horde", { [1] = true, [2] = true, [3] = true }, { [1] = 20 }),
            ally = profile("Al", "Ly", "Alliance", { [1] = true }),
            nofaction = profile("Old", nil, nil, { [2] = true }),
            junk = "not a table",
        }
        local bags = { [1] = 30, [2] = 5, [3] = 7, [4] = 1 }
        local list = Alts.Suggest("me", chars.me, chars, bags)
        -- 1 -> Tai (restock 20), 2 -> Old (faction unknown: allowed), 2 -> Tai; 3 is yours; 4 nobody uses; Al is Alliance
        H.eq(#list, 3)
        H.eq(list[1].itemID, 1); H.eq(list[1].reason, "restock"); H.eq(list[1].give, 20); H.eq(list[1].have, 30); H.eq(list[1].key, "tailor")
        H.eq(list[2].profile.name, "Old"); H.eq(list[2].give, 5)
        H.eq(list[3].profile.name, "Tai"); H.eq(list[3].itemID, 2); H.eq(list[3].reason, "crafting")
        H.eq(#Alts.Suggest("me", chars.me, { me = chars.me }, bags), 0, "only yourself known")
    end)

    H.test("Suggest: a restock need bigger than what you have gives all you have (boundary)", function()
        local chars = { t = profile("T", nil, "Horde", { [1] = true }, { [1] = 50 }) }
        local list = Alts.Suggest("me", profile("Me", nil, "Horde"), chars, { [1] = 12 })
        H.eq(list[1].give, 12); H.eq(list[1].need, 50)
    end)

    local function stacks(...)
        local out = {}
        for i, n in ipairs({ ... }) do out[i] = { bag = 0, slot = i, count = n } end
        return out
    end

    H.test("PickStacks (boundary values): exact, smallest covering stack, overshoot, slot limit, empty", function()
        local p, t = Alts.PickStacks(stacks(20, 5, 20), 20)
        H.eq(#p, 1); H.eq(t, 20, "one exact stack")
        p, t = Alts.PickStacks(stacks(20, 7, 5), 6)
        H.eq(#p, 1); H.eq(p[1].count, 7, "smallest stack that covers 6")
        p, t = Alts.PickStacks(stacks(20, 20, 5), 45)
        H.eq(#p, 3); H.eq(t, 45)
        p, t = Alts.PickStacks(stacks(20, 20, 20), 60, 2)
        H.eq(#p, 2); H.eq(t, 40, "no more than the free attachment slots")
        p, t = Alts.PickStacks(stacks(3, 3), 10)
        H.eq(t, 6, "all you have when it isn't enough")
        p, t = Alts.PickStacks({}, 10)
        H.eq(#p, 0); H.eq(t, 0)
        p, t = Alts.PickStacks(stacks(5), 0)
        H.eq(#p, 0, "nothing wanted, nothing picked")
    end)

    ------------------------------------------------------------------------------------------------
    -- Core: the published profile

    local CORE = { "Planner.lua", "Market.lua", "Skill.lua", "Restock.lua", "Alts.lua", "Scanner.lua", "Core.lua" }

    local function bootCore(player)
        local frame = mock.installCore()
        mock.installAuctionator({}, { [2589] = 10 })
        mock.installTradeSkill({})
        MakeOrBuyDB = nil
        UnitGUID = function() return player.guid end
        UnitName = function() return player.name, player.surname end
        UnitFactionGroup = function() return player.faction end
        time = os.time
        issecretvalue = player.secret and function(v) return v == player.secret end or nil
        local ns = H.load(CORE)
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        return ns, frame
    end

    local function cleanup()
        UnitGUID, UnitName, UnitFactionGroup, issecretvalue = nil, nil, nil, nil
    end

    H.test("PLAYER_LOGOUT publishes this character's profile to the account data", function()
        local ns, frame = bootCore({ guid = "G1", name = "Azhariel", surname = "Deadheart", faction = "Horde" })
        H.eq(MakeOrBuyDB.version, 1); H.eq(ns.account, MakeOrBuyDB)
        ns.db.recipes[1] = { recipeID = 1, outputItemID = 2996, reagents = { { itemID = 2589, qty = 2 } } }
        frame:Fire("PLAYER_LOGOUT")
        local p = MakeOrBuyDB.chars.G1
        H.truthy(p, "published")
        H.eq(p.name, "Azhariel"); H.eq(p.surname, "Deadheart"); H.eq(p.faction, "Horde")
        H.truthy(p.uses[2589])
        cleanup()
    end)

    H.test("the restock list's shopping becomes the profile's needs", function()
        local ns = bootCore({ guid = "G1", name = "A", faction = "Horde" })
        ns.db.recipes[7] = { recipeID = 7, name = "Bolt", outputItemID = 2996, outputQty = 1, reagents = { { itemID = 2589, qty = 2 } } }
        ns.Reindex()
        ns.RestockAdd(7, 3)
        H.eq(MakeOrBuyDB.chars.G1.needs[2589], 6, "3 crafts x 2 cloth")
        cleanup()
    end)

    H.test("a secret or missing name isn't published (equivalence classes: secret, nil)", function()
        local ns = bootCore({ guid = "G1", name = "SECRET", secret = "SECRET" })
        ns.PublishSelf()
        H.eq(MakeOrBuyDB.chars.G1, nil, "secret name")
        ns = bootCore({ guid = nil, name = "A" })
        ns.PublishSelf()
        H.eq(next(MakeOrBuyDB.chars), nil, "no GUID")
        cleanup()
    end)

    H.test("saved profiles of other characters survive a reload", function()
        local frame = mock.installCore()
        mock.installAuctionator({}, {})
        MakeOrBuyDB = { version = 1, chars = { G2 = profile("Alt", nil, "Horde") } }
        local ns = H.load(CORE)
        frame:Fire("ADDON_LOADED", "MakeOrBuy")
        H.eq(ns.account.chars.G2.name, "Alt")
    end)

    ------------------------------------------------------------------------------------------------
    -- MailPanel smoke test

    local function widget()
        local w = { shown = false, scripts = {} }
        return setmetatable(w, { __index = function(t, k)
            if k == "Show" then return function(s) s.shown = true end end
            if k == "Hide" then return function(s) s.shown = false end end
            if k == "IsShown" then return function(s) return s.shown end end
            if k == "SetText" then return function(s, v) s.text = v end end
            if k == "GetText" then return function(s) return s.text end end
            if k == "SetScript" or k == "HookScript" then return function(s, n, fn) s.scripts[n] = fn end end
            if k == "SetParent" then return function(s, p) s.parent = p end end
            if k == "CreateFontString" or k == "CreateTexture" then return function() return widget() end end
            return function() end
        end })
    end

    local function bootMail(opts)
        local ns = bootCore({ guid = "ME", name = "Me", surname = "Mine", faction = "Horde" })
        local created = {}
        local mailEvents
        CreateFrame = function(kind, name)
            local w = widget()
            if not mailEvents and kind == "Frame" and not name then mailEvents = w end
            created[#created + 1] = w
            if name then _G[name] = w end
            return w
        end
        MailFrame = widget(); MailFrame.shown = true
        SendMailFrame = widget()
        SendMailNameEditBox = widget(); SendMailNameEditBox.text = opts.to or ""
        SendMailSubjectEditBox = widget(); SendMailSubjectEditBox.text = ""
        MailFrameTab_OnClick = function(_, tab) if tab == 2 then SendMailFrame.shown = true end end
        mock.used = {}
        local bag = opts.bag or { { itemID = 2589, stackCount = 20 }, { itemID = 2589, stackCount = 20 }, { itemID = 2589, stackCount = 5 },
            { itemID = 6948, stackCount = 1, isBound = true } }
        C_Container = {
            GetContainerNumSlots = function(b) return b == 0 and #bag or 0 end,
            GetContainerItemInfo = function(b, s) return b == 0 and bag[s] or nil end,
            UseContainerItem = function(b, s) mock.used[#mock.used + 1] = s end,
        }
        GetSendMailItem = function(i) return (opts.attached or 0) >= i and "x" or nil end
        ATTACHMENTS_MAX_SEND = 12
        GameTooltip = widget()
        MakeOrBuyDB.chars.ALT = profile("Tai", "Lor", "Horde", { [2589] = true, [6948] = true }, { [2589] = 22 })
        H.load({ "MailPanel.lua" }, ns)
        return ns, mailEvents
    end

    local function mailCleanup()
        MailFrame, SendMailFrame, SendMailNameEditBox, SendMailSubjectEditBox, MailFrameTab_OnClick = nil, nil, nil, nil, nil
        C_Container, GetSendMailItem, GameTooltip, MakeOrBuyMailPanel = nil, nil, nil, nil
        cleanup()
    end

    H.test("mailbox: the panel lists what your alt needs; soulbound items are left out", function()
        local ns, ev = bootMail({})
        ev.scripts.OnEvent(ev, "MAIL_SHOW")
        mock.runTimers()
        local f = ns.MailPanel.frame
        H.truthy(f and f.shown, "panel shown")
        H.truthy(f.rows[1].shown); H.eq(f.rows[2].shown, false, "the bound item isn't offered")
        H.truthy(f.rows[1].text.text:find("22x Item2589", 1, true), f.rows[1].text.text)
        H.truthy(f.rows[1].text.text:find("Tai Lor", 1, true))
        H.truthy(f.rows[1].text.text:find("restock 22", 1, true))
        ev.scripts.OnEvent(ev, "MAIL_CLOSED")
        H.eq(f.shown, false)
        mailCleanup()
    end)

    H.test("mailbox click (state: inbox -> send tab with name, subject and stacks attached)", function()
        local ns, ev = bootMail({})
        ev.scripts.OnEvent(ev, "MAIL_SHOW")
        mock.runTimers()
        local row = ns.MailPanel.frame.rows[1]
        row.scripts.OnClick(row)
        H.eq(SendMailFrame.shown, true, "switched to Send Mail")
        H.eq(SendMailNameEditBox.text, "Tai-Lor")
        H.eq(SendMailSubjectEditBox.text, "Materials")
        H.eq(#mock.used, 2, "20 + 5 covers 22 with the least extra")
        H.truthy(mock.chat[#mock.chat]:find("Attached 25x", 1, true), mock.chat[#mock.chat])
        mailCleanup()
    end)

    H.test("mailbox click won't mix recipients: a mail for someone else with attachments stays as is", function()
        local ns, ev = bootMail({ to = "Someone-Else", attached = 1 })
        ev.scripts.OnEvent(ev, "MAIL_SHOW")
        mock.runTimers()
        local row = ns.MailPanel.frame.rows[1]
        SendMailFrame.shown = true
        row.scripts.OnClick(row)
        H.eq(SendMailNameEditBox.text, "Someone-Else")
        H.eq(#mock.used, 0)
        H.truthy(mock.chat[#mock.chat]:find("already for Someone-Else", 1, true))
        mailCleanup()
    end)

    H.test("Daylight UI's mailbox: the panel sits beside it and a click fills its Send page", function()
        local ns, ev = bootMail({})
        -- Daylight UI shows its own window and parks the game's (still shown, out of sight)
        _G.DaylightUIMail = widget(); DaylightUIMail.shown = true
        local page = widget()
        page.to, page.subject = widget(), widget()
        page.subject.text = ""
        local send = { page = page }
        local window = { ShowTab = function(id) if id == "send" then page.shown = true end end }
        DaylightUI = { GetModule = function(_, name) return name == "Mail" and { ns = { Window = window, Send = send } } or nil end }
        ev.scripts.OnEvent(ev, "MAIL_SHOW")
        mock.runTimers()
        local f = ns.MailPanel.frame
        H.truthy(f.shown, "panel shown")
        local row = f.rows[1]
        row.scripts.OnClick(row)
        H.eq(page.shown, true, "switched to Daylight UI's Send page")
        H.eq(page.to.text, "Tai-Lor")
        H.eq(page.subject.text, "Materials")
        H.eq(SendMailNameEditBox.text, "", "the game's parked form is left alone")
        H.eq(#mock.used, 2)
        -- A Daylight UI whose Send page can't be opened this way: nothing is attached, and it says so
        page.shown = false
        window.ShowTab = function() end
        row.scripts.OnClick(row)
        H.truthy(mock.chat[#mock.chat]:find("Open the Send Mail tab first", 1, true), mock.chat[#mock.chat])
        -- It lives on Daylight UI's window and closes with it, even when MAIL_CLOSED doesn't come
        H.eq(f.parent, DaylightUIMail, "on Daylight UI's window")
        DaylightUIMail.shown = false
        DaylightUIMail.scripts.OnHide(DaylightUIMail)
        H.eq(f.shown, false, "closed with the mailbox")
        DaylightUIMail, DaylightUI = nil, nil
        mailCleanup()
    end)

    H.test("mailbox with nothing for your alts keeps the panel hidden; /mob alts says why", function()
        local ns, ev = bootMail({ bag = { { itemID = 1, stackCount = 1 } } })
        ev.scripts.OnEvent(ev, "MAIL_SHOW")
        mock.runTimers()
        H.eq(ns.MailPanel.frame, nil, "never built")
        ns.PrintAlts()
        H.truthy(mock.chat[#mock.chat]:find("Nothing in your bags", 1, true))
        MakeOrBuyDB.chars.ALT = nil
        ns.PrintAlts()
        H.truthy(mock.chat[#mock.chat]:find("No other characters known yet", 1, true))
        mailCleanup()
    end)
end
