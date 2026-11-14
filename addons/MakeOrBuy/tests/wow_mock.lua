-- Test doubles for the parts of the WoW and Auctionator APIs MakeOrBuy touches (ISTQB: stubs/fakes).
local M = {}

-- Fake C_TradeSkillUI backed by a table of recipes:
-- { [recipeID] = { learned = bool, schematic = {...} } }
function M.installTradeSkill(recipes, opts)
    opts = opts or {}
    Enum = { CraftingReagentType = { Basic = 0, Modifying = 1, Finishing = 2 } }
    C_TradeSkillUI = {
        IsTradeSkillLinked = function() return opts.linked or false end,
        IsTradeSkillGuild = function() return false end,
        IsNPCCrafting = function() return false end,
        GetBaseProfessionInfo = function() return { professionID = opts.professionID or 197 } end,
        GetAllRecipeIDs = function()
            local ids = {}
            for id in pairs(recipes) do
                ids[#ids + 1] = id
            end
            table.sort(ids)
            return ids
        end,
        GetRecipeInfo = function(id)
            local r = recipes[id]
            return r and { recipeID = id, learned = r.learned, relativeDifficulty = r.difficulty,
                numSkillUps = r.numSkillUps } or nil
        end,
        GetRecipeSchematic = function(id)
            return recipes[id] and recipes[id].schematic
        end,
    }
end

-- Basic reagent slot helper
function M.slot(itemID, qty, reagentType)
    return { reagentType = reagentType or 0, quantityRequired = qty, reagents = { { itemID = itemID } } }
end

-- Minimal globals Core.lua needs at load time; returns the fake event frame so tests can fire events.
function M.installCore()
    local frame = { events = {} }
    function frame:RegisterEvent(e) self.events[e] = true end
    function frame:SetScript(_, fn) self.handler = fn end
    function frame:Fire(event, ...) self.handler(self, event, ...) end
    CreateFrame = function() return frame end
    SlashCmdList = {}
    M.chat = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.chat[#M.chat + 1] = msg end }
    GetMoneyString = function(c) return c .. "c" end
    M.timers = {}
    C_Timer = { After = function(_, fn) M.timers[#M.timers + 1] = fn end }
    C_Item = { GetItemNameByID = function(id) return "Item" .. id end }
    MakeOrBuyCharDB = nil
    return frame
end

function M.runTimers()
    local pending = M.timers
    M.timers = {}
    for _, fn in ipairs(pending) do
        fn()
    end
end

-- Fake Auctionator price API: vendor and ah are { [itemID] = copper }
function M.installAuctionator(vendor, ah)
    M.callers = {}
    Auctionator = { API = { v1 = {
        GetVendorPriceByItemID = function(caller, id) M.callers[caller] = true return vendor[id] end,
        GetAuctionPriceByItemID = function(caller, id) M.callers[caller] = true return ah[id] end,
    } } }
end

return M
