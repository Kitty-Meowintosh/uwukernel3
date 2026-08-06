local ProcessManager = require("proc.ProcessManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local Signal = require("proc.classes.Signal");
local IPCManager = require("ipc.IPCManager");

--- @class SignalManager
local SignalManager = {};

---@param sender Process
---@param target Process
---@return boolean
function SignalManager.maySignal(sender, target)
    return (sender.uid == 0)
            or (target.uid == sender.uid)
            or (target.ppid == sender.pid);
end

---Send signal to process
---@param pcb Process sender
---@param targetPid number receiver
---@param signal table
---@param payload table
function SignalManager.send(pcb, targetPid, signal, payload)
    local target = ProcessRegistry.get(targetPid);
    if (not target) then error("ESRCH: Process not found.") end;

    if (not SignalManager.maySignal(pcb, target)) then
        error("EPERM: No permission.");
    end

    -- we always kill process if it gets SIGKILL,
    -- also, I should probably document error codes somewhere.
    if (signal == Signal.SIGKILL) then
        ProcessManager.exit(targetPid, 137);
        return;
    end

    local portId = target.signalPorts[signal];
    if (portId) then
        local message = {
            signal = signal,
            origin = pcb.pid,
            data = payload,
        };

        local success, err = IPCManager.sendKernelMessage(portId, message, { type = "SIGNAL" });
        return;
    end

    -- default action
    if (signal == Signal.SIGTERM)
            or (signal == Signal.SIGPIPE)
            or (signal == Signal.SIGHUP)
            or (signal == Signal.SIGINT)
    then
        -- default terminate
        ProcessManager.exit(targetPid, 128 + signal);
        return;
    elseif (signal == Signal.SIGCHLD) then
        -- default drop
    else
        -- wtf you sent me
        error("EINVAL: Invalid signal!");
    end
end

local BROADCAST_EXEMPT = { [0] = true, [1] = true };

---Delivers one signal to a snapshot of pids.
---@param pcb Process sender
---@param members number[] snapshot of candidate pids
---@param signal number
---@param payload table|nil
---@return number delivered
local function deliverToAll(pcb, members, signal, payload)
    local ordered, includesSelf = {}, false;
    for _, pid in ipairs(members) do
        if (pid == pcb.pid) then includesSelf = true; else table.insert(ordered, pid) end;
    end
    if (includesSelf) then table.insert(ordered, pcb.pid) end;

    local candidates, permitted, delivered, firstError = 0, 0, 0, nil;

    for _, pid in ipairs(ordered) do
        local target = ProcessRegistry.get(pid);

        if (target) and (pid ~= 0) and (target.state == "ALIVE") then
            candidates = candidates + 1;

            if (SignalManager.maySignal(pcb, target)) then
                permitted = permitted + 1;

                local ok, err = pcall(SignalManager.send, pcb, pid, signal, payload);
                if (ok) then
                    delivered = delivered + 1;
                elseif (not firstError) then
                    firstError = err;
                end
            end
        end
    end

    if (candidates > 0) and (permitted == 0) then error("EPERM: No permission.") end;
    if (delivered == 0) and (firstError) then error(firstError, 0) end;

    return delivered;
end

---Delivers a signal to every live member of a process group.
---@param pcb Process sender
---@param pgid number target group
---@param signal number
---@param payload table|nil
---@return number delivered how many processes the signal reached
function SignalManager.sendToGroup(pcb, pgid, signal, payload)
    if (type(pgid) ~= "number") or (pgid < 1) or (pgid ~= math.floor(pgid)) then
        error("EINVAL: Invalid process group.");
    end

    local members = ProcessRegistry.getByPgid(pgid);
    if (#members == 0) then
        error("ESRCH: No such process group.");
    end

    return deliverToAll(pcb, members, signal, payload);
end

---kill(-1): everything the sender is allowed to signal.
---@param pcb Process sender
---@param signal number
---@param payload table|nil
---@return number delivered
function SignalManager.broadcast(pcb, signal, payload)
    local all = ProcessRegistry.getAll();
    table.sort(all);

    local targets = {};
    for _, pid in ipairs(all) do
        if (not BROADCAST_EXEMPT[pid]) then
            table.insert(targets, pid);
        end
    end

    if (#targets == 0) then
        error("ESRCH: No process found.");
    end

    return deliverToAll(pcb, targets, signal, payload);
end

---Raises SIGPIPE at a process that wrote somewhere nobody is listening any more.
---@param pcb Process the writer
---@param fd number|nil descriptor that was written to
---@param message string|nil what the writer sees, if it survives
function SignalManager.brokenPipe(pcb, fd, message)
    pcall(SignalManager.send, ProcessRegistry.get(0), pcb.pid, Signal.SIGPIPE, { fd = fd });

    if (pcb.state == "ZOMBIE") then
        return;
    end

    error(message or "EPIPE: Nothing is listening on the other end.");
end

return SignalManager;