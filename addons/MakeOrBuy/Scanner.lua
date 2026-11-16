-- Scanner: learns the player's recipes from the open profession window and stores them in saved variables,
-- so the planner knows Bolt of Woolen Cloth = 3 Wool Cloth even while you look at a different recipe.
local _, ns = ...

local Scanner = {}
ns.Scanner = Scanner

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

-- True when the open window is not the player's own profession (a chat-linked profession,
-- a guild view, or an NPC crafting window). Those must not overwrite our recipe list.
function Scanner.IsForeignView()
    local ui = C_TradeSkillUI
    return (safe(ui.IsTradeSkillLinked) or safe(ui.IsTradeSkillGuild) or safe(ui.IsNPCCrafting)) and true or false
end

-- Key that groups recipes by profession, so rescanning Tailoring replaces only Tailoring recipes.
function Scanner.ProfessionKey()
    local ui = C_TradeSkillUI
    local info = safe(ui.GetBaseProfessionInfo) or safe(ui.GetChildProfessionInfo)
    if info then
        return info.professionID or info.professionName
    end
    return nil
end

-- Reads one recipe into the planner's format. Returns nil for recipes without an item output
-- (enchants) or without basic reagents.
function Scanner.ReadRecipe(recipeID)
    local schematic = safe(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not schematic then
        return nil
    end
    local outputItemID = schematic.outputItemID
    if not outputItemID then
        -- Same source Auctionator uses for the output link
        local output = safe(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        outputItemID = output and output.itemID
    end
    if not outputItemID then
        return nil
    end
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local option = slot.reagents and slot.reagents[1]
        local qty = slot.quantityRequired
        if (basic == nil or slot.reagentType == basic) and option and option.itemID and qty and qty > 0 then
            reagents[#reagents + 1] = { itemID = option.itemID, qty = qty }
        end
    end
    if #reagents == 0 then
        return nil
    end
    local outputQty = schematic.quantityMin
    if not outputQty or outputQty < 1 then
        outputQty = 1
    end
    return {
        recipeID = recipeID,
        name = schematic.name,
        outputItemID = outputItemID,
        outputQty = outputQty,
        reagents = reagents,
    }
end

-- Current and maximum skill of the open profession: level, max (nil if unknown).
-- `profession` (optional, a ProfessionKey): only a reading of that profession counts. While switching
-- professions the child info can still describe the previous one, so a child that names another parent is
-- skipped, and so is a level above the base info's cap (the base info is what names the profession).
function Scanner.SkillLevel(profession)
    local ui = C_TradeSkillUI
    local base = safe(ui.GetBaseProfessionInfo)
    local baseIsIt = base and (profession == nil or base.professionID == nil or base.professionID == profession)
    local cap = baseIsIt and type(base.maxSkillLevel) == "number" and base.maxSkillLevel > 0 and base.maxSkillLevel or nil
    -- Not ipairs: a missing first function (nil) would end the loop before the second
    for _, name in ipairs({ "GetChildProfessionInfo", "GetBaseProfessionInfo" }) do
        local info = name == "GetBaseProfessionInfo" and base or safe(ui[name])
        local other = profession ~= nil and info and (
            (name == "GetBaseProfessionInfo" and not baseIsIt)
            or (info.parentProfessionID ~= nil and info.parentProfessionID ~= profession and info.professionID ~= profession))
        if info and not other and type(info.skillLevel) == "number" and info.skillLevel > 0
            and not (cap and info.skillLevel > cap) then
            return info.skillLevel, info.maxSkillLevel
        end
    end
    return nil
end

local function playerFaction()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
end

local function replaceProfession(store, profession, found)
    if profession ~= nil then
        for recipeID, recipe in pairs(store) do
            if recipe.profession == profession then
                store[recipeID] = nil
            end
        end
    end
    local count = 0
    for recipeID, recipe in pairs(found) do
        store[recipeID] = recipe
        count = count + 1
    end
    return count
end

-- recipeID -> profession, from the bundled recipe data (built once)
local dataProfession
local function professionFromData(recipeID)
    if not dataProfession then
        dataProfession = {}
        for prof, list in pairs(ns.RecipeData or {}) do
            for id in pairs(list) do
                dataProfession[id] = prof
            end
        end
    end
    return dataProfession[recipeID]
end

-- The profession a recipe belongs to, independent of which window is open: the bundled data first,
-- then the game's own recipe -> skill line lookup. nil when unknown.
function Scanner.RecipeProfession(recipeID)
    local prof = professionFromData(recipeID)
    if prof then
        return prof
    end
    local lookup = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe
    if type(lookup) == "function" then
        local ok, line, _, parent = pcall(lookup, recipeID)
        if ok then
            parent = type(parent) == "number" and parent > 0 and parent or nil
            line = type(line) == "number" and line > 0 and line or nil
            return parent or line
        end
    end
    return nil
end

-- Forgets the cached data lookup (tests swap ns.RecipeData)
function Scanner.ResetCache()
    dataProfession = nil
end

-- Moves recipes saved under the wrong profession (by an earlier scan that raced a profession switch) to the
-- right one, drops unlearned copies of recipes that are learned, and forgets skill-up colours seen at a skill
-- above the recipe's profession cap (the same race, reading another profession's skill). Returns the number of
-- recipes fixed.
function Scanner.Repair(db)
    local fixed = 0
    for _, store in ipairs({ db.recipes or {}, db.unlearned or {} }) do
        for recipeID, recipe in pairs(store) do
            local prof = Scanner.RecipeProfession(recipeID)
            if prof and recipe.profession ~= prof then
                recipe.profession = prof
                fixed = fixed + 1
            end
        end
    end
    for recipeID in pairs(db.recipes or {}) do
        if db.unlearned and db.unlearned[recipeID] then
            db.unlearned[recipeID] = nil
        end
    end
    if ns.Skill and ns.Skill.Impossible then
        for recipeID, bounds in pairs(db.bounds or {}) do
            local recipe = (db.recipes or {})[recipeID]
            local skill = recipe and db.skill and db.skill[recipe.profession]
            if skill and ns.Skill.Impossible(bounds, tonumber(skill.max)) then
                db.bounds[recipeID] = nil
                fixed = fixed + 1
            end
        end
    end
    return fixed
end

-- Scans the open profession:
--   db.recipes[recipeID]    learned recipes (what the planner may craft)
--   db.unlearned[recipeID]  recipes you could still learn, from the game list and ns.RecipeData
--   db.bounds[recipeID]     what each recipe's colour at the current skill says about its thresholds
--   db.skill[profession]    { level, max }
-- Returns the number of learned recipes stored, or nil, reason if nothing could be scanned: "foreign"
-- (someone else's profession), "empty" (window not ready) or "mismatch" (the recipe list belongs to another
-- profession than the window says, which happens for a moment while switching professions; try again).
function Scanner.ScanOpenProfession(db)
    if Scanner.IsForeignView() then
        return nil, "foreign"
    end
    local recipeIDs = safe(C_TradeSkillUI.GetAllRecipeIDs)
    if not recipeIDs or #recipeIDs == 0 then
        return nil, "empty"
    end
    local profession = Scanner.ProfessionKey()

    -- The list and the profession name must agree; recipes of another profession are never stored under this one
    local own, other = 0, 0
    local foreign = {}
    for _, recipeID in ipairs(recipeIDs) do
        local prof = Scanner.RecipeProfession(recipeID)
        if prof ~= nil and profession ~= nil then
            if prof == profession then
                own = own + 1
            else
                other = other + 1
                foreign[recipeID] = true
            end
        end
    end
    if other > own then
        return nil, "mismatch"
    end

    local level, maxLevel = Scanner.SkillLevel(profession)
    db.unlearned = db.unlearned or {}
    db.bounds = db.bounds or {}
    db.skill = db.skill or {}
    if profession ~= nil and level then
        db.skill[profession] = { level = level, max = maxLevel }
    end

    local found, unlearned, seen = {}, {}, {}
    for _, recipeID in ipairs(recipeIDs) do
        seen[recipeID] = true
        local info = not foreign[recipeID] and safe(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if info then
            local recipe = Scanner.ReadRecipe(recipeID)
            if recipe then
                recipe.profession = profession
                if info.learned then
                    found[recipeID] = recipe
                else
                    unlearned[recipeID] = recipe
                end
            elseif info.learned then
                -- Details not loaded yet (or no item output): keep what an earlier scan saved
                local saved = db.recipes[recipeID]
                if saved and saved.profession == profession then
                    found[recipeID] = saved
                end
            end
            if info.learned and level and info.relativeDifficulty ~= nil and ns.Skill then
                db.bounds[recipeID] = ns.Skill.Observe(db.bounds[recipeID], level, info.relativeDifficulty)
            end
        end
    end

    -- Recipes the game list doesn't show yet (trainer/vendor/drop recipes), from WhatsTraining's data
    local data = ns.RecipeData and profession and ns.RecipeData[profession]
    if data then
        local faction = playerFaction()
        for recipeID, entry in pairs(data) do
            if not seen[recipeID] and not found[recipeID] and (entry[5] == nil or faction == nil or entry[5] == faction) then
                -- Recipes don't change: reuse the saved copy (this runs after every craft)
                local saved = db.unlearned[recipeID]
                local recipe = (saved and saved.profession == profession) and saved or Scanner.ReadRecipe(recipeID)
                if recipe then
                    recipe.profession = profession
                    unlearned[recipeID] = recipe
                end
            end
        end
    end

    -- Drop this profession's previous entries so unlearned/changed recipes don't linger
    replaceProfession(db.unlearned, profession, unlearned)
    return replaceProfession(db.recipes, profession, found)
end
