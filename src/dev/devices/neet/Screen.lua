--- @class ScreenDevice
--- Wraps NEET's screen API almost 1:1. Excludes drawPolygon/drawCircle/
--- drawSpline/drawBezier/toRadius -- dev is planning to remove those upstream.
local ScreenDevice = {};
ScreenDevice.__index = ScreenDevice;

local METHODS = {
    "getSize", "setColor", "substituteColor", "setRotation", "copy",
    "drawLayer", "drawPixels", "drawPixel", "drawLine", "drawRectangle",
    "fill", "floodFill", "draw", "createLayer", "getAsArray",
};

function ScreenDevice.new()
    local new = {
        type = "screen",
        methods = {},
    };

    for _, m in ipairs(METHODS) do
        new.methods[m] = true;
    end

    setmetatable(new, ScreenDevice);
    return new;
end

function ScreenDevice:ioctl(pcb, method, ...)
    if not self.methods[method] then
        error("EINVAL: Unknown screen method: " .. tostring(method));
    end

    return screen[method](...);
end

return ScreenDevice;
