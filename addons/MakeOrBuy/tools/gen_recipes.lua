-- Generates MakeOrBuy/Data/RecipeData.lua from WhatsTraining's Camelot recipe data (MIT).
local src, out = arg[1], arg[2]
local files = { "Alchemy","Blacksmithing","Cooking","Enchanting","Engineering","FirstAid","Leatherworking","Mining","Tailoring" }
local ns = { L = setmetatable({}, { __index = function(_, k) return k end }) }
for _, f in ipairs(files) do
  local chunk = assert(loadfile(src .. "/" .. f .. ".lua"))
  chunk("WhatsTraining", ns)
end
local letters = { trainer="t", vendor="v", drop="d", quest="q", crafted="c" }
local lines = {
  "-- GENERATED from WhatsTraining's Crafting/Recipes/Camelot data (MIT License, (c) 2019 WhatsTraining authors).",
  "-- Regenerate with tools/gen_recipes.lua. Do not edit by hand.",
  "-- [professionID] = { [recipeSpellID] = { learnSkill, trainerCostCopper, sources, teachItemID, faction } }",
  "-- sources: t trainer, v vendor, d drop, q quest, c crafted. faction: A / H / nil (both).",
  "local _, ns = ...",
  "ns.RecipeData = {",
}
local profs = {}
for id in pairs(ns.Recipes) do profs[#profs+1] = id end
table.sort(profs)
local n = 0
for _, id in ipairs(profs) do
  lines[#lines+1] = ("    [%d] = {"):format(id)
  local list = ns.Recipes[id]
  table.sort(list, function(a,b) return a.spell < b.spell end)
  for _, r in ipairs(list) do
    local s = ""
    for _, x in ipairs(r.source or {}) do s = s .. (letters[x] or "") end
    local fac = r.faction == "Alliance" and '"A"' or r.faction == "Horde" and '"H"' or "nil"
    lines[#lines+1] = ("        [%d] = { %d, %d, %q, %s, %s },"):format(r.spell, r.skill or 0, r.cost or 0, s,
      r.teach and tostring(r.teach) or "nil", fac)
    n = n + 1
  end
  lines[#lines+1] = "    },"
end
lines[#lines+1] = "}"
local f = assert(io.open(out, "w")); f:write(table.concat(lines, "\n"), "\n"); f:close()
print(n .. " recipes")
