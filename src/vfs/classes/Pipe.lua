local KernelObject = require("core.KernelObject");
local ObjectManager = require("core.ObjectManager");
local Scheduler = require("core.Scheduler");
local ThreadRegistry = require("proc.registry.ThreadRegistry");
local ProcessRegistry = require("proc.registry.ProcessRegistry");

--- @class Pipe
local Pipe = {};

---How many unread bytes a pipe holds before writers start blocking.
Pipe.CAPACITY = 4096;

--- @class PipeBuffer
--- @field chunks string[] unread data, in write order
--- @field head number bytes of chunks[1] already handed out
--- @field size number unread bytes in total
--- @field readWaiters table[] threads parked in read, oldest first
--- @field writeWaiters table[] threads parked in write, oldest first

--- @class PipeEnd
--- @field pipe PipeBuffer buffer shared with the other end
--- @field peer KernelObject the other end, whose refs say whether it still exists
--- @field id number global id of this end

local ReadEnd = {};
ReadEnd.__index = ReadEnd;

local WriteEnd = {};
WriteEnd.__index = WriteEnd;

--- buffer

---@param pipe PipeBuffer
---@param data string
local function append(pipe, data)
    if #data == 0 then return end

    table.insert(pipe.chunks, data);
    pipe.size = pipe.size + #data;
end

---Removes up to `bytes` from the front of the buffer.
---@param pipe PipeBuffer
---@param bytes number
---@return string
local function take(pipe, bytes)
    if bytes <= 0 or pipe.size == 0 then return ""; end

    local wanted = math.min(bytes, pipe.size);
    local remaining = wanted;
    local parts = {};

    while remaining > 0 do
        local chunk = pipe.chunks[1];
        local available = #chunk - pipe.head;

        if available <= remaining then
            table.insert(parts, string.sub(chunk, pipe.head + 1));
            table.remove(pipe.chunks, 1);
            pipe.head = 0;
            remaining = remaining - available;
        else
            table.insert(parts, string.sub(chunk, pipe.head + 1, pipe.head + remaining));
            pipe.head = pipe.head + remaining;
            remaining = 0;
        end
    end

    pipe.size = pipe.size - wanted;
    return table.concat(parts);
end

--- waiters

---A thread whose process died while parked must not be handed data.
---@param tid number
local function parked(tid)
    --- @type Thread
    local tcb = ThreadRegistry.get(tid);
    return tcb ~= nil and (tcb.state == "WAITING" or tcb.state == "BLOCKED");
end

---Pops the oldest waiter that is still there to be woken, dropping the rest.
---@param queue table[]
---@return table|nil
local function popWaiter(queue)
    while #queue > 0 do
        local waiter = table.remove(queue, 1);
        if parked(waiter.tid) then return waiter; end
    end
end

---Hands buffered bytes to parked readers, in the order they parked.
---@param pipe PipeBuffer
local function serveReaders(pipe)
    while pipe.size > 0 do
        local waiter = popWaiter(pipe.readWaiters);
        if not waiter then return; end

        Scheduler.wake(waiter.tid, { true, { take(pipe, waiter.bytes) } });
    end
end

