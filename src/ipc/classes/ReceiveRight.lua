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

        -- SIGPIPE
        local ProcessRegistry = require("proc.registry.ProcessRegistry");
        local SignalManager = require("proc.SignalManager");
        local kernelProcess = ProcessRegistry.get(0);

        for _, senderPid in ipairs(port.senders) do
            local senderPcb = ProcessRegistry.get(senderPid);
            if senderPcb then
                local fd;
                 for lFd, gId in pairs(senderPcb.handles) do
                    local obj = ObjectManager.get(gId);
                    if obj and obj.type == "SEND_RIGHT" and obj.impl.portId == self.portId then
                        fd = lFd;
                        break;
                    end
                end

                if fd then
                    pcall(SignalManager.send, kernelProcess, senderPid, 13, { fd });
                end
            end
        end
    end
end

function ReceiveRight:onDestroy()
    ObjectManager.release(self.portId);
end

return ReceiveRight;