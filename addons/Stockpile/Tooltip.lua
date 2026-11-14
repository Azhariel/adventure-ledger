-- Tooltip: adds "Stockpile: N" and a line per character on the realm to item tooltips.
local _, ns = ...
local Store = ns.Store

local Tooltip = {}
ns.Tooltip = Tooltip

-- Lines to add for one item (empty when nobody on the realm has it).
function Tooltip.LinesFor(itemID)
    if not (ns.db and ns.playerKey) or type(itemID) ~= "number" then
        return {}
    end
    local total, list = Store.Count(ns.db, itemID, "realm", ns.playerKey)
    return Store.Lines(total, list, ns.ColorName)
end

function Tooltip.Add(tooltip, itemID)
    itemID = ns.Safe(itemID)
    local lines = Tooltip.LinesFor(itemID)
    if #lines == 0 then
        return
    end
    tooltip:AddLine(lines[1], 0.53, 0.8, 1)
    for i = 2, #lines do
        tooltip:AddLine(lines[i], 0.85, 0.85, 0.85)
    end
    tooltip:Show()
end

local function idFromTooltip(tooltip)
    if not tooltip.GetItem then
        return nil
    end
    local _, link = tooltip:GetItem()
    link = ns.Safe(link)
    return type(link) == "string" and Store.ParseItemID(link) or nil
end

function Tooltip.Init()
    if Tooltip.hooked then
        return
    end
    Tooltip.hooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            local id = data and ns.Safe(data.id)
            if type(id) ~= "number" then
                id = idFromTooltip(tooltip)
            end
            Tooltip.Add(tooltip, id)
        end)
        return
    end
    for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tip and tip.HookScript then
            tip:HookScript("OnTooltipSetItem", function(self)
                Tooltip.Add(self, idFromTooltip(self))
            end)
        end
    end
end
