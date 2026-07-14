--- @class Port
--- @field queue table messages in a queue
--- @field capacity number capacity of a queue
--- @field senders number[] processes with send right
--- @field receivers number[] threads waiting for messages
--- @field temporarySenders number[] threads that have receive right, but only for once
--- @field blockedSenders number[] threads that are blocked by attempting to send when queue is full
--- @field ownerPid number pid of a process that port belongs to
--- @field sendRight number pointer to send right kernel object
--- @field receiveRight number pointer to receive right kernel object
--- @field temporary boolean if port has to be closed after one read
local Port = {}
Port.__index = Port;

function Port.new()
    local new = {
        queue = {},
        capacity = math.huge, -- I do not want to care about capacity, really for later
        pollers = {},
        receivers = {},
        senders = {},
        ownerPid = nil,
        receiveRight = nil,
        sendRight = nil,
        temporary = false,

        temporarySenders = {},
        blockedSenders = {},
    }

    setmetatable(new, Port);
    return new;
end

return Port;