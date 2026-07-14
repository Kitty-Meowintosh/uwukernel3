local ThreadManager = require("proc.ThreadManager");
local ThreadRegistry = require("proc.registry.ThreadRegistry");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local Scheduler = require("core.Scheduler");
local Utils = require("misc.Utils")

local thread = {};

--- Creates a new thread (coroutine) within the current process.
--- @param tcb Thread Thread calling the syscall.
--- @param entry function The Lua function to execute.
--- @param args table|nil Table of arguments to pass to `entry` when it starts.
function thread.create(tcb, entry, args)
    return ThreadManager.create(tcb.pid, entry, args);
end

--- Blocks the calling thread until the target thread `tid` terminates.
--- @param tcb Thread Thread calling the syscall.
--- @param tid number Thread to join.
function thread.join(tcb, tid)
    return ThreadManager.join(tcb.tid, tid);
end

--- Get id of a current running thread.
--- @param tcb Thread Thread calling the syscall.
function thread.id(tcb)
    return Scheduler.getCurrentTid();
end

--- Get list of threads belonging to current process.
--- @param tcb Thread Thread calling the syscall.
function thread.list(tcb)
    local process = ProcessRegistry.get(tcb.pid);
    return Utils.deepcopy(process.threads);
end

return {
    [9] = thread.create,
    [10] = thread.join,
    [11] = thread.id,
    [12] = thread.list,
}
