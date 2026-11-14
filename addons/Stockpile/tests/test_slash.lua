-- Component integration tests for the /stockpile slash command.
return function(H)
    local mock = require("wow_mock")

    local function boot()
        return mock.boot(H, {
            containers = { [0] = { n = 1, { 2592, 20 } } },
            db = { version = 1, chars = {
                ["Bankalt-Deadheart"] = { name = "Bankalt", realm = "Deadheart", class = "MAGE",
                    bags = {}, bank = { [2592] = 10 }, mail = {} },
            } },
        })
    end

    H.test("both slash names are registered", function()
        boot()
        H.eq(SLASH_STOCKPILE1, "/stockpile"); H.eq(SLASH_STOCKPILE2, "/stock")
        H.truthy(SlashCmdList.STOCKPILE)
    end)

    H.test("an item link prints the total and a line per character", function()
        boot()
        SlashCmdList.STOCKPILE("|cffffffff|Hitem:2592::::::::|h[Wool Cloth]|h|r")
        H.truthy(mock.chat[1]:find("Item2592: 30", 1, true), mock.chat[1])
        H.truthy(mock.chat[2]:find("Azhariel|r: 20 bags", 1, true), mock.chat[2])
        H.truthy(mock.chat[3]:find("Bankalt|r: 10 bank", 1, true), mock.chat[3])
    end)

    H.test("an item id nobody has says so", function()
        boot()
        SlashCmdList.STOCKPILE("12345")
        H.truthy(mock.chat[1]:find("none on this realm"), mock.chat[1])
    end)

    H.test("no arguments prints usage and the tracked characters", function()
        boot()
        SlashCmdList.STOCKPILE("")
        H.truthy(mock.chat[1]:find("/stockpile %[item"), mock.chat[1])
        H.truthy(mock.chat[3]:find("Bank: not saved yet. Talk to a banker"), mock.chat[3])
        H.truthy(mock.chat[4]:find("Azhariel%-Deadheart, Bankalt%-Deadheart"), mock.chat[4])
    end)

    H.test("usage shows when this character's bank was last saved", function()
        boot()
        mock.frame:Fire("BANKFRAME_OPENED")
        mock.chat = {}
        SlashCmdList.STOCKPILE("")
        H.eq(mock.chat[3], "|cff88ccffStockpile|r: Bank: saved " .. os.date("%Y-%m-%d %H:%M", mock.now))
    end)

    H.test("forget removes a character and notifies; unknown names explain", function()
        boot()
        mock.runTimers()
        SlashCmdList.STOCKPILE("forget Bankalt-Deadheart")
        H.eq(StockpileDB.chars["Bankalt-Deadheart"], nil)
        H.truthy(mock.chat[1]:find("Forgot Bankalt%-Deadheart"))
        H.eq(#mock.timers, 1, "change callback scheduled")
        SlashCmdList.STOCKPILE("forget Nobody-Deadheart")
        H.truthy(mock.chat[2]:find("No character called"))
    end)

    H.test("forgetting the current character: it is tracked again on the next scan", function()
        boot()
        SlashCmdList.STOCKPILE("forget Azhariel-Deadheart")
        H.eq(StockpileDB.chars["Azhariel-Deadheart"], nil)
        mock.frame:Fire("BAG_UPDATE_DELAYED")
        H.eq(StockpileDB.chars["Azhariel-Deadheart"].bags[2592], 20)
    end)
end
