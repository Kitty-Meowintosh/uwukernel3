local ObjectManager = require("core.ObjectManager");
local KernelObject = require("core.KernelObject");
local Port = require("ipc.classes.Port");
local ReceiveRight = require("ipc.classes.ReceiveRight");
local SendRight = require("ipc.classes.SendRight");
local Scheduler = require("core.Scheduler");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local Utils = require("misc.Utils");

--- @class IPCManager
local IPCManager = {};

-- Wakes any waiting pollers for this port.
local function notifyPollers(port)
    if #port.pollers == 0 then return end

    local remainingPollers = {};
    for _, pr in ipairs(port.pollers) do
        if not pr.req.triggered then
            pr.req.triggered = true;
            Scheduler.wake(pr.req.tid, { true, { pr.fd } });
        else
            -- drop
        end
    end
    port.pollers = remainingPollers;
end

-- Removes pid from port.temporarySenders if present, returning whether it was found.
local function consumeTemporarySender(port, pid)
    for i, v in pairs(port.temporarySenders) do
        if (v == pid) then
            table.remove(port.temporarySenders, i);
            return true;
        end
    end
    return false;
end

-- Closes a temporary port's receive-right handle on its owner, once it's served its one use.
-- If `strict`, errors when the handle can't be found instead of silently skipping.
local function closeTemporaryPort(port, strict)
    if not port.temporary then return end

    local process = ProcessRegistry.get(port.ownerPid);
    local fd;
    for i, v in pairs(process.handles) do
        if (v == port.receiveRight) then
            fd = i;
        end
    end

    if (process and fd) then
        IPCManager.close(process, fd);
    elseif strict then
        error("EINTERNAL: Failed to close temporary handler!");
    end
end

-- Converts a message's in-transit global handles/reply port into local fds for `target`.
local function deliverHandles(message, target)
    if message.globalHandles then
        message.handles = {};
        for _, gId in ipairs(message.globalHandles) do
            local newFd = ObjectManager.link(target, gId);
            table.insert(message.handles, newFd);
            ObjectManager.get(gId):release();
        end
        message.globalHandles = nil;
    end

    if message.globalReply then
        message.reply = ObjectManager.link(target, message.globalReply);
        ObjectManager.get(message.globalReply):release();
        message.globalReply = nil;
    end
end

---Creates new port.
---Calling process gets receive right by default, by owning the process.
---@param pcb Process process that creates new port.
---@param temporary boolean if port should be one time use (automatically cleaned up afterwards).
---@return number file descriptor of created port.
function IPCManager.createPort(pcb, temporary)
    -- create port
    local port = Port.new();
    local portObj = KernelObject.new("PORT", port);
    local portId = ObjectManager.register(portObj);

    -- create rights
    local receiveRight = ReceiveRight.new(portId);
    local receiveRightObj = KernelObject.new("RECEIVE_RIGHT", receiveRight);
    local receiveRightId = ObjectManager.register(receiveRightObj);

    local sendRight = SendRight.new(portId);
    local sendRightObj = KernelObject.new("SEND_RIGHT", sendRight);
    local sendRightId = ObjectManager.register(sendRightObj);

    -- link rights to port
    port.receiveRight = receiveRightId;
    port.sendRight = sendRightId;

    ObjectManager.retain(sendRightId);

    port.onDestroy = function()
        ObjectManager.release(sendRightId);
    end

    port.temporary = temporary or false;

    -- link fd
    return ObjectManager.link(pcb, receiveRightId);
end

