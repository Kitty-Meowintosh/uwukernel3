--- @class DeviceRegistry
local DeviceRegistry = {};
local devices = {};

---register new device
---@param name string name of device
---@param device table related data
function DeviceRegistry.register(name, device)
    devices[name] = device;
end

---get device from registry by name
---@param name string
function DeviceRegistry.get(name)
    return devices[name];
end

function DeviceRegistry.getAll()
    local names = {};
    for k, _ in pairs(devices) do
        table.insert(names, k);
    end
    return names;
end

---remove device from registry by name
---@param name string
function DeviceRegistry.remove(name)
    devices[name] = nil;
end

return DeviceRegistry;