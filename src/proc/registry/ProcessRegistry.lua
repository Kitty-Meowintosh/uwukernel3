--- @class ProcessRegistry
local ProcessRegistry = {};
local processList = {};
local nextId = 1;

--

---Receive next Process ID in line.
---@return number new pid
function ProcessRegistry.getNextPid()
    local next = nextId;
    nextId = next + 1;
    return next;
end

---Register new process in a registry.
---@param pid number pid of new process.
---@param process Process process to be registered
function ProcessRegistry.register(pid, process)
    if (processList[pid]) then error(string.format("Process with pid %s already exists!", pid)) end;

    processList[pid] = process;
end

---Retrieve a process in a registry at certain PID
---@param pid number pid of process to be retrieved
---@return Process|nil
function ProcessRegistry.get(pid)
    return processList[pid];
end

---Get list of all process ids.
---@return number[] every pid
function ProcessRegistry.getAll()
    local result = {};
    for pid, _ in pairs(processList) do
        table.insert(result, pid);
    end
    return result;
end

---Remove process from a registry
---@param pid number
function ProcessRegistry.remove(pid)
    processList[pid] = nil;
end

return ProcessRegistry;