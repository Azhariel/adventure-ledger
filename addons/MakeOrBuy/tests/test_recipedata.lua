-- The bundled recipe data (generated from WhatsTraining by tools/gen_recipes.lua)
return function(H)
    H.test("RecipeData covers Mining: Smelt Bronze from a trainer at 65 for 2s, Smelt Tin at 65", function()
        local ns = {}
        H.load({ "Data/RecipeData.lua" }, ns)
        local mining = ns.RecipeData[186]
        H.truthy(mining, "Mining (186) present")
        local bronze = mining and mining[2659]
        H.truthy(bronze, "Smelt Bronze present")
        if bronze then
            H.eq(bronze[1], 65); H.eq(bronze[2], 200); H.eq(bronze[3], "t"); H.eq(bronze[4], nil); H.eq(bronze[5], nil)
        end
        local tin = mining and mining[3304]
        H.eq(tin and tin[1], 65, "Smelt Tin learn skill")
    end)
end
