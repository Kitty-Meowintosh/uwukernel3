local Protocol = require("vfs.classes.Protocol");
local Promise = require("vfs.classes.Promise");

--- @class FileDescriptor
--- @field driverPort number globalId of port
--- @field fileId number id of a file inside driver to identify it
--- @field mode string The mode file is open in
--- @field cursor number position of cursor at open file
--- @field path string mount-relative path this descriptor was opened with
local FileDescriptor = {};
FileDescriptor.__index = FileDescriptor;

---Creates new file descriptor
---@param driverPort number
---@param fileId number
---@param mode string
---@param path string mount-relative path this descriptor was opened with
function FileDescriptor.new(driverPort, fileId, mode, path)
    local new = {
        driverPort = driverPort,
        fileId = fileId,
        mode = mode,
        cursor = 0,
        path = path,
    };

    setmetatable(new, FileDescriptor);
    return new;
end

---Returns if file descriptor can be read from.
function FileDescriptor:canRead()
    return self.mode:find("r") ~= nil;
end

---Returns if file descriptor can be written to.
function FileDescriptor:canWrite()
    return self.mode:find("w") ~= nil or self.mode:find("a") ~= nil;
end

function FileDescriptor:read(pcb, bytes, offset)
    return Promise.send(self.driverPort, Protocol.Methods.READ, {
        fileId = self.fileId,
        offset = offset,
        bytes = bytes,
        user = { uid = pcb.euid, gid = pcb.egid },
    }, function(data)
        if data and type(data) == "string" then
            self.cursor = offset + #data
        end
        return { data }
    end);
end

function FileDescriptor:write(pcb, data, offset)
    return Promise.send(self.driverPort, Protocol.Methods.WRITE, {
        fileId = self.fileId,
        offset = offset,
        data = data,
        user = { uid = pcb.euid, gid = pcb.egid },
    }, function(written)
        if type(written) == "number" then
            self.cursor = offset + written
        end
        return { written }
    end);
end

function FileDescriptor:flush(pcb)
    return Promise.send(self.driverPort, Protocol.Methods.FLUSH, {
        fileId = self.fileId,
        user = { uid = pcb.euid, gid = pcb.egid },
    })
end

function FileDescriptor:close(pcb)
    self.closed = true;
    return Promise.send(self.driverPort, Protocol.Methods.CLOSE, {
        fileId = self.fileId
    })
end

function FileDescriptor:ioctl(pcb, cmd, ...)
    local args = { ... }

    return Promise.send(self.driverPort, Protocol.Methods.IOCTL, {
        fileId = self.fileId,
        cmd = cmd,
        args = args,
        user = { uid = pcb.euid, gid = pcb.egid }
    }, function(result)
        return result;
    end)
end

function FileDescriptor:onDestroy()
    if self.closed then return end

    local VFSProtocol = require("vfs.classes.Protocol");
    local IPCManager = require("ipc.IPCManager");

    IPCManager.sendKernelMessage(self.driverPort, {
        type = VFSProtocol.Methods.CLOSE;
        data = { fileId = self.fileId };
    });
end

return FileDescriptor;