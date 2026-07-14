-- Software timer/alarm wheel for NEET, backing HAL.scheduleTimer/scheduleAlarm.
local HAL = require("hal");

local TICKS_PER_DAY = 24000;
local TICKS_PER_HOUR = TICKS_PER_DAY / 24;

local clock = {};
local nextId = 1;
local timers = {}; -- id -> deadline (ms, HAL.now())
local alarms = {}; -- id -> target lunar tick

local function getNextId()
    local id = nextId;
    nextId = nextId + 1;
    return id;
end

function clock.scheduleTimer(duration)
    local id = getNextId();
    timers[id] = HAL.now() + duration * 1000;
    return id;
end

function clock.cancelTimer(id)
    timers[id] = nil;
end

function clock.scheduleAlarm(time)
    local id = getNextId();
    local lunar = chip.getLunarTime();
    local dayStart = lunar - (lunar % TICKS_PER_DAY);
    local target = dayStart + time * TICKS_PER_HOUR;

    if target <= lunar then
        target = target + TICKS_PER_DAY;
    end

    alarms[id] = target;
    return id;
end

function clock.cancelAlarm(id)
    alarms[id] = nil;
end

-- Returns {"timer"|"alarm", id} pairs for everything that's elapsed, clearing them.
function clock.poll()
    local fired = {};

    local now = HAL.now();
    for id, deadline in pairs(timers) do
        if now >= deadline then
            table.insert(fired, { "timer", id });
            timers[id] = nil;
        end
    end

    local lunar = chip.getLunarTime();
    for id, deadline in pairs(alarms) do
        if lunar >= deadline then
            table.insert(fired, { "alarm", id });
            alarms[id] = nil;
        end
    end

    return fired;
end

return clock;
