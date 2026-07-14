local HAL = require("hal");

--- @class DriveDevice
--- Wraps NEET's files/fileheaders API for one physical disk. File I/O is
--- stateless: read/write open a header, do the one operation, and close it
--- internally -- no handles kept on the device.
local DriveDevice = {};
DriveDevice.__index = DriveDevice;

local METHODS = {
    "getPartitions", "getPartition", "createPartition", "deletePartition",
    "setPartitionHidden", "setPartitionReadOnly", "makeDir", "list",
    "read", "write",
};

function DriveDevice.new(disk)
    local new = {
        type = "drive",
        disk = disk,
        methods = {},
    };

    for _, m in ipairs(METHODS) do
        new.methods[m] = true;
    end

    setmetatable(new, DriveDevice);
    return new;
end

function DriveDevice:read(path, offset, amount)
    local handle = HAL.files.open(path, "rb", self.disk);
    handle.seek("set", offset or 0);
    local data = handle.read(amount);
    handle.close();
    return data;
end

function DriveDevice:write(path, offset, data, mode)
    local handle = HAL.files.open(path, mode or "wb", self.disk);
    handle.seek("set", offset or 0);
    handle.write(data);
    handle.close();
    return #data;
end

function DriveDevice:ioctl(pcb, method, ...)
    if not self.methods[method] then
        error("EINVAL: Unknown drive method: " .. tostring(method));
    end

    if method == "read" then
        local path, offset, amount = ...;
        return self:read(path, offset, amount);
    end

    if method == "write" then
        local path, offset, data, mode = ...;
        return self:write(path, offset, data, mode);
    end

    if method == "list" then
        local path = ...;
        return HAL.files.getChildren(path, self.disk);
    end

    -- partition management: every files.* function here takes disk last.
    local args = { ... };
    table.insert(args, self.disk);
    return HAL.files[method](table.unpack(args));
end

return DriveDevice;
