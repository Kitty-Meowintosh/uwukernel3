--- @class IoPeripheralDevice
--- Generic wrapper for one NEET-attached peripheral (io.*). Methods come
--- from whatever io.wrapPeripheral(id) exposes for that specific block, not
--- a fixed set -- one instance per attached peripheral id.
local IoPeripheralDevice = {};
IoPeripheralDevice.__index = IoPeripheralDevice;

function IoPeripheralDevice.new(id)
    local new = {
        id = id,
        type = io.getType(id),
        methods = {},
    };

    local wrapped = io.wrapPeripheral(id);
    if wrapped then
        for m, _ in pairs(wrapped) do
            new.methods[m] = true;
        end
    end

    setmetatable(new, IoPeripheralDevice);
    return new;
end

function IoPeripheralDevice:ioctl(pcb, method, ...)
    if not self.methods[method] then
        error("EINVAL: Unknown method for peripheral " .. tostring(self.id) .. ": " .. tostring(method));
    end

    return io.callFunction(self.id, method, ...);
end

return IoPeripheralDevice;
