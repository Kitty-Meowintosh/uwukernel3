---@class Thread
---@field tid number Unique Thread ID
---@field pid number Process ID of the owner
---@field co thread The actual coroutine
---@field state "READY"|"RUNNING"|"BLOCKED"|"DEAD" Current status
---@field priority number Scheduling priority (Higher = runs more often)
---@field cpuTime number Accumulated CPU time (in seconds or ticks)
---@field waitingReason string|nil What is it waiting for (debug)?
---@field waitingFor number|nil Who we are waiting for (debug)?
---@field error string|nil Crash message
---@field joiningThreads number[] Threads waiting for this thread to finish.
---@field resumeArgs table Arguments to resume function with.
local Thread = {}
Thread.__index = Thread;

---Construct a new thread with certain arguments.
---@param tid number unique thread id
---@param pid number parent process id
---@param co thread lua coroutine
---@param priority number priority, default 10
function Thread.new(tid, pid, co, priority)
    local new = {
        tid = tid,
        pid = pid,

        co = co,
        state = "READY",
        priority = priority or 10,

        cpuTime = 0,
        blockedBy = nil,
        error = nil,

        joiningThreads = {},
    };

    setmetatable(new, Thread);
    return new;
end

return Thread;