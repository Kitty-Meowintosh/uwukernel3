-- Merges NEET's real event queues with HAL's software timer wheel into one
-- blocking-shaped poll, backing HAL.pollEvent.
local clock = require("hal.clock");

local CATEGORIES = { "Unlabeled", "User", "System", "Network", "Peripheral", "Compatibility" };

local events = {};
local buffer = {};

local function refill()
    for _, item in ipairs(clock.poll()) do
        table.insert(buffer, item);
    end

    for _, category in ipairs(CATEGORIES) do
        for _, e in ipairs(event.getQueue(category)) do
            table.insert(buffer, e);
        end
    end
end

function events.poll()
    while #buffer == 0 do
        refill();
        if #buffer == 0 then
            coroutine.yield();
        end
    end
    local event = table.remove(buffer, 1);
    return event;
end

return events;
