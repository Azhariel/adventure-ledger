-- The /ledger window: Ledger Link's status, its warnings, and the window against fake widgets
return function(H)
    local test, eq, load, stubAuctionator, at = H.test, H.eq, H.load, H.stubAuctionator, H.at
    local function truthy(v, msg) if not v then error((msg or "expected a true value"), 2) end end

    local function find(status, title)
        for _, s in ipairs(status.sections) do
            if s.title == title then
                local rows = {}
                for _, r in ipairs(s.rows) do rows[r[1]] = r[2] end
                return rows, s.rows
            end
        end
    end
    local function warned(status, text)
        for _, w in ipairs(status.warnings) do if w:find(text, 1, true) then return true end end
        return false
    end

    -- Swaps CreateFrame for fake widgets: unknown Set*/Get*/... methods do nothing, Show/Hide/SetText are kept.
    -- Returns { [frame name] = frame, fonts = { every font string made } }.
    local function useFakeWidgets()
        local made = { fonts = {} }
        local function noop() end
        local Fake = {}
        local function new()
            return setmetatable({ scripts = {}, shown = true }, { __index = function(_, k)
                if Fake[k] then return Fake[k] end
                if type(k) == "string" and (k:match("^Set%u") or k:match("^Get%u") or k:match("^Enable")
                    or k:match("^Clear") or k:match("^Register") or k:match("^Start") or k:match("^Stop")) then
                    return noop
                end
            end })
        end
        function Fake:Show() if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
        function Fake:Hide() self.shown = false end
        function Fake:IsShown() return self.shown end
        function Fake:SetScript(name, fn) self.scripts[name] = fn end
        function Fake:SetText(t) self.text = t end
        function Fake:GetText() return self.text end
        function Fake:GetPoint() return "TOPLEFT", nil, "BOTTOMLEFT", 40, 300 end
        function Fake:CreateTexture() return new() end
        function Fake:CreateFontString() local fs = new(); made.fonts[#made.fonts + 1] = fs; return fs end
        _G.CreateFrame = function(_, name)
            local f = new()
            if name then made[name] = f end
            return f
        end
        _G.UIParent = _G.UIParent or new()
        _G.UISpecialFrames = {}
        return made
    end

    test("status: combat log state, the realm key, Neutral mode and book counts, recent visits", function()
        local L, st = load(); stubAuctionator()
        st.fire()
        at(1446, "Gadgetzan", "Tanaris"); L.OnAuctionShow(os.time() - 120)
        Auctionator.Database:SetPrice("2447", 400, 3)
        Auctionator.Database:SetPrice("765", 10, 1)
        at(1411, "", "Orgrimmar"); L.OnAuctionShow(os.time() - 60)
        Auctionator.Database:SetPrice("2447", 300, 40)
        local s = st.ns.Status()
        local log = find(s, "Combat log")
        eq(log["Logging now"], "on"); eq(log["Switch on at login"], "yes")
        local prices = find(s, "Prices")
        eq(prices["Realm key"], "PvP"); eq(prices["Neutral mode"], "split")
        truthy(tostring(prices["Neutral book"]):find("^2 items"), "two Neutral items: " .. tostring(prices["Neutral book"]))
        truthy(tostring(prices["Horde book"]):find("^1 item"), "one Horde item: " .. tostring(prices["Horde book"]))
        truthy(tostring(prices["Neutral book"]):find("last price now", 1, true), "with when it last saw a price")
        eq(prices["Books, all realms"], 2)
        local _, visits = find(s, "Auction house visits")
        eq(#visits, 2)
        truthy(visits[1][2]:find("faction", 1, true) and visits[1][2]:find("Orgrimmar", 1, true), "newest first")
        truthy(visits[2][2]:find("neutral", 1, true) and visits[2][2]:find("Tanaris", 1, true))
        eq(#s.warnings, 0, "nothing wrong")
    end)

    test("status: only the last few visits", function()
        local L, st = load(); stubAuctionator()
        at(1411, "", "Orgrimmar")
        for i = 1, 12 do L.OnAuctionShow(os.time() - 100 + i) end
        local _, visits = find(st.ns.Status(), "Auction house visits")
        eq(#visits, 5)
    end)

    test("warns when the combat log is off while Ledger Link should keep it on", function()
        local L, st = load(); stubAuctionator()
        truthy(warned(st.ns.Status(), "Live"), "logging off, enable on: the Live view gets nothing")
        L.Command("off")
        eq(warned(st.ns.Status(), "Live"), false, "switched off on purpose: no warning")
        eq(find(st.ns.Status(), "Combat log")["Switch on at login"], "no")
    end)

    test("warns when the realm key is ?: no realm and no game rules", function()
        local _, st = load({ realm = function() return "" end, on = true }); stubAuctionator()
        local s = st.ns.Status()
        eq(find(s, "Prices")["Realm key"], "?")
        truthy(warned(s, '"?"'))
    end)

    test("warns when Auctionator isn't loaded: no prices recorded", function()
        local _, st = load({ on = true })
        truthy(warned(st.ns.Status(), "Auctionator"))
        stubAuctionator()
        eq(warned(st.ns.Status(), "Auctionator"), false)
    end)

    test("/ledger toggles the window; /ledger print sends the status to the chat", function()
        local L, st = load({ on = true }); stubAuctionator()
        local made = useFakeWidgets()
        local n = #st.printed
        SlashCmdList.LEDGERLINK("")
        local f = made.LedgerLinkStatusFrame
        truthy(f, "the window is made on first use")
        truthy(f.shown, "and shown")
        eq(#st.printed, n, "nothing goes to the chat")
        local texts = {}
        for _, fs in ipairs(made.fonts) do if fs.text then texts[#texts + 1] = fs.text end end
        local all = table.concat(texts, "\n")
        truthy(all:find("Ledger Link", 1, true) and all:find("Combat log", 1, true), "the window shows the status")
        SlashCmdList.LEDGERLINK("")
        eq(f.shown, false, "a second /ledger closes it")
        SlashCmdList.LEDGERLINK("print")
        truthy(#st.printed > n + 5, "the status went to the chat")
        truthy(table.concat(st.printed, "\n"):find("Realm key", 1, true))
    end)

    test("the window's place is saved in LedgerLinkDB.window and survives a login", function()
        local L, st = load({ on = true }); stubAuctionator()
        local made = useFakeWidgets()
        SlashCmdList.LEDGERLINK("")
        made.LedgerLinkStatusFrame.scripts.OnDragStop(made.LedgerLinkStatusFrame)
        eq(LedgerLinkDB.window.point, "TOPLEFT"); eq(LedgerLinkDB.window.x, 40)
        st.fire()
        eq(LedgerLinkDB.window.y, 300, "Migrate and Ensure keep it")
    end)

    test("without frames, /ledger prints the status instead", function()
        local _, st = load()
        local n = #st.printed
        SlashCmdList.LEDGERLINK("") -- load's CreateFrame stub makes no font strings
        truthy(#st.printed > n + 5)
    end)
end
