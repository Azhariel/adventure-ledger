-- Status: what Logbook has recorded for this character, for the /logbook window (StatusWindow.lua).
local _, ns = ...

local KIND = { -- log line kinds (README "What it records") in words, most interesting first
    { "ki", "Kills" }, { "xp", "XP lines" }, { "qt", "Quests turned in" }, { "qa", "Quests accepted" },
    { "lo", "Items received" }, { "ga", "Gathered" }, { "mn", "Gold changes" }, { "ah", "Auction house" },
    { "ma", "Mail" }, { "de", "Deaths" }, { "fi", "Fights read" }, { "zo", "Zones" }, { "ie", "Dungeons" },
    { "pl", "Players met" }, { "fl", "Flights" }, { "lv", "Levels" }, { "sk", "Skill ranks" },
}
local WORD = { ["in"] = "logged in", out = "logged out", il = "left dungeon", ge = "gear", qx = "abandoned quest" }
for _, k in ipairs(KIND) do WORD[k[1]] = k[2]:lower() end

local RECENT = 6

local function fields(line)
    local f = {}
    for part in (line .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
    return f
end

local function money(c)
    c = math.floor(c + 0.5)
    local sign = c < 0 and "-" or "+"
    c = math.abs(c)
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if cp > 0 or #parts == 0 then parts[#parts + 1] = cp .. "c" end
    return sign .. table.concat(parts, " ")
end
ns.StatusMoney = money

local function ago(now, t)
    local d = math.max(0, now - (t or now))
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end

local function day(t)
    return (date and t) and date("%d %b %Y", t) or tostring(t or "?")
end

-- Lines since t, read from the end: { [kind] = count }, the gold and XP they add up to
local function since(log, t)
    local n, gold, xp = {}, 0, 0
    for i = #log, 1, -1 do
        local f = fields(log[i])
        local lt = tonumber(f[1])
        if not lt or lt < t then break end
        local kind = f[6]
        n[kind] = (n[kind] or 0) + 1
        if kind == "mn" then gold = gold + (tonumber(f[7]) or 0) end
        if kind == "xp" then xp = xp + (tonumber(f[7]) or 0) end
    end
    return n, gold, xp
end

function ns.Status()
    local db = ns.db
    if not db then return { warnings = { "nothing loaded yet: Logbook starts at login" } } end
    local now = ns.Now()
    local c = db.char or {}
    local warnings, sections = {}, {}
    local realm = type(c.realm) == "string" and c.realm ~= "" and c.realm or nil
    if not realm then
        warnings[#warnings + 1] = "no realm or ruleset saved: the dashboard can't tell this character's auction house"
    end
    local meter = db.meter or {}
    if meter.available == false then
        warnings[#warnings + 1] = "damage meter unavailable (" .. tostring(meter.reason or "unknown") .. "): no fights recorded"
    end

    sections[#sections + 1] = { title = "Character", rows = {
        { "Name", c.name or "?" }, { "Realm", realm or "(none)" },
        { "Faction", c.faction or "?" }, { "Race, class", (c.race or "?") .. ", " .. (c.class or "?") },
        { "Level", c.level or "?" }, { "Zone", c.zone or "?" },
    } }

    local s = db.sessions[#db.sessions]
    if s then
        local n, gold, xp = since(db.log, s.start)
        local rows = { { "Started", ago(now, s.start) .. " (" .. (s.how or "login") .. ")" } }
        if xp > 0 then rows[#rows + 1] = { "XP gained", xp } end
        if n.mn then rows[#rows + 1] = { "Gold", money(gold) } end
        for _, k in ipairs(KIND) do
            if n[k[1]] and k[1] ~= "xp" and k[1] ~= "mn" then rows[#rows + 1] = { k[2], n[k[1]] } end
        end
        sections[#sections + 1] = { title = "This session", rows = rows }
    end

    local counts = db.counts or {}
    local rows = {
        { "Since", day(db.since) },
        { "Log lines", #db.log }, { "Sessions", #db.sessions }, { "Trail chunks", #db.trail.chunks },
        { "Kills", (counts.fights or {}).kills or 0 },
        { "Quests done", (counts.quests or {}).done or 0 },
        { "Deaths", (counts.deaths or {}).total or 0 },
        { "Fights read", (counts.damage or {}).fights or 0 },
    }
    if db.baseline then rows[#rows + 1] = { "Carried on from", db.baseline.from } end
    if db.history then rows[#rows + 1] = { "Older history", #db.history.log .. " lines from " .. tostring(db.history.from) } end
    sections[#sections + 1] = { title = "All recorded", rows = rows }

    local recent = {}
    for i = #db.log, math.max(1, #db.log - RECENT + 1), -1 do
        local f = fields(db.log[i])
        local args = {}
        for j = 7, math.min(#f, 10) do if f[j] ~= "" then args[#args + 1] = f[j] end end
        local what = table.concat(args, ", ")
        if #what > 48 then what = what:sub(1, 45) .. "..." end
        recent[#recent + 1] = { ago(now, tonumber(f[1])), (WORD[f[6]] or f[6] or "?") .. (what ~= "" and (": " .. what) or "") }
    end
    sections[#sections + 1] = { title = "Recent", rows = recent }

    return { warnings = warnings, sections = sections,
        footer = "Saved when you log out or /reload; the dashboard reads it then.  /logbook print: to the chat" }
end

local window = ns.StatusWindow.New({
    name = "LogbookStatusFrame", title = "Logbook",
    build = ns.Status,
    position = function()
        if not ns.account then return nil end
        ns.account.window = ns.account.window or {}
        return ns.account.window
    end,
})
ns.StatusWindowFrame = window

function ns.ShowStatus(msg)
    if (msg or ""):lower():match("^%s*print%s*$") then return window:Print() end
    window:Toggle()
end
