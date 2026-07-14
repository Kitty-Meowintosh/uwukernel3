local ProcessRegistry = require("proc.registry.ProcessRegistry");
local ObjectManager = require("core.ObjectManager");

local io = {};

function io.dup(tcb, oldFd, newFd)
    assert(type(oldFd) == "number", "EINVAL: Old FD must be a number");
    assert(type(newFd) == "number" or newFd == nil, "EINVAL: New FD must be a number or nil");

    local pcb = ProcessRegistry.get(tcb.pid);
    local fd = ObjectManager.dup(pcb, oldFd, newFd);
    return fd;
end

return {
    -- 73 is documented as io.pipe() but was never implemented in UwUKernel2 either; left out until it is.
    [74] = io.dup,
};
