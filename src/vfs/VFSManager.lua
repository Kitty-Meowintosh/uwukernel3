local MountRegistry = require("vfs.registry.MountRegistry");
local Promise = require("vfs.classes.Promise");
local Protocol = require("vfs.classes.Protocol");

local KernelObject = require("core.KernelObject");
local ObjectManager = require("core.ObjectManager");
local FileDescriptor = require("vfs.classes.FileDescriptor");

local Scheduler = require("core.Scheduler");

--- @class VFSManager
local VFSManager = {};

---Opens a file, returns file descriptor.
---@param pcb Process process we are reading file as
---@param path string path to a file
---@param mode string
---@param options table currently not implemented!
function VFSManager.open(pcb, path, mode, options)
    options = {};
    -- 0. Resolve path to mount point
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    -- 1. Send a message to driver to open file
    return Promise.send(port, Protocol.Methods.OPEN, {
        path = relativePath,
        mode = mode,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    }, function(data) -- callback, { fileId, size }
        local fileDescriptor = FileDescriptor.new(port, data.fileId, mode, relativePath);
        local kobj = KernelObject.new("FILE", fileDescriptor);
        local fd = ObjectManager.createHandle(pcb, kobj);

        if mode:find("a") and type(data.size) == "number" then
            fileDescriptor.cursor = data.size;
        end

        return { fd };
    end);
end

---Closes open file descriptor.
---@param pcb Process
---@param fd number
function VFSManager.close(pcb, fd)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local kobj = ObjectManager.get(globalId);

    -- if there are other files using this shit, do not actually close!
    if (kobj.refs > 1) then
        ObjectManager.close(pcb, fd);
        return { true };
    end

    --- @type FileDescriptor
    local file = kobj.impl; -- psst, this is not file anymore lol
    if (file.close) then
        local result = file:close(pcb);
        ObjectManager.close(pcb, fd);
        return result;
    end

    ObjectManager.close(pcb, fd);
    return { status = "OK", val = {} };
end

---Reads file from file descriptor.
---@param pcb Process
---@param fd number
---@param number number
---@param offset number
function VFSManager.read(pcb, fd, number, offset)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local kobj = ObjectManager.get(globalId);
    --- @type FileDescriptor
    local file = kobj.impl; -- psst, this is not file anymore lol
    local absolute = (file.cursor or 0) + (offset or 0);

    if (not file.read) then
        error("EINVAL: Object does not support reading")
    end

    return file:read(pcb, number, absolute);
end

---Writes to file using file descriptor.
---@param pcb Process
---@param fd number
---@param data string
---@param offset number
function VFSManager.write(pcb, fd, data, offset)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local kobj = ObjectManager.get(globalId);

    --- @type FileDescriptor
    local file = kobj.impl; -- psst, this is not file anymore lol

    local absolute = (file.cursor or 0) + (offset or 0);

    if (not file.write) then
        error("EINVAL: Object does not support writing");
    end

    return file:write(pcb, data, absolute);
end

---Flushes a file to a disk.
---@param pcb Process
---@param fd number
function VFSManager.flush(pcb, fd)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local kobj = ObjectManager.get(globalId);

    --- @type FileDescriptor
    local file = kobj.impl;

    if (not file.flush) then
        return;
    end

    return file:flush(pcb);
end

---Sends I/O control request to the driver.
---@param pcb Process
---@param fd number
---@param cmd string
function VFSManager.ioctl(pcb, fd, cmd, ...)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local kobj = ObjectManager.get(globalId);

    --- @type FileDescriptor
    local file = kobj.impl; -- psst, this is not file anymore lol

    if (not file.ioctl) then
        error("EINVAL: Object does not support ioctl");
    end

    return file:ioctl(pcb, cmd, ...);
end

---Move cursor.
---@param pcb Process
---@param fd number
---@param offset number
---@param whence number|string (0/"set", 1/"cur", 2/"end")
function VFSManager.seek(pcb, fd, offset, whence)
    local globalId = pcb.handles[fd];
    if not globalId then error("EBADF: Invalid file descriptor.") end;

    local kObj = ObjectManager.get(globalId);
    if not kObj or kObj.type ~= "FILE" then error("EBADF: Not a file.") end;

    --- @type FileDescriptor
    local file = kObj.impl;

    -- set default whence to "cur"
    if whence == nil then whence = 1 end;

    if type(whence) == "string" then
        if whence == "set" then whence = 0;
        elseif whence == "cur" then whence = 1;
        elseif whence == "end" then whence = 2;
        else error("EINVAL: Invalid whence mode '" .. whence .. "'") end;
    end

    local newPos = 0;
    if whence == 0 then -- at start
        newPos = offset;
    elseif whence == 1 then -- at cursor
        newPos = file.cursor + offset;
    elseif whence == 2 then -- at end (this one sucks)
        return Promise.send(file.driverPort, Protocol.Methods.STAT, {
            fileId = file.fileId;
            path = file.path;
        }, function(meta)
            if not meta or type(meta.size) ~= "number" then
                error("EINTERNAL: Driver returned invalid size for seek.")
            end

            local calculated = meta.size + offset
            if calculated < 0 then calculated = 0 end

            file.cursor = calculated;
            return { calculated };
        end)
    else
        error("EINVAL: Invalid whence mode " .. tostring(whence));
    end

    if newPos < 0 then newPos = 0 end;
    file.cursor = newPos;

    return newPos;
