-- Minimal JSON for the plugin protocol. Lightroom ships Lua 5.1 and no library.

local Json = {}

local function skip(s, i)
    while i <= #s and s:sub(i, i):match("%s") do
        i = i + 1
    end
    return i
end

local parseValue

local function parseString(s, i)
    i = i + 1
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == "\\" then
            local e = s:sub(i + 1, i + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", r = "\r", t = "\t" }
            parts[#parts + 1] = map[e] or e
            i = i + 2
        else
            parts[#parts + 1] = c
            i = i + 1
        end
    end
    error("unterminated string")
end

local function parseNumber(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num then
        error("expected number at " .. i)
    end
    return tonumber(num), i + #num
end

local function parseArray(s, i)
    i = skip(s, i + 1)
    local arr = {}
    if s:sub(i, i) == "]" then
        return arr, i + 1
    end
    while true do
        local value
        value, i = parseValue(s, i)
        arr[#arr + 1] = value
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "]" then
            return arr, i + 1
        end
        if c ~= "," then
            error("expected comma in array")
        end
        i = skip(s, i + 1)
    end
end

local function parseObject(s, i)
    i = skip(s, i + 1)
    local obj = {}
    if s:sub(i, i) == "}" then
        return obj, i + 1
    end
    while true do
        i = skip(s, i)
        local key
        key, i = parseString(s, i)
        i = skip(s, i)
        if s:sub(i, i) ~= ":" then
            error("expected colon")
        end
        i = skip(s, i + 1)
        local value
        value, i = parseValue(s, i)
        obj[key] = value
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "}" then
            return obj, i + 1
        end
        if c ~= "," then
            error("expected comma in object")
        end
        i = skip(s, i + 1)
    end
end

parseValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return parseString(s, i)
    elseif c == "{" then
        return parseObject(s, i)
    elseif c == "[" then
        return parseArray(s, i)
    elseif c == "t" then
        return true, i + 4
    elseif c == "f" then
        return false, i + 5
    elseif c == "n" then
        return nil, i + 4
    else
        return parseNumber(s, i)
    end
end

function Json.decode(s)
    local value = parseValue(s, 1)
    return value
end

local function encode(value)
    local kind = type(value)
    if kind == "nil" then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return string.format("%.8g", value)
    elseif kind == "string" then
        local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. escaped .. '"'
    elseif kind == "table" then
        local marker = getmetatable(value)
        local forceArray = type(marker) == "table" and marker.json == "array"
        local array = true
        local count = 0
        for key in pairs(value) do
            count = count + 1
            if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
                array = false
                break
            end
        end
        if forceArray or (array and count == #value and count > 0) then
            local parts = {}
            for index = 1, count do
                parts[index] = encode(value[index])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for key, item in pairs(value) do
            parts[#parts + 1] = encode(tostring(key)) .. ":" .. encode(item)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

function Json.encode(value)
    return encode(value)
end

function Json.array(items)
    local value = items or {}
    return setmetatable(value, { json = "array" })
end

return Json
