local IPCManager = require("ipc.IPCManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");

local ipc = {};

---Creates a new port kernel object. Calling process receives **receive right**.
---@param tcb Thread Thread calling the syscall.
function ipc.create(tcb)
    local process = ProcessRegistry.get(tcb.pid);
    return IPCManager.createPort(process);
end

---Sends a message to a port. This is non-blocking by default, unless queue is full.
---@param tcb Thread Thread calling the syscall.
---@param fd number Port to use when sending message.
---@param msg table Data you want to send.
function ipc.send(tcb, fd, msg, opts)
    local process = ProcessRegistry.get(tcb.pid);
    local block, port, recipient = IPCManager.send(process, fd, msg, opts);

    -- TODO: Pass correct target or smth.
    if (block) then
        table.insert(port.blockedSenders, tcb.tid);
        return { status = "BLOCK", reason = "Waiting due to full queue!", target = recipient.pid };
    else
        return { status = "OK" };
    end
end

---Blocks until a message arrives on specific port.
---@param tcb Thread Thread calling the syscall.
---@param port number File descriptor pointing to port.
---@param opts table Options.
function ipc.receive(tcb, port, opts)
    local process = ProcessRegistry.get(tcb.pid);
    local message, status = IPCManager.receive(process, port);

    if (status == "OK") then
        return message;
    else
        return { status = "BLOCK", reason = "Waiting for IPC", target = port };
    end
end

---Blocks until a message arrives on one of the specified ports.
---@param tcb Thread Thread calling the syscall.
---@param fds table|number Array of FDs or a single FD.
function ipc.poll(tcb, fds)
    local process = ProcessRegistry.get(tcb.pid)
    local readyFd, status = IPCManager.poll(process, fds)

    if status == "OK" then
        return readyFd
    else
        return { status = "BLOCK", reason = "POLL", target = fds }
    end
end

---Releases a handle.
---@param tcb Thread Thread calling the syscall.
---@param fd number Handle to close.
function ipc.close(tcb, fd)
    local process = ProcessRegistry.get(tcb.pid);
    IPCManager.close(process, fd);
end

---Returns debug information about a port.
---@param tcb Thread Thread calling the syscall.
---@param fd number Handle to inspect.
function ipc.stat(tcb, fd)
    local process = ProcessRegistry.get(tcb.pid);
    return IPCManager.stat(process, fd);
end

return {
    [32] = ipc.create,
    [33] = ipc.send,
    [34] = ipc.receive,
    -- ipc.transfer (35) was redundant and I decided to remove it.
    [36] = ipc.close,
    [37] = ipc.stat,
    [38] = ipc.poll,
}
