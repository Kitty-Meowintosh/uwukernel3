--- @class EnvironmentFactory
local EnvironmentFactory = {};
local Utils = require("misc.Utils");

function EnvironmentFactory.getEnvironment(pid, args)
    ---@type table
    local env;
    env = {
        arg = args or {},

        package = {
            preload = {},
            loaded = {},
            -- TODO: Put path here
            path = "/System/Library/?.lua;/System/Library/?/init.lua",
        },

        -- calling syscalls
        call = function(id, ...)
            local result, returns = coroutine.yield("SYSCALL", id, table.pack(...));
            if (result) then
                return table.unpack(returns);
            else
                error(returns, 2);
            end
        end,

        -- default print
        print = function(...)
            local count = select('#', ...);
            local parts = {};

            for i = 1, count do
                table.insert(parts, tostring(select(i, ...)));
            end

            local result = table.concat(parts, " ");
            result = result .. "\n";

            local length = env.call(67, 2, result);
            env.call(82, 2);
            return length;
        end,

        read = function(number)
            return env.call(66, 1, number);
        end,

        sleep = function(duration)
            local port = env.call(32); -- create port
            env.call(97, port, duration); -- create timer for certain duration
            env.call(34, port); -- wait for timer
            env.call(36, port); -- close the port
        end,

        -- TODO: Maybe make it use package.loaders?
        require = function(modname)
            assert(type(modname) == "string", "Bad argument #1: Module name must be a string!");

            -- check preloads
            if env.package.preload[modname] then
                if (env.package.loaded[modname] == nil) then
                    local res = env.package.preload[modname](modname);
                    if (res ~= nil) then
                        env.package.loaded[modname] = res;
                    elseif env.package.loaded[modname] == nil then
                        env.package.loaded[modname] = true;
                    end
                end
                return env.package.loaded[modname];
            end

            local function normalisePath(path)
                local parts = {};
                for part in string.gmatch(path, "[^/]+") do
                    if part == ".." then
                        table.remove(parts);
                    elseif part ~= "." and part ~= "" then
                        table.insert(parts, part);
                    end
                end
                local prefix = string.sub(path, 1, 1) == "/" and "/" or "";
                return prefix .. table.concat(parts, "/");
            end

            local function exists(path)
                local success, stat = pcall(env.call, 69, path);
                return success and type(stat) == "table" and not stat.isDir;
            end

            --- @type string|nil
            local resolved_path = nil;
            if (string.sub(modname, 1, 1) == "/") then
                -- absolute
                resolved_path = normalisePath(modname);
            elseif (string.sub(modname, 1, 2) == "./") or (string.sub(modname, 1, 3) == "../") then
                -- relative
                local info = debug.getinfo(2, "S");
                local caller_path = (info and info.source:sub(1, 1) == "@") and info.source:sub(2) or "/";
                local caller_dir = caller_path:match("^(.*)/[^/]*$") or "/";
                resolved_path = normalisePath(caller_dir .. "/" .. modname);
            else
                -- default lua
                local modpath = string.gsub(modname, "%.", "/");
                local path_template = env.package.path or "";

                for template in string.gmatch(path_template, "[^;]+") do
                    local candidate = string.gsub(template, "%?", modpath);
                    candidate = normalisePath(candidate);
                    if exists(candidate) then
                        resolved_path = candidate;
                        break;
                    end
                end
            end

            -- still did not find
            if (not resolved_path) or (not exists(resolved_path)) then
                error("Module '" .. modname .. "' not found");
            end

            if env.package.loaded[resolved_path] ~= nil then
                env.package.loaded[modname] = env.package.loaded[resolved_path];
                return env.package.loaded[resolved_path];
            end

            local successStat, stat = pcall(env.call, 69, resolved_path);
            local readSize = (successStat and stat and stat.size) and stat.size or math.huge;

            local successOpen, fd = pcall(env.call, 64, resolved_path, "r");
            if (not successOpen) or (not fd) then
                error("Error opening module '" .. resolved_path .. "'");
            end

            local successRead, source = pcall(env.call, 66, fd, readSize);
            pcall(env.call, 65, fd);

            if (not successRead) or (not source) then
                error("Error reading module '" .. resolved_path .. "'");
            end

            local chunk, err = env.loadstring(source, "@" .. resolved_path);
            if (not chunk) then
                error("Syntax error loading module '" .. resolved_path .. "':\n" .. tostring(err));
            end

            local result = chunk(modname, resolved_path);
            if result ~= nil then
                env.package.loaded[resolved_path] = result;
            elseif env.package.loaded[resolved_path] == nil then
                env.package.loaded[resolved_path] = true;
            end

            env.package.loaded[modname] = env.package.loaded[resolved_path];
            return env.package.loaded[resolved_path];
        end,

        -- lua libraries
        table = Utils.deepcopy(table),
        coroutine = Utils.deepcopy(coroutine),
        bit = Utils.deepcopy(bit),
        bit32 = Utils.deepcopy(bit32),
        utf8 = Utils.deepcopy(utf8),
        vector = Utils.deepcopy(vector),
        string = Utils.deepcopy(string),
        math = Utils.deepcopy(math),

        -- debug library
        -- I decided to limit it, because half of it completely breaks the security and sandboxing.
        -- there is potential for its reintroduction later, but at current stage there is not much point
        -- and while writing debuggers is cool, implementing related functionality at this stage will take too long.
        debug = {
            traceback = debug.traceback,
            -- TODO: Maybe needs some wrapping for getinfo, as it will reveal underlying real file system..
            getinfo = debug.getinfo,
            serialize = Utils.serialize,
        },

        -- lua functions
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack,
        xpcall = xpcall,
        rawget = rawget,
        rawset = rawset,
        rawequal = rawequal,
        getmetatable = getmetatable,
        setmetatable = setmetatable,

        _VERSION = _VERSION,
        _HOST = _HOST,

        load = function(str, name, mode, loadEnv)
            return load(str, name, mode, loadEnv or env);
        end,

        loadstring = function(str, name)
            return env.load(str, name);
        end,
    }

    env._G = env;
    return env;
end

return EnvironmentFactory;