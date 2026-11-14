-- Test doubles (ISTQB: stubs/fakes) for the WoW and Auctionator APIs Haul touches.
local M = {}

-- Installs the globals Core.lua needs and returns the fake event frame.
-- opts: { money, level, xp, xpMax, zone, ah = {[id]=copper}, items = {[id]=sellPrice}, uncached = {[id]=true} }
function M.install(opts)
    opts = opts or {}
    M.state = {
        money = opts.money or 0, level = opts.level or 10, xp = opts.xp or 0, xpMax = opts.xpMax or 1000,
        zone = opts.zone or "Elwynn Forest", afk = false, now = opts.now or 1000, clock = 0,
        items = opts.items or {}, uncached = opts.uncached or {}, secrets = {},
    }
    local st = M.state
    local frame = { events = {} }
    function frame:RegisterEvent(e) self.events[e] = true end
    function frame:SetScript(_, fn) self.handler = fn end
    function frame:Fire(event, ...) self.handler(self, event, ...) end
    M.frame = frame
    CreateFrame = function() return frame end
    SlashCmdList = {}
    M.chat = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.chat[#M.chat + 1] = msg end }
    GetMoneyString = function(c) return c .. "c" end
    GetCoinTextureString = nil
    time = function() return st.now end
    GetTime = function() return st.clock end
    GetMoney = function() return st.money end
    UnitLevel = function() return st.level end
    UnitXP = function() return st.xp end
    UnitXPMax = function() return st.xpMax end
    UnitIsAFK = function() return st.afk end
    GetRealZoneText = function() return st.zone end
    date = function() return "11/07 12:00" end
    issecretvalue = function(v) return st.secrets[v] == true end
    M.requested = {}
    C_Item = {
        GetItemInfo = function(id)
            if st.uncached[id] then return nil end
            return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, st.items[id] or 0
        end,
        RequestLoadItemDataByID = function(id) M.requested[#M.requested + 1] = id end,
    }
    local ah = opts.ah or {}
    Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id) return ah[id] end } } }
    C_Timer = { NewTicker = function(_, fn) M.ticker = fn return {} end }
    LOOT_ITEM_SELF = "You receive loot: %s."
    LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
    LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
    LOOT_ITEM_CREATED_SELF = "You create: %s."
    HaulCharDB = nil
    return frame
end

function M.link(id, name)
    return "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. (name or ("Item" .. id)) .. "]|h|r"
end

-- Boots Haul through ADDON_LOADED and PLAYER_LOGIN, optionally with saved data
function M.boot(H, opts, savedDB, files)
    local frame = M.install(opts)
    HaulCharDB = savedDB
    local ns = H.load(files or { "Session.lua", "Core.lua" })
    frame:Fire("ADDON_LOADED", "Haul")
    frame:Fire("PLAYER_LOGIN")
    return ns, frame
end

return M
