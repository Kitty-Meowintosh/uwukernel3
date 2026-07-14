local DeviceManager = require("dev.DeviceManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ObjectManager = require("core.ObjectManager");

local dev = {};

---Wraps a native peripheral or virtual device into a kernel handle.
---@param tcb table Thread calling the syscall.
---@param name string Name of the device.
function dev.open(tcb, name)
    assert(type(name) == "string", "EINVAL: Bad argument #1: Name must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);
    return DeviceManager.open(pcb, name);
end

---Calls a method on an already-opened device handle.
---@param tcb table Thread calling the syscall.
---@param fd number Handle returned by dev.open.
---@param method string Method name to call.
function dev.call(tcb, fd, method, ...)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(method) == "string", "EINVAL: Bad argument #2: Method must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    local globalId = pcb.handles[fd];
    if not globalId then
        error("EBADF: Invalid file descriptor.");
    end

    local kObj = ObjectManager.get(globalId);
    if not kObj or kObj.type ~= "DEVICE" then
        error("EBADF: File descriptor is not a device.");
    end

    return kObj.impl:ioctl(pcb, method, ...);
end

---Returns a list of all registered device names.
---@param tcb table Thread calling the syscall.
function dev.list(tcb)
    local pcb = ProcessRegistry.get(tcb.pid);
    if (pcb.uid ~= 0) then
        error("EPERM: No permission.");
    end

    return DeviceManager.list();
end

---Returns type of a registered device.
---@param tcb table Thread calling the syscall.
---@param name string Name of the device.
function dev.type(tcb, name)
    local pcb = ProcessRegistry.get(tcb.pid);
    if (pcb.uid ~= 0) then
        error("EPERM: No permission.");
    end

    return DeviceManager.type(name);
end

---Returns the list of methods available on a registered device.
---@param tcb table Thread calling the syscall.
---@param name string Name of the device.
function dev.methods(tcb, name)
    local pcb = ProcessRegistry.get(tcb.pid);
    if (pcb.uid ~= 0) then
        error("EPERM: No permission.");
    end

    return DeviceManager.methods(name);
end

return {
    [106] = dev.open,
    [107] = dev.call,
    [108] = dev.list,
    [109] = dev.type,
    [110] = dev.methods,
}
