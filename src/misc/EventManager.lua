local TimerManager = require("misc.TimerManager");
local IPCManager = require("ipc.IPCManager");
local ObjectManager = require("core.ObjectManager");
local DeviceManager = require("dev.DeviceManager");
local DeviceRegistry = require("dev.DeviceRegistry");

--- @class EventManager
local EventManager = {};

--- @type table maps event type to global id
local binds = {};

-- CC's peripheral/peripheral_detach, NEET's peripheralAttached/peripheralDetached.
local PERIPHERAL_EVENTS = {
    peripheral = true, peripheral_detach = true,
    peripheralAttached = true, peripheralDetached = true,
};

---Handle event.
---@param event string
---@param args table
function EventManager.handleEvent(event, args)
    if (event == "timer" or event == "alarm") then
        TimerManager.handleEvent(event, args[1]);
        return;
    end

    if (PERIPHERAL_EVENTS[event]) then
        DeviceManager.onEvent(event, args);
        return;
    end

    if (event == "WebsocketOpened") then
        local device = DeviceRegistry.get("internet");
        if device then device:onWebsocketOpened(args[1], args[2], args[3]) end
        return;
    end

    local globalId = binds[event];
    if (globalId) then
        IPCManager.sendKernelMessage(globalId, {
            type = event,
            args = args,
        }, {
            type = "ROUTED_EVENT",
        })
    end
end

---Bind event towards certain ipc, it will route every event of this type towards it.
---@param pcb Process
---@param fd number
---@param type string
function EventManager.bindEvent(pcb, fd, type)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local rightObj = ObjectManager.get(globalId);
    if (not rightObj or rightObj.type ~= "RECEIVE_RIGHT") then
        error("EPERM: Descriptor is not a receive right.");
    end

    if (binds[type]) then
        error("ESMTH: Someone is already bound to this event!");
    end

    local portId = rightObj.impl.portId;
    binds[type] = portId;
end

---Unbind event.
---@param pcb Process
---@param type string
function EventManager.unbindEvent(pcb, type)
    local portId = binds[type];
    if (portId) then
        --- @type Port;
        local port = (ObjectManager.get(portId) or {}).impl;
        if (not port) then return end;

        if (port.ownerPid ~= pcb.pid) then
            error("EPERM: No permission.");
        end

        binds[type] = nil;
    end
end

return EventManager;