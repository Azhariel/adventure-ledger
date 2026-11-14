-- Minimal CBOR (RFC 8949) decoder for the data WoW's C_EncodingUtil.SerializeCBOR writes: unsigned/negative
-- integers, byte and text strings, arrays, maps, floats (half/single/double), true/false/null.
-- Arrays become 1-based Lua tables. Indefinite-length items are supported for strings, arrays and maps.
local CBOR = {}

local function half(bits)
    local sign = (bits >> 15) == 1 and -1 or 1
    local exp = (bits >> 10) & 0x1f
    local frac = bits & 0x3ff
    if exp == 0 then
        return sign * frac * 2.0 ^ -24
    elseif exp == 31 then
        return frac == 0 and sign * math.huge or 0 / 0
    end
    return sign * (1 + frac / 1024) * 2.0 ^ (exp - 15)
end

-- Decodes one item at byte `pos` of `s`. Returns value, next position.
local function item(s, pos)
    local b = s:byte(pos)
    if not b then
        error("CBOR: unexpected end of data at " .. pos)
    end
    pos = pos + 1
    local major, info = b >> 5, b & 0x1f

    if major == 7 then
        if info == 20 then return false, pos end
        if info == 21 then return true, pos end
        if info == 22 or info == 23 then return nil, pos end
        if info == 25 then return half(string.unpack(">I2", s, pos)), pos + 2 end
        if info == 26 then return (string.unpack(">f", s, pos)), pos + 4 end
        if info == 27 then return (string.unpack(">d", s, pos)), pos + 8 end
        if info < 20 then return info, pos end -- unassigned simple value
        error("CBOR: unsupported simple value " .. info)
    end

    local len
    if info < 24 then
        len = info
    elseif info == 24 then
        len = s:byte(pos); pos = pos + 1
    elseif info == 25 then
        len = string.unpack(">I2", s, pos); pos = pos + 2
    elseif info == 26 then
        len = string.unpack(">I4", s, pos); pos = pos + 4
    elseif info == 27 then
        len = string.unpack(">I8", s, pos); pos = pos + 8
    elseif info == 31 then
        len = nil -- indefinite
    else
        error("CBOR: bad length info " .. info)
    end

    if major == 0 then
        return len, pos
    elseif major == 1 then
        return -1 - len, pos
    elseif major == 2 or major == 3 then
        if len then
            return s:sub(pos, pos + len - 1), pos + len
        end
        local parts = {}
        while s:byte(pos) ~= 0xff do
            local part
            part, pos = item(s, pos)
            parts[#parts + 1] = part
        end
        return table.concat(parts), pos + 1
    elseif major == 4 then
        local t = {}
        if len then
            for i = 1, len do
                t[i], pos = item(s, pos)
            end
        else
            local i = 0
            while s:byte(pos) ~= 0xff do
                i = i + 1
                t[i], pos = item(s, pos)
            end
            pos = pos + 1
        end
        return t, pos
    elseif major == 5 then
        local t = {}
        local function pair()
            local k, v
            k, pos = item(s, pos)
            v, pos = item(s, pos)
            if k ~= nil then
                t[k] = v
            end
        end
        if len then
            for _ = 1, len do pair() end
        else
            while s:byte(pos) ~= 0xff do pair() end
            pos = pos + 1
        end
        return t, pos
    elseif major == 6 then
        return item(s, pos) -- tag: ignore it, keep the value
    end
end

-- Decodes a whole CBOR string. Returns the value, or nil and an error message.
function CBOR.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, "not a CBOR string"
    end
    local ok, value = pcall(item, s, 1)
    if not ok then
        return nil, value
    end
    return value
end

return CBOR
