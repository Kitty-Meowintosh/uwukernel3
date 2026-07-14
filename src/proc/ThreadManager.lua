local HAL = require("hal");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ThreadRegistry = require("proc.registry.ThreadRegistry");
local Thread = require("proc.classes.Thread");
local Scheduler = require("core.Scheduler");

--- @class ThreadManager
local ThreadManager = {};

---Creates a new thread.
---@param pid number process that new thread should belong to.
---@param func function function for this thread to run.
---@param args table table of arguments for this table.
function ThreadManager.create(pid, func, args)
    -- Get and validate parent process.
    local pcb = ProcessRegistry.get(pid)
    if not pcb then error("ESRCH: Process not found") end

    -- Create coroutine.
    local co = coroutine.create(function(...)
        local results = { func(...) };
        coroutine.yield("EXIT", results);
    end)

    -- Setup for tid.
    local tid = ThreadRegistry.getNextTid();
    local tcb = Thread.new(tid, pid, co, 10);
    tcb.resumeArgs = args or {};
    tcb.joiningThreads = {};

    -- Register thread in a registry.
    ThreadRegistry.register(tid, tcb);
    table.insert(pcb.threads, tid);

    -- Schedule the thing.
    Scheduler.schedule(tid);

    return tid;
end

---Terminate the thread and return certain results.
---@param tid number
---@param results table
function ThreadManager.terminate(tid, results)
    local tcb = ThreadRegistry.get(tid)
    if not tcb then return end

    tcb.state = "DEAD";
    tcb.results = results;
    tcb.exitTime = HAL.now();

    -- TODO: Create a signal to notify the process, and kill it if nothing is done.
    if tcb.joiningThreads and #tcb.joiningThreads > 0 then
        for _, waiterTid in ipairs(tcb.joiningThreads) do
            local wakeData = { true, results };
            Scheduler.wake(waiterTid, wakeData);
        end

        local process = ProcessRegistry.get(tcb.pid);
        for i, v in pairs(process.threads) do
            if (v == tid) then
                table.remove(process.threads, i);
                break;
            end
        end
    end
    tcb.joiningThreads = {}
end

---Wait until thread finishes execution.
---@param callerTid number id of a calling thread
---@param targetTid number id of a targeted thread
function ThreadManager.join(callerTid, targetTid)
    -- validation
    local targetTcb = ThreadRegistry.get(targetTid)

    if not targetTcb then
        error("ESRCH: Thread not found");
    end

    if callerTid == targetTid then
        error("EDEADLK: Cannot join self")
    end

    -- target is dead
    if targetTcb.state == "DEAD" then
        local process = ProcessRegistry.get(targetTcb.pid);
        for i, v in pairs(process.threads) do
            if (v == targetTid) then
                table.remove(process.threads, i);
                break;
            end
        end

        return { true, targetTcb.results }
    end

    -- target is alive
    if not targetTcb.joiningThreads then targetTcb.joiningThreads = {} end
    table.insert(targetTcb.joiningThreads, callerTid);

    return {
        status = "BLOCK",
        reason = "JOIN",
        target = targetTid
    }
end

return ThreadManager;
