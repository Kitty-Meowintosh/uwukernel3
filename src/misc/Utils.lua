--- @class Utils
local Utils = {};

--- Creates a deep copy of a table
--- @param orig table table to copy
--- @param copies table|nil internal, tracks already-copied tables to preserve cycles/sharing
function Utils.deepcopy(orig, copies)
    copies = copies or {};

    local origType = type(orig);
    if origType ~= 'table' then
        return orig;
    end

    if copies[orig] then
        return copies[orig];
    end

    local copy = {};
    copies[orig] = copy;

    for origKey, origValue in next, orig, nil do
        copy[Utils.deepcopy(origKey, copies)] = Utils.deepcopy(origValue, copies);
    end

    setmetatable(copy, Utils.deepcopy(getmetatable(orig), copies));
    return copy;
end

--- Validates an environment variable name.
--- @param name any candidate name
function Utils.checkEnvName(name)
    if (type(name) ~= "string") then
        error("EINVAL: Environment name must be a string.");
    end

    if (name == "") then
        error("EINVAL: Environment name must not be empty.");
    end

    if (name:find("=", 1, true) or name:find("\0", 1, true)) then
        error("EINVAL: Environment name must not contain '=' or a null byte.");
    end
end

--- Validates a whole environment map.
--- @param map any candidate map
function Utils.checkEnvMap(map)
    if (type(map) ~= "table") then
        error("EINVAL: Environment must be a table.");
    end

    for name, value in pairs(map) do
        Utils.checkEnvName(name);

        if (type(value) ~= "string") then
            error("EINVAL: Environment value for '" .. name .. "' must be a string.");
        end
    end
end

function Utils.serialize(node, name, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local prefix = string.rep("  ", depth)

    local name_str = ""
    if name then
        if type(name) == "string" and name:match("^[%a_][%w_]*$") then
            name_str = name .. " = "
        else
            name_str = "[" .. tostring(name) .. "] = "
        end
    end

    local node_type = type(node)

    if node_type == "table" then
        if seen[node] then
            return prefix .. name_str .. '"<cycle ' .. tostring(node) .. '>"'
        end
        seen[node] = true

        local result = { prefix .. name_str .. "{" }
        for k, v in pairs(node) do
            table.insert(result, Utils.serialize(v, k, depth + 1, seen))
        end
        table.insert(result, prefix .. "}")

        return table.concat(result, "\n")

    elseif node_type == "string" then
        return prefix .. name_str .. string.format("%q", node)
    elseif node_type == "number" or node_type == "boolean" or node_type == "nil" then
        return prefix .. name_str .. tostring(node)
    else
        return prefix .. name_str .. '"<' .. tostring(node) .. '>"'
    end
end

return Utils;