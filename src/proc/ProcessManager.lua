local HAL = require("hal");
local ProcessRegistry = require("proc.registry.ProcessRegistry");
local Process = require("proc.classes.Process");
local ObjectManager = require("core.ObjectManager");
local ThreadManager = require("proc.ThreadManager");
local Scheduler = require("core.Scheduler");
local Utils = require("misc.Utils");
local IPCManager = require("ipc.IPCManager");
local EnvironmentFactory = require("core.EnvironmentFactory")

--- @class ProcessManager
local ProcessManager = {};

local FINITE_HUGE = 2147483647; -- 2^31 - 1

local function createKernelProcess()
    local kernelProcess = Process.new(0, nil, "Kernel", 0, 0);
    kernelProcess.limits = {
        maxFiles = FINITE_HUGE;
        maxPorts = FINITE_HUGE;
        maxProcesses = FINITE_HUGE;
        maxThreads = FINITE_HUGE;
    }

    ProcessRegistry.register(0, kernelProcess);
end

---Spawn a new process.
---@param ppid number parent pid.
---@param path string debug name of the executable (loading is done by the caller; see attr.blob).
---@param args string[] command-line arguments to the application.
---@param attr table table of attributes. attr.blob (source string) is required.
---@return number pid of a newly created process.
function ProcessManager.spawn(ppid, path, args, attr)
    -- Check parent and validate permissions.
    attr = attr or {};
    local parent = ProcessRegistry.get(attr.parent or ppid);
    if (not parent) then error("ESRSH: Invalid parent.") end;

    local currentUid = parent and parent.uid or 0
    if (attr.uid and attr.uid ~= currentUid and currentUid ~= 0) then
        error("EPERM: No permission.");
    end

    local currentGid = parent and parent.gid or 0
    if (attr.gid and attr.gid ~= currentGid and currentUid ~= 0) then
        error("EPERM: No permission.");
    end

    local currentGroups = parent and parent.groups or {}
    if (attr.groups and attr.groups ~= currentGroups and currentUid ~= 0) then
        error("EPERM: No permission.");
    end

    if (attr.parent and currentUid ~= 0) then
        error("EPERM: No permission.");
    end

    -- TODO: Replace with more sophisticated check!
    if (attr.limits and currentUid ~= 0) then
        error("EPERM: No permission.");
    end

    -- Create new PCB.
    local newPid = ProcessRegistry.getNextPid();
    local targetUid = attr.uid or currentUid;
    local targetGid = attr.gid or (parent and parent.gid or 0);
    local targetGroups = attr.groups or (parent and parent.groups or {});
    local child = Process.new(
            newPid,
            attr.parent or ppid,
            attr.name or path,
            targetUid, targetGid
    );

    -- Inherit working directory and environment.
    child.cwd = parent and parent.cwd or "/";

    -- Inherit limits and groups
    child.groups = targetGroups;
    if (parent and not attr.limits) then
        child.limits = Utils.deepcopy(parent.limits);
    elseif (attr.limits) then
        child.limits = Utils.deepcopy(attr.limits);
    end

    -- TODO: Copy environment.

    -- File descriptor inheritance / passing.
    if (parent and attr.fds) then
        for childFd, value in pairs(attr.fds) do
            local parentFd = type(value) == "table" and value.fd or value;
            local op = type(value) == "table" and value.op or "SHARE";

            local globalId = parent.handles[parentFd];
            if not globalId then error("EBADF: Parent handle is invalid") end

            if op == "SHARE" then
                -- if no operation, or share is passed, we convert all receive rights into send rights
                -- and clone fd
                local migratedId = IPCManager.migrateRight(globalId);
                ObjectManager.link(child, migratedId, childFd);
            elseif op == "MOVE" then
                -- if operation move is defined, we move all fds without cloning
                ObjectManager.link(child, globalId, childFd);
                ObjectManager.close(parent, parentFd);
            else
                error("EINVAL: Unknown fd operation")
            end
        end
    end

    ProcessRegistry.register(newPid, child);
    if (parent) then parent.children[#parent.children + 1] = newPid end;

    -- get environment.
    local processEnv = EnvironmentFactory.getEnvironment(newPid, args);

    -- inject preload
    if (attr.preload) then
        for name, data in pairs(attr.preload) do
            if type(data) == "string" then
                processEnv.package.preload[name] = function(modname)
                    local chunk, err = load(data, "@" .. (name:gsub("%.", "/") .. ".lua"), "t", processEnv);
                    if not chunk then
                        error("ENOEXEC: Failed to load preload " .. name .. ": " .. tostring(err));
                    end
                    return chunk(modname);
                end
            elseif type(data) == "function" then
                -- Lua 5.2+ has no setfenv: an already-compiled function's _ENV
                -- can't be forced after the fact, so this is trusted as-is.
                processEnv.package.preload[name] = function(modname)
                    return data(modname);
                end
            else
                processEnv.package.preload[name] = function() return data end;
            end
        end
    end

    child.env = processEnv;

    -- get source: kernel no longer loads from disk, callers must pass a blob.
    local blob = attr.blob;
    if (not blob) then
        ProcessRegistry.remove(newPid);
        error("EINVAL: attr.blob is required (path-based loading now lives in userspace).");
    end

    -- load source
    local chunk, syntaxErr = load(blob, "@" .. path, "t", child.env);
    if (not chunk) then
        ProcessRegistry.remove(newPid);
        error("ENOEXEC: Syntax error: " .. tostring(syntaxErr));
    end

    -- execute source
    local mainTid = ThreadManager.create(newPid, chunk, args);
    child.threads[1] = mainTid;

    return newPid;
end

---Exit the process.
---@param pid number process to exit.
---@param exitCode number exit code, defaults to 0.
function ProcessManager.exit(pid, exitCode)
    local pcb = ProcessRegistry.get(pid);
    if (not pcb) then error("ESRSH: Process not found.") end;

    -- Terminate threads.
    local threadsToKill = pcb.threads
    pcb.threads = {}

    for _, tid in ipairs(threadsToKill) do
        ThreadManager.terminate(tid);
    end

    -- Close handles.
    for fd, _ in pairs(pcb.handles) do
        ObjectManager.close(pcb, fd);
    end
    pcb.handles = {};

    -- Move orphans to launchd.
    if (pcb.pid == 1) then
        error("Launchd died, cannot continue working as OS, bye!", 3);
    elseif #pcb.children > 0 then
        local launchd = ProcessRegistry.get(1);
        for _, childPid in ipairs(pcb.children) do
            local childPcb = ProcessRegistry.get(childPid);
            if childPcb then
                childPcb.ppid = 1;
                table.insert(launchd.children, childPid);
            end
        end
        pcb.children = {};
    end

    pcb.state = "ZOMBIE";
    pcb.exitCode = exitCode or 0;
    pcb.endTime = HAL.now();

    local parent = ProcessRegistry.get(pcb.ppid)
    if parent then
        local SignalManager = require("proc.SignalManager");
        local Signal = require("proc.classes.Signal");

        SignalManager.send(ProcessRegistry.get(0), parent.pid, Signal.SIGCHLD, {
            pid = pid,
            code = exitCode,
        });

        for i = #parent.threadsWaitingForChildren, 1, -1 do
            local waiter = table.remove(parent.threadsWaitingForChildren, i);

            if (waiter.target ~= -1 and waiter.target ~= pid) then
                return;
            end

            local result = {
                pid = pcb.pid,
                code = pcb.exitCode,
                usage = pcb.cpuTime or 0
            };

            -- wake waiter
            Scheduler.wake(waiter.tid, { true, { result } });

            -- reap process
            ProcessRegistry.remove(pid);

            -- remove from list of children
            for j, childPid in ipairs(parent.children) do
                if childPid == pid then
                    table.remove(parent.children, j)
                    break
                end
            end

            return;
        end
    end
end

---Wait until child process exits.
---@param pcb Process process that is supposed to wait.
---@param targetPid number pid of a child to wait for, -1 for any.
---@param opts table table of options.
function ProcessManager.wait(pcb, targetPid, opts)
    opts = opts or {};

    if (#pcb.children == 0) then
        error("ECHILD: No child processes."); -- <-- it fails here actually
    end

    -- Search for a zombie process among children.
    local foundMatch = false;
    for i, childPid in ipairs(pcb.children) do
        if (targetPid == -1) or (targetPid == childPid) then
            foundMatch = true;
            local child = ProcessRegistry.get(childPid);

            if (child and child.state == "ZOMBIE") then
                local result = {
                    pid = child.pid,
                    code = child.exitCode,
                    usage = child.cpuTime or 0
                }

                ProcessRegistry.remove(childPid);
                table.remove(pcb.children, i);
                return result;
            end
        end
    end

    if targetPid ~= -1 and not foundMatch then
        error("ECHILD: PID " .. targetPid .. " is not a child of this process.")
    end

    local callerTid = Scheduler.getCurrentTid();
    table.insert(pcb.threadsWaitingForChildren, {
        tid = callerTid,
        target = targetPid,
    });

    return {
        status = "BLOCK",
        reason = "CHILD",
        target = targetPid,
    }
end

createKernelProcess();
return ProcessManager;
