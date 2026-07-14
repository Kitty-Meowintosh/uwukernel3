local Scheduler = require("core.Scheduler");

local ConditionVariable = {};
ConditionVariable.__index = ConditionVariable;

---Creates new conditional variable
function ConditionVariable.new()
    local new = {
        waitQueue = {};
    }
    setmetatable(new, ConditionVariable);
    return new;
end

---Wait for conditional variable
---@param tid number thread
---@param mutexObj Mutex mutex object
function ConditionVariable:wait(tid, mutexObj)
    mutexObj:unlock(tid);

    table.insert(self.waitQueue, { tid = tid, mutex = mutexObj })
    return "BLOCK";
end

---Notify threads waiting for conditional variable.
---@param all boolean if notify all threads or one.
function ConditionVariable:notify(all)
    local count = all and #self.waitQueue or 1;

    for i = 1, count do
        if #self.waitQueue == 0 then break end;

        local waiter = table.remove(self.waitQueue, 1);
        local target_tid = waiter.tid;
        local mutex = waiter.mutex;

        if not mutex.locked then
            mutex.locked = true;
            mutex.owner = target_tid;
            Scheduler.wake(target_tid, { true, { true } });
        else
            table.insert(mutex.waitQueue, target_tid);
        end
    end
end

return ConditionVariable;