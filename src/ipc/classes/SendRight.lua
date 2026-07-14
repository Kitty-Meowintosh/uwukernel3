local ObjectManager = require("core.ObjectManager");

--- @class SendRight
--- @field portId number global id of port we are referencing.
local SendRight = {}
SendRight.__index = SendRight;

--- @param port number global id of a port we are pointing towards.
function SendRight.new(port)
    local new = {
        portId = port,
    }

    setmetatable(new, SendRight);
    return new;
end

--- @param by number pid of process that acquired us.
function SendRight:onAcquire(by)
    local kernelObject = ObjectManager.get(self.portId);

    if (kernelObject and kernelObject.type == "PORT") then
        ---@type Port
        local port = kernelObject.impl;
        table.insert(port.senders, by);
    end
end

--- @param by number pid of process that released us.
function SendRight:onRelease(by)
    local kernelObject = ObjectManager.get(self.portId);

    if (kernelObject and kernelObject.type == "PORT") then
        ---@type Port
        local port = kernelObject.impl;

        for i, v in pairs(port.senders) do
            if (v == by) then
                table.remove(port.senders, i);
                break;
            end
        end
    end
end

return SendRight;