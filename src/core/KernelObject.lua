--- @class KernelObject
--- @field type string - type of kernel object
--- @field refs number - number of references to an object
--- @field impl table - implementation of object
local KernelObject = {};
KernelObject.__index = KernelObject;

---Construct new kernel object.
---@param type string
---@param impl table
function KernelObject.new(type, impl)
    local new = setmetatable({}, KernelObject);
    new.refs = 0;
    new.type = type;
    new.impl = impl;

    return new
end

---Increment reference count by 1.
function KernelObject:retain()
    self.refs = self.refs + 1;
end

---Releases object, calls destroy on implementation.
---@return boolean - return true if object should be destroyed.
function KernelObject:release()
    self.refs = self.refs - 1;

    return self.refs <= 0;
end

---Type safe way to access implementation of kernel-object.
---@param type string - type of kernel object that is accessed.
---@return table - returned implementation
function KernelObject:as(type)
    if (type == self.type) then
        return self.impl;
    else
        error(string.format("Trying to access KernelObject as %s, while it is actually %s", type, self.type))
    end
end

return KernelObject;