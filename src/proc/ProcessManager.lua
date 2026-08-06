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

---Which session a process group belongs to, or nil when the group has no members.
---@param pgid number group to look up.
---@return number|nil sid
function ProcessManager.sessionOfGroup(pgid)
    local members = ProcessRegistry.getByPgid(pgid);
    for _, pid in ipairs(members) do
        local member = ProcessRegistry.get(pid);
        if (member) then return member.sid end;
    end

    return nil;
end

---Undo a registration when spawn fails after the child was already linked to its
---parent.
local function unregisterChild(parent, pid)
    ProcessRegistry.remove(pid);

    for i, childPid in ipairs(parent.children) do
        if (childPid == pid) then
            table.remove(parent.children, i);
            break;
        end
    end
end

---POSIX wait() target matching.
---@param target number >0 that child, -1 any child, 0 the caller's group, <-1 group (-target).
---@param childPcb Process candidate child.
---@param callerPcb Process process doing the waiting.
---@return boolean
local function waitMatches(target, childPcb, callerPcb)
    if (target == -1) then return true end;
    if (target > 0) then return childPcb.pid == target end;
    if (target == 0) then return childPcb.pgid == callerPcb.pgid end;

    return childPcb.pgid == -target;
end

ProcessManager.waitMatches = waitMatches;

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

    local caller = ProcessRegistry.get(ppid) or parent;
    local callerUid = caller.uid;

    local currentUid = parent.uid;
    if (attr.uid and attr.uid ~= currentUid and callerUid ~= 0) then
        error("EPERM: No permission.");
    end

    local currentGid = parent.gid;
    if (attr.gid and attr.gid ~= currentGid and callerUid ~= 0) then
        error("EPERM: No permission.");
    end

    local currentGroups = parent.groups;
    if (attr.groups and attr.groups ~= currentGroups and callerUid ~= 0) then
        error("EPERM: No permission.");
    end

    if (attr.parent and callerUid ~= 0) then
        error("EPERM: No permission.");
    end

    -- TODO: Replace with more sophisticated check!
    if (attr.limits and callerUid ~= 0) then
        error("EPERM: No permission.");
    end

    if (attr.pgid ~= nil) then
        if (attr.session) then
            error("EINVAL: attr.session and attr.pgid cannot be set together.");
        end

        if (type(attr.pgid) ~= "number")
                or (attr.pgid < 0)
                or (attr.pgid ~= math.floor(attr.pgid))
        then
            error("EINVAL: attr.pgid must be a non-negative integer.");
        end
    end

    -- Create new PCB.
    local newPid = ProcessRegistry.getNextPid();

    local targetSid, targetPgid;
    if (parent.pid == 0) or (attr.session) then
        targetSid = newPid;
        targetPgid = newPid;
    else
        targetSid = parent.sid;
        targetPgid = parent.pgid;
    end

    if (attr.pgid) then
        if (attr.pgid == 0) or (attr.pgid == newPid) then
            targetPgid = newPid;
        else
            local groupSid = ProcessManager.sessionOfGroup(attr.pgid);
            if (not groupSid) then
                error("EPERM: Process group " .. attr.pgid .. " does not exist.");
            end

            if (groupSid ~= caller.sid) then
                error("EPERM: Process group " .. attr.pgid .. " is in another session.");
            end

            targetPgid = attr.pgid;
            targetSid = groupSid;
        end
    end

    local targetUid = attr.uid or currentUid;
    local targetGid = attr.gid or (parent and parent.gid or 0);
    local targetGroups = attr.groups or (parent and parent.groups or {});
    local child = Process.new(
            newPid,
            attr.parent or ppid,
            attr.name or path,
            targetUid, targetGid
    );

    -- Inherit session and process group.
    child.sid = targetSid;
    child.pgid = targetPgid;

    -- Inherit working directory and environment.
    child.cwd = attr.cwd or (parent and parent.cwd or "/");

    if (attr.env) then
        Utils.checkEnvMap(attr.env);
        child.env = Utils.deepcopy(attr.env);
    else
        child.env = Utils.deepcopy(parent and parent.env or {});
    end

    -- Inherit limits and groups
    child.groups = targetGroups;
    if (parent and not attr.limits) then
        child.limits = Utils.deepcopy(parent.limits);
    elseif (attr.limits) then
        child.limits = Utils.deepcopy(attr.limits);
    end

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
    local processEnv = EnvironmentFactory.getEnvironment(child, args);

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
                processEnv.package.preload[name] = function(modname)
                    return data(modname);
                end
            else
                processEnv.package.preload[name] = function() return data end;
            end
        end
    end

    child.globals = processEnv;

    -- get source: kernel no longer loads from disk, callers must pass a blob.
    local blob = attr.blob;
    if (not blob) then
        unregisterChild(parent, newPid);
        error("EINVAL: attr.blob is required (path-based loading now lives in userspace).");
    end

    -- load source
    local chunk, syntaxErr = load(blob, "@" .. path, "t", child.globals);
    if (not chunk) then
        unregisterChild(parent, newPid);
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

    if (pcb.state == "ZOMBIE") then return end;

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

        -- A signal port handler on the parent side must not take the reaping
        -- path down with it.
        pcall(SignalManager.send, ProcessRegistry.get(0), parent.pid, Signal.SIGCHLD, {
            pid = pid,
            code = exitCode,
        });

        if (parent.state ~= "ALIVE") then return end;

        -- Wake the oldest waiter whose target matches and leave every other one
        -- parked: they are waiting for a different child.
        for i = 1, #parent.threadsWaitingForChildren do
            local waiter = parent.threadsWaitingForChildren[i];

            if (waitMatches(waiter.target, pcb, parent)) then
                table.remove(parent.threadsWaitingForChildren, i);

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

                break;
            end
        end
    end
end

---Wait until a matching child exits.
---@param pcb Process process that is supposed to wait.
---@param targetPid number child pid, -1 for any, 0 for the caller's group, <-1 for group (-targetPid).
---@param opts table table of options.
function ProcessManager.wait(pcb, targetPid, opts)
    opts = opts or {};

    if (type(targetPid) ~= "number") or (targetPid ~= math.floor(targetPid)) then
        error("EINVAL: Bad argument #1: Pid must be an integer.");
    end

    -- Drop children whose PCB is already gone, so a stale entry cannot look like
    -- something worth blocking on.
    for i = #pcb.children, 1, -1 do
        if (not ProcessRegistry.get(pcb.children[i])) then
            table.remove(pcb.children, i);
        end
    end

    if (#pcb.children == 0) then
        error("ECHILD: No child processes.");
    end

    -- Search for a zombie process among the matching children.
    local foundMatch = false;
    for i, childPid in ipairs(pcb.children) do
        local child = ProcessRegistry.get(childPid);

        if (waitMatches(targetPid, child, pcb)) then
            foundMatch = true;

            if (child.state == "ZOMBIE") then
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

    -- Nothing matches and nothing ever will, so blocking would block forever.
    if (not foundMatch) then
        error("ECHILD: No child process matches " .. targetPid .. ".");
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
