-- Small helpers: binary-safe SavedVariables loading, base64, JSON encoding.
local U = {}

-- Loads a SavedVariables file into a fresh environment table and returns it (nil, err on failure).
-- Read in binary mode: on Windows, text mode stops at byte 0x1A, which Auctionator's serialized prices contain.
function U.loadSV(path)
    local f = io.open(path, "rb")
    if not f then
        return nil, "missing"
    end
    local src = f:read("a")
    f:close()
    local env = {}
    local chunk, err = load(src, "@" .. path, "t", env)
    if not chunk then
        return nil, err
    end
    local ok, e = pcall(chunk)
    if not ok then
        return nil, e
    end
    return env
end

function U.readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end

function U.writeFile(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64INV = {}
for i = 1, #B64 do
    B64INV[B64:byte(i)] = i - 1
end

function U.base64decode(s)
    local out, bits, nbits = {}, 0, 0
    for i = 1, #s do
        local v = B64INV[s:byte(i)]
        if v then
            bits = (bits << 6) | v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                out[#out + 1] = string.char((bits >> nbits) & 0xff)
            end
        end
    end
    return table.concat(out)
end

-- JSON ------------------------------------------------------------------------------------------

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function str(s)
    s = s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end)
    -- "</" would end the <script> block the JSON is embedded in
    s = s:gsub("</", "<\\/")
    return '"' .. s .. '"'
end

local function isArray(t)
    local n = #t
    if n == 0 then
        return next(t) == nil
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    return count == n
end

local function encode(v, out)
    local t = type(v)
    if t == "nil" then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif math.type(v) == "integer" or (v % 1 == 0 and math.abs(v) < 2 ^ 53) then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.6g", v)
        end
    elseif t == "string" then
        out[#out + 1] = str(v)
    elseif t == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i, x in ipairs(v) do
                if i > 1 then out[#out + 1] = "," end
                encode(x, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = str(tostring(k))
                out[#out + 1] = ":"
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

function U.json(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- Splits "a|b||c" into { "a", "b", "", "c" }
function U.split(s, sep)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
        out[#out + 1] = part
    end
    return out
end

return U
