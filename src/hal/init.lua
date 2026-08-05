local HAL = {};

local function detectBackend()
    if _G.chip and chip.version then
        return "neet";
    end

    if _G.os and os.version and os.version():find("CraftOS") then
        return "cc";
    end

    error("HAL: unable to detect a supported platform");
end

HAL.backend = detectBackend();

-- Native file access, bypassing any bios-time shim over _G.files.
if HAL.backend == "neet" then
    HAL.files = files.__old or files;
end

-- NEET's own require() resolves module names but does not memoize -- every
-- call re-executes the file fresh, which breaks every singleton module in
-- the kernel (registries, TimerManager, the console's cursor, etc). Wrap it
-- with a cache, keeping its resolution logic as the underlying loader.
if HAL.backend == "neet" and not _G.__uwuRequireCached then
    local nativeRequire = require;
    local cache = { hal = HAL };

    function _G.require(name)
        if cache[name] ~= nil then return cache[name]; end

        local result = nativeRequire(name);
        cache[name] = result;
        return result;
    end

    _G.__uwuRequireCached = true;
end

-- Kernel log ring buffer (see sys.log, syscall 100): persisted to a native
-- file so it survives even if the system never gets far enough to bring up
-- a real VFS, and so callers aren't forced to spam the live screen (which
-- has no scrollback worth mentioning on NEET) to see more than the last
-- few lines. Kept in memory too so NEET (no real append mode) only has to
-- rewrite the whole file, not re-read it back first.
local logLines = {};
local LOG_PATH_CC = "kernel.log";
local LOG_PATH_NEET = "system:/kernel.log";

-- Truncate any log left over from a previous boot -- this file only executes
-- once per boot (module caching), so this naturally runs exactly once.
if HAL.backend == "cc" then
    local h = fs.open(LOG_PATH_CC, "w");
    if h then h.close(); end
elseif HAL.backend == "neet" then
    pcall(function()
        local h = HAL.files.open(LOG_PATH_NEET, "w", 0);
        if h then h.write(""); h.close(); end
    end)
end

--- Appends one line to the persistent kernel log file.
function HAL.appendLog(text)
    table.insert(logLines, text);

    if HAL.backend == "cc" then
        local h = fs.open(LOG_PATH_CC, "a");
        if h then
            h.writeLine(text);
            h.close();
        end
    elseif HAL.backend == "neet" then
        pcall(function()
            local h = HAL.files.open(LOG_PATH_NEET, "w", 0);
            if h then
                h.write(table.concat(logLines, "\n") .. "\n");
                h.close();
            end
        end)
    end
end

--- Unix time in ms (UTC).
function HAL.now()
    if HAL.backend == "neet" then
        return math.floor(chip.getUnixTime() * 1000);
    elseif HAL.backend == "cc" then
        return os.epoch("utc");
    end
end

--- Prints a line of debug text to the platform's console/screen.
function HAL.print(text)
    if HAL.backend == "cc" then
        print(text);
    elseif HAL.backend == "neet" then
        require("hal.console").print(text);
    end
end

--- Clears the terminal/screen.
function HAL.clear()
    if HAL.backend == "cc" then
        term.clear();
        term.setCursorPos(1, 1);
    elseif HAL.backend == "neet" then
        require("hal.console").clear();
    end
end

--- Seconds of CPU time this computer has actually run for.
function HAL.uptime()
    if HAL.backend == "cc" then
        return os.clock();
    elseif HAL.backend == "neet" then
        return chip.getTime();
    end
end

--- Platform/firmware version string.
function HAL.platformVersion()
    if HAL.backend == "cc" then
        return os.version();
    elseif HAL.backend == "neet" then
        return chip.version();
    end
end

--- Shuts the computer down.
function HAL.shutdown()
    if HAL.backend == "cc" then
        os.shutdown();
    elseif HAL.backend == "neet" then
        screen.fill(0, 0, 0);
        screen.draw();
        chip.shutdown();
    end
end

--- Reboots the computer.
--- NEET has no reboot primitive yet, so this just shuts down for now.
function HAL.reboot()
    if HAL.backend == "cc" then
        os.reboot();
    elseif HAL.backend == "neet" then
        chip.shutdown();
    end
end

--- Starts a one-shot timer, firing after `duration` seconds. Returns an opaque id.
function HAL.scheduleTimer(duration)
    if HAL.backend == "cc" then
        return os.startTimer(duration);
    elseif HAL.backend == "neet" then
        return require("hal.clock").scheduleTimer(duration);
    end
end

--- Cancels a timer started with HAL.scheduleTimer.
function HAL.cancelTimer(id)
    if HAL.backend == "cc" then
        os.cancelTimer(id);
    elseif HAL.backend == "neet" then
        require("hal.clock").cancelTimer(id);
    end
end

--- Sets an alarm for the next occurrence of in-game time (0.0-24.0). Returns an opaque id.
function HAL.scheduleAlarm(time)
    if HAL.backend == "cc" then
        return os.setAlarm(time);
    elseif HAL.backend == "neet" then
        return require("hal.clock").scheduleAlarm(time);
    end
end

--- Cancels an alarm started with HAL.scheduleAlarm.
function HAL.cancelAlarm(id)
    if HAL.backend == "cc" then
        os.cancelAlarm(id);
    elseif HAL.backend == "neet" then
        require("hal.clock").cancelAlarm(id);
    end
end

--- Blocks until the next event (or elapsed timer/alarm) and returns it as
--- {name, args...}. On CC this is a real block; on NEET it's a poll-then-
--- coroutine.yield()-then-retry loop, since the engine re-drives a yielding
--- coroutine every tick anyway.
function HAL.pollEvent()
    if HAL.backend == "cc" then
        return { os.pullEventRaw() };
    elseif HAL.backend == "neet" then
        return require("hal.events").poll();
    end
end

return HAL;
