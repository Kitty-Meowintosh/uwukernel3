local ProcessRegistry = require("proc.registry.ProcessRegistry");
local IPCManager = require("ipc.IPCManager");
local ObjectManager = require("core.ObjectManager");
local Scheduler = require("core.Scheduler");
local VFSProtocol = require("vfs.classes.Protocol");

--- @class Promise
local Promise = {};

local function createCallbackPort(callback)
    local kernelProcess = ProcessRegistry.get(0);

    local localFd = IPCManager.createPort(kernelProcess, true);
    local globalId = kernelProcess.handles[localFd];

    local receiveRightObj = ObjectManager.get(globalId);
    local portObj = ObjectManager.get(receiveRightObj.impl.portId);

    portObj.impl.isKernelCallback = true;
    portObj.impl.callback = callback;

    return globalId, localFd;
end

function Promise.send(driverPortId, method, payload, transform)
    local tid = Scheduler.getCurrentTid();
    local kernelProcess = ProcessRegistry.get(0);

    local replyGlobalId, replyLocalFd;
    replyGlobalId, replyLocalFd = createCallbackPort(function(msg)
        IPCManager.close(kernelProcess, replyLocalFd);
        if (msg.data.status == VFSProtocol.Status.OK) then
            local result = msg.data.data;
            if transform then
                local success, transformed = pcall(transform, result);
                if success then
                    Scheduler.wake(tid, { true, transformed });
                else
                    Scheduler.wake(tid, { false, "EINTERNAL: Transform failed: " .. tostring(transformed) });
                end
            else
                Scheduler.wake(tid, { true, { result } });
            end
        else
            local err = msg.data.data or "EINTERNAL: Driver returned error without message";
            Scheduler.wake(tid, { false, err });
        end
    end)

    local message = payload;

    local success, err = IPCManager.sendKernelMessage(driverPortId, message, {
        reply_global_id = replyGlobalId,
        type = method,
    })

    if not success then
        IPCManager.close(kernelProcess, replyLocalFd)
        error(err);
    end

    return {
        status = "BLOCK",
        reason = "VFS_WAIT",
        target = driverPortId
    }
end

return Promise;