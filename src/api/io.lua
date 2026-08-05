local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ObjectManager = require("core.ObjectManager");
local Pipe = require("vfs.classes.Pipe");

local io = {};

function io.pipe(tcb)
    local pcb = ProcessRegistry.get(tcb.pid);
    return Pipe.create(pcb);
end

function io.dup(tcb, oldFd, newFd)
    assert(type(oldFd) == "number", "EINVAL: Old FD must be a number");
    assert(type(newFd) == "number" or newFd == nil, "EINVAL: New FD must be a number or nil");

    local pcb = ProcessRegistry.get(tcb.pid);
    local fd = ObjectManager.dup(pcb, oldFd, newFd);
    return fd;
end

return {
    [73] = io.pipe,
    [74] = io.dup,
};
