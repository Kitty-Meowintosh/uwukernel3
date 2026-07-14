--- @class ObjectManager
local ObjectManager = {};
local globalRegistry = {};
local nextGlobalId = 1;

local function getNextId()
    local id = nextGlobalId;
    nextGlobalId = nextGlobalId + 1;

    return id;
end

--- Kernel Object registry.

---Registers a kernel object in the global registry without attaching it to a process.
---@param kernelObject KernelObject object to be registered
---@return number globalId
function ObjectManager.register(kernelObject)
    local globalId = getNextId();
    globalRegistry[globalId] = kernelObject;
    return globalId;
end

---Increment reference count of a global object.
---@param globalId number
function ObjectManager.retain(globalId)
    local obj = globalRegistry[globalId];
    if (obj) then
        obj:retain();
    end
end

---Decrement reference count of a global object and destroy it if needed.
---@param globalId number
function ObjectManager.release(globalId)
    local kernelObject = globalRegistry[globalId];
    if (not kernelObject) then return end;

    local shouldDie = kernelObject:release();

    if (shouldDie) then
        if (kernelObject.impl.onDestroy) then kernelObject.impl:onDestroy() end
        globalRegistry[globalId] = nil;
    end
end

---Create a new handle.
---@param pcb table valid Process control block, belonging to process creating handle.
---@param kernelObject KernelObject object to be created as a handle.
function ObjectManager.createHandle(pcb, kernelObject)
    if type(pcb.handles) ~= "table" then error("Invalid PCB handles") end

    local globalId = getNextId()
    globalRegistry[globalId] = kernelObject

    local fd = 0
    while pcb.handles[fd] do fd = fd + 1 end

    pcb.handles[fd] = globalId
    kernelObject:retain()

    if (kernelObject.impl.onAcquire) then kernelObject.impl:onAcquire(pcb.pid) end

    return fd
end

---Get kernel object at a global id in a registry.
---@param globalId number global id of a kernel object.
---@return KernelObject|nil object that is returned, can be null.
function ObjectManager.get(globalId)
    return globalRegistry[globalId];
end

---Link global kernel object to specific process handles.
---@param pcb table
---@param globalId number global id of object to link to
---@param targetFd number|nil optional specific FD to link to (overwrites if exists)
---@return number file descriptor object was linked to.
function ObjectManager.link(pcb, globalId, targetFd)
    ---@type KernelObject
    local kernelObject = globalRegistry[globalId];
    if (not kernelObject) then
        error(string.format("Linking invalid global id: %s", globalId)); end

    local fd = 1;
    if (targetFd) then
        fd = targetFd;
        if (pcb.handles[fd]) then
            ObjectManager.close(pcb, fd);
        end
    else
        fd = 1;
        if (not pcb.handles or type(pcb.handles) ~= "table") then
            error("Invalid PCB") end;
        while pcb.handles[fd] do fd = fd + 1 end;
    end

    pcb.handles[fd] = globalId;
    kernelObject:retain();

    if (kernelObject.impl.onAcquire) then kernelObject.impl:onAcquire(pcb.pid) end

    return fd;
end

---Duplicates file handle.
---@param pcb Process valid process
---@param oldFd number id of handle to duplicate
---@param newFd number position to duplicate to (optional).
function ObjectManager.dup(pcb, oldFd, newFd)
    local globalId = pcb.handles[oldFd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor " .. tostring(oldFd));
    end

    local kernelObject = globalRegistry[globalId];
    if not kernelObject then
        error("EINTERNAL: PCB handle points to non-existent object");
    end

    if (kernelObject.type == "RECEIVE_RIGHT") then
        local portId = kernelObject.impl.portId;
        local portObj = globalRegistry[portId];

        if (portObj and portObj.impl.sendRight) then
            globalId = portObj.impl.sendRight;
            kernelObject = globalRegistry[globalId];
        end
    end

    local targetFd = newFd;
    if (targetFd) then
        if targetFd == oldFd then
            return targetFd;
        end

        if pcb.handles[targetFd] then
            ObjectManager.close(pcb, targetFd);
        end
    else
        targetFd = 0;
        while pcb.handles[targetFd] do
            targetFd = targetFd + 1;
        end
    end

    pcb.handles[targetFd] = globalId;
    kernelObject:retain();

    return targetFd;
end

---Closes the handle and automatically cleans up related resources.
---@param pcb table valid PCB handle belongs to.
---@param localFd number id of a file descriptor belonging to a process.
function ObjectManager.close(pcb, localFd)
    if (not pcb.handles or not type(pcb.handles) == "table") then
        error("Invalid PCB") end;

    local globalId = pcb.handles[localFd];
    if (not globalId or not globalRegistry[globalId]) then
        error("Invalid file descriptor") end;

    pcb.handles[localFd] = nil;

    local kernelObject = globalRegistry[globalId];
    local shouldDie = kernelObject:release();

    if (kernelObject.impl.onRelease) then kernelObject.impl:onRelease(pcb.pid) end

    if (shouldDie) then
        if (kernelObject.impl.onDestroy) then kernelObject.impl:onDestroy() end
        globalRegistry[globalId] = nil;
    end
end

return ObjectManager;