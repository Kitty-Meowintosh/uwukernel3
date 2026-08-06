local HAL = require("hal");
local ThreadRegistry = require("proc.registry.ThreadRegistry");
local ProcessRegistry = require("proc.registry.ProcessRegistry");

-- Preemption
local QUANTUM_TIME = 0.05;
local QUANTUM_INSTRUCTIONS = 10000;
local deadline = 0;

local SYS_EXIT = 1;
local SYS_WRITE = 67;
local STDERR = 2;

local function reporter(text)
    coroutine.yield("SYSCALL", SYS_WRITE, table.pack(STDERR, text));
    coroutine.yield("SYSCALL", SYS_EXIT, table.pack(1));
end

local function hook()
    if (HAL.now() > deadline) then
        coroutine.yield("PREEMPT");
    end
end

-- Actual scheduler

---@class Scheduler
local Scheduler = {}
---@type number[]
local readyThreads = {}
---@type number
local currentTid;

-- times
local startEpoch = 0;
local runningTime = 0;
local systemTime = 0;
local idleTime = 0;

--- Add a thread to the execution queue.
---@param tid number id of a thread to be added.
function Scheduler.schedule(tid)
    table.insert(readyThreads, tid);
end

--- Wakes a blocked thread and prepares it to run.
---@param tid number id of a thread to wake.
---@param args table|nil values to pass to the thread.
function Scheduler.wake(tid, args)
    ---@type Thread
    local tcb = ThreadRegistry.get(tid);
    if tcb and (tcb.state == "WAITING" or tcb.state == "BLOCKED") then
        tcb.state = "READY";
        tcb.resumeArgs = args or {};
        tcb.waitingReason = nil;
        tcb.waitingFor = nil;

        table.insert(readyThreads, tid);
    end
end

--- Returns id of a thread that is currently running.
--- @return number id of a thread.
function Scheduler.getCurrentTid()
    return currentTid;
end

--- Returns debug information about resource usage by kernel.
--- @return table { startEpoch, runningTime, systemTime, idleTime }
function Scheduler.getTimeUsage()
    return {
        startEpoch = startEpoch,
        runningTime = runningTime,
        systemTime = systemTime,
        idleTime = idleTime,
    }
end

--- Starts the scheduler.
function Scheduler.run()
    local ThreadManager = require("proc.ThreadManager");
    local EventManager = require("misc.EventManager");
    local Dispatcher = require("core.Dispatcher");
    local delayedThreads = {};

    startEpoch = HAL.now();
    while (true) do
        local tid = table.remove(readyThreads, 1);
        if (tid) then
            currentTid = tid;

            ---@type Thread
            local tcb = ThreadRegistry.get(tid);
            if (tcb and tcb.state == "READY") then
                -- change thread state and set up a hook.
                tcb.state = "RUNNING";
                deadline = HAL.now() + QUANTUM_TIME;
                if HAL.backend == "cc" then
                    debug.sethook(tcb.co, hook, "", QUANTUM_INSTRUCTIONS);
                end

                -- resume coroutine
                local args = tcb.resumeArgs or {};
                tcb.resumeArgs = nil;

                local startTime = HAL.now();
                local returns = table.pack(coroutine.resume(tcb.co, table.unpack(args)));
                local endTime = HAL.now();

                local ok = table.remove(returns, 1);
                local trap = table.remove(returns, 1);

                -- add running time to the process cpuTime;
                local pcb = ProcessRegistry.get(tcb.pid);
                pcb.cpuTime = pcb.cpuTime + (endTime - startTime) / 1000;
                tcb.cpuTime = tcb.cpuTime + (endTime - startTime) / 1000;
                runningTime = runningTime + (endTime - startTime) / 1000;

                -- handle traps
                if (not ok) then
                    -- crash
                    local trace = debug.traceback(tcb.co);
                    local prefix = pcb.name .. "(" .. pcb.pid .. ":" .. tcb.tid .. ")";
                    local summary = prefix .. " [ERROR] " .. tostring(trap):gsub("^.-:%d+: ", "");

                    if HAL.backend == "cc" then term.setTextColor(16384) end -- red
                    HAL.appendLog(summary);
                    HAL.appendLog(trace);
                    if HAL.backend == "cc" then term.setTextColor(1) end

                    local ProcessManager = require("proc.ProcessManager");
                    local doomed = pcb.threads;
                    pcb.threads = {};

                    for _, doomedTid in ipairs(doomed) do
                        ThreadManager.terminate(doomedTid);
                    end

                    if (pcb.reporting or not pcb.handles[STDERR]) then
                        ProcessManager.exit(tcb.pid, 1);
                    else
                        pcb.reporting = true;
                        ThreadManager.create(tcb.pid, reporter, { summary .. "\n" .. trace .. "\n" });
                    end
                elseif (coroutine.status(tcb.co) == "dead") then
                    -- adequate exit
                    local results = { trap, returns[1] }
                    ThreadManager.terminate(tid, results)
                elseif (trap == "PREEMPT") then
                    -- preempted
                    tcb.state = "READY";
                    table.insert(delayedThreads, tid);
                elseif (trap == "EXIT") then
                    -- thread finished
                    ThreadManager.terminate(tid, returns[1])
                elseif (trap == "SYSCALL") then
                    -- syscall called
                    -- returns[1] here corresponds to syscall id;
                    -- returns[2] here corresponds to syscall arguments table;
                    local systemTimeStart = HAL.now();
                    local instr = Dispatcher.dispatch(tcb, returns[1], returns[2]);
                    local systemTimeEnd = HAL.now();

                    -- add system time to the total
                    systemTime = systemTime + (systemTimeEnd - systemTimeStart) / 1000;

                    if instr.status == "OK" then
                       tcb.state = "READY";
                        tcb.resumeArgs = { true, instr.val };
                        table.insert(readyThreads, tid);
                    elseif (instr.status == "BLOCK") then
                        tcb.state = "WAITING";
                        tcb.waitingReason = instr.reason;
                        tcb.waitingFor = instr.target;
                    elseif (instr.status == "ERROR") then
                        tcb.state = "READY";
                        tcb.resumeArgs = { false, instr.error };

                        -- very important
                        table.insert(readyThreads, tid);
                    elseif (instr.status == "DROP") then
                        -- do nothing
                    else
                        ThreadManager.terminate(tid, "Unknown error in Dispatcher!");
                    end
                else
                    -- regular yield
                    -- may cause problems in future,
                    -- I assume that sometimes user can call coroutine.yield without arguments.
                    -- Or something like that.
                    tcb.state = "READY";
                    tcb.resumeArgs = { true };
                    table.insert(delayedThreads, tid);
                end
            end
        else
            -- merge delayed threads, give the engine a turn, come straight back
            if (#delayedThreads > 0) then
                for _, v in pairs(delayedThreads) do
                    table.insert(readyThreads, v);
                end
                delayedThreads = {};

                coroutine.yield();
            else
                -- fully idle: block until an event (or elapsed timer/alarm) shows up
                local idleTimeStart = HAL.now();
                local eventData = HAL.pollEvent();
                local idleTimeEnd = HAL.now();

                idleTime = idleTime + (idleTimeEnd - idleTimeStart) / 1000;

                local type = table.remove(eventData, 1);

                if type == "terminate" then
                    HAL.print("Terminating!");
                    break;
                end

                EventManager.handleEvent(type, eventData);
            end
        end
    end
end

return Scheduler;
