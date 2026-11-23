-- Test doubles (ISTQB: stubs/fakes) for the WoW APIs Stockpile touches.
local M = {}

M.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

-- Installs a fake client. opts:
--   containers = { [bagID] = { [slot] = { itemID, count } | false, n = slotCount } }
--   mail = { { { itemID, count }, ... }, ... }   (one inner list per mail)
--   name, realm, class, bagIndex (table for Enum.BagIndex), tooltipProcessor (bool)
function M.install(opts)
    opts = opts or {}
    M.containers = opts.containers or {}
    M.mail = opts.mail or {}
    local frame = { events = {} }
    function frame:RegisterEvent(e)
        if opts.unknownEvents and opts.unknownEvents[e] then
            error("Attempt to register unknown event " .. e)
        end
        self.events[e] = true
    end
    function frame:SetScript(_, fn) self.handler = fn end
    function frame:Fire(event, ...) self.handler(self, event, ...) end
    M.frame = frame
    CreateFrame = function() return frame end

    issecretvalue = function(v) return v == M.SECRET end
    UnitName = function() return opts.name or "Azhariel" end
    GetRealmName = function() return opts.realm or "Deadheart" end
    UnitClass = function() return "Priest", opts.class or "PRIEST" end
    NUM_BAG_SLOTS, NUM_TOTAL_EQUIPPED_BAG_SLOTS, NUM_BANKBAGSLOTS = 4, opts.totalBags, 7
    BANK_CONTAINER, REAGENTBANK_CONTAINER = -1, nil
    ATTACHMENTS_MAX_RECEIVE = 16
    Enum = { BagIndex = opts.bagIndex, PlayerInteractionType = { Banker = 8 },
        TooltipDataType = { Item = 0 } }

    C_Container = {
        GetContainerNumSlots = function(bag)
            local c = M.containers[bag]
            return c and c.n or 0
        end,
        GetContainerItemInfo = function(bag, slot)
            local c = M.containers[bag]
            local s = c and c[slot]
            if not s then return nil end
            return { itemID = s[1], stackCount = s[2] }
        end,
    }
    GetInboxNumItems = function() return #M.mail end
    GetInboxItem = function(i, a)
        local att = M.mail[i] and M.mail[i][a]
        if not att then return nil end
        return "Item" .. tostring(att[1]), att[1], 1, att[2], 1, true
    end

    M.now = opts.now or 1700000000
    time = function() return M.now end
    date = function(fmt, t) return os.date(fmt, t) end
    M.timers = {}
    C_Timer = { After = function(_, fn) M.timers[#M.timers + 1] = fn end }
    M.chat = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.chat[#M.chat + 1] = msg end }
    SlashCmdList = {}
    RAID_CLASS_COLORS = { PRIEST = { colorStr = "ffffffff" }, MAGE = { colorStr = "ff3fc7eb" } }
    C_Item = { GetItemNameByID = function(id) return "Item" .. id end }
    geterrorhandler = function() return function(err) M.lastError = err end end

    M.postCalls = {}
    if opts.tooltipProcessor ~= false then
        TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) M.postCalls[kind] = fn end }
    else
        TooltipDataProcessor = nil
    end
    if opts.gameTooltipLink then
        GameTooltip, ItemRefTooltip = M.tooltip(opts.gameTooltipLink), M.tooltip(opts.gameTooltipLink)
    end
    StockpileDB = opts.db
    return frame
end

function M.runTimers()
    local pending = M.timers
    M.timers = {}
    for _, fn in ipairs(pending) do
        fn()
    end
end

-- Fake tooltip that records added lines.
function M.tooltip(link)
    local t = { lines = {}, shown = 0 }
    function t:AddLine(text) self.lines[#self.lines + 1] = text end
    function t:Show() self.shown = self.shown + 1 end
    function t:GetItem() return "Item", link end
    function t:HookScript(script, fn) self.hooks = self.hooks or {}; self.hooks[script] = fn end
    return t
end

-- Swaps CreateFrame for fake widgets: unknown Set*/Get*/... methods do nothing, Show/Hide/SetText are kept.
-- Returns { [frame name] = frame, fonts = { every font string made } } for the test to look at.
-- Call it after boot: the event frame made at load stays the plain fake from install.
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

-- Loads the addon in TOC order and fires ADDON_LOADED + PLAYER_ENTERING_WORLD.
function M.boot(H, opts)
    M.install(opts)
    local ns = H.load({ "Store.lua", "Core.lua", "StatusWindow.lua", "Status.lua", "API.lua", "Tooltip.lua" })
    M.frame:Fire("ADDON_LOADED", "Stockpile")
    if not (opts and opts.noLogin) then
        M.frame:Fire("PLAYER_ENTERING_WORLD")
    end
    return ns
end

return M
