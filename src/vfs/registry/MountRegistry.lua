---@class MountRegistry
local MountRegistry = {};
local mounts = {};

---Registers a mount point.
---@param path string path to register mount point for.
---@param globalId number id pointing to the PORT messages should arrive at.
---@param uid number owning user id, allowed to unmount later.
function MountRegistry.register(path, globalId, uid)
    mounts[path] = { portId = globalId, uid = uid };
end

---Resolves port of a mount point with longest prefix.
---@param path string path to resolve path for.
---@return number|nil global id of a resolved PORT.
---@return string|nil relative path to a mount point.
function MountRegistry.resolve(path)
    --- @type number|nil
    local bestMatch = nil;
    local longestLen = -1;

    -- find best match
    for mountPath, entry in pairs(mounts) do
        if path:find(mountPath, 1, true) == 1 then
            local mountLen = #mountPath;
            local nextChar = path:sub(mountLen + 1, mountLen + 1);

            if mountPath == "/" or nextChar == "" or nextChar == "/" then
                if mountLen > longestLen then
                    longestLen = mountLen;
                    bestMatch = entry.portId;
                end
            end
        end
    end

    -- get relative path
    if bestMatch then
        local relativePath = path:sub(longestLen + 1)

        if relativePath == "" or relativePath:sub(1, 1) ~= "/" then
            relativePath = "/" .. relativePath
        end

        return bestMatch, relativePath
    end
end

function MountRegistry.get(path)
    return mounts[path];
end

---Unregisters mount point.
---@param path string path to unregister mount for.
function MountRegistry.unregister(path)
    mounts[path] = nil;
end

return MountRegistry;