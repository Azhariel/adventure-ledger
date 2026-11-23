-- StatusWindow: a small read-only window showing what an addon has collected. The same file ships in every
-- Adventure Ledger addon (each must work alone); dashboard/tests/test_addons_shared.py checks the copies match.
--
-- The addon gives a build function returning its status as plain data:
--   { warnings = { "text", ... }, sections = { { title = "Character", rows = { { "Realm", "PvP" }, ... } }, ... },
--     footer = "text" }
-- W.New{ name, title, build, position } makes the window: name = a global frame name, position() = a table to save
-- the window's place in (or nil before the saved data loads). win:Toggle(), win:Refresh(), win:Print().
-- Wears Daylight UI's shell, font and colors while Daylight UI is installed. When no frame can be made, the
-- status goes to the chat instead.
local _, ns = ...

local W = {}
ns.StatusWindow = W

W.WIDTH = 340
W.LABEL_WIDTH = 120
W.PAD = 10
W.REFRESH = 1 -- seconds between refreshes while shown

local WARN, HEAD, LABEL, VALUE, FOOT = "ffe6b422", "ffbd93f9", "ff9a9a9a", "ffffffff", "ff7a7a7a"

-- Every line the window shows, in order: { kind = "warn" | "head" | "row" | "foot", text, value }
function W.Lines(status)
    status = type(status) == "table" and status or {}
    local out = {}
    for _, w in ipairs(status.warnings or {}) do
        out[#out + 1] = { kind = "warn", text = tostring(w) }
    end
    for _, s in ipairs(status.sections or {}) do
        if s.rows and #s.rows > 0 then
            out[#out + 1] = { kind = "head", text = tostring(s.title or "") }
            for _, r in ipairs(s.rows) do
                out[#out + 1] = { kind = "row", text = tostring(r[1] or ""), value = tostring(r[2] == nil and "" or r[2]) }
            end
        end
    end
    if status.footer then out[#out + 1] = { kind = "foot", text = tostring(status.footer) } end
    return out
end

-- The same lines as chat text
function W.ChatLines(status)
    local out = {}
    for _, l in ipairs(W.Lines(status)) do
        if l.kind == "warn" then
            out[#out + 1] = "|c" .. WARN .. "! " .. l.text .. "|r"
        elseif l.kind == "head" then
            out[#out + 1] = "|c" .. HEAD .. l.text .. "|r"
        elseif l.kind == "row" then
            out[#out + 1] = "  |c" .. LABEL .. l.text .. ":|r " .. l.value
        end
    end
    return out
end

-- DaylightUI.API (major 1), when Daylight UI is installed
local function daylight()
    local dui = _G.DaylightUI
    local api = type(dui) == "table" and dui.API
    return type(api) == "table" and api.major == 1 and api or nil
end

local function hex(c)
    if type(c) ~= "table" then return nil end
    local function b(v) return math.floor((tonumber(v) or 1) * 255 + 0.5) end
    return string.format("ff%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

local Window = {}
Window.__index = Window

function W.New(opts)
    return setmetatable({ opts = opts, fonts = {} }, Window)
end

-- The status, or a status saying why there's none
function Window:Status()
    local ok, status = pcall(self.opts.build)
    if not ok then return { warnings = { "couldn't read the status: " .. tostring(status) } } end
    return status
end

function Window:Print()
    local say = (_G.DEFAULT_CHAT_FRAME and function(m) _G.DEFAULT_CHAT_FRAME:AddMessage(m) end) or print
    say("|c" .. HEAD .. self.opts.title .. "|r")
    for _, line in ipairs(W.ChatLines(self:Status())) do say(line) end
end

local function newFont(self, size)
    local f, API = self.frame, self.api
    local fs = API and API.Text(f, size, "LEFT") or f:CreateFontString(nil, "OVERLAY",
        size == "title" and "GameFontNormalLarge" or (size == "small" and "GameFontHighlightSmall" or "GameFontHighlight"))
    if fs.SetJustifyH then fs:SetJustifyH("LEFT") end
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    return fs
end

-- A pooled font string for line i (two per line: label/text and value)
local function font(self, i, which)
    local key = which .. i
    if not self.fonts[key] then self.fonts[key] = newFont(self, which == "v" and "body" or "small") end
    return self.fonts[key]
end

local function savePosition(self)
    local pos = self.opts.position and self.opts.position()
    local point, _, relPoint, x, y = self.frame:GetPoint()
    if pos and point then pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y end
end

function Window:Build()
    if self.frame then return self.frame end
    local name = self.opts.name
    local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
    if not ok or not f then ok, f = pcall(CreateFrame, "Frame", name, UIParent) end
    if not ok or type(f) ~= "table" or not f.CreateFontString then return nil end
    self.frame, self.api = f, daylight()
    f:Hide()
    f:SetSize(W.WIDTH, 80)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    local pos = self.opts.position and self.opts.position()
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
    f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing(); savePosition(self) end)
    local API = self.api
    if API then
        API.Skin(f, { window = true })
        HEAD = hex({ API.Accent() }) or HEAD
        local c = API.Colors()
        WARN, LABEL, VALUE, FOOT = hex(c.WARN) or WARN, hex(c.LABEL) or LABEL, hex(c.VALUE) or VALUE, hex(c.OFF) or FOOT
        API.Close(f, function() f:Hide() end)
    else
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            f:SetBackdropColor(0.05, 0.05, 0.06, 0.92)
            f:SetBackdropBorderColor(0.3, 0.3, 0.32, 1)
        end
        local okClose, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
        if okClose and close and close.SetPoint then
            close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
            close:SetScript("OnClick", function() f:Hide() end)
        end
    end
    self.title = newFont(self, "title")
    self.title:SetPoint("TOPLEFT", f, "TOPLEFT", W.PAD, -W.PAD)
    self.title:SetText(self.opts.title)
    local elapsed = 0
    f:SetScript("OnShow", function() elapsed = 0; self:Refresh() end)
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed >= W.REFRESH then elapsed = 0; self:Refresh() end
    end)
    if type(_G.UISpecialFrames) == "table" and name then table.insert(_G.UISpecialFrames, name) end -- Esc closes it
    return f
end

local function height(fs, fallback)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (type(h) == "number" and h > 0) and h or fallback
end

function Window:Refresh()
    local f = self.frame
    if not f then return end
    local lines = W.Lines(self:Status())
    local y = W.PAD + height(self.title, 18) + 8
    local inner = W.WIDTH - 2 * W.PAD
    for i, l in ipairs(lines) do
        local left, right = font(self, i, "t"), font(self, i, "v")
        left:ClearAllPoints(); right:ClearAllPoints()
        left:SetPoint("TOPLEFT", f, "TOPLEFT", W.PAD, -y)
        local h
        if l.kind == "row" then
            left:SetWidth(W.LABEL_WIDTH - 6)
            left:SetText("|c" .. LABEL .. l.text .. "|r")
            right:SetPoint("TOPLEFT", f, "TOPLEFT", W.PAD + W.LABEL_WIDTH, -y)
            right:SetWidth(inner - W.LABEL_WIDTH)
            right:SetText("|c" .. VALUE .. l.value .. "|r")
            right:Show()
            h = math.max(height(left, 14), height(right, 14))
        else
            left:SetWidth(inner)
            local color = (l.kind == "warn" and WARN) or (l.kind == "head" and HEAD) or FOOT
            if l.kind == "head" and i > 1 then y = y + 6; left:SetPoint("TOPLEFT", f, "TOPLEFT", W.PAD, -y) end
            left:SetText("|c" .. color .. (l.kind == "warn" and "! " or "") .. l.text .. "|r")
            right:Hide()
            h = height(left, 14)
        end
        left:Show()
        y = y + h + 3
    end
    local n = #lines
    for key, fs in pairs(self.fonts) do
        if tonumber(key:sub(2)) > n then fs:Hide() end
    end
    f:SetHeight(y + W.PAD)
    if self.api then self.api.Skin(f, { window = true }) end -- Daylight's shell follows a resize
end

function Window:Toggle()
    local f = self:Build()
    if not f then return self:Print() end
    if f:IsShown() then f:Hide() else f:Show() end
end

return W
