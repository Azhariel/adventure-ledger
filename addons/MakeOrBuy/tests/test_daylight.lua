-- Daylight.lua against a fake DaylightUI.API (ISTQB: fakes for an external interface). The fake keeps
-- what Make or Buy asked for (pane, events, painters, wraps) so the tests can play Daylight UI's part:
-- open its profession window, pick a recipe, paint a recipe line.
return function(H)
    local F = require("ui_fakes")
    local mock, newObj, Fake = F.mock, F.newObj, F.Fake

    local function fakeDaylight()
        local dl = { events = {}, painters = {}, wraps = {}, offs = 0, selected = nil }
        local theirProfit = { Of = function() return { profit = -1, known = true } end }
        dl.Profit = theirProfit
        local holders = {}
        local API = { major = 1, minor = 13 }
        function API.Colors()
            local c = { 1, 1, 1 }
            return { TITLE = c, VALUE = c, TEXT = c, LABEL = { 0.8, 0.7, 0.5 }, OFF = { 0.5, 0.5, 0.5 },
                GOOD = { 0.3, 1, 0.3 }, WARN = { 1, 0.6, 0.2 }, BAD = { 1, 0.3, 0.3 } }
        end
        function API.Accent() return 0.4, 0.5, 1 end
        function API.Text(parent) return parent:CreateFontString() end
        function API.Button() return newObj() end
        function API.Close() return newObj() end
        function API.Skin(frame) frame.skinned = true end
        function API.Attach(frame)
            holders[frame] = holders[frame] or newObj()
            return holders[frame]
        end
        function API.Off() dl.offs = dl.offs + 1 end
        function API.SelectCraftRecipe(id) dl.selected = id return true end
        function API.For(name)
            dl.plugin = name
            return {
                AttachCraftPane = function(width) dl.paneWidth = width dl.pane = newObj() return dl.pane end,
                On = function(event, fn) dl.events[event] = fn end,
                Paint = function(kind, fn) dl.painters[kind] = fn return {} end,
                Wrap = function(tbl, fname, fn)
                    local original = tbl[fname]
                    tbl[fname] = function(...) return fn(original, ...) end
                    dl.wraps[#dl.wraps + 1] = fname
                end,
                RegisterSkin = function(_, fn) fn({ Auto = function() end, Font = function() end }) return true end,
            }
        end
        dl.holders = holders
        DaylightUI = { API = API, GetModule = function(_, name)
            return name == "Professions" and { ns = { Profit = theirProfit } } or nil
        end }
        return dl
    end

    local function bootWithDaylight(opts)
        local dl
        opts = opts or {}
        opts.files = { "MailPanel.lua", "Daylight.lua" }
        opts.beforeLoad = function() dl = fakeDaylight() end
        local ns, frames, tab, panel = F.boot(H, opts)
        frames[1].scripts.OnEvent(frames[1], "PLAYER_LOGIN")
        return ns, dl, tab, panel
    end

    local function texts()
        local out = {}
        for _, fs in ipairs(mock.fonts) do
            if fs.text then out[#out + 1] = fs.text end
        end
        return table.concat(out, "\n")
    end

    H.test("no Daylight UI: nothing is set up and the game's window keeps its lines and tab", function()
        local ns, _, tab = F.boot(H, { files = { "MailPanel.lua", "Daylight.lua" } })
        DaylightUI = nil
        H.eq(ns.Daylight.Init(), false)
        H.eq(ns.Daylight.InUse(), false)
        H.truthy(tab:IsShown(), "side tab")
        H.truthy(_G.MakeOrBuyProfessionsFrame.Text.text:find("Make or Buy cost"), "lines on the game's window")
    end)

    H.test("login: a slim pane is docked, Profit.Of is wrapped and recipe lines get a painter", function()
        local _, dl = bootWithDaylight()
        H.eq(dl.plugin, "MakeOrBuy")
        H.eq(dl.paneWidth, 240)
        H.truthy(dl.events.CraftShown and dl.events.CraftRecipeSelected, "events")
        H.truthy(dl.painters.craftrow, "craftrow painter")
        H.eq(dl.wraps[1], "Of")
    end)

    H.test("picking a recipe fills the pane: cost with savings, profit, reagents", function()
        local _, dl = bootWithDaylight()
        mock.fonts = {}
        dl.events.CraftShown()
        dl.events.CraftRecipeSelected(3757) -- Woolen Bag: bolts crafted from wool
        local t = texts()
        H.truthy(t:find("Cost"), t)
        H.truthy(t:find("559c"), t)
        H.truthy(t:find("saves 1341c"), t)
        H.truthy(t:find("Profit"), t)
        H.truthy(t:find("296c"), t)
        H.truthy(t:find("3x Item2997"), t) -- the bolts
        H.truthy(t:find("craft 3x"), t)
    end)

    H.test("recipe lines show our profit in Daylight UI's spot; its recipe page keeps its Profit section off", function()
        local _, dl = bootWithDaylight()
        dl.events.CraftShown()
        local p = dl.Profit.Of({ id = 3757 })
        H.eq(p.profit, 296)
        H.eq(p.known, nil)
        -- A recipe we can't price is left to Daylight UI
        H.eq(dl.Profit.Of({ id = 99999 }).profit, -1)
    end)

    H.test("restock: the pane's button adds a craft, the line's icon shows the count", function()
        local ns, dl = bootWithDaylight()
        dl.events.CraftShown()
        dl.events.CraftRecipeSelected(3757)
        ns.RestockAdd(3757, 2)
        local row, icon = newObj(), newObj()
        dl.painters.craftrow(row, { icon = icon }, { recipeID = 3757 })
        local badge = dl.holders[row].mobRestock
        H.eq(badge.text, "2")
        H.truthy(badge:IsShown(), "badge shown")
        H.truthy(dl.offs > 0, "lines redrawn after the change")
        dl.painters.craftrow(row, { icon = icon }, { recipeID = 2964 })
        H.eq(badge:IsShown(), false)
    end)

    H.test("with Daylight UI's window open the side tab hides; Views opens the panel as its own window", function()
        local ns, dl, tab, panel = bootWithDaylight()
        dl.events.CraftShown()
        mock.runTimers()
        H.eq(tab:IsShown(), false)
        ns.ProfitTab.ToggleWindow()
        H.truthy(panel:IsShown(), "views window")
        H.truthy(panel.skinned, "Daylight UI's shell")
        H.truthy(#mock.rows > 0, "rows built")
        -- Opening a recipe from the views selects it in Daylight UI's window
        mock.view.init(newObj(), mock.rows[1])
        dl.events.CraftHidden()
        H.eq(panel:IsShown(), false)
    end)

    H.test("Daylight UI's window closed and the game's shown again: the tab and docked panel come back", function()
        local ns, dl, tab, panel = bootWithDaylight()
        dl.events.CraftShown()
        ns.ProfitTab.ToggleWindow()
        dl.events.CraftHidden()
        ns.ProfitTab.HostChanged()
        H.truthy(tab:IsShown(), "tab back")
        ns.ProfitTab.Toggle()
        H.truthy(panel:IsShown(), "panel as the tab's page")
    end)
end
