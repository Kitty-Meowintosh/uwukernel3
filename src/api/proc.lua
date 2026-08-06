local ProcessManager = require("proc.ProcessManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local SignalManager = require("proc.SignalManager");
local Utils = require("misc.Utils");

local proc = {};

---Creates new process in one atomic method. Analogue of `posix_spawn`.
---@param tcb Thread Thread calling the syscall.
---@param path string Path to executable (Lua).
---@param args string[]|nil Array of arguments.
---@param attributes table|nil Array of attributes (env, cwd, fds, uid, gid, name, limits).
function proc.spawn(tcb, path, args, attributes)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(args) == "table" or args == nil, "EINVAL: Bad argument #2: Arguments must be nil or table.");
    assert(type(attributes) == "table" or attributes == nil, "EINVAL: Bad argument #3: Attributes must be nil or table.");

    return ProcessManager.spawn(tcb.pid, path, args, attributes);
end

---Terminates calling process. Closes all owned handles/ports.
---@param tcb Thread Thread calling the syscall.
---@param code number Exit status (0 = success, >0 = error).
function proc.exit(tcb, code)
    assert(type(code) == "number", "EINVAL: Bad argument #1: Code must be an integer.");
    ProcessManager.exit(tcb.pid, code);
end

---Blocks until a matching child process exits.
---@param tcb number Thread calling the syscall.
---@param pid number Child pid, -1 for any, 0 for the caller's group, <-1 for group (-pid).
---@param opts table Table of options.
function proc.wait(tcb, pid, opts)
    assert(type(pid) == "number", "EINVAL: Bad argument #1: Pid must be a valid number.");
    assert(type(opts) == "table" or opts == nil, "EINVAL: Bad argument #2: Options must be table or nil.");

    local caller = ProcessRegistry.get(tcb.pid);
    return ProcessManager.wait(caller, pid, opts);
end

