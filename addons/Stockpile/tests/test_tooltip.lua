-- Component integration tests for Tooltip.lua on fake tooltips.
return function(H)
    local mock = require("wow_mock")

    local function boot(opts)
        opts = opts or {}
        opts.containers = { [0] = { n = 1, { 2592, 20 } } }
        opts.db = { version = 1, chars = {
            ["Bankalt-Deadheart"] = { name = "Bankalt", realm = "Deadheart", class = "MAGE",
                bags = {}, bank = { [2592] = 10 }, mail = { [2592] = 4 } },
            ["Faraway-Otherrealm"] = { name = "Faraway", realm = "Otherrealm", class = "MAGE",
                bags = { [2592] = 99 }, bank = {}, mail = {} },
        } }
        return mock.boot(H, opts)
    end

    H.test("item tooltip shows the realm total and class-colored lines per character", function()
        boot()
        local tip = mock.tooltip()
        mock.postCalls[0](tip, { id = 2592 })
        H.eq(tip.lines[1], "Stockpile: 34")
        H.eq(tip.lines[2], "  |cffffffffAzhariel|r: 20 bags")
        H.eq(tip.lines[3], "  |cff3fc7ebBankalt|r: 10 bank, 4 mail")
        H.eq(#tip.lines, 3, "other realm left out")
        H.eq(tip.shown, 1, "tooltip resized")
    end)

    H.test("items nobody has add nothing", function()
        boot()
        local tip = mock.tooltip()
        mock.postCalls[0](tip, { id = 12345 })
        H.eq(#tip.lines, 0); H.eq(tip.shown, 0)
    end)

    H.test("secret item id in tooltip data falls back to the tooltip's item link", function()
        boot()
        local tip = mock.tooltip("|cffffffff|Hitem:2592::::::::|h[Wool Cloth]|h|r")
        mock.postCalls[0](tip, { id = mock.SECRET })
        H.eq(tip.lines[1], "Stockpile: 34")
    end)

    H.test("secret id and secret link add nothing and don't error", function()
        boot()
        local tip = mock.tooltip(mock.SECRET)
        mock.postCalls[0](tip, { id = mock.SECRET })
        H.eq(#tip.lines, 0)
    end)

    H.test("without TooltipDataProcessor, OnTooltipSetItem is hooked on GameTooltip and ItemRefTooltip", function()
        boot({ tooltipProcessor = false, gameTooltipLink = "item:2592" })
        H.truthy(GameTooltip.hooks and GameTooltip.hooks.OnTooltipSetItem)
        H.truthy(ItemRefTooltip.hooks.OnTooltipSetItem)
        GameTooltip.hooks.OnTooltipSetItem(GameTooltip)
        H.eq(GameTooltip.lines[1], "Stockpile: 34")
        GameTooltip, ItemRefTooltip = nil, nil
    end)
end
