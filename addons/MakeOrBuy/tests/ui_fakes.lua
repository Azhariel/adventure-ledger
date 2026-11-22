-- Fake widgets and a booted Make or Buy (ISTQB: fakes) shared by the UI smoke tests. Widgets are fake objects
-- whose unknown methods are no-ops, so tests check that the real code paths run without Lua errors and
-- produce the expected text/state. Layout is verified in game.
local mock = require("wow_mock")

local function noop() end
local Fake = {}
local function newObj()
    return setmetatable({ scripts = {}, shown = true }, {
        -- Like real widgets: unknown *methods* exist, unknown fields are nil
        __index = function(_, k)
            if Fake[k] then
                return Fake[k]
            end
            if type(k) == "string" and (k:match("^Set%u") or k:match("^Get%u") or k:match("^Enable")
                or k:match("^Clear") or k:match("^Has") or k:match("^Register") or k:match("^Unregister")) then
                return noop
            end
            return nil
        end,
    })
end
function Fake:Show()
    if not self.shown then
        self.shown = true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
end
function Fake:Hide()
    if self.shown then
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
end
function Fake:SetShown(v) if v then self:Show() else self:Hide() end end
function Fake:IsShown() return self.shown end
function Fake:IsVisible() return self.shown end
function Fake:SetScript(name, fn) self.scripts[name] = fn end
function Fake:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = function(...) if old then old(...) end fn(...) end
end
function Fake:CreateTexture() return newObj() end
function Fake:CreateFontString() local fs = newObj() mock.fonts[#mock.fonts + 1] = fs return fs end
function Fake:SetText(t) self.text = t end
function Fake:GetText() return self.text end
function Fake:SetChecked(v) self.checked = v end
function Fake:GetChecked() return self.checked end
function Fake:SetFrameLevel(l) self.level = l end
function Fake:GetFrameLevel() return self.level or 1 end
function Fake:SetCustomOnMouseUpHandler(fn) self.mouseUp = fn end
function Fake:GetChildren() return end
function Fake:AddLine(t) self.lines[#self.lines + 1] = t end
function Fake:AddDoubleLine(l, r) self.lines[#self.lines + 1] = l .. " | " .. r end
function Fake:SetOwner() self.lines = {} end
function Fake:Disable() self.disabled = true end
function Fake:Enable() self.disabled = false end

local function sideTab(icon)
    local t = newObj()
    t.Icon = newObj()
    t.Icon.GetTexture = function() return icon end
    t.SelectedTexture = newObj()
    return t
end

local function click(tab, button)
    tab.mouseUp(tab, button or "LeftButton", true)
end

local function boot(H, opts)
    opts = opts or {}
    mock.installCore()
    mock.fonts = {}
    local frames = {}
    CreateFrame = function(_, name, _, template)
        local o = template == "LargeSideTabButtonTemplate" and sideTab() or newObj()
        frames[#frames + 1] = o
        if name then _G[name] = o end
        return o
    end
    hooksecurefunc = function(t, name, fn)
        local old = t[name]
        t[name] = function(...) local a = old(...) fn(...) return a end
    end
    RunNextFrame = function(fn) fn() end
    mock.callbacks = {}
    EventRegistry = { RegisterCallback = function(_, event, fn) mock.callbacks[event] = fn end }

    mock.installTradeSkill({
        [2964] = { learned = true, difficulty = opts.boltDifficulty or 0, schematic = { name = "Bolt of Woolen Cloth", outputItemID = 2997,
            quantityMin = 1, reagentSlotSchematics = { mock.slot(2592, 3) } } },
        [3757] = { learned = true, difficulty = 1, schematic = { name = "Woolen Bag", outputItemID = 4241,
            quantityMin = 1, reagentSlotSchematics = { mock.slot(2997, 3), mock.slot(2321, 1) } } },
        -- Not learned yet: a second bag recipe (same reagents, same 9s bag)
        [3758] = { learned = false, difficulty = 0, schematic = { name = "Trainer Bag", outputItemID = 4241,
            quantityMin = 1, reagentSlotSchematics = { mock.slot(2997, 3), mock.slot(2321, 1) } } },
    })
    -- Vendor sell prices via C_Item.GetItemInfo (11th return); items not listed are "cached" with no price
    mock.vendorSell = opts.vendorSell or {}
    C_Item.GetItemInfo = function(id)
        return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, mock.vendorSell[id] or 0
    end
    C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 197, professionName = "Tailoring", skillLevel = opts.skillLevel, maxSkillLevel = opts.maxSkill } end
    mock.installAuctionator({ [2321] = 100 }, { [2592] = 51, [2997] = 600, [4241] = opts.bagPrice or 900 })
    local api = Auctionator.API.v1
    api.GetAuctionAgeByItemID = function() return 0 end
    api.RegisterForDBUpdate = function(_, fn) mock.dbUpdate = fn end
    api.MultiSearchAdvanced = function(_, terms) mock.searched = terms end
    C_Item.GetItemIconByID = function() return 1 end

    local form = newObj()
    form.Reagents = newObj()
    form.Init = function() end
    form.GetRecipeInfo = function() return { recipeID = 3757 } end
    local page = newObj()
    page.RecipeList, page.SchematicForm = newObj(), form
    page.SelectRecipe = function(_, info) mock.selected = info.recipeID end
    ProfessionsFrame = newObj()
    ProfessionsFrame.CraftingPage = page
    ProfessionsFrame.PortraitContainer = newObj()
    ProfessionsFrame.PortraitContainer.level = 600
    ProfessionsFrame.ProfessionsOverviewTab = sideTab("overview")
    local tailoring = sideTab("tailoring")
    ProfessionsFrame.rightProfessionTabs = { sideTab("firstaid"), tailoring }
    for _, t in ipairs(ProfessionsFrame.rightProfessionTabs) do t.SelectedTexture.shown = false end
    ProfessionsFrame.ProfessionsOverviewTab.SelectedTexture.shown = false
    mock.selectedNative = tailoring
    _G.WhatsTrainingCraftingTab = opts.whatsTraining and newObj() or nil
    GameTooltip = newObj()
    AuctionHouseFrame = nil

    CreateScrollBoxListLinearView = function()
        local view = newObj()
        view.SetElementInitializer = function(self, _, fn) self.init = fn end
        mock.view = view
        return view
    end
    ScrollUtil = { InitScrollBoxListWithScrollBar = noop }
    CreateDataProvider = function(rows) return rows end
    Fake.SetDataProvider = function(self, rows) self.rows = rows; mock.rows = rows end

    if opts.beforeLoad then opts.beforeLoad() end
    local files = { "Planner.lua", "Market.lua", "Skill.lua", "Ranking.lua", "Restock.lua", "Scanner.lua", "Core.lua", "UI.lua", "ProfitTab.lua" }
    for _, f in ipairs(opts.files or {}) do files[#files + 1] = f end
    local ns = H.load(files)
    local events = frames[1]
    if opts.db then MakeOrBuyCharDB = opts.db end
    events.scripts.OnEvent(events, "ADDON_LOADED", "MakeOrBuy")
    events.scripts.OnEvent(events, "TRADE_SKILL_SHOW")
    mock.runTimers() -- recipe scan
    return ns, frames, _G.MakeOrBuyTab, _G.MakeOrBuyProfitPanel, _G.MakeOrBuyReturnTab
end

return { mock = mock, newObj = newObj, Fake = Fake, sideTab = sideTab, click = click, noop = noop, boot = boot }