---Sends a control signal to a process or a process group.
---POSIX pid conventions: >0 that process, 0 the caller's own group, -1 every
---process the caller may signal, <-1 the process group (-pid).
---@param tcb Thread Thread calling the syscall.
---@param pid number Process, or negated process group, to signal.
---@param signal string Desired signal to be sent.
---@return number delivered Number of processes the signal reached.
function proc.kill(tcb, pid, signal)
    assert(type(pid) == "number", "EINVAL: Bad argument #1: Pid must be a valid number.");
    assert(type(signal) == "number", "EINVAL: Bad argument #2: Signal ID must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    -- TODO: Add payload?
    if (pid > 0) then
        SignalManager.send(pcb, pid, signal, {});
        return 1;
    elseif (pid == 0) then
        return SignalManager.sendToGroup(pcb, pcb.pgid, signal, {});
    elseif (pid == -1) then
        return SignalManager.broadcast(pcb, signal, {});
    end

    return SignalManager.sendToGroup(pcb, -pid, signal, {});
end

---Returns metadata of process.
---@param tcb Thread Thread calling the syscall.
---@param pid number|nil PID of process to get metadata of (nil for self).
function proc.info(tcb, pid)
    if (pid == nil) then pid = tcb.pid end;

    local process = ProcessRegistry.get(pid);
    if (not process) then
        error("ESRCH: Process not found.");
    end

    return {
        pid = pid,
        ppid = process.ppid,
        pgid = process.pgid,
        sid = process.sid,
        uid = process.uid,
        gid = process.gid,
        state = process.state,
        cwd = process.cwd,
        groups = Utils.deepcopy(process.groups),
        name = process.name,
        cpuTime = process.cpuTime,
        children = Utils.deepcopy(process.children),
        limits = Utils.deepcopy(process.limits),
    };
end

---Changes attributes of running process.
---@param tcb Thread Thread calling the syscall.
---@param attr table Attributes to set (uid, gid, groups, cwd, pgid, session).
---@return table ids `pgid` and `sid` after the change.
function proc.setattr(tcb, attr)
    local process = ProcessRegistry.get(tcb.pid);
    local isRoot = process.uid == 0;

    if (attr.uid) then
        if (not isRoot) then
            error("EPERM: No permission.");
        end

        process.euid = attr.uid;
        process.uid = attr.uid;
    end

    if (attr.gid) then
        if (not isRoot) then
            error("EPERM: No permission.");
        end

        process.egid = attr.gid;
        process.gid = attr.gid;
    end

    if (attr.groups) then
        if (not isRoot) then
            error("EPERM: No permission.");
        end

        process.groups = attr.groups;
    end

    if (attr.cwd) then
        process.cwd = attr.cwd;
    end

    if (attr.session and attr.pgid) then
        error("EINVAL: session and pgid cannot be set together.");
    end

    if (attr.session) then
        -- A group is named only by its leader's pid, so a leader walking into a
        -- new session would leave its members pointing at a pgid that now names
        -- a group in a different one.
        if (process.pgid == process.pid) then
            error("EPERM: A process group leader cannot start a new session.");
        end

        process.sid = process.pid;
        process.pgid = process.pid;
    end

    if (attr.pgid) then
        if (type(attr.pgid) ~= "number")
                or (attr.pgid < 0)
                or (attr.pgid ~= math.floor(attr.pgid))
        then
            error("EINVAL: pgid must be a non-negative integer.");
        end

        if (process.sid == process.pid) then
            error("EPERM: A session leader cannot change process group.");
        end

        local targetPgid = (attr.pgid == 0) and process.pid or attr.pgid;

        if (targetPgid ~= process.pid) then
            local groupSid = ProcessManager.sessionOfGroup(targetPgid);
            if (not groupSid) then
                error("EPERM: Process group " .. targetPgid .. " does not exist.");
            end

            if (groupSid ~= process.sid) then
                error("EPERM: Process group " .. targetPgid .. " is in another session.");
            end
        end

        process.pgid = targetPgid;
    end

    return { pgid = process.pgid, sid = process.sid };
end

---Sets strict limits for calling process (inherited by children).
---Limits cannot be raised without root permissions, but can be decreased.
---@param tcb Thread Thread calling the syscall.
---@param resource string Resource name (maxFiles, maxPorts, maxProcesses, maxThreads).
---@param value number Limit value (must be integer).
function proc.limit(tcb, resource, value)
    local process = ProcessRegistry.get(tcb.pid);
    if (resource ~= "maxFiles"
            and resource ~= "maxPorts"
            and resource ~= "maxProcesses"
            and resource ~= "maxThreads"
    ) then
        error("EINVAL: Bad argument #1: Invalid resource.")
    end

    assert(type(value) == "number", "EINVAL: Bad argument #2: Value must be a number.");
    assert(value >= 0, "EINVAL: Bad argument #2: Value must be positive.");

    if (value > process.limits[resource] and process.uid ~= 0) then
        error("EPERM: No permission.");
    end

    process.limits[resource] = value;
end

---Gets list of all active process ids in system.
---@param tcb Thread Thread calling the syscall.
---@return number[] list Array of active PIDs.
function proc.list(tcb)
    return ProcessRegistry.getAll();
end

---Reads the calling process's environment.
---@param tcb Thread Thread calling the syscall.
---@param name string|nil Variable to read (nil for a copy of the whole map).
---@return string|table<string, string>|nil value
function proc.getenv(tcb, name)
    local process = ProcessRegistry.get(tcb.pid);

    if (name == nil) then
        return Utils.deepcopy(process.env);
    end

    Utils.checkEnvName(name);
    return process.env[name];
end

---Sets or unsets a variable in the calling process's environment.
---Children inherit the result; existing children are unaffected.
---@param tcb Thread Thread calling the syscall.
---@param name string Variable to write.
---@param value string|nil New value, nil to unset.
function proc.setenv(tcb, name, value)
    Utils.checkEnvName(name);
    if (value ~= nil and type(value) ~= "string") then
        error("EINVAL: Bad argument #2: Value must be a string or nil.");
    end

    local process = ProcessRegistry.get(tcb.pid);
    process.env[name] = value;
end

return {
    [0] = proc.spawn,
    [1] = proc.exit,
    [2] = proc.wait,
    [3] = proc.kill,
    [4] = proc.info,
    [5] = proc.setattr,
    [6] = proc.limit,
    -- 7 was proc.yield, and it was removed, as coroutine.yield() can be used instead, and it was actually dangerous.
    [8] = proc.list,
    [13] = proc.getenv,
    [14] = proc.setenv,
}
