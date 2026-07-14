--- @class InternetDevice
--- Wraps NEET's internet API. GET/POST/CreateWebsocket/hasAccess/isReady pass
--- through directly. send/close are scoped by socket id, since NEET only
--- hands those out as function values via the WebsocketOpened event -- see
--- InternetDevice:onWebsocketOpened, called by EventManager.
local InternetDevice = {};
InternetDevice.__index = InternetDevice;

local METHODS = { "GET", "POST", "CreateWebsocket", "hasAccess", "isReady", "send", "close" };

function InternetDevice.new()
    local new = {
        type = "internet",
        methods = {},
        sockets = {}, -- id -> { send = fn, close = fn }
    };

    for _, m in ipairs(METHODS) do
        new.methods[m] = true;
    end

    setmetatable(new, InternetDevice);
    return new;
end

--- Called by EventManager when a WebsocketOpened event arrives.
function InternetDevice:onWebsocketOpened(id, send, close)
    self.sockets[id] = { send = send, close = close };
end

function InternetDevice:ioctl(pcb, method, ...)
    if not self.methods[method] then
        error("EINVAL: Unknown internet method: " .. tostring(method));
    end

    if method == "send" then
        local id, body, binaryMode = ...;
        local socket = self.sockets[id];
        if not socket then error("ENOENT: No open websocket with id " .. tostring(id)); end
        return socket.send(body, binaryMode);
    end

    if method == "close" then
        local id = ...;
        local socket = self.sockets[id];
        if not socket then error("ENOENT: No open websocket with id " .. tostring(id)); end
        socket.close();
        self.sockets[id] = nil;
        return;
    end

    return internet[method](...);
end

return InternetDevice;
