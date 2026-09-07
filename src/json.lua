return function(B)
local J={}
function J.json_escape(value)
    return string.gsub(value, '[%z\1-\31\\"]', function(character)
        local replacements = {
            ['"'] = '\\"',
            ['\\'] = '\\\\',
            ['\b'] = '\\b',
            ['\f'] = '\\f',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
        }
        return replacements[character] or string.format("\\u%04x", string.byte(character))
    end)
end


function J.json_encode(value, stack)
    local value_type = type(value)
    if value == nil then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    elseif value_type == "string" then
        return '"' .. J.json_escape(value) .. '"'
    elseif value_type ~= "table" then
        return '"' .. J.json_escape(tostring(value)) .. '"'
    end

    stack = stack or {}
    if stack[value] then
        error("circular table in JSON")
    end
    stack[value] = true
    local is_array = true
    local max_index = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            is_array = false
            break
        end
        max_index = math.max(max_index, key)
    end
    local parts = {}
    if is_array then
        for index = 1, max_index do
            parts[#parts + 1] = J.json_encode(value[index], stack)
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        if type(key) == "string" then
            parts[#parts + 1] = '"' .. J.json_escape(key) .. '":'
                .. J.json_encode(item, stack)
        end
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function J.json_decode(text)
    local position = 1
    local length = #text
    local parse_value
    local depth=0
    local function utf8char(code)
        if code<128 then return string.char(code) end
        if code<2048 then return string.char(192+math.floor(code/64),128+code%64) end
        if code<65536 then return string.char(224+math.floor(code/4096),128+math.floor(code/64)%64,128+code%64) end
        return string.char(240+math.floor(code/262144),128+math.floor(code/4096)%64,128+math.floor(code/64)%64,128+code%64)
    end

    local function skip_space()
        while position <= length and string.match(string.sub(text, position, position), "%s") do
            position = position + 1
        end
    end

    local function parse_string()
        position = position + 1
        local parts = {}
        while position <= length do
            local character = string.sub(text, position, position)
            if character == '"' then
                position = position + 1
                return table.concat(parts)
            elseif character == "\\" then
                local escaped = string.sub(text, position + 1, position + 1)
                local replacements = {
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
                }
                if escaped == "u" then
                    local code = tonumber(string.sub(text, position + 2, position + 5), 16)
                    if not code then error("invalid JSON unicode escape") end
                    position = position + 6
                    if code>=55296 and code<=56319 then
                        if text:sub(position,position+1)~='\\u' then error('unpaired JSON surrogate') end
                        local low=tonumber(text:sub(position+2,position+5),16)
                        if not low or low<56320 or low>57343 then error('invalid JSON surrogate') end
                        code=65536+(code-55296)*1024+low-56320
                        position=position+6
                    elseif code>=56320 and code<=57343 then error('unpaired JSON surrogate') end
                    parts[#parts + 1] = utf8char(code)
                else
                    parts[#parts + 1] = replacements[escaped] or escaped
                    position = position + 2
                end
            else
                parts[#parts + 1] = character
                position = position + 1
            end
        end
        error("unterminated JSON string")
    end

    local function parse_number()
        local start = position
        while position <= length and string.match(string.sub(text, position, position), "[%d%+%-%eE%.]") do
            position = position + 1
        end
        local number = tonumber(string.sub(text, start, position - 1))
        if number == nil then error("invalid JSON number") end
        return number
    end

    local function parse_array()
        position = position + 1
        local result = {}
        skip_space()
        if string.sub(text, position, position) == "]" then
            position = position + 1
            return result
        end
        while true do
            result[#result + 1] = parse_value()
            skip_space()
            local character = string.sub(text, position, position)
            if character == "]" then
                position = position + 1
                return result
            elseif character ~= "," then
                error("invalid JSON array")
            end
            position = position + 1
        end
    end

    local function parse_object()
        position = position + 1
        local result = {}
        skip_space()
        if string.sub(text, position, position) == "}" then
            position = position + 1
            return result
        end
        while true do
            skip_space()
            if string.sub(text, position, position) ~= '"' then error("invalid JSON object key") end
            local key = parse_string()
            skip_space()
            if string.sub(text, position, position) ~= ":" then error("missing JSON colon") end
            position = position + 1
            result[key] = parse_value()
            skip_space()
            local character = string.sub(text, position, position)
            if character == "}" then
                position = position + 1
                return result
            elseif character ~= "," then
                error("invalid JSON object")
            end
            position = position + 1
        end
    end

    parse_value = function()
        skip_space()
        local character = string.sub(text, position, position)
        if character == '"' then return parse_string() end
        if character == '{' or character == '[' then
            depth=depth+1 if depth>32 then error('JSON nesting limit') end
            local v=character=='{' and parse_object() or parse_array()
            depth=depth-1 return v
        end
        if string.sub(text, position, position + 3) == "true" then position = position + 4; return true end
        if string.sub(text, position, position + 4) == "false" then position = position + 5; return false end
        if string.sub(text, position, position + 3) == "null" then position = position + 4; return nil end
        return parse_number()
    end

    local result = parse_value()
    skip_space()
    if position <= length then error("trailing JSON data") end
    return result
end



B.json={encode=function(_,v) return J.json_encode(v) end,decode=function(_,v) return J.json_decode(v) end}
end
