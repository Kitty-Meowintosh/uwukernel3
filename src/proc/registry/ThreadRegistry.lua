--- @class ThreadRegistry
local ThreadRegistry = {};
local threadList = {};
local nextId = 1;

--

function ThreadRegistry.getNextTid()
    local next = nextId;
    nextId = next + 1;
    return next;
end

function ThreadRegistry.register(tid, thread)
    if (threadList[tid]) then error(string.format("Thread with tid %s already exists!", tid)) end;

    threadList[tid] = thread;
end

function ThreadRegistry.get(tid)
    return threadList[tid];
end

function ThreadRegistry.remove(tid)
    threadList[tid] = nil;
end

return ThreadRegistry;