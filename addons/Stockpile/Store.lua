-- Store: pure logic over the saved data. No WoW calls, so it runs in the offline tests.
--
-- Saved layout:
--   db = { version = 1, chars = { ["Name-Realm"] = {
--       name = "Name", realm = "Realm", class = "PRIEST",
--       bags = { [itemID] = count }, bank = { ... }, mail = { ... } } } }
local _, ns = ...

local Store = {}
ns.Store = Store

Store.VERSION = 1
Store.LOCATIONS = { "bags", "bank", "mail" }

function Store.NewDB()
    return { version = Store.VERSION, chars = {} }
end

-- Returns a valid db, keeping the old one when it already has the current layout.
function Store.Upgrade(db)
    if type(db) ~= "table" or db.version ~= Store.VERSION or type(db.chars) ~= "table" then
        return Store.NewDB()
    end
    return db
end

function Store.Key(name, realm)
    return name .. "-" .. realm
end

-- Creates or updates a character entry; keeps its counts.
function Store.EnsureChar(db, name, realm, class)
    local key = Store.Key(name, realm)
    local c = db.chars[key]
    if not c then
        c = { bags = {}, bank = {}, mail = {} }
        db.chars[key] = c
    end
    c.name, c.realm, c.class = name, realm, class or c.class
    for _, loc in ipairs(Store.LOCATIONS) do
        c[loc] = c[loc] or {}
    end
    return key, c
end

-- Adds n to t[itemID]; ignores missing or non-positive counts.
function Store.Add(t, itemID, n)
    if type(itemID) ~= "number" or type(n) ~= "number" or n <= 0 then
        return
    end
    t[itemID] = (t[itemID] or 0) + n
end

local function same(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Replaces one location's counts. Returns true when anything changed.
function Store.SetLocation(db, key, location, counts)
    local c = db.chars[key]
    if not c then
        return false
    end
    local old = c[location] or {}
    c[location] = counts
    return not same(old, counts)
end

function Store.Forget(db, key)
    if db.chars[key] then
        db.chars[key] = nil
        return true
    end
    return false
end

-- Keys of the characters a scope covers. "realm" = every character on the current one's realm;
-- anything else = only the current character.
function Store.ScopeKeys(db, scope, currentKey)
    local keys = {}
    local current = db.chars[currentKey]
    if scope == "realm" and current then
        for key, c in pairs(db.chars) do
            if c.realm == current.realm then
                keys[#keys + 1] = key
            end
        end
    elseif current then
        keys[1] = currentKey
    end
    return keys
end

-- total, list for one item. The list holds one row per character that has any, the current
-- character first, then most first, then by name.
function Store.Count(db, itemID, scope, currentKey)
    local total, list = 0, {}
    for _, key in ipairs(Store.ScopeKeys(db, scope, currentKey)) do
        local c = db.chars[key]
        local row = { key = key, name = c.name, realm = c.realm, class = c.class, total = 0 }
        for _, loc in ipairs(Store.LOCATIONS) do
            row[loc] = c[loc][itemID] or 0
            row.total = row.total + row[loc]
        end
        if row.total > 0 then
            list[#list + 1] = row
            total = total + row.total
        end
    end
    table.sort(list, function(a, b)
        if (a.key == currentKey) ~= (b.key == currentKey) then
            return a.key == currentKey
        end
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.key < b.key
    end)
    for _, row in ipairs(list) do
        row.key = nil
    end
    return total, list
end

-- A fresh { [itemID] = count } over the scope; callers may change it freely.
function Store.OwnedMap(db, scope, currentKey)
    local owned = {}
    for _, key in ipairs(Store.ScopeKeys(db, scope, currentKey)) do
        local c = db.chars[key]
        for _, loc in ipairs(Store.LOCATIONS) do
            for itemID, n in pairs(c[loc]) do
                Store.Add(owned, itemID, n)
            end
        end
    end
    return owned
end

-- "20 bags, 10 bank, 4 mail", leaving out empty places.
function Store.Breakdown(row)
    local parts = {}
    for _, loc in ipairs(Store.LOCATIONS) do
        if (row[loc] or 0) > 0 then
            parts[#parts + 1] = row[loc] .. " " .. loc
        end
    end
    return table.concat(parts, ", ")
end

-- Tooltip/chat lines. colorName(row) returns the (colored) name to show; defaults to the plain name.
function Store.Lines(total, list, colorName)
    if total <= 0 then
        return {}
    end
    colorName = colorName or function(row) return row.name end
    local lines = { "Stockpile: " .. total }
    for _, row in ipairs(list) do
        lines[#lines + 1] = "  " .. colorName(row) .. ": " .. Store.Breakdown(row)
    end
    return lines
end

-- Item ID from a number, a numeric string, or an item link/string. nil otherwise.
function Store.ParseItemID(text)
    if type(text) == "number" then
        return text
    end
    if type(text) ~= "string" then
        return nil
    end
    local id = text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$")
    return id and tonumber(id)
end
