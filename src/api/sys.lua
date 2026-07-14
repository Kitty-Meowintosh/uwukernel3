local HAL = require("hal");
local TimerManager = require("misc.TimerManager");
local EventManager = require("misc.EventManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ObjectManager = require("core.ObjectManager")

local sys = {};

---Returns number of milliseconds since epoch (UTC).
---@param tcb Thread Thread calling the syscall.
---@param locale string locale to get time for. Only "utc" is supported for now.
function sys.epoch(tcb, locale)
    assert(type(locale) == "string", "EINVAL: Bad argument #1: Locale must be string.");
    return HAL.now();
end

---Starts a system timer that fires after `duration` seconds.
---@param tcb Thread Thread calling the syscall.
---@param fd number File descriptor pointing to port, that timer should send message to.
---@param duration number Duration in seconds after which timer should fire.
---@param cookie any Optional payload.
function sys.timer(tcb, fd, duration, cookie)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(duration) == "number", "EINVAL: Bad argument #2: Duration must be a number.");
    assert(duration >= 0, "EINVAL: Bad argument #2: Duration must be positive number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return TimerManager.createTimer(pcb, fd, duration, cookie);
end

---Sets an alarm for a specific in-game time (0.0 to 24.0).
---@param tcb Thread Thread calling the syscall.
---@param fd number File descriptor pointing to port, that timer should send message to.
---@param time number Time for alarm to be set to.
---@param cookie any Optional payload.
function sys.alarm(tcb, fd, time, cookie)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(time) == "number","EINVAL: Bad argument #2: Time must be a number.");
    assert(time >= 0, "EINVAL: Bad argument #2: Time must be positive number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return TimerManager.createAlarm(pcb, fd, time, cookie)
end

---Cancel timer or alarm based on file descriptor.
---@param tcb Thread Thread calling the syscall.
---@param id number Id of timer or alarm that we should cancel.
function sys.cancel(tcb, id)
    assert(type(id) == "number", "EINVAL: Bad argument #1: Id must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return TimerManager.cancel(pcb, id);
end

---Writes a message to kernel ring buffer.
---Always persisted to the native kernel.log file; only WARN/ERROR also hit
---the live screen, since the screen (especially on NEET) has nowhere near
---enough scrollback to survive a busy caller (e.g. a test suite) logging
---every line.
---@param tcb Thread Thread calling the syscall.
---@param level string Log severity ("INFO", "WARN", "ERROR").
---@param msg string Message content.
function sys.log(tcb, level, msg)
    local line = "[" .. tostring(level) .. "] " .. tostring(msg);
    HAL.appendLog(line);

    if level == "WARN" or level == "ERROR" then
        HAL.print(line);
    end
end

---Returns a table containing global system information.
---@param tcb Thread Thread calling the syscall.
function sys.info(tcb)
    local Scheduler = require("core.Scheduler");
    local times = Scheduler.getTimeUsage();

    return {
        version = require("version").string; -- os version
        craftos_version = HAL.platformVersion(); -- platform/firmware version
        host = _G._HOST;
        build = require("version").build, -- os build
        uptime = HAL.uptime(); -- time since computer was started
        startEpoch = times.startEpoch; -- time since scheduler started running
        runningTime = times.runningTime; -- time spent running user processes
        systemTime = times.systemTime; -- time spent running syscalls (kernel time)
        idleTime = times.idleTime; -- time spent waiting for hardware events
    }
end

---Subscribes a port to a specific raw ComputerCraft event type.
---Once bound, kernel intercepts all events of this type and routes them exclusively to the specified port.
---Requires root.
---@param tcb Thread Thread calling the syscall.
---@param event string Event name.
---@param port number Handle id of the port to receive events.
function sys.bind_event(tcb, event, port)
    local pcb = ProcessRegistry.get(tcb.pid);
    if (pcb.uid ~= 0) then
        error("EPERM: No permission.");
    end

    EventManager.bindEvent(pcb, port, event);
    return { status = "OK" };
end

---Releases the exclusive subscription for an event type.
---Requires root.
---@param tcb Thread Thread calling the syscall.
---@param event string Event name.
function sys.unbind_event(tcb, event)
    local pcb = ProcessRegistry.get(tcb.pid);
    if (pcb.uid ~= 0) then
        error("EPERM: No permission.");
    end

    EventManager.unbindEvent(pcb, event);
    return { status = "OK" };
end

---Shuts down the computer. Requires root permissions.
---@param tcb Thread Thread calling the syscall.
function sys.shutdown(tcb)
    local process = ProcessRegistry.get(tcb.pid);
    if (process.uid ~= 0) then
        error("EPERM: No permission.");
    end

    HAL.shutdown();
end

---Reboots the computer. Requires root permissions.
---@param tcb Thread Thread calling the syscall.
function sys.reboot(tcb)
    local process = ProcessRegistry.get(tcb.pid);
    if (process.uid ~= 0) then
        error("EPERM: No permission.");
    end

    HAL.reboot();
end

function sys.signal(tcb, signal, fd)
    assert(type(signal) == "number", "EINVAL: Bad argument #1: Signal id must be a number.");
    assert(fd == nil or type(fd) == "number", "EINVAL: Bad argument #2: File descriptor must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    if fd == nil then
        pcb.signalPorts[signal] = nil;
        return { status = "OK" };
    end

    local globalId = pcb.handles[fd];
    if not globalId then
        error("EBADF: Invalid file descriptor.");
    end

    local rightObj = ObjectManager.get(globalId);
    if not rightObj or rightObj.type ~= "RECEIVE_RIGHT" then
        error("EPERM: Descriptor is not a receive right.");
    end

    local portId = rightObj.impl.portId;
    pcb.signalPorts[signal] = portId;

    return { status = "OK" };
end

return {
    [96] = sys.epoch,
    [97] = sys.timer,
    [98] = sys.alarm,
    [99] = sys.cancel,
    [100] = sys.log,
    [101] = sys.info,
    [102] = sys.bind_event,
    [103] = sys.unbind_event,
    [104] = sys.shutdown,
    [105] = sys.reboot,
    [111] = sys.signal,
}
