local VFSManager = require("vfs.VFSManager");
local ProcessRegistry = require("proc.registry.ProcessRegistry");

local fs = {};

---Opens a file.
---@param tcb Thread
---@param path string
---@param mode string
---@param opts table
function fs.open(tcb, path, mode, opts)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(mode) == "string", "EINVAL: Bad argument #2: Mode must be a string.");
    assert(type(opts) == "table" or opts == nil, "EINVAL: Bad argument #3: Opts must be a table or nil.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.open(pcb, path, mode, opts);
end

function fs.close(tcb, fd)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.close(pcb, fd);
end

function fs.read(tcb, fd, number, offset)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(number) == "number", "EINVAL: Bad argument #2: Number of bytes must be a number (obviously).");
    assert(type(offset) == "number" or offset == nil, "EINVAL: Bad argument #3: Offset must be a number or nil.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.read(pcb, fd, number, offset);
end

function fs.write(tcb, fd, data, offset)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(data ~= nil, "EINVAL: Bad argument #2: Data written must not be nil!");
    assert(type(offset) == "number" or offset == nil, "EINVAL: Bad argument #3: Offset must be a number or nil.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.write(pcb, fd, data, offset);
end

function fs.flush(tcb, fd)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.flush(pcb, fd);
end

function fs.seek(tcb, fd, offset, whence)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(offset) == "number", "EINVAL: Bad argument #2: Offset must be a number.");
    assert(type(whence) == "number" or type(whence) == "string" or whence == nil, "EINVAL: Bad argument #3: Whence must be either number, string, or nil.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.seek(pcb, fd, offset, whence);
end

function fs.stat(tcb, path, opts)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(opts) == "table" or opts == nil, "EINVAL: Bad argument #2: Opts must be a table or nil.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.stat(pcb, path, opts or {});
end

function fs.list(tcb, path)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.list(pcb, path);
end

function fs.ioctl(tcb, fd, cmd, ...)
    assert(type(fd) == "number", "EINVAL: Bad argument #1: File descriptor must be a number.");
    assert(type(cmd) == "string", "EINVAL: Bad argument #2: Command must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.ioctl(pcb, fd, cmd, ...);
end

function fs.mount(tcb, path, port)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(port) == "number", "EINVAL: Bad argument #2: EINVAL: Bad argument #1: File descriptor must be a number.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.mount(pcb, path, port);
end

function fs.unmount(tcb, path)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.unmount(pcb, path);
end

function fs.setaddr(tcb, path, attr)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(attr) == "table", "EINVAL: Bad argument #2: Attributes must be table.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.setattr(pcb, path, attr);
end

function fs.rename(tcb, path, destination)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(destination) == "string", "EINVAL: Bad argument #1: Destination must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.rename(pcb, path, destination);
end

function fs.copy(tcb, path, destination)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    assert(type(destination) == "string", "EINVAL: Bad argument #1: Destination must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.copy(pcb, path, destination);
end

function fs.remove(tcb, path)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.remove(pcb, path);
end

function fs.mkdir(tcb, path)
    assert(type(path) == "string", "EINVAL: Bad argument #1: Path must be a string.");
    local pcb = ProcessRegistry.get(tcb.pid);

    return VFSManager.mkdir(pcb, path);
end

return {
    [64] = fs.open,
    [65] = fs.close,
    [66] = fs.read,
    [67] = fs.write,
    [68] = fs.seek,
    [69] = fs.stat,
    [70] = fs.list,
    [72] = fs.ioctl,
    [75] = fs.mount,
    [76] = fs.unmount,
    [77] = fs.setaddr,
    [78] = fs.rename,
    [79] = fs.copy,
    [80] = fs.remove,
    [81] = fs.mkdir,
    [82] = fs.flush,
}
