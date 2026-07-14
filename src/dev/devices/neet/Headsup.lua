--- @class HeadsupDevice
--- Wraps NEET's headsup API almost 1:1.
local HeadsupDevice = {};
HeadsupDevice.__index = HeadsupDevice;

local METHODS = { "clear", "draw", "getSize", "drawPixel", "drawLine", "drawRec" };

function HeadsupDevice.new()
    local new = {
        type = "headsup",
        methods = {},
    };

    for _, m in ipairs(METHODS) do
        new.methods[m] = true;
    end

    setmetatable(new, HeadsupDevice);
    return new;
end

function HeadsupDevice:ioctl(pcb, method, ...)
    if not self.methods[method] then
        error("EINVAL: Unknown headsup method: " .. tostring(method));
    end

    return headsup[method](...);
end

return HeadsupDevice;
