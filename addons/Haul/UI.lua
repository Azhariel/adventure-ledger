-- UI: a small movable frame with the session's rates, and a tooltip with the details.
local _, ns = ...

local Session = ns.Session
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 200, 56 -- minimum width; it grows with the text

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint()
    if point then
        ns.db.window.point = { point, relPoint, x, y }
    end
end

local function Lines()
    local s = ns.session
    if not s then
        return "Haul", "", ""
    end
    local now = ns.Now()
    local elapsed = Session.Elapsed(s, now)
    local total = Session.Total(s)
    local head = "|cffe6b422Haul|r " .. ns.Duration(elapsed) .. "  " .. ns.Rate(Session.PerHour(total, elapsed))
    if Session.IsPaused(s) then
        head = head .. (s.pauseReason == "afk" and "  |cff999999(AFK)|r" or "  |cff999999(paused)|r")
    end
    local income = "Loot " .. ns.Money(s.itemValue) .. " · Coin " .. ns.Money(s.money.loot)
        .. " · Quests " .. ns.Money(s.money.quest)
    local xpRate = Session.PerHour(s.xp, elapsed)
    local xpLine
    if xpRate and xpRate > 0 then
        local eta = Session.TimeToLevel(s, now)
        xpLine = "XP " .. ns.Short(xpRate) .. "/h" .. (eta and (" · level in " .. ns.Eta(eta)) or "")
    else
        xpLine = "XP " .. ns.Short(s.xp)
    end
    return head, income, xpLine
end
UI.Lines = Lines

function UI.ShowTooltip(owner)
    local s = ns.session
    if not (s and GameTooltip) then
        return
    end
    local now = ns.Now()
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Haul")
    local items = Session.TopItems(s, 8)
    if #items > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Top loot")
        for _, it in ipairs(items) do
            GameTooltip:AddDoubleLine((it.link or ("item:" .. it.itemID)) .. " x" .. it.count,
                it.pending and "|cff999999pricing...|r" or ns.Money(it.value), 1, 1, 1, 1, 1, 1)
        end
    end
    local zones = Session.ZoneRates(s, now)
    if #zones > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Zones")
        for i, z in ipairs(zones) do
            if i > 5 then
                break
            end
            GameTooltip:AddDoubleLine(z.zone .. "  |cff999999" .. ns.Duration(z.time) .. "|r", ns.Rate(z.perHour),
                1, 1, 1, 1, 1, 1)
        end
    end
    local history = ns.db and ns.db.history or {}
    if #history > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Last sessions")
        for i = 1, math.min(3, #history) do
            local h = history[i]
            local total = (h.loot or 0) + (h.quest or 0) + (h.items or 0)
            GameTooltip:AddDoubleLine(ns.Duration(h.duration) .. "  " .. ns.Money(total),
                ns.Rate(Session.PerHour(total, h.duration)), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Drag to move. /haul reset, pause, resume, history", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function UI.Init()
    if UI.frame then
        return
    end
    local ok, f = pcall(CreateFrame, "Frame", "HaulFrame", UIParent, "BackdropTemplate")
    if not ok or not f then
        f = CreateFrame("Frame", "HaulFrame", UIParent)
    end
    UI.frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    local p = ns.db.window.point
    if p then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(0, 0, 0, 0.75)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.75)
    end
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    f:SetScript("OnEnter", UI.ShowTooltip)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    f.lines = {}
    for i = 1, 3 do
        local fs = f:CreateFontString(nil, "OVERLAY", i == 1 and "GameFontNormal" or "GameFontHighlightSmall")
        -- Left anchor only: the frame grows to fit the longest line (see UI.Update)
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -7 - (i - 1) * 15)
        fs:SetJustifyH("LEFT")
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        f.lines[i] = fs
    end
    if ns.db.window.shown == false then
        f:Hide()
    end
    UI.Update()
end

function UI.Update()
    local f = UI.frame
    if not (f and f:IsShown()) then
        return
    end
    local a, b, c = Lines()
    f.lines[1]:SetText(a)
    f.lines[2]:SetText(b)
    f.lines[3]:SetText(c)
    f:SetWidth(UI.FitWidth(f.lines))
end

-- Frame width that fits every line (8px padding each side), never below WIDTH.
function UI.FitWidth(lines)
    local widest = 0
    for _, fs in ipairs(lines) do
        local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
            or (fs.GetStringWidth and fs:GetStringWidth())
        if type(w) == "number" and w > widest then
            widest = w
        end
    end
    return math.max(WIDTH, math.ceil(widest) + 16)
end

function UI.Toggle()
    if not UI.frame then
        UI.Init()
    end
    local f = UI.frame
    if f:IsShown() then
        f:Hide()
        ns.db.window.shown = false
    else
        f:Show()
        ns.db.window.shown = true
        UI.Update()
    end
end
