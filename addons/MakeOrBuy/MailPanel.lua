-- MailPanel: at a mailbox, a small list next to the mail window of items in your bags that your other
-- characters craft with (see Alts.lua). Clicking a row opens Send Mail, fills in the alt's name and attaches
-- the stacks. Sending stays a click on Blizzard's Send button.
local _, ns = ...

local MailPanel = {}
ns.MailPanel = MailPanel

local ROWS = 10
local ROW_HEIGHT = 18
local WIDTH = 290
local GREEN, CYAN, GREY = "ff40ff40", "ff4dd2ff", "ff9d9d9d"

local function colored(color, text)
    return "|c" .. color .. text .. "|r"
end

local function bagIDs()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    local ids = {}
    for bag = 0, last do ids[#ids + 1] = bag end
    return ids
end

-- Mailable stacks in your bags: { [itemID] = { { bag, slot, count } } } (soulbound and locked items left out)
function MailPanel.BagStacks()
    local out = {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then
        return out
    end
    for _, bag in ipairs(bagIDs()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound and not info.isLocked then
                out[info.itemID] = out[info.itemID] or {}
                local list = out[info.itemID]
                list[#list + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
            end
        end
    end
    return out
end

local function counts(stacks)
    local out = {}
    for itemID, list in pairs(stacks) do
        local n = 0
        for _, s in ipairs(list) do n = n + s.count end
        out[itemID] = n
    end
    return out
end

-- Suggestions for this character's bags right now
function MailPanel.Suggestions()
    if not (ns.account and ns.Alts) then
        return {}, 0
    end
    local key, mine = ns.SelfProfile()
    local others = 0
    for k in pairs(ns.account.chars) do
        if k ~= key then others = others + 1 end
    end
    return ns.Alts.Suggest(key, mine, ns.account.chars, counts(MailPanel.BagStacks())), others
end

local function describe(s)
    local who = ns.Alts.DisplayName(s.profile)
    local why = s.need and ("restock needs " .. s.need) or "crafts with it"
    return s.give, ns.ItemName(s.itemID), who, why
end

function ns.PrintAlts()
    local list, others = MailPanel.Suggestions()
    if others == 0 then
        ns.Print("No other characters known yet. Log in once with each alt (with Make or Buy on) and open their professions.")
        return
    end
    if #list == 0 then
        ns.Print("Nothing in your bags that your other characters craft with.")
        return
    end
    ns.Print("For your other characters (open a mailbox to attach them):")
    for _, s in ipairs(list) do
        local give, item, who, why = describe(s)
        ns.Print("   " .. give .. "x " .. item .. " -> " .. who .. " (" .. why .. ")")
    end
end

----------------------------------------------------------------------------------------------------
-- Attaching

local function attachedCount()
    local n, max = 0, ATTACHMENTS_MAX_SEND or 12
    if GetSendMailItem then
        for i = 1, max do
            if GetSendMailItem(i) then n = n + 1 end
        end
    end
    return n, max
end

local function openSendTab()
    if SendMailFrame and SendMailFrame:IsShown() then
        return true
    end
    if MailFrameTab_OnClick then
        pcall(MailFrameTab_OnClick, nil, 2)
    end
    return SendMailFrame and SendMailFrame:IsShown()
end

-- Attaches what a suggestion gives to a mail for that character. Returns the number of items attached.
function MailPanel.Attach(s)
    if not openSendTab() then
        ns.Print("Open the Send Mail tab first.")
        return 0
    end
    local recipient = ns.Alts.Recipient(s.profile)
    local box = SendMailNameEditBox
    local current = box and box:GetText() or ""
    local used, max = attachedCount()
    if used > 0 and current ~= "" and current ~= recipient then
        ns.Print("This mail is already for " .. current .. ". Send it or clear it first.")
        return 0
    end
    if used >= max then
        ns.Print("This mail is full. Send it first.")
        return 0
    end
    if box then box:SetText(recipient) end
    if SendMailSubjectEditBox and (SendMailSubjectEditBox:GetText() or "") == "" then
        SendMailSubjectEditBox:SetText("Materials")
    end
    local stacks = MailPanel.BagStacks()[s.itemID] or {}
    local picked, total = ns.Alts.PickStacks(stacks, s.give, max - used)
    for _, st in ipairs(picked) do
        C_Container.UseContainerItem(st.bag, st.slot)
    end
    if total > 0 then
        ns.Print("Attached " .. total .. "x " .. ns.ItemName(s.itemID) .. " for " .. ns.Alts.DisplayName(s.profile)
            .. ". Check the name and press Send.")
    end
    return total
end

----------------------------------------------------------------------------------------------------
-- The panel

local frame

local function rowEnter(row)
    local s = row.suggestion
    if not s then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(s.itemID)
    else
        GameTooltip:AddLine(ns.ItemName(s.itemID))
    end
    local give, _, who, why = describe(s)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(who .. ": " .. why, 1, 1, 1)
    GameTooltip:AddLine("You have " .. s.have .. ". Click to attach " .. give .. " to a mail to " .. ns.Alts.Recipient(s.profile) .. ".", 0.3, 0.82, 1, true)
    GameTooltip:Show()
end

local function build()
    if frame then return frame end
    local parent = MailFrame or UIParent
    local ok, f = pcall(CreateFrame, "Frame", "MakeOrBuyMailPanel", parent, "BackdropTemplate")
    if not ok or not f then
        f = CreateFrame("Frame", "MakeOrBuyMailPanel", parent)
    end
    frame = f
    MailPanel.frame = f
    f:SetSize(WIDTH, 60)
    if MailFrame then
        f:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, -28)
    else
        f:SetPoint("CENTER")
    end
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(0, 0, 0, 0.8)
    end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText("For your alts")
    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(WIDTH - 16, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -26 - (i - 1) * ROW_HEIGHT)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 0, 0)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.text:SetPoint("RIGHT", 0, 0)
        row.text:SetJustifyH("LEFT")
        if row.text.SetWordWrap then row.text:SetWordWrap(false) end
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)
        row:SetScript("OnEnter", rowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.suggestion then
                MailPanel.Attach(self.suggestion)
            end
        end)
        f.rows[i] = row
    end
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetJustifyH("LEFT")
    f:Hide()
    return f
end

-- Row text: "40x Linen Cloth > Bob Smith  restock 20"
function MailPanel.RowText(s)
    local give, item, who = describe(s)
    local tag = s.need and colored(CYAN, "restock " .. s.need) or colored(GREY, "crafting")
    return give .. "x " .. item .. colored(GREY, " > ") .. colored(GREEN, who) .. "  " .. tag
end

function MailPanel.Refresh()
    if not (MailFrame and MailFrame:IsShown()) then
        if frame then frame:Hide() end
        return
    end
    local list = MailPanel.Suggestions()
    if #list == 0 then
        if frame then frame:Hide() end
        return
    end
    local f = build()
    local shown = math.min(#list, ROWS)
    for i, row in ipairs(f.rows) do
        local s = list[i]
        row.suggestion = s
        if s then
            row.text:SetText(MailPanel.RowText(s))
            local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(s.itemID)
            row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row:Show()
        else
            row:Hide()
        end
    end
    f.hint:ClearAllPoints()
    f.hint:SetPoint("TOPLEFT", 10, -30 - shown * ROW_HEIGHT)
    f.hint:SetText((#list > ROWS and ("+" .. (#list - ROWS) .. " more (/mob alts). ") or "")
        .. "Click to attach; you press Send.")
    f:SetHeight(48 + shown * ROW_HEIGHT)
    f:Show()
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "BAG_UPDATE_DELAYED", "MAIL_SEND_SUCCESS" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "MAIL_CLOSED" then
        if frame then frame:Hide() end
    elseif event == "MAIL_SHOW" then
        -- the mail window finishes opening this frame
        if C_Timer then C_Timer.After(0, MailPanel.Refresh) else MailPanel.Refresh() end
    elseif frame and frame:IsShown() or event == "MAIL_SEND_SUCCESS" then
        MailPanel.Refresh()
    end
end)
