-- AH signals: deals (bought under the market value, resold after the cut) and sell windows (what you hold, priced
-- well over the market value at the house you'd sell it at), each per house from the API's market values.
-- Items the API has no market value for keep today's scan-based buy/sell rows (I.market), marked basis "scans".
-- Pure functions: build.lua passes in the merged books (R.merge), the holders and the legacy lists.
local Sg = {}

-- DEAL_BELOW / SELL_ABOVE / MIN_GAIN start from I.MARKET (buyBelow, sellAbove, minGain). *_MIN_SOLD: sales a
-- day the market must show. LIMIT: rows per list (and as many legacy rows). WANTED_LIST: deals per house whose
-- series the engine keeps. FLIP_MIN_LISTED: listings at both houses for a flip to be wanted (the page's GAP_MIN).
-- RISE / FALL / MOVER_*: the movers list. DEAL_SUSPECT: a deal this far under market (0.90 = 90%) is most likely
-- one stray listing, so it counts one unit, not what the market takes, and is marked lone.
-- Deals are stricter than I.MARKET's buy rule: on the API's data (Nov 2026) 0.70 and 2 sales a day made 784
-- deals at PvP Horde and 224 at PvP Neutral; 0.50 and 5 a day make about 200 and 75.
-- Craft flips: FLIP_SELL_HOURS: the whole stack (lowballs bought out plus crafted) must sell within this many hours
-- of the product's sales. FLIP_BOOK_DAYS: a product listed for more days of sales than this is too crowded.
-- FLIP_BAND: a craft must still pay with its AH reagents this much dearer (the top of the 10% cheap band).
Sg.C = { DEAL_BELOW = 0.50, DEAL_SUSPECT = 0.90, DEAL_MIN_SOLD = 5, MIN_GAIN = 50, SELL_ABOVE = 1.25, SELL_MIN_SOLD = 1, LIMIT = 25,
    RISE = 0.25, FALL = -0.20, MOVER_MIN_SOLD = 2, MOVER_LIMIT = 30, WANTED_LIST = 25, FLIP_MIN_LISTED = 5,
    FLIP_SELL_HOURS = 2, FLIP_BOOK_DAYS = 1, FLIP_BAND = 1.10 }

local function num(v) return type(v) == "number" and v or nil end

local function trim(list, n)
    for i = #list, n + 1, -1 do list[i] = nil end
    return list
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- book: a merged book ({ prices = { [id] = entry } }). cut: the house's AH cut (I.CUT). owned: { [id] = { count } }
-- or nil. legacyBuy: I.market's buy list or nil (the default faction house only).
-- Returns the API rows { id, name, now, market, pct, soldPerDay, units, cheap, profit, perDay, lone, guessed,
-- nowFrom, nowAt, have, basis = "api" } by profit per day, then the legacy rows (basis = "scans") for items without a market value.
function Sg.deals(book, cut, nameOf, owned, legacyBuy)
    local C, prices = Sg.C, book and book.prices or {}
    local api = {}
    for id, e in pairs(prices) do
        local now, market, sold = num(e.now), num(e.market), num(e.soldPerDay)
        if market and market > 0 and now and now > 0 and sold and now <= market * C.DEAL_BELOW
            and sold >= C.DEAL_MIN_SOLD then
            local profit = math.floor(market * (1 - cut)) - now
            if profit >= C.MIN_GAIN then
                local units = num(e.units) or 0
                local pct = 1 - now / market
                -- the API's count of units within 10% of the lowest price, when "now" is the API's lowest; without
                -- it (older data, or a newer scan set the price) far under market is guessed to be one stray listing
                local cheap = e.nowFrom == "api" and num(e.cheap) or nil
                local lone, guessed, qty
                if cheap then
                    lone, qty = cheap == 1, cheap
                else
                    lone, guessed, qty = pct >= C.DEAL_SUSPECT, pct >= C.DEAL_SUSPECT, units
                end
                api[#api + 1] = { id = id, name = nameOf(id), now = now, market = market, pct = pct,
                    soldPerDay = sold, units = num(e.units), cheap = cheap, profit = profit,
                    perDay = lone and profit or math.floor(profit * math.min(sold, qty)), lone = lone or nil,
                    guessed = guessed or nil,
                    nowFrom = e.nowFrom, nowAt = e.nowAt, have = owned and owned[id] and owned[id].count or 0,
                    basis = "api" }
            end
        end
    end
    table.sort(api, function(a, b)
        if a.perDay ~= b.perDay then return a.perDay > b.perDay end
        return a.id < b.id
    end)
    trim(api, C.LIMIT)
    local legacy = {}
    for _, r in ipairs(legacyBuy or {}) do
        local e = prices[r.id]
        if not (e and e.market) then
            local row = copy(r)
            row.basis = "scans"
            legacy[#legacy + 1] = row
        end
    end
    table.sort(legacy, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.id < b.id
    end)
    trim(legacy, C.LIMIT)
    for _, r in ipairs(legacy) do api[#api + 1] = r end
    return api
end

local function held(w) return (w.bags or 0) + (w.bank or 0) + (w.mail or 0) end

-- holders: { { id = charId, name, holds = { [item] = { bags, bank, mail } } } }. houseOf(charId): the faction house
-- key the character sells at, nil when it can't be told (then defaultKey, as the character pages do). books:
-- { [key] = merged book }. legacySell: I.market's sell list or nil (judged at defaultKey).
-- Returns { id, name, key, now, market, pct, soldPerDay, count, sells, extra, where = { { name, bags, bank, mail } },
-- basis = "api" } by extra copper, then the legacy rows (key = defaultKey, basis = "scans").
function Sg.sellWindows(holders, houseOf, books, nameOf, legacySell, defaultKey)
    local C = Sg.C
    local byHouse = {}  -- key -> item -> where list
    for _, h in ipairs(holders or {}) do
        local key = houseOf(h.id) or defaultKey
        if key then
            local items = byHouse[key] or {}
            byHouse[key] = items
            for item, w in pairs(h.holds or {}) do
                if held(w) > 0 then
                    items[item] = items[item] or {}
                    table.insert(items[item], { name = h.name, bags = w.bags or 0, bank = w.bank or 0, mail = w.mail or 0 })
                end
            end
        end
    end
    local api = {}
    for key, items in pairs(byHouse) do
        local prices = books and books[key] and books[key].prices or {}
        for id, where in pairs(items) do
            local e = prices[id]
            local now, market, sold = e and num(e.now), e and num(e.market), e and num(e.soldPerDay)
            if market and market > 0 and now and now > 0 and sold and now >= market * C.SELL_ABOVE
                and now - market >= C.MIN_GAIN and sold >= C.SELL_MIN_SOLD then
                local count = 0
                for _, w in ipairs(where) do count = count + held(w) end
                table.sort(where, function(a, b)
                    if held(a) ~= held(b) then return held(a) > held(b) end
                    return a.name < b.name
                end)
                -- what sells in a day at this house (SELL_MIN_SOLD keeps it at 1 or more), not everything held
                local sells = math.min(count, math.floor(sold))
                api[#api + 1] = { id = id, name = nameOf(id), key = key, now = now, market = market,
                    pct = now / market - 1, soldPerDay = sold, count = count, sells = sells,
                    extra = (now - market) * sells,
                    where = where, basis = "api" }
            end
        end
    end
    table.sort(api, function(a, b)
        if a.extra ~= b.extra then return a.extra > b.extra end
        if a.key ~= b.key then return a.key < b.key end
        return a.id < b.id
    end)
    trim(api, C.LIMIT)
    local prices = defaultKey and books and books[defaultKey] and books[defaultKey].prices or {}
    local n = 0
    for _, r in ipairs(legacySell or {}) do
        local e = prices[r.id]
        if n < C.LIMIT and not (e and e.market) then
            local row = copy(r)
            row.key, row.basis = defaultKey, "scans"
            api[#api + 1] = row
            n = n + 1
        end
    end
    return api
end

-- Ids of the best Faction <-> Neutral flips (I.compareHouses rows): a positive flip either way, FLIP_MIN_LISTED or
-- more listed at both houses, by the better of the two flips, at most WANTED_LIST. Their series are wanted too.
function Sg.flipIds(rows)
    local picked = {}
    for _, r in ipairs(rows or {}) do
        local best = math.max(r.toNeutral or 0, r.toFaction or 0)
        if best > 0 and (r.fListed or 0) >= Sg.C.FLIP_MIN_LISTED and (r.nListed or 0) >= Sg.C.FLIP_MIN_LISTED then
            picked[#picked + 1] = { id = r.id, best = best }
        end
    end
    table.sort(picked, function(a, b)
        if a.best ~= b.best then return a.best > b.best end
        return a.id < b.id
    end)
    local ids = {}
    for i = 1, math.min(#picked, Sg.C.WANTED_LIST) do ids[i] = picked[i].id end
    return ids
end

-- Rising and fallen items. prices: { [id] = { shifted, trend, soldPerDay, ... } }; scanRule(id, p) -> upV, downV (numbers or nil, either or both)
-- is today's launch-low / peak rule for items without API figures. An item with an API trend or shifted level
-- needs MOVER_MIN_SOLD sales a day and is judged only by the API (shifted decides when present). Order: shifted
-- by size, API trend by size, then scans; ties by id. Returns rising, falling (id lists) and basis[id].
function Sg.movers(prices, scanRule, limit)
    local C = Sg.C
    local lists = { up = {}, down = {} }
    local basis = {}
    for id, p in pairs(prices) do
        local dir, rank, v, how
        if p.shifted or p.trend then
            if (num(p.soldPerDay) or 0) >= C.MOVER_MIN_SOLD then
                if p.shifted then
                    dir, rank, how = p.shifted.dir, 1, "shifted"
                    v = math.abs(num(p.shifted.pct) or 0)
                else
                    local t = num(p.trend) or 0
                    if t >= C.RISE then dir = "up" elseif t <= C.FALL then dir = "down" end
                    rank, how, v = 2, "trend", math.abs(t)
                end
            end
        elseif scanRule then
            local upV, downV = scanRule(id, p)
            if upV then lists.up[#lists.up + 1] = { id = id, rank = 3, v = upV, how = "scan" } end
            if downV then lists.down[#lists.down + 1] = { id = id, rank = 3, v = downV, how = "scan" } end
        end
        if dir and lists[dir] then
            local l = lists[dir]
            l[#l + 1] = { id = id, rank = rank, v = v, how = how }
        end
    end
    local function finish(l)
        table.sort(l, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.v ~= b.v then return a.v > b.v end
            return a.id < b.id
        end)
        local ids = {}
        for i = 1, math.min(limit or C.MOVER_LIMIT, #l) do ids[i] = l[i].id; basis[l[i].id] = l[i].how end
        return ids
    end
    return finish(lists.up), finish(lists.down), basis
end

local FACTION_CODE = { Horde = "H", Alliance = "A" }

-- The recipes a character can flip: the ones it knows, and the unlearned ones it could learn now, from a trainer
-- or a vendor, at its saved skill and for its faction. mob: a merged MakeOrBuyCharDB (recipes, unlearned, skill).
-- recipeData: Make or Buy's RecipeData ({ [profession] = { [recipeID] = { learnSkill, trainerCost, sources,
-- teachItemID, faction } } }). faction: "Horde" | "Alliance" | nil (any). bookNow(id): the house's price of a
-- recipe item. Returns { [recipeID] = recipe } (copies): learn = nil when known, else { how = "trainer" |
-- "vendor", cost = copper or nil, skill }.
function Sg.flipRecipes(mob, recipeData, faction, bookNow)
    local out = {}
    if not mob then return out end
    for id, r in pairs(mob.recipes or {}) do out[id] = copy(r) end
    local code = faction and FACTION_CODE[faction]
    for id, r in pairs(mob.unlearned or {}) do
        local entry = not out[id] and recipeData and recipeData[r.profession] and recipeData[r.profession][id]
        local skill = mob.skill and mob.skill[r.profession]
        local level = type(skill) == "table" and tonumber(skill.level)
        if entry and level and (entry[1] or 0) <= level and (entry[5] == nil or code == nil or entry[5] == code) then
            local sources = entry[3] or ""
            local learn
            if sources:find("t", 1, true) then
                learn = { how = "trainer", cost = entry[2], skill = entry[1] }
            elseif sources:find("v", 1, true) then
                learn = { how = "vendor", cost = entry[4] and bookNow and bookNow(entry[4]) or nil, skill = entry[1] }
            end
            if learn then
                local c = copy(r)
                c.learn = learn
                out[id] = c
            end
        end
    end
    return out
end

-- The items one craft of `plan` buys, at any depth: { [itemID] = { amount, unit, source } }. A crafted reagent is
-- planned per unit, so its own reagents scale by qty / outputQty and stay fractional. learns collects the learn
-- of every crafted sub-recipe that has one.
local function flipLeaves(plan, mult, leaves, learns)
    for _, r in ipairs(plan.reagents or {}) do
        local amount, node = mult * r.qty, r.node
        if node.method == "craft" then
            local sub = node.craft
            if sub.recipe.learn then learns[sub.recipe.recipeID or sub.recipe] = sub.recipe end
            flipLeaves(sub, amount / sub.outputQty, leaves, learns)
        else
            local l = leaves[node.itemID]
            if not l then
                l = { amount = 0, unit = node.buyPrice, source = node.buySource }
                leaves[node.itemID] = l
            end
            l.amount = l.amount + amount
        end
    end
end

-- One crafter's flip of one recipe at a house, or nil (rules in Sg.craftFlips)
local function flipRow(crafter, recipe, index, book, cut, P, price, nameOf)
    local C, prices = Sg.C, book.prices or {}
    local out = recipe.outputItemID
    local e = out and prices[out]
    local market, sold, units = e and num(e.market), e and num(e.soldPerDay), e and num(e.units)
    if not (market and market > 0 and sold and sold > 0 and units) then return nil end
    if units / sold > C.FLIP_BOOK_DAYS then return nil end
    local plan = P.PlanRecipe(recipe, index, price)
    if not plan.complete then return nil end
    local qty = plan.outputQty
    local unitValue = math.floor(market * (1 - cut))
    local cost, sale = math.floor(plan.total), qty * unitValue
    local profit = sale - cost
    if profit <= 0 then return nil end
    local leaves, learns = {}, {}
    flipLeaves(plan, 1, leaves, learns)
    local band = 0
    for _, l in pairs(leaves) do
        band = band + l.amount * (l.source == "vendor" and l.unit or l.unit * C.FLIP_BAND)
    end
    if sale - band <= 0 then return nil end
    local now = num(e.now)
    local lowballs = 0
    -- cheap is the API's count near its lowest; a newer in-game scan keeps it (R.merge copies it), so it counts too
    if num(e.cheap) and now and now < unitValue then lowballs = e.cheap end
    local perHour = sold / 24
    local crafts, capBy = math.floor((perHour * C.FLIP_SELL_HOURS - lowballs) / qty), "sales"
    local reagents = {}
    for id, l in pairs(leaves) do
        local le = prices[id]
        local cheap = le and num(le.cheap) or nil
        local held = crafter.held and crafter.held[id] or 0
        if l.source ~= "vendor" then
            local cap = math.floor(((cheap or 0) + held) / l.amount + 1e-9)
            if cap < crafts then crafts, capBy = cap, id end
        end
        reagents[#reagents + 1] = { id = id, name = nameOf(id), perCraft = l.amount, unit = l.unit,
            source = l.source == "vendor" and "vendor" or "ah", cheap = cheap, held = held > 0 and held or nil }
    end
    if crafts < 1 then return nil end
    table.sort(reagents, function(a, b) return a.id < b.id end)
    local buyout = lowballs > 0 and (unitValue - now) * lowballs or 0
    local gold = profit * crafts + buyout
    local learnCost, subLearns
    if recipe.learn or next(learns) then
        learnCost = recipe.learn and recipe.learn.cost or 0
        for _, r in pairs(learns) do
            learnCost = learnCost + (r.learn.cost or 0)
            subLearns = subLearns or {}
            subLearns[#subLearns + 1] = { name = r.name or nameOf(r.outputItemID), how = r.learn.how, cost = r.learn.cost }
        end
        if subLearns then table.sort(subLearns, function(a, b) return tostring(a.name) < tostring(b.name) end) end
    end
    return { id = out, name = nameOf(out) or recipe.name, recipeName = recipe.name, recipeID = recipe.recipeID,
        outputQty = qty,
        crafter = { id = crafter.id, name = crafter.name, learn = recipe.learn, subLearn = subLearns and true or nil },
        subLearns = subLearns, cost = cost, sale = sale,
        profit = profit, crafts = crafts, capBy = capBy, capName = capBy ~= "sales" and nameOf(capBy) or nil,
        lowballs = lowballs, buyout = buyout, hours = (lowballs + crafts * qty) / perHour, gold = gold,
        learnCost = learnCost, paysBackIn = learnCost and learnCost > 0 and math.ceil(learnCost / gold) or nil,
        soldPerDay = sold, units = units, reagents = reagents }
end

-- Craft flips at one house: buy every reagent at the house's lowest price (vendor when cheaper), craft, sell at
-- market value after the cut. crafters = { { id, name, recipes = Sg.flipRecipes(...), held = { [id] = n } } };
-- book: the house's merged book (prices, vendor); cut: I.CUT's; P: Make or Buy's Planner. A row needs:
-- - a product with a market value, sales a day and listings, listed for at most FLIP_BOOK_DAYS of sales;
-- - a profit, still positive with every AH-bought reagent at FLIP_BAND times its price;
-- - at least one craft, capped by each AH reagent's cheap units (plus what the crafter holds; vendor reagents are
--   unlimited) and by what sells in FLIP_SELL_HOURS, after the product's cheap listings under value (lowballs,
--   bought out and relisted: buyout is what that earns).
-- One row per product: the crafter with the most gold (the known one on a tie); who lists every crafter, known
-- first (a crafter who must learn a sub-craft counts as learning: subLearns names those). learnCost (shown, never
-- subtracted) sums the recipe's and its sub-crafts' learn costs. Sorted by gold.
local function learnable(c) return (c.learn or c.subLearn) and true or false end

function Sg.craftFlips(crafters, book, cut, P, nameOf)
    local best, who = {}, {}
    if not (P and book) then return {} end
    local prices, vendor = book.prices or {}, book.vendor or {}
    local function price(id)
        local v, e = num(vendor[id]), prices[id]
        local now = e and num(e.now)
        if now and now <= 0 then now = nil end
        if v and (not now or v <= now) then return v, "vendor" end
        if now then return now, "ah" end
        return nil
    end
    for _, c in ipairs(crafters or {}) do
        local index = P.IndexByOutput(c.recipes)
        local mine = {}
        for _, recipe in pairs(c.recipes or {}) do
            -- a saved recipe the planner can't read (a reagent without a quantity) is skipped, never the whole build
            local ok, row = pcall(flipRow, c, recipe, index, book, cut, P, price, nameOf)
            if ok and row and (not mine[row.id] or row.gold > mine[row.id].gold) then mine[row.id] = row end
        end
        for id, row in pairs(mine) do
            who[id] = who[id] or {}
            who[id][#who[id] + 1] = { id = c.id, name = c.name, learn = row.crafter.learn, subLearn = row.crafter.subLearn }
            local b = best[id]
            if not b or row.gold > b.gold or (row.gold == b.gold and learnable(b.crafter) and not learnable(row.crafter)) then
                best[id] = row
            end
        end
    end
    local list = {}
    for id, row in pairs(best) do
        table.sort(who[id], function(a, b)
            if learnable(a) ~= learnable(b) then return not learnable(a) end
            return tostring(a.name) < tostring(b.name)
        end)
        row.who = who[id]
        list[#list + 1] = row
    end
    table.sort(list, function(a, b)
        if a.gold ~= b.gold then return a.gold > b.gold end
        return a.id < b.id
    end)
    return trim(list, Sg.C.LIMIT)
end

return Sg