end

---Get metadata for a file.
---@param pcb Process
---@param path string
---@param opts table
function VFSManager.stat(pcb, path, opts)
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    return Promise.send(port, Protocol.Methods.STAT, {
        path = relativePath,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    });
end

---List files in a folder.
---@param pcb Process
---@param path table
function VFSManager.list(pcb, path)
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    return Promise.send(port, Protocol.Methods.LIST, {
        path = relativePath,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    });
end

---Rename (move) file.
---@param pcb Process
---@param path string
---@param destination string
function VFSManager.rename(pcb, path, destination)
    local srcPort, srcRelative = MountRegistry.resolve(path);
    local dstPort, dstRelative = MountRegistry.resolve(destination);

    if (not srcPort) or (not dstPort) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    if srcPort ~= dstPort then
        error("EXDEV: Cross-device link");
    end

    return Promise.send(srcPort, Protocol.Methods.RENAME, {
        path = srcRelative,
        destination = dstRelative,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    });
end

---Copy file.
---@param pcb Process
---@param path string
---@param destination string
function VFSManager.copy(pcb, path, destination)
    local port, relativePath = MountRegistry.resolve(path);
    local dstPort, dstRelative = MountRegistry.resolve(destination);

    if (not port) or (not relativePath) or (not dstPort) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    if port ~= dstPort then
        error("EXDEV: Cross-device link");
    end

    return Promise.send(port, Protocol.Methods.COPY, {
        path = relativePath,
        destination = dstRelative,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    });
end

---Create directory at path.
---@param pcb Process
---@param path string
function VFSManager.mkdir(pcb, path)
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    return Promise.send(port, Protocol.Methods.MKDIR, {
        path = relativePath,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    })
end

---Remove file or directory.
---@param pcb Process
---@param path string
function VFSManager.remove(pcb, path)
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    return Promise.send(port, Protocol.Methods.REMOVE, {
        path = relativePath,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    });
end

function VFSManager.link(pcb, path, target)

end

function VFSManager.unlink(pcb, path)

end

---Set some of metadata properties.
---@param pcb Process
---@param path string
---@param attr table
function VFSManager.setattr(pcb, path, attr)
    local port, relativePath = MountRegistry.resolve(path);
    if (not port) or (not relativePath) then
        error("ENOTFOUND: No mount point was resolved for this path.");
    end

    return Promise.send(port, Protocol.Methods.SETATTR, {
        path = relativePath,
        attr = attr,
        user = {
            uid = pcb.euid,
            gid = pcb.egid,
            groups = pcb.groups,
        },
    })
end

---Mount driver to a path.
---@param pcb Process
---@param path string
---@param port number
function VFSManager.mount(pcb, path, port)
    if pcb.uid ~= 0 then
        error("EPERM: Only root can mount filesystems.");
    end

    local globalId = pcb.handles[port];
    if not globalId then
        error("EBADF: Invalid port handle.");
    end

    local kObj = ObjectManager.get(globalId);
    if not kObj or kObj.type ~= "RECEIVE_RIGHT" then
        error("EBADF: Handle must be a port.");
    end

    if MountRegistry.get(path) then
        error("EBUSY: Path is already a mount point.");
    end

    ObjectManager.retain(globalId);
    MountRegistry.register(path, globalId, pcb.uid);
    return true;
end

---Unmount driver from path.
---@param pcb Process
---@param path string
function VFSManager.unmount(pcb, path)
    local mount = MountRegistry.get(path);
    if not mount then
        error("EINVAL: Path is not a mount point.");
    end

    if pcb.uid ~= 0 and pcb.uid ~= mount.uid then
        error("EPERM: Permission denied.");
    end

    MountRegistry.unregister(path);
    ObjectManager.release(mount.portId);

    return true;
end

return VFSManager;