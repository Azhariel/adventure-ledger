-- Unit tests for Market.lua: how much to trust an AH price.
-- Techniques (ISTQB): boundary value analysis at each limit (spike 1.5x, dip 0.6x, stale 3 days,
-- low supply 2, minimum history 3 days) and equivalence partitions for normal/spike/dip.
return function(H)
    local ns = H.load({ "Market.lua" })
    local Market = ns.Market

    -- history newest first; today's entry is index 1 and is never part of the baseline
    local function history(today, ...)
        local h = { { minSeen = today, available = 10 } }
        for _, p in ipairs({ ... }) do
            h[#h + 1] = { minSeen = p, available = 10 }
        end
        return h
    end

    H.test("a normal price has no flags", function()
        local a = Market.Assess(100, history(100, 90, 100, 110), 0)
        H.eq(a.usual, 100); H.near(a.ratio, 1)
        H.eq(Market.Risky(a), false)
    end)

    H.test("spike boundary: exactly 1.5x is a spike, just under is not", function()
        H.eq(Market.Assess(150, history(150, 100, 100, 100), 0).spike, true)
        H.eq(Market.Assess(149, history(149, 100, 100, 100), 0).spike, nil)
    end)

    H.test("dip boundary: exactly 0.6x is a dip, and a dip alone is not risky", function()
        local a = Market.Assess(60, history(60, 100, 100, 100), 0)
        H.eq(a.dip, true); H.eq(Market.Risky(a), false)
        H.eq(Market.Assess(61, history(61, 100, 100, 100), 0).dip, nil)
    end)

    H.test("fewer than 3 earlier days: no comparison", function()
        local a = Market.Assess(500, history(500, 100, 100), 0)
        H.eq(a.usual, nil); H.eq(a.spike, nil)
    end)

    H.test("today's spike doesn't count towards the usual price (median of earlier days)", function()
        local a = Market.Assess(300, history(300, 100, 100, 1000), 0)
        H.eq(a.usual, 100, "median ignores one odd old day")
        H.eq(a.spike, true)
    end)

    H.test("stale boundary: 2 days is fine, 3 days is stale", function()
        H.eq(Market.Assess(100, {}, 2).stale, nil)
        local a = Market.Assess(100, {}, 3)
        H.eq(a.stale, true); H.eq(Market.Risky(a), true)
    end)

    H.test("low supply boundary: 2 listed is thin, 3 is not", function()
        H.eq(Market.Assess(100, { { minSeen = 100, available = 2 } }, 0).thin, true)
        H.eq(Market.Assess(100, { { minSeen = 100, available = 3 } }, 0).thin, nil)
        H.eq(Market.Assess(100, { { minSeen = 100 } }, 0).thin, nil, "unknown supply isn't flagged")
    end)

    H.test("Reasons explains the flags in plain words", function()
        local money = function(c) return c .. "c" end
        local a = Market.Assess(200, { { minSeen = 200, available = 1 }, { minSeen = 100 }, { minSeen = 100 }, { minSeen = 100 } }, 4)
        local r = Market.Reasons(a, money)
        H.eq(r[1], "2.0x the usual 100c")
        H.eq(r[2], "4 days old")
        H.eq(r[3], "only 1 listed")
        H.eq(#Market.Reasons(nil, money), 0)
    end)
end
