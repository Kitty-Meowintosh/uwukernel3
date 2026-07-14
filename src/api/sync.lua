local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ThreadRegistry = require("proc.registry.ThreadRegistry");
local ObjectManager = require("core.ObjectManager");
local KernelObject = require("core.KernelObject");
local Mutex = require("sync.classes.Mutex");
local ConditionVariable = require("sync.classes.ConditionVariable");
local Scheduler = require("core.Scheduler");

local sync = {}

function sync.create(tcb, type, init)
    assert(type == "MUTEX" or type == "SEM" or type == "COND", "EINVAL: Invalid sync type specified.");

    local pcb = ProcessRegistry.get(tcb.pid);
    local obj;

    if type == "MUTEX" then
        obj = KernelObject.new("MUTEX", Mutex.new(init, tcb.tid));
    elseif type == "COND" then
        obj = KernelObject.new("COND", ConditionVariable.new());
    elseif type == "SEM" then
        error("ENOSYS: Semaphores not yet implemented");
    end

    return ObjectManager.link(pcb, ObjectManager.register(obj));
end

function sync.lock(tcb, handle, timeout)
    local pcb = ProcessRegistry.get(tcb.pid);
    local globalId = pcb.handles[handle];
    if not globalId then error("EBADF: Invalid handle.") end;

    local kobj = ObjectManager.get(globalId)
    if kobj.type ~= "MUTEX" then error("EINVAL: Handle is not a Mutex.") end;

    local result = kobj.impl:lock(tcb.tid, timeout);

    if result == "BLOCK" then
        return { status = "BLOCK", reason = "MUTEX_LOCK", target = handle };
    end

    return result
end

function sync.unlock(tcb, handle)
    local pcb = ProcessRegistry.get(tcb.pid);
    local globalId = pcb.handles[handle];
    if not globalId then error("EBADF: Invalid handle.") end;

    local kobj = ObjectManager.get(globalId);
    if kobj.type ~= "MUTEX" then error("EINVAL: Handle is not a Mutex.") end;

    kobj.impl:unlock(tcb.tid);
end

function sync.wait(tcb, condHandle, mutexHandle, timeout)
    local pcb = ProcessRegistry.get(tcb.pid);

    local condGlobalId = pcb.handles[condHandle];
    local mutexGlobalId = pcb.handles[mutexHandle];
    if not condGlobalId or not mutexGlobalId then error("EBADF: Invalid handles.") end;

    local condObj = ObjectManager.get(condGlobalId);
    local mutexObj = ObjectManager.get(mutexGlobalId);

    if condObj.type ~= "COND" or mutexObj.type ~= "MUTEX" then
        error("EINVAL: Handles are not correct types.");
    end

    local result = condObj.impl:wait(tcb.tid, mutexObj.impl);
    if result == "BLOCK" then
        return { status = "BLOCK", reason = "COND_WAIT", target = condHandle };
    end

    return result
end

function sync.notify(tcb, condHandle, all)
    local pcb = ProcessRegistry.get(tcb.pid);
    local globalId = pcb.handles[condHandle];
    if not globalId then error("EBADF: Invalid handle.") end;

    local kobj = ObjectManager.get(globalId);
    if kobj.type ~= "COND" then error("EINVAL: Handle is not a Condition Variable.") end;

    kobj.impl:notify(all);
end

return {
    [128] = sync.create,
    [129] = sync.lock,
    [130] = sync.unlock,
    [131] = sync.wait,
    [132] = sync.notify,
}
