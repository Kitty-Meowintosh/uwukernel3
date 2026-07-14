local ProcessManager = require("proc.ProcessManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local Signal = require("proc.classes.Signal");
local IPCManager = require("ipc.IPCManager");

--- @class SignalManager
local SignalManager = {};

---Send signal to process
---@param pcb Process sender
---@param targetPid number receiver
---@param signal table
---@param payload table
function SignalManager.send(pcb, targetPid, signal, payload)
    local target = ProcessRegistry.get(targetPid);
    if (not target) then error("ESRCH: Process not found.") end;

    if (pcb.uid ~= 0 and target.ppid ~= pcb.pid) then
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

return SignalManager;