---Buffers as much of `data` as fits, serving parked readers as room is made.
---@param pipe PipeBuffer
---@param data string
---@return number written, string remainder
local function push(pipe, data)
    local written = 0;
    local remainder = data;

    while #remainder > 0 do
        local room = Pipe.CAPACITY - pipe.size;
        if room <= 0 then break; end

        local fits = string.sub(remainder, 1, room);
        append(pipe, fits);

        written = written + #fits;
        remainder = string.sub(remainder, #fits + 1);

        serveReaders(pipe);
    end

    return written, remainder;
end

---Moves parked writers into whatever room a read has just freed.
---@param pipe PipeBuffer
local function drainWriters(pipe)
    while true do
        local waiter = popWaiter(pipe.writeWaiters);
        if not waiter then return; end

        local written, remainder = push(pipe, waiter.data);
        waiter.written = waiter.written + written;
        waiter.data = remainder;

        if #remainder > 0 then
            table.insert(pipe.writeWaiters, 1, waiter);
            return;
        end

        Scheduler.wake(waiter.tid, { true, { waiter.written } });
    end
end

---Ends a write that was parked when the last reader went away. A writer that
---already placed something keeps that count; one that placed nothing is a
---broken pipe, same as a write that never got started.
---@param waiter table
local function breakWriter(waiter)
    local SignalManager = require("proc.SignalManager");
    local Signal = require("proc.classes.Signal");

    --- @type Thread
    local tcb = ThreadRegistry.get(waiter.tid);
    local pcb = tcb and ProcessRegistry.get(tcb.pid);
    if not pcb then return; end

    if waiter.written > 0 then
        Scheduler.wake(waiter.tid, { true, { waiter.written } });
        return;
    end

    pcall(SignalManager.send, ProcessRegistry.get(0), pcb.pid, Signal.SIGPIPE, { fd = waiter.fd });

    if pcb.state ~= "ZOMBIE" then
        Scheduler.wake(waiter.tid, { false, "EPIPE: The reading end of the pipe went away." });
    end
end

--- ends

---@param pcb Process
---@param bytes number
---@param offset number
---@return string|nil data, nil once the buffer is empty and no writer is left
function ReadEnd:read(pcb, bytes, offset)
    if (offset or 0) ~= 0 then
        error("ESPIPE: A pipe has no cursor to read from.");
    end

    if bytes < 0 then
        error("EINVAL: Byte count must not be negative.");
    end

    local pipe = self.pipe;

    if bytes == 0 then return ""; end

    if pipe.size > 0 then
        local data = take(pipe, bytes);
        drainWriters(pipe);
        return data;
    end

    if self.peer.refs <= 0 then
        return nil;
    end

    table.insert(pipe.readWaiters, {
        tid = Scheduler.getCurrentTid(),
        bytes = bytes,
    });

    return {
        status = "BLOCK",
        reason = "PIPE_READ",
        target = self.id,
    };
end

function ReadEnd:onDestroy()
    local pipe = self.pipe;

    pipe.readWaiters = {};

    local waiters = pipe.writeWaiters;
    pipe.writeWaiters = {};

    for _, waiter in ipairs(waiters) do
        breakWriter(waiter);
    end
end

---@param pcb Process
---@param data string
---@param offset number
---@param fd number|nil descriptor this write came in on, for the SIGPIPE payload
---@return number written
function WriteEnd:write(pcb, data, offset, fd)
    if type(data) ~= "string" then
        error("EINVAL: A pipe carries bytes; data must be a string.");
    end

    if (offset or 0) ~= 0 then
        error("ESPIPE: A pipe has no cursor to write at.");
    end

    local pipe = self.pipe;

    if self.peer.refs <= 0 then
        local SignalManager = require("proc.SignalManager");
        return SignalManager.brokenPipe(pcb, fd, "EPIPE: Attempt to write to a pipe with no reader.");
    end

    if #data == 0 then return 0; end

    local written, remainder = push(pipe, data);

    if #remainder == 0 then
        return written;
    end

    table.insert(pipe.writeWaiters, {
        tid = Scheduler.getCurrentTid(),
        data = remainder,
        written = written,
        fd = fd,
    });

    return {
        status = "BLOCK",
        reason = "PIPE_WRITE",
        target = self.id,
    };
end

function WriteEnd:onDestroy()
    local pipe = self.pipe;

    pipe.writeWaiters = {};

    local waiters = pipe.readWaiters;
    pipe.readWaiters = {};

    for _, waiter in ipairs(waiters) do
        if parked(waiter.tid) then
            Scheduler.wake(waiter.tid, { true, {} });
        end
    end
end

---Creates a pipe and hands both ends to `pcb`.
---@param pcb Process
---@return number readFd, number writeFd
function Pipe.create(pcb)
    --- @type PipeBuffer
    local pipe = {
        chunks = {},
        head = 0,
        size = 0,
        readWaiters = {},
        writeWaiters = {},
    };

    local readImpl = setmetatable({ pipe = pipe }, ReadEnd);
    local writeImpl = setmetatable({ pipe = pipe }, WriteEnd);

    local readObject = KernelObject.new("PIPE", readImpl);
    local writeObject = KernelObject.new("PIPE", writeImpl);

    readImpl.peer = writeObject;
    writeImpl.peer = readObject;

    readImpl.id = ObjectManager.register(readObject);
    writeImpl.id = ObjectManager.register(writeObject);

    local readFd = ObjectManager.link(pcb, readImpl.id);
    local writeFd = ObjectManager.link(pcb, writeImpl.id);

    return readFd, writeFd;
end

return Pipe;