---Sends a message to the specific port.
---@param pcb Process sending process.
---@param fd number file descriptor pointing to the port.
---@param payload table message payload that is sent to another process.
---@param opts table optional table with optional options.
---@return boolean returns `true` if queue is full, `false` if not.
---Options table contains:
---`timeout: number` - time to wait if queue is full;
---`reply_port: number` - port to send reply to;
---`transfer: number[]` - handles to transfer;
function IPCManager.send(pcb, fd, payload, opts)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local rightObj = ObjectManager.get(globalId);
    if (not rightObj) then error("EBADF: Invalid file descriptor.") end -- <-- errors here

    local portId;
    if (rightObj.type == "SEND_RIGHT" or rightObj.type == "RECEIVE_RIGHT") then
        portId = rightObj.impl.portId;
    else
        error("EBADF: File descriptor is not a port right.");
    end

    local portObj = ObjectManager.get(portId);
    if (not portObj) then error("EINTERNAL: Right points to invalid port") end

    --- @type Port
    local port = portObj.impl;
    local recipient = ProcessRegistry.get(port.ownerPid);
    if (not recipient) then
        error("EPIPE: Attempt to write to port with no recipient.");
    end

    if (#port.receivers == 0 and #port.queue >= port.capacity and not (port.isKernelCallback and port.callback)) then
        return true, port, recipient;
    end

    -- build the message object (reply)
    local localReplyPort = (opts or {}).reply_port;
    local globalReplyPort;
    if (localReplyPort) then
        -- CHANGED: Use migrateRight logic to ensure we send a SendRight
        local originalGlobalId = pcb.handles[localReplyPort];
        if (not originalGlobalId) then error("EBADF: Invalid reply port") end

        globalReplyPort = IPCManager.migrateRight(originalGlobalId);

        -- Retain it because it's now referenced by the message in transit
        ObjectManager.retain(globalReplyPort);

        -- Add temporary sender tracking logic if needed (simplified here)
        local replyPortObj = ObjectManager.get(ObjectManager.get(globalReplyPort).impl.portId);
        if replyPortObj then
            table.insert(replyPortObj.impl.temporarySenders, recipient.pid);
        end
    end

    local message = {
        pid = pcb.pid,
        globalReply = globalReplyPort,
        data = Utils.deepcopy(payload),
        type = (opts or {}).type or "IPC",
    }

    -- build the message object (handles)
    if (opts and opts.transfer) then
        message.globalHandles = {};
        for _, v in pairs(opts.transfer) do
            local gId = pcb.handles[v];
            if (not gId or not ObjectManager.get(gId)) then
                error("EBADF: Trying to transfer invalid file descriptor.");
            end

            -- If user wants to give a Send Right from a Receive Right, they should
            -- duplicate it first.

            ObjectManager.retain(gId);
            table.insert(message.globalHandles, gId);
            ObjectManager.close(pcb, v);
        end
    end

    -- callbacks
    if (port.isKernelCallback and port.callback) then
        -- Handle one-time senders (reply ports)
        local oneTimeUse = consumeTemporarySender(port, pcb.pid) or port.temporary;

        if (oneTimeUse) then
            ObjectManager.close(pcb, fd);
        end

        local success, err = pcall(port.callback, message);
        if not success then
            error("EINTERNAL: Kernel Callback Error: " .. tostring(err));
        end

        return false, port, recipient;
    end

    -- send it
    if (#port.receivers > 0) then
        deliverHandles(message, recipient);

        -- remove thread send rights if it was temporary sender
        if consumeTemporarySender(port, pcb.pid) then
            ObjectManager.close(pcb, fd);
        end

        -- close temporary port
        if (port.temporary) then
            IPCManager.close(pcb, fd);
        end

        -- wake thread
        local receiver = table.remove(port.receivers, 1);
        Scheduler.wake(receiver, { true, { message } });
        return false;
    end

    -- remove thread send rights if it was temporary sender
    if consumeTemporarySender(port, pcb.pid) then
        ObjectManager.close(pcb, fd);
    end

    table.insert(port.queue, message);
    notifyPollers(port);

    return false;
end

---Bypasses local handle lookups and permissions.
---@param globalPortId number The target port's global registry ID.
---@param payload table The data to send.
---@param opts table|nil Options: { reply_global_id = number, transfer_global_ids = number[] }
function IPCManager.sendKernelMessage(globalPortId, payload, opts)
    local portObj = ObjectManager.get(globalPortId);

    if portObj and (portObj.type == "RECEIVE_RIGHT" or portObj.type == "SEND_RIGHT") then
        local realPortId = portObj.impl.portId
        portObj = ObjectManager.get(realPortId)
    end

    if not portObj or portObj.type ~= "PORT" then
        return false, "EINTERNAL: Invalid kernel target port";
    end

    --- @type Port
    local port = portObj.impl;
    local recipient = ProcessRegistry.get(port.ownerPid);

    if not recipient then
        return false, "EINTERNAL: Port owner is dead";
    end

    if (#port.receivers == 0 and #port.queue >= port.capacity and not (port.isKernelCallback and port.callback)) then
        return false, "EINTERNAL: Queue full";
    end

    local message = {
        pid = 0,
        data = Utils.deepcopy(payload),
        type = (opts or {}).type or "IPC",
    }

    if opts and opts.reply_global_id then
        local globalReplyPort = IPCManager.migrateRight(opts.reply_global_id);
        local replyRightObj = ObjectManager.get(globalReplyPort);

        if replyRightObj and replyRightObj.type == "SEND_RIGHT" then
            replyRightObj:retain();
            message.globalReply = globalReplyPort;

            local replyPortObj = ObjectManager.get(replyRightObj.impl.portId);
            if replyPortObj then
                table.insert(replyPortObj.impl.temporarySenders, recipient.pid);
            end
        end
    end

    if opts and opts.transfer_global_ids then
        message.globalHandles = {};
        for _, gId in ipairs(opts.transfer_global_ids) do
            local obj = ObjectManager.get(gId);
            if obj then
                obj:retain();
                table.insert(message.globalHandles, gId);
            end
        end
    end

    -- callbacks
    if (port.isKernelCallback and port.callback) then
        local success, err = pcall(port.callback, message);
        if not success then
            error("EINTERNAL: Kernel Callback Error: " .. tostring(err));
        end

        closeTemporaryPort(port, false);
        return true;
    end

    if (#port.receivers > 0) then
        deliverHandles(message, recipient);
        closeTemporaryPort(port, true);

        local receiver = table.remove(port.receivers, 1);
        Scheduler.wake(receiver, { true, { message } });
        return true;
    else
        table.insert(port.queue, message);
        notifyPollers(port);

        return true;
    end
end

---Blocks until a message arrives on specific port.
---@param pcb Process waiting process.
---@param fd number file descriptor pointing to the port.
---@return table|nil message received
---@return string status - "OK" or "EMPTY"
---@return number|nil id of a port to subscribe for, in case its empty
function IPCManager.receive(pcb, fd)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local rightObj = ObjectManager.get(globalId);
    if (not rightObj or rightObj.type ~= "RECEIVE_RIGHT") then
        error("EPERM: Descriptor is not a receive right.");
    end

    local portObj = ObjectManager.get(rightObj.impl.portId);

    --- @type Port
    local port = portObj.impl;

    -- if there is already something in a queue
    -- we return immediately
    if #port.queue > 0 then
        local message = table.remove(port.queue, 1);
        deliverHandles(message, pcb);

        -- revive blocked senders
        if (#port.blockedSenders > 0) then
            local senderTid = table.remove(port.blockedSenders, 1);
            Scheduler.wake(senderTid, { true, { }});
        end

        -- close temporary port
        if (port.temporary) then
            IPCManager.close(pcb, fd);
        end

        return message, "OK";
    end

    local tid = Scheduler.getCurrentTid();
    table.insert(port.receivers, tid);

    return nil, "EMPTY", globalId
end

--- Closes port.
--- @param pcb Process process to close port for.
--- @param fd number specific file descriptor pointing to port, to get metadata for.
function IPCManager.close(pcb, fd)
    ObjectManager.close(pcb, fd);
end

--Blocks until at least one of the provided ports has a message in its queue.
---@param pcb Process
---@param fds table|number Array of port file descriptors (or a single fd)
---@return number|nil readyFd The fd that is ready to be read
---@return string status "OK" or "EMPTY"
function IPCManager.poll(pcb, fds)
    if type(fds) ~= "table" then
        fds = { fds }
    end

    local portsToPoll = {}

    -- validate and check if already have messages
    for _, fd in ipairs(fds) do
        local globalId = pcb.handles[fd];
        if not globalId then error("EBADF: Invalid file descriptor.") end

        local rightObj = ObjectManager.get(globalId);
        if not rightObj or rightObj.type ~= "RECEIVE_RIGHT" then
            error("EPERM: Descriptor is not a receive right.");
        end

        local portObj = ObjectManager.get(rightObj.impl.portId);
        local port = portObj.impl;

        if port.ownerPid ~= pcb.pid then
            error("EPERM: Only port owner can poll.");
        end

        if #port.queue > 0 then
            return fd, "OK";
        end

        table.insert(portsToPoll, { port = port, fd = fd })
    end

    local tid = Scheduler.getCurrentTid();
    local req = { tid = tid, triggered = false };

    for _, p in ipairs(portsToPoll) do
        table.insert(p.port.pollers, { req = req, fd = p.fd });
    end

    return nil, "EMPTY"
end

--- Returns some debug data about port.
--- @param pcb Process process to get metadata for.
--- @param fd number specific file descriptor pointing to port, to get metadata for.
function IPCManager.stat(pcb, fd)
    local globalId = pcb.handles[fd];
    if (not globalId) then
        error("EBADF: Invalid file descriptor.");
    end

    local rightObj = ObjectManager.get(globalId);
    if (not rightObj) then error("EBADF: Invalid file descriptor.") end

    local portId;
    if (rightObj.type == "SEND_RIGHT" or rightObj.type == "RECEIVE_RIGHT") then
        portId = rightObj.impl.portId;
    else
        error("EBADF: File descriptor is not a port right.");
    end

    local portObj = ObjectManager.get(portId);
    if (not portObj) then error("EINTERNAL: Right points to invalid port") end

    local port = portObj.impl;

    return {
        messages = #port.queue,
        capacity = port.capacity,
        receivers = #port.receivers,
        senders = #port.senders
    }
end

---Migrates right, if receives send right - returns pointer to same send right, if gets receive right - returns pointer to send right.
---@param rightId number id of a kernel object corresponding to specific right.
---@return number id of migrated kernel object.
function IPCManager.migrateRight(rightId)
    local kernelObject = ObjectManager.get(rightId);
    if (not kernelObject) then return rightId end

    if (kernelObject.type == "SEND_RIGHT") then
        return rightId;
    elseif (kernelObject.type == "RECEIVE_RIGHT") then
        --- @type ReceiveRight
        local right = kernelObject.impl;
        local portId = right.portId;

        --- @type Port
        local port = ObjectManager.get(portId).impl;
        return port.sendRight;
    else
        return rightId
    end
end

return IPCManager;
