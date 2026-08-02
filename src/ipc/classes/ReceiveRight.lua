local ObjectManager = require("core.ObjectManager");

--- @class ReceiveRight
--- @field portId number global id of port we are referencing
local ReceiveRight = {}
ReceiveRight.__index = ReceiveRight;

--- @param portId number global id of a port we are pointing towards.
function ReceiveRight.new(portId)
    local new = {
        portId = portId,
    }

    setmetatable(new, ReceiveRight);
    return new;
end

--- @param by number pid of process that acquired us.
function ReceiveRight:onAcquire(by)
    local kernelObject = ObjectManager.get(self.portId);

    if (kernelObject and kernelObject.type == "PORT") then
        ---@type Port
        local port = kernelObject.impl;
        port.ownerPid = by;
    end
end

--- @param by number pid of process that released us.
function ReceiveRight:onRelease(by)
    local kernelObject = ObjectManager.get(self.portId);

    if (kernelObject and kernelObject.type == "PORT") then
        ---@type Port
        local port = kernelObject.impl;

        if (by ~= port.ownerPid) then
            return;
        end;

        port.ownerPid = nil;
    end
end

function ReceiveRight:onDestroy()
    ObjectManager.release(self.portId);
end

return ReceiveRight;