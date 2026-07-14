local HAL = require("hal");
local DeviceRegistry = require("dev.DeviceRegistry");
local ObjectManager = require("core.ObjectManager");
local KernelObject = require("core.KernelObject");

--- @class DeviceManager
local DeviceManager = {};

--- Populates DeviceRegistry with whatever devices this platform actually has.
function DeviceManager.onStartup()
    if HAL.backend == "neet" then
        require("dev.devices.neet").register();
    end
end

function DeviceManager.open(pcb, name)
    local device = DeviceRegistry.get(name);
    if not device then
        error("ENOENT: Device not found: " .. tostring(name));
    end

    if device.claimedBy and device.claimedBy ~= pcb.pid then
        error("EBUSY: Device is claimed by PID " .. device.claimedBy);
    end
    device.claimedBy = pcb.pid;

    device.onDestroy = function(self)
        self.claimedBy = nil;
    end

    local kObj = KernelObject.new("DEVICE", device);
    return ObjectManager.link(pcb, ObjectManager.register(kObj));
end

function DeviceManager.list()
    return DeviceRegistry.getAll();
end

function DeviceManager.type(name)
    local device = DeviceRegistry.get(name);
    if not device then return nil end;
    return device.type;
end

function DeviceManager.methods(name)
    local device = DeviceRegistry.get(name);
    if not device then return nil end;

    local mList = {};
    for k, _ in pairs(device.methods) do
        table.insert(mList, k);
    end
    return mList;
end

--- Keeps the registry in sync with peripherals attaching/detaching at runtime.
function DeviceManager.onEvent(event, args)
    if HAL.backend == "neet" then
        if event == "peripheralAttached" then
            local id = args[2];
            DeviceRegistry.register(id, require("dev.devices.neet.Peripheral").new(id));
        elseif event == "peripheralDetached" then
            DeviceRegistry.remove(args[2]);
        end
    end
end

return DeviceManager;
