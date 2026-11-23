-- Status: what Stockpile has counted, for the /stockpile window (StatusWindow.lua).
local _, ns = ...
local Store = ns.Store

local function ago(now, t)
    local d = math.max(0, now - (t or now))
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end

-- items (the sum of the counts) and kinds (distinct item IDs) in one { [itemID] = count }
local function tally(counts)
    local items, kinds = 0, 0
    for _, n in pairs(counts or {}) do
        items, kinds = items + n, kinds + 1
    end
    return items, kinds
end

local function held(counts)
    local items, kinds = tally(counts)
    return items .. " items (" .. kinds .. (kinds == 1 and " kind)" or " kinds)")
end

local function total(c)
    local n = 0
    for _, loc in ipairs(Store.LOCATIONS) do n = n + tally(c[loc]) end
    return n
end

function ns.Status()
    local db = ns.db
    if not db then return { warnings = { "nothing loaded yet: Stockpile starts at login" } } end
    local now = time and time() or 0
    local key = ns.playerKey
    local c = key and db.chars[key]
    local warnings, sections = {}, {}

    if not key then
        -- Without a key nothing is saved for this character, so the dashboard won't see its items
        warnings[#warnings + 1] = "no realm from the client and no saved one or game rules to stand in: "
            .. "this character's items aren't saved"
        sections[#sections + 1] = { title = "This character", rows = { { "Key", "(none)" } } }
    elseif c then
        if not c.bankTime then
            warnings[#warnings + 1] = "bank never saved: talk to a banker once, it updates on every visit"
        end
        sections[#sections + 1] = { title = "This character", rows = {
            { "Key", key }, { "Realm", c.realm or "?" },
            { "Bags", held(c.bags) }, { "Bank", held(c.bank) },
            -- Mail has no saved time: it is read whenever the mailbox opens
            { "Mail", held(c.mail) },
            { "Bank saved", c.bankTime and (date("%Y-%m-%d %H:%M", c.bankTime) .. " (" .. ago(now, c.bankTime) .. ")")
                or "never" },
        } }
    end

    local keys = {}
    for k in pairs(db.chars) do keys[#keys + 1] = k end
    table.sort(keys)
    local rows = {}
    for _, k in ipairs(keys) do
        local ch = db.chars[k]
        local bank = ch.bankTime and ("bank " .. ago(now, ch.bankTime)) or "bank never saved"
        rows[#rows + 1] = { ch.name or k, tostring(ch.realm) .. ": " .. total(ch) .. " items, " .. bank }
    end
    if #rows == 0 then rows[1] = { "None yet", "" } end
    sections[#sections + 1] = { title = "All characters", rows = rows }

    return { warnings = warnings, sections = sections,
        footer = "/stockpile <item link or id>: who has it and where.  /stockpile forget Name-Realm: stop tracking "
            .. "one.  /stockpile print: this to the chat.  Saved when you log out or /reload; the dashboard reads it then." }
end

local window = ns.StatusWindow.New({
    name = "StockpileStatusFrame", title = "Stockpile",
    build = ns.Status,
    -- StockpileDB keeps unknown top-level keys while its version holds (Store.Upgrade); the dashboard reads only chars
    position = function()
        if not ns.db then return nil end
        ns.db.window = ns.db.window or {}
        return ns.db.window
    end,
})
ns.StatusWindowFrame = window

function ns.ShowStatus(msg)
    if (msg or ""):lower():match("^%s*print%s*$") then return window:Print() end
    window:Toggle()
end
