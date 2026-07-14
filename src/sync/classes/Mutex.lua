local Scheduler = require("core.Scheduler");

--- @class Mutex
local Mutex = {};
Mutex.__index = Mutex;

---Creates new mutex
---@param init number 1 means unlocked, 0 means locked
---@param tid table thread that created the mutex
function Mutex.new(init, tid)
    local new = {
        locked = (init == 0),
        owner = (init == 0) and tid or nil,
        waitQueue = {},
    }

    setmetatable(new, Mutex);
    return new;
end

---Lock the mutex
---@param tid number thread that locks
---@param timeout number, 0 to not yield if locked, nil to lock indefinitely, number timeout is not yet implemented
function Mutex:lock(tid, timeout)
    -- if not locked. lock the mutex
    if (not self.locked) then
        self.locked = true;
        self.owner = tid;
        return true;
    end

    if (self.owner == tid) then
        error("EDEADLK: Attempting to lock a mutex you already did lock.");
    end

    if (timeout == 0) then
        -- if tried to lock, but resource is not available, do not wait.
        return false;
    end

    table.insert(self.waitQueue, tid);
    return "BLOCK";
end

---Unlock the mutex
---@param tid number
function Mutex:unlock(tid)
    if (self.owner ~= tid) then
        error("EPERM: Attempting to unlock a mutex you do not own.");
    end

    if (#self.waitQueue > 0) then
        local next_tid = table.remove(self.waitQueue, 1);
        self.owner = next_tid;
        Scheduler.wake(next_tid, { true, { true } });
    else
        self.locked = false;
        self.owner = nil;
    end
end

return Mutex