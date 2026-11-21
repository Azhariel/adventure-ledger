-- Smoke tests: run UI.lua on fake widgets to catch Lua errors and check the text it shows.
return function(H)
    local mock = require("wow_mock")

    local function fakeWidget()
        local w = { shown = true, scripts = {}, children = {} }
        return setmetatable(w, { __index = function(t, k)
            if type(k) == "string" and (k:match("^Set") or k:match("^Enable") or k:match("^Register")
                or k:match("^Clear") or k == "StartMoving" or k == "StopMovingOrSizing") then
                return function() end
            end
            return nil
        end })
    end

    local function install()
        UIParent = fakeWidget()
        local tip = { lines = {} }
        function tip:SetOwner() self.lines = {} end
        function tip:AddLine(t) self.lines[#self.lines + 1] = t end
        function tip:AddDoubleLine(a, b) self.lines[#self.lines + 1] = a .. " | " .. b end
        function tip:Show() end
        function tip:Hide() end
        GameTooltip = tip
        local base = CreateFrame -- the event frame from wow_mock
        CreateFrame = function(kind, name)
            if name ~= "HaulFrame" then
                return base(kind, name)
            end
            local f = fakeWidget()
            function f:SetScript(k, fn) self.scripts[k] = fn end
            function f:IsShown() return self.shown end
            function f:Show() self.shown = true end
            function f:Hide() self.shown = false end
            function f:GetPoint() return "TOP", nil, "TOP", 5, -50 end
            function f:CreateFontString()
                local fs = fakeWidget()
                function fs:SetText(t) self.text = t end
                function fs:GetStringWidth() return #(self.text or "") * 5 end -- 5px per character
                return fs
            end
            function f:CreateTexture() return fakeWidget() end
            function f:SetWidth(w) self.width = w end
            return f
        end
    end

    local function boot(opts)
        mock.install(opts)
        install()
        local ns = H.load({ "Session.lua", "Core.lua", "UI.lua" })
        local frame = mock.frame
        frame:Fire("ADDON_LOADED", "Haul")
        frame:Fire("PLAYER_LOGIN")
        return ns, frame, ns.UI.frame
    end

    H.test("frame shows duration, rate, income split and XP", function()
        local ns, f, ui = boot({ ah = { [2592] = 1000 }, items = { [2592] = 10 }, xp = 0, xpMax = 6000 })
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(2592) .. "x2.")
        f:Fire("QUEST_TURNED_IN", 1, 0, 100)
        mock.state.xp = 1000
        f:Fire("PLAYER_XP_UPDATE", "player")
        mock.state.now = 1000 + 1800
        mock.ticker()
        H.eq(ui.lines[1].text, "|cffe6b422Haul|r 0:30  4000c/h")
        H.eq(ui.lines[2].text, "Loot 1900c · Coin 0c · Quests 100c")
        H.eq(ui.lines[3].text, "XP 2.0k/h · level in 2h 30m")
    end)

    H.test("rate shows -- in the first minute and the paused state is labelled", function()
        local ns, f, ui = boot()
        mock.ticker()
        H.eq(ui.lines[1].text, "|cffe6b422Haul|r 0:00  --")
        SlashCmdList.HAUL("pause")
        H.truthy(ui.lines[1].text:find("%(paused%)"), ui.lines[1].text)
        H.eq(ui.lines[3].text, "XP 0")
    end)

    H.test("tooltip lists top loot, zones and past sessions", function()
        local ns, f, ui = boot({ items = { [2592] = 10 }, uncached = { [4306] = true } })
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(2592) .. ".")
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(4306) .. ".")
        mock.state.now = 1000 + 600
        SlashCmdList.HAUL("reset")
        f:Fire("CHAT_MSG_LOOT", "You receive loot: " .. mock.link(2592) .. ".")
        mock.state.now = 1000 + 1200
        ui.scripts.OnEnter(ui)
        local text = table.concat(GameTooltip.lines, "\n")
        H.truthy(text:find("Top loot"), text)
        H.truthy(text:find("%[Item2592%]|h|r x1 | 10c"), text)
        H.truthy(text:find("Elwynn Forest"), text)
        H.truthy(text:find("Last sessions\n0:10  10c | 60c/h"), text)
    end)

    H.test("frame width follows the longest line, with a minimum (boundary: short vs long text)", function()
        local ns, f, ui = boot()
        mock.ticker()
        H.eq(ui.width, 200, "short lines keep the minimum width")
        f:Fire("QUEST_TURNED_IN", 1, 0, 123456789012)
        mock.ticker()
        H.eq(ui.width, #ui.lines[2].text * 5 + 16, "grows to the income line plus padding")
    end)

    H.test("with Daylight UI the window wears its shell, font and accent", function()
        local skinned
        DaylightUI = { API = { major = 1, minor = 13,
            Skin = function(f) skinned = f end,
            Accent = function() return 0.4, 0.5, 1 end,
            Colors = function() return { VALUE = { 1, 1, 1 }, TEXT = { 0.9, 0.9, 0.9 } } end,
            Text = function(parent) return parent:CreateFontString() end } }
        local ns, f, ui = boot()
        mock.ticker()
        H.eq(skinned, ui, "Daylight UI's shell")
        H.eq(ui.lines[1].text, "|cff6680ffHaul|r 0:00  --")
        H.eq(ui.width, 200)
        f:Fire("QUEST_TURNED_IN", 1, 0, 123456789012)
        mock.ticker()
        H.eq(ui.width, #ui.lines[2].text * 5 + 20, "its padding is a little wider")
        DaylightUI = nil
    end)

    H.test("toggle hides and shows, the choice and dragged position are saved", function()
        local ns, f, ui = boot()
        SlashCmdList.HAUL("")
        H.eq(ui.shown, false); H.eq(HaulCharDB.window.shown, false)
        SlashCmdList.HAUL("")
        H.eq(ui.shown, true)
        ui.scripts.OnDragStop(ui)
        H.eq(HaulCharDB.window.point[1], "TOP"); H.eq(HaulCharDB.window.point[4], -50)
    end)
end
