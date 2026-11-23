-- Status: what Ledger Link is doing and has kept, for the /ledger window (StatusWindow.lua).
local _, ns = ...
local L = ns.LedgerLink

local RECENT_VISITS = 5

local function ago(now, t)
    local d = math.max(0, now - (t or now))
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end

local function items(n)
    return n .. (n == 1 and " item" or " items")
end

-- "12 items, last price 3 min ago", or just the count when the book holds no timestamps
local function book(now, side, realm)
    local n, last = L.BookInfo(side, realm)
    if last then return items(n) .. ", last price " .. ago(now, last) end
    return items(n)
end

function ns.Status()
    local d = L.DB()
    local now = time()
    local realm = L.RealmKey()
    local on = L.LoggingOn()
    local warnings, sections = {}, {}
    if d.enable and not on then
        warnings[#warnings + 1] = "combat log is off: the Live view gets nothing (/ledger on switches it on)"
    end
    if realm == "?" then
        warnings[#warnings + 1] = 'no realm name and no game rules: prices are kept under "?", which the dashboard can\'t place'
    end
    if not _G.Auctionator then
        warnings[#warnings + 1] = "Auctionator isn't loaded: no prices are recorded"
    end

    sections[#sections + 1] = { title = "Combat log", rows = {
        { "Logging now", on and "on" or "off" },
        { "Switch on at login", d.enable and "yes" or "no" },
    } }

    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local rows = {
        { "Realm key", realm },
        { "Neutral mode", d.neutralMode or "?" },
        { "Neutral book", book(now, "Neutral", realm) },
    }
    if faction then rows[#rows + 1] = { faction .. " book", book(now, faction, realm) } end
    local total = 0
    for _, sides in pairs(d.books or {}) do
        for _ in pairs(sides) do total = total + 1 end
    end
    rows[#rows + 1] = { "Books, all realms", total }
    sections[#sections + 1] = { title = "Prices", rows = rows }

    local visits, list = {}, d.visits or {}
    for i = #list, math.max(1, #list - RECENT_VISITS + 1), -1 do
        local v = list[i]
        visits[#visits + 1] = { ago(now, v.t), (v.kind or "?") .. ", " .. (v.zone or "?") }
    end
    sections[#sections + 1] = { title = "Auction house visits", rows = visits }

    return { warnings = warnings, sections = sections,
        footer = "/ledger on | off | neutral split|both|off.  /ledger print: to the chat.  "
            .. "Saved at logout or /reload; the dashboard reads it then." }
end

local window = ns.StatusWindow.New({
    name = "LedgerLinkStatusFrame", title = "Ledger Link",
    build = ns.Status,
    -- LedgerLinkDB.window; built only on /ledger, after the saved variables have loaded
    position = function()
        local d = L.DB()
        d.window = d.window or {}
        return d.window
    end,
})
ns.StatusWindowFrame = window

function ns.ShowStatus(msg)
    if (msg or ""):lower():match("^%s*print%s*$") then return window:Print() end
    window:Toggle()
end
