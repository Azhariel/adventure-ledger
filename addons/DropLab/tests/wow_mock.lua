-- Test doubles (ISTQB: stubs/fakes) for the WoW, Make or Buy and WhereToFarm APIs DropLab touches.
local M = {}

-- A creature GUID like the game's
function M.guid(npcID, spawn, kind)
    return (kind or "Creature") .. "-0-1-2-3-" .. npcID .. "-" .. (spawn or "0000ABCD")
end

function M.link(id, name)
    return "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. (name or ("Item" .. id)) .. "]|h|r"
end

-- opts: { sale = {[id]=copper}, buy = {[id]=copper}, questie = {[itemID] = { {npcID, rate} }}, noWhereToFarm,
--         noAuctionator }
function M.install(opts)
    opts = opts or {}
    M.state = { clock = 0, units = {}, loot = {}, fishing = false, secrets = {} }
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
    GetTime = function() return st.clock end
    issecretvalue = function(v) return v ~= nil and st.secrets[v] == true end
    geterrorhandler = function() return function(err) error(err, 0) end end
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
    Enum = { LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 }, TooltipDataType = { Unit = 2 } }

    -- units: st.units[unit] = { guid, name, dead, player }
    UnitExists = function(u) return st.units[u] ~= nil end
    UnitGUID = function(u) return st.units[u] and st.units[u].guid end
    UnitName = function(u) return st.units[u] and st.units[u].name end
    UnitIsDead = function(u) return st.units[u] and st.units[u].dead or false end
    UnitIsPlayer = function(u) return st.units[u] and st.units[u].player or false end

    -- loot window: st.loot = { { money = bool, link, text, sources = { guid, qty, guid, qty } } }
    GetNumLootItems = function() return #st.loot end
    GetLootSlotType = function(i) return st.loot[i].money and 2 or 1 end
    GetLootSlotLink = function(i) return st.loot[i].link end
    GetLootSlotInfo = function(i) return 134400, st.loot[i].text end
    GetLootSourceInfo = function(i) return unpack(st.loot[i].sources) end
    IsFishingLoot = function() return st.fishing end
    unpack = unpack or table.unpack

    C_Item = { GetItemNameByID = function(id) return "Item" .. id end,
        GetItemIconByID = function(id) return "icon" .. id end }

    local sale, buy = opts.sale or {}, opts.buy or {}
    MakeOrBuy = { API = {
        GetSaleValue = function(id) return sale[id] end,
        GetBuyPrice = function(id) return buy[id], buy[id] and "ah" or nil end,
    } }
    -- Make or Buy prices from Auctionator; DropLab only checks it's there
    Auctionator = not opts.noAuctionator and { API = { v1 = {} } } or nil
    if opts.noWhereToFarm then
        WhereToFarm = nil
    else
        local questie = opts.questie or {}
        WhereToFarm = { API = { GetSources = function(itemID)
            local out = {}
            for _, s in ipairs(questie[itemID] or {}) do
                out[#out + 1] = { npcID = s[1], rate = s[2] }
            end
            return out
        end } }
    end

    M.tooltipCalls = {}
    TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) M.tooltipCalls[kind] = fn end }
    M.tooltipLines = {}
    GameTooltip = { AddLine = function(_, text) M.tooltipLines[#M.tooltipLines + 1] = text end }
    DropLabDB = nil
    DropLab = nil
    return frame
end

-- Boots DropLab through ADDON_LOADED and PLAYER_LOGIN, optionally with saved data
function M.boot(H, opts, savedDB)
    local frame = M.install(opts)
    DropLabDB = savedDB
    local ns = H.load({ "Stats.lua", "Core.lua", "StatusWindow.lua", "Status.lua" })
    frame:Fire("ADDON_LOADED", "DropLab")
    frame:Fire("PLAYER_LOGIN")
    return ns, frame
end

-- Frames that can make font strings, so the /droplab window can be built: made[name] = the named frame,
-- made.fonts = every font string. Each fake records shown, text and scripts; other Set*/Get* calls do nothing.
function M.useFakeWidgets()
    local made = { fonts = {} }
    local function noop() end
    local Fake = {}
    local function new()
        return setmetatable({ scripts = {}, shown = true }, { __index = function(_, k)
            if Fake[k] then return Fake[k] end
            if type(k) == "string" and (k:match("^Set%u") or k:match("^Get%u") or k:match("^Enable") or k:match("^Clear")
                or k:match("^Register") or k:match("^Start") or k:match("^Stop")) then return noop end
        end })
    end
    function Fake:Show() if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
    function Fake:Hide() self.shown = false end
    function Fake:IsShown() return self.shown end
    function Fake:SetScript(name, fn) self.scripts[name] = fn end
    function Fake:SetText(t) self.text = t end
    function Fake:GetText() return self.text end
    function Fake:CreateTexture() return new() end
    function Fake:CreateFontString() local fs = new(); made.fonts[#made.fonts + 1] = fs; return fs end
    CreateFrame = function(_, name)
        local f = new()
        if name then made[name] = f end
        return f
    end
    UIParent = UIParent or new()
    UISpecialFrames = {}
    return made
end

-- Opens a loot window with these slots, then closes it
function M.loot(frame, slots, keepOpen)
    M.state.loot = slots
    frame:Fire("LOOT_READY")
    frame:Fire("LOOT_OPENED")
    if not keepOpen then
        M.state.loot = {}
        frame:Fire("LOOT_CLOSED")
    end
end

return M
