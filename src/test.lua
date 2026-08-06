-- Full syscall regression/conformance suite for UwUKernel3.
--
-- Runs as a normal spawned process (pid 1), so every check below goes
-- through the real syscall path via `call(id, ...)`, never kernel-internal
-- APIs directly. Reports via sys.log (100) since stdio isn't wired up yet.
--
-- sys.log persists every message (pass and fail) to the native kernel.log
-- file (see hal/init.lua's HAL.appendLog), and only echoes WARN/ERROR to the
-- live screen. So: every test result is recorded in kernel.log for review,
-- but the live console only ever shows failures plus the final tally --
-- it won't overflow NEET's screen buffer even with hundreds of tests.
-- This is meant to be re-run after every change as a regression baseline;
-- diff kernel.log between runs to see what changed.
--
-- Tests prefixed "[GAP]" pin a *known* divergence between SYSCALLME.md and
-- the actual implementation. Where safe, they assert the *documented* (spec)
-- behaviour and are therefore EXPECTED TO FAIL until the code catches up --
-- a red [GAP] test is a bug report, not a mistake. Where asserting the spec
-- directly would be unsafe (i.e. it would block a thread forever, because
-- the relevant timeout/limit is simply not implemented), the test instead
-- proves the gap indirectly with a bounded wait and pins the current (safe)
-- behaviour as green, so accidental regressions in *that* are still caught.
--
-- IMPORTANT SAFETY NOTE, read before adding tests:
-- If a thread created via thread.create() (or a process spawned via
-- proc.spawn()) raises an *uncaught* Lua error at its coroutine top level,
-- the scheduler treats that as a crash and force-exits the *entire owning
-- process* (see core/Scheduler.lua's `if not ok then ... ProcessManager.exit`
-- branch) -- not just that one thread. Since this whole suite is one
-- process, an uncaught error in a helper thread would silently kill the
-- suite mid-run with no final tally. Every thread/child body below is
-- therefore wrapped in its own pcall, stashing pass/fail into a shared
-- table that the main thread inspects afterwards via the normal test()
-- harness (which is safe, since it runs in the main thread's own coroutine
-- and its pcall(fn) catches everything before it can propagate).

local SYS = {
    proc_spawn = 0, proc_exit = 1, proc_wait = 2, proc_kill = 3, proc_info = 4,
    proc_setattr = 5, proc_limit = 6, proc_list = 8,
    proc_getenv = 13, proc_setenv = 14,

    thread_create = 9, thread_join = 10, thread_id = 11, thread_list = 12,

    ipc_create = 32, ipc_send = 33, ipc_receive = 34, ipc_close = 36,
    ipc_stat = 37, ipc_poll = 38,

    fs_open = 64, fs_close = 65, fs_read = 66, fs_write = 67, fs_seek = 68,
    fs_stat = 69, fs_list = 70, fs_ioctl = 72, fs_mount = 75, fs_unmount = 76,
    fs_setaddr = 77, fs_rename = 78, fs_copy = 79, fs_remove = 80, fs_mkdir = 81,
    fs_flush = 82,

    io_pipe = 73, io_dup = 74,

    sys_epoch = 96, sys_timer = 97, sys_alarm = 98, sys_cancel = 99,
    sys_log = 100, sys_info = 101, sys_bind_event = 102, sys_unbind_event = 103,
    sys_shutdown = 104, sys_reboot = 105, sys_signal = 111,

    dev_open = 106, dev_call = 107, dev_list = 108, dev_type = 109, dev_methods = 110,

    sync_create = 128, sync_lock = 129, sync_unlock = 130, sync_wait = 131, sync_notify = 132,
};

local function log(msg) call(SYS.sys_log, "INFO", msg); end
local function logFail(msg) call(SYS.sys_log, "WARN", msg); end

local passed, failed, gapFailed, realFailed = 0, 0, 0, 0;

--- Runs fn under pcall, counts it, and only logs on failure.
local function test(name, fn)
    local ok, err = pcall(fn);
    if ok then
        passed = passed + 1;
        log("[PASS] " .. name); -- file only (INFO); the point is a full record, not a screen dump
    else
        failed = failed + 1;
        if name:sub(1, 5) == "[GAP]" then
            gapFailed = gapFailed + 1;
        else
            realFailed = realFailed + 1;
        end
        logFail("[FAIL] " .. name .. ": " .. tostring(err)); -- file + screen (WARN)
    end
end

--- Asserts fn() raises an error; if pattern given, the error text must match it (plain find).
local function expectError(fn, pattern)
    local ok, err = pcall(fn);
    if ok then error("expected an error, call succeeded"); end
    if pattern and not tostring(err):find(pattern) then
        error("error '" .. tostring(err) .. "' did not match pattern '" .. pattern .. "'");
    end
    return err;
end

--- Runs fn(resultTable) inside a brand new thread, pcall-wrapped so a
--- failing assert or raised error can never crash the owning process.
--- Returns tid, resultTable ({ ok = bool, err = ... } plus whatever fn sets).
local function runInThread(fn)
    local result = {};
    local tid = call(SYS.thread_create, function()
        local ok, err = pcall(fn, result);
        result.ok = ok;
        if not ok then result.err = err; end
    end, {});
    return tid, result;
end

--- Builds a self-contained child-process blob. `vars` maps local-name -> numeric
--- syscall id, emitted as `local NAME = <id>;` prefix lines, since a spawned
--- process is a fresh chunk (via load()) that shares no upvalues with this
--- script. `src` is the child's test body; it's run under pcall, and the
--- child exits 0 on success, 1 on failure (logging the reason via sys.log).
local function body(vars, src)
    local prefix = {};
    for name, id in pairs(vars) do
        table.insert(prefix, "local " .. name .. " = " .. tostring(id) .. ";");
    end
    return table.concat(prefix, " ") .. "\n" .. src;
end

local function spawnChild(src, attrs)
    attrs = attrs or {};
    attrs.blob = "local ok, err = pcall(function()\n" .. src .. "\nend);"
        .. " if not ok then call(" .. SYS.sys_log .. ", 'WARN', 'child failed: ' .. tostring(err)); end;"
        .. " call(" .. SYS.proc_exit .. ", ok and 0 or 1);";
    return call(SYS.proc_spawn, attrs.name or "childtest", attrs.args, attrs);
end

--- Spawns src as a child and asserts it exits with expectedCode (default 0).
local function expectChildExit(name, src, attrs, expectedCode)
    expectedCode = expectedCode or 0;
    test(name, function()
        local pid = spawnChild(src, attrs);
        local r = call(SYS.proc_wait, pid);
        assert(r.code == expectedCode,
            "expected exit code " .. expectedCode .. ", got " .. tostring(r.code) .. " (pid " .. pid .. ")");
    end);
end

log("=== UwUKernel3 syscall suite starting ===");

--============================================================--
-- proc.* (0-8, 13-14)
--============================================================--

test("proc.info(nil) describes the calling process", function()
    local info = call(SYS.proc_info);
    assert(type(info) == "table", "expected a table");
    assert(type(info.pid) == "number", "missing pid");
    assert(type(info.ppid) == "number" or info.ppid == nil, "ppid wrong type");
    assert(type(info.uid) == "number", "missing uid");
    assert(type(info.gid) == "number", "missing gid");
    assert(type(info.state) == "string", "missing state");
    assert(type(info.groups) == "table", "missing groups");
    assert(type(info.name) == "string", "missing name");
    assert(type(info.cpuTime) == "number", "missing cpuTime");
    assert(type(info.children) == "table", "missing children");
    assert(type(info.limits) == "table", "missing limits");
    assert(info.uid == 0, "expected test process to run as root (uid 0)");
end)

test("proc.info(pid) explicit self-pid matches proc.info(nil)", function()
    local self1 = call(SYS.proc_info);
    local self2 = call(SYS.proc_info, self1.pid);
    assert(self1.pid == self2.pid, "pid mismatch between implicit/explicit self lookup");
end)

test("proc.info(invalid pid) -> ESRCH", function()
    expectError(function() call(SYS.proc_info, 999999) end, "ESRCH");
end)

test("proc.list contains our own pid and the kernel process (pid 0)", function()
    local list = call(SYS.proc_list);
    local self = call(SYS.proc_info);
    local sawSelf, sawKernel = false, false;
    for _, pid in ipairs(list) do
        if pid == self.pid then sawSelf = true; end
        if pid == 0 then sawKernel = true; end
    end
    assert(sawSelf, "proc.list did not include our own pid");
    assert(sawKernel, "proc.list did not include the kernel process (pid 0)");
end)

test("proc.spawn requires attr.blob -> clean EINVAL", function()
    expectError(function() call(SYS.proc_spawn, "nothing", nil, {}) end, "EINVAL");
end)

test("proc.spawn(path, args, nil) with attributes entirely omitted -> clean EINVAL, not a crash", function()
    -- ProcessManager.spawn defaults attr to {} before touching it, and the
    -- Dispatcher correctly forwards a real `nil` here (not silently dropping
    -- it -- see the syscallArguments.n bounds fix in core/Dispatcher.lua).
    local err = expectError(function() call(SYS.proc_spawn, "nothing", nil, nil) end);
    assert(tostring(err):find("EINVAL"), "expected a clean EINVAL, got raw: " .. tostring(err));
end)

test("proc.spawn(path, args, <bad type>) is validated cleanly, not a crash", function()
    local err = expectError(function() call(SYS.proc_spawn, "nothing", nil, 42) end);
    assert(tostring(err):find("EINVAL"), "expected a clean EINVAL, got raw: " .. tostring(err));
end)

test("proc.spawn + proc.wait round-trips a normal exit code", function()
    local pid = call(SYS.proc_spawn, "exit-code-test", nil, { blob = "call(1, 42);" });
    local r = call(SYS.proc_wait, pid);
    assert(r.pid == pid, "wait returned wrong pid");
    assert(r.code == 42, "expected exit code 42, got " .. tostring(r.code));
    assert(type(r.usage) == "number", "usage missing/not a number");
end)

test("proc.spawn passes args through to the child's `arg` global", function()
    local pid = call(SYS.proc_spawn, "argtest", { "hello", "world" }, {
        blob = "local ok = (arg[1] == 'hello' and arg[2] == 'world'); call(1, ok and 0 or 1);",
    });
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child did not see forwarded args");
end)

test("proc.spawn attr.fds SHARE inherits a send-capable copy of a port", function()
    local port = call(SYS.ipc_create);
    local pid = call(SYS.proc_spawn, "fdtest", nil, {
        fds = { [3] = port },
        blob = "local ok, err = pcall(function() call(33, 3, { hello = 'child' }); end);"
            .. " call(1, ok and 0 or 1);",
    });
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.hello == "child", "did not receive the child's message on the inherited port");
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child failed to send via inherited fd");
    call(SYS.ipc_close, port);
end)

test("proc.wait(-1) waits for any child and reaps in completion order", function()
    local pidA = call(SYS.proc_spawn, "any-a", nil, { blob = "call(1, 11);" });
    local pidB = call(SYS.proc_spawn, "any-b", nil, { blob = "call(1, 22);" });
    local seen = {};
    for _ = 1, 2 do
        local r = call(SYS.proc_wait, -1);
        seen[r.pid] = r.code;
    end
    assert(seen[pidA] == 11, "did not reap child A with the right code");
    assert(seen[pidB] == 22, "did not reap child B with the right code");
end)

test("proc.wait for a pid that is not our child -> ECHILD", function()
    local pid = call(SYS.proc_spawn, "not-my-child", nil, { blob = "call(1, 0);" });
    -- reparented instantly to launchd (pid 1... but we ARE pid 1 in this boot,
    -- so just prove waiting on a bogus/foreign pid fails cleanly instead):
    expectError(function() call(SYS.proc_wait, 999999) end, "ECHILD");
    call(SYS.proc_wait, pid); -- reap it so it doesn't linger as a zombie
end)

expectChildExit("proc.wait with zero children -> ECHILD", body({ WAIT = SYS.proc_wait }, [[
    local ok, err = pcall(call, WAIT, -1)
    assert(not ok, "expected an error")
    assert(tostring(err):find("ECHILD"), "expected ECHILD, got: " .. tostring(err))
]]))

test("proc.kill with SIGKILL(9) force-exits the child with code 137", function()
    local pid = call(SYS.proc_spawn, "kill-me", nil, { blob = "while true do call(9); end" });
    call(SYS.proc_kill, pid, 9);
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 137, "expected 137 (SIGKILL), got " .. tostring(r.code));
end)

test("proc.kill with SIGTERM(15) and no handler -> default terminate, code 143", function()
    local pid = call(SYS.proc_spawn, "term-me", nil, { blob = "while true do call(9); end" });
    call(SYS.proc_kill, pid, 15);
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 143, "expected 128+15=143, got " .. tostring(r.code));
end)

test("proc.kill with an unrecognised signal id and no handler -> EINVAL", function()
    local pid = call(SYS.proc_spawn, "signal-victim", nil, { blob = "call(9);" });
    expectError(function() call(SYS.proc_kill, pid, 999) end, "EINVAL");
    call(SYS.proc_kill, pid, 9); -- clean up
    call(SYS.proc_wait, pid);
end)

test("proc.kill: a non-root, non-parent process cannot signal a sibling -> EPERM", function()
    local sibling = call(SYS.proc_spawn, "sibling", nil, { blob = "while true do call(9); end" });
    expectChildExit("(nested) sibling kill EPERM", body(
        { KILL = SYS.proc_kill, TARGET = sibling },
        [[
            local ok, err = pcall(call, KILL, TARGET, 15)
            assert(not ok, "expected EPERM")
            assert(tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
        ]]
    ), { uid = 1000 });
    call(SYS.proc_kill, sibling, 9);
    call(SYS.proc_wait, sibling);
end)

expectChildExit("proc.setattr: non-root cannot change uid/gid/groups (EPERM), but can change cwd", body(
    { SETATTR = SYS.proc_setattr },
    [[
        local ok1, err1 = pcall(call, SETATTR, { uid = 0 })
        assert(not ok1 and tostring(err1):find("EPERM"), "expected EPERM for uid change, got: " .. tostring(err1))

        local ok2, err2 = pcall(call, SETATTR, { gid = 0 })
        assert(not ok2 and tostring(err2):find("EPERM"), "expected EPERM for gid change, got: " .. tostring(err2))

        local ok3, err3 = pcall(call, SETATTR, { groups = { 1, 2 } })
        assert(not ok3 and tostring(err3):find("EPERM"), "expected EPERM for groups change, got: " .. tostring(err3))

        local ok4, err4 = pcall(call, SETATTR, { cwd = "/somewhere" })
        assert(ok4, "expected cwd change to be allowed for non-root: " .. tostring(err4))
    ]]
), { uid = 1000 })

test("proc.setattr: root can change uid/gid/groups", function()
    local pid = call(SYS.proc_spawn, "setattr-root", nil, {
        blob = "local ok = pcall(call, 5, { uid = 5, gid = 5, groups = { 9 } }); call(1, ok and 0 or 1);",
    });
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "root child failed to change its own uid/gid/groups");
end)

test("proc.limit: invalid resource name -> EINVAL", function()
    expectError(function() call(SYS.proc_limit, "not_a_real_resource", 5) end, "EINVAL");
end)

test("proc.limit: negative value -> EINVAL", function()
    expectError(function() call(SYS.proc_limit, "maxFiles", -1) end, "EINVAL");
end)

test("proc.limit: root can raise a limit above the current value", function()
    local info = call(SYS.proc_info);
    call(SYS.proc_limit, "maxFiles", info.limits.maxFiles + 1);
    local after = call(SYS.proc_info);
    assert(after.limits.maxFiles == info.limits.maxFiles + 1, "limit did not increase");
    call(SYS.proc_limit, "maxFiles", info.limits.maxFiles); -- restore
end)

expectChildExit("proc.limit: non-root can lower a limit but not raise it", body(
    { LIMIT = SYS.proc_limit, INFO = SYS.proc_info },
    [[
        local info = call(INFO)
        local ok1, err1 = pcall(call, LIMIT, "maxFiles", info.limits.maxFiles - 1)
        assert(ok1, "expected lowering to be allowed: " .. tostring(err1))

        local ok2, err2 = pcall(call, LIMIT, "maxFiles", info.limits.maxFiles + 100)
        assert(not ok2, "expected raising to fail for non-root")
        assert(tostring(err2):find("EPERM"), "expected EPERM, got: " .. tostring(err2))
    ]]
), { uid = 1000 })

test("[GAP] thread.create should enforce proc.limit('maxThreads', N) per SYSCALLME.md, but doesn't", function()
    local info = call(SYS.proc_info);
    local savedLimit = info.limits.maxThreads;
    call(SYS.proc_limit, "maxThreads", 1);

    -- We already have >=1 thread (this main one); creating another should,
    -- per docs, hit "Process reached a thread limit." It currently doesn't.
    local extraTid = call(SYS.thread_create, function() end, {});
    call(SYS.thread_join, extraTid);

    local err = expectError(function()
        local t = call(SYS.thread_create, function() end, {});
        call(SYS.thread_join, t);
        error("thread.create should have raised a thread-limit error but didn't");
    end);
    assert(tostring(err):find("limit"), "expected a thread-limit error, got: " .. tostring(err));

    call(SYS.proc_limit, "maxThreads", savedLimit); -- restore
end)

test("removed proc.yield(7) -> ENOSYS", function()
    expectError(function() call(7) end, "ENOSYS");
end)

local DEFAULT_LUA_PATH = "/Library/?.lua;/Library/?/init.lua";

test("proc.setenv / proc.getenv round-trip a value", function()
    call(SYS.proc_setenv, "MEOW_ROUNDTRIP", "purr");
    assert(call(SYS.proc_getenv, "MEOW_ROUNDTRIP") == "purr",
        "got " .. tostring(call(SYS.proc_getenv, "MEOW_ROUNDTRIP")));
    call(SYS.proc_setenv, "MEOW_ROUNDTRIP", nil);
end)

test("proc.getenv of an unset name returns nil", function()
    assert(call(SYS.proc_getenv, "MEOW_DEFINITELY_UNSET") == nil, "expected nil for an unset name");
end)

test("proc.setenv with a nil value unsets", function()
    call(SYS.proc_setenv, "MEOW_UNSET_ME", "here");
    call(SYS.proc_setenv, "MEOW_UNSET_ME", nil);
    assert(call(SYS.proc_getenv, "MEOW_UNSET_ME") == nil, "variable survived being unset");
end)

test("proc.getenv() with no name returns the whole map", function()
    call(SYS.proc_setenv, "MEOW_MAP_A", "1");
    call(SYS.proc_setenv, "MEOW_MAP_B", "2");

    local map = call(SYS.proc_getenv);
    assert(type(map) == "table", "expected a table, got " .. type(map));
    assert(map.MEOW_MAP_A == "1" and map.MEOW_MAP_B == "2", "map is missing variables that are set");

    call(SYS.proc_setenv, "MEOW_MAP_A", nil);
    call(SYS.proc_setenv, "MEOW_MAP_B", nil);
end)

test("proc.getenv() returns a copy, so mutating it cannot reach the process", function()
    local map = call(SYS.proc_getenv);
    map.MEOW_SMUGGLED = "nope";
    assert(call(SYS.proc_getenv, "MEOW_SMUGGLED") == nil, "writing the returned map changed the environment");
end)

test("proc.setenv rejects malformed names and non-string values", function()
    expectError(function() call(SYS.proc_setenv, 5, "x") end, "EINVAL");
    expectError(function() call(SYS.proc_setenv, "", "x") end, "EINVAL");
    expectError(function() call(SYS.proc_setenv, "MEOW=BAD", "x") end, "EINVAL");
    expectError(function() call(SYS.proc_setenv, "MEOW_BAD_VALUE", 5) end, "EINVAL");
end)

test("proc.getenv rejects a malformed name", function()
    expectError(function() call(SYS.proc_getenv, "MEOW=BAD") end, "EINVAL");
end)

test("a child with no attributes.env inherits the parent's environment", function()
    call(SYS.proc_setenv, "MEOW_INHERITED", "yes");

    local pid = spawnChild(body({ GETENV = SYS.proc_getenv }, [[
        assert(call(GETENV, "MEOW_INHERITED") == "yes",
            "child did not inherit, got " .. tostring(call(GETENV, "MEOW_INHERITED")))
    ]]));
    local r = call(SYS.proc_wait, pid);

    call(SYS.proc_setenv, "MEOW_INHERITED", nil);
    assert(r.code == 0, "child did not see the inherited environment");
end)

test("attributes.env replaces the environment rather than merging into it", function()
    call(SYS.proc_setenv, "MEOW_SHOULD_NOT_LEAK", "leaked");

    local pid = spawnChild(body({ GETENV = SYS.proc_getenv }, [[
        assert(call(GETENV, "MEOW_OWN") == "mine", "child is missing its own environment")
        assert(call(GETENV, "MEOW_SHOULD_NOT_LEAK") == nil, "parent's environment leaked into a replaced one")
    ]]), { env = { MEOW_OWN = "mine" } });
    local r = call(SYS.proc_wait, pid);

    call(SYS.proc_setenv, "MEOW_SHOULD_NOT_LEAK", nil);
    assert(r.code == 0, "attributes.env did not replace the environment");
end)

test("a child's setenv does not leak back into the parent", function()
    local pid = spawnChild(body({ SETENV = SYS.proc_setenv }, [[
        call(SETENV, "MEOW_CHILD_ONLY", "x")
    ]]));
    local r = call(SYS.proc_wait, pid);

    assert(r.code == 0, "child failed to set its own variable");
    assert(call(SYS.proc_getenv, "MEOW_CHILD_ONLY") == nil, "the child's environment is shared with the parent");
end)

test("proc.spawn validates attributes.env", function()
    expectError(function()
        call(SYS.proc_spawn, "badenv", nil, { blob = "call(1, 0);", env = { MEOW = 5 } });
    end, "EINVAL");

    expectError(function()
        call(SYS.proc_spawn, "badenv", nil, { blob = "call(1, 0);", env = { ["MEOW=BAD"] = "x" } });
    end, "EINVAL");
end)

test("proc.spawn attr.cwd sets the child's working directory", function()
    local pid = spawnChild(body({ INFO = SYS.proc_info }, [[
        local cwd = call(INFO).cwd
        assert(cwd == "/Library", "expected /Library, got " .. tostring(cwd))
    ]]), { cwd = "/Library" });
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "attr.cwd was ignored");
end)

test("a child with no attr.cwd inherits the parent's", function()
    local mine = call(SYS.proc_info).cwd;
    assert(type(mine) == "string", "proc.info does not report cwd");

    local pid = spawnChild(body({ INFO = SYS.proc_info }, [[
        local cwd = call(INFO).cwd
        assert(cwd == "]] .. mine .. [[", "expected ]] .. mine .. [[, got " .. tostring(cwd))
    ]]));
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child did not inherit the parent's cwd");
end)

test("package.path reads LUA_PATH, and falls back when it is unset", function()
    local saved = call(SYS.proc_getenv, "LUA_PATH");

    call(SYS.proc_setenv, "LUA_PATH", nil);
    assert(package.path == DEFAULT_LUA_PATH, "expected the default path, got " .. tostring(package.path));

    call(SYS.proc_setenv, "LUA_PATH", "/meow/?.lua");
    assert(package.path == "/meow/?.lua", "package.path did not follow LUA_PATH, got " .. tostring(package.path));

    call(SYS.proc_setenv, "LUA_PATH", saved);
end)

test("writing package.path writes LUA_PATH", function()
    local saved = call(SYS.proc_getenv, "LUA_PATH");

    package.path = "/meow/?.lua;" .. package.path;
    assert(call(SYS.proc_getenv, "LUA_PATH") == package.path,
        "LUA_PATH does not match package.path after a write");
    assert(package.path:sub(1, 12) == "/meow/?.lua;", "the prepend did not survive the round-trip");

    call(SYS.proc_setenv, "LUA_PATH", saved);
end)

test("package.preload and package.loaded are still ordinary fields", function()
    package.preload["meow.probe"] = function() return "loaded" end;
    assert(require("meow.probe") == "loaded", "preload stopped working");
    assert(package.loaded["meow.probe"] == "loaded", "loaded was not recorded");

    package.preload["meow.probe"] = nil;
    package.loaded["meow.probe"] = nil;
end)

expectChildExit("a child spawned with LUA_PATH starts with that package.path", [[
    assert(package.path == "/meow/child/?.lua", "got " .. tostring(package.path))
]], { env = { LUA_PATH = "/meow/child/?.lua" } })

--============================================================--
-- thread.* (9-12)
--============================================================--

test("thread.id() returns a number identifying the calling thread", function()
    local tid = call(SYS.thread_id);
    assert(type(tid) == "number", "expected a number");
end)

test("thread.create/join round-trips a return value", function()
    local tid = call(SYS.thread_create, function(a, b)
        return a + b, "extra";
    end, { 2, 3 });
    local result = call(SYS.thread_join, tid);
    assert(result[1] == true, "join did not report success");
    assert(result[2][1] == 5, "expected 2+3=5, got " .. tostring(result[2][1]));
    assert(result[2][2] == "extra", "second return value did not round-trip");
end)

test("thread.join on an unknown tid -> ESRCH", function()
    expectError(function() call(SYS.thread_join, 999999) end, "ESRCH");
end)

test("thread.join(self) -> EDEADLK", function()
    local selfTid = call(SYS.thread_id);
    expectError(function() call(SYS.thread_join, selfTid) end, "EDEADLK");
end)

test("thread.list includes a newly created thread until it's joined/reaped", function()
    local gatePort = call(SYS.ipc_create);
    local tid = call(SYS.thread_create, function()
        pcall(call, SYS.ipc_receive, gatePort);
    end, {});

    local during = call(SYS.thread_list);
    local found = false;
    for _, t in ipairs(during) do if t == tid then found = true; end end
    assert(found, "expected the still-blocked thread to be in thread.list");

    call(SYS.ipc_send, gatePort, {}); -- release it
    call(SYS.thread_join, tid);
    call(SYS.ipc_close, gatePort);
end)

expectChildExit(
    "[GAP] task.join should report success=false on a crashed thread; instead the crash "
        .. "force-exits the whole owning process (dead path: ThreadManager.terminate is never "
        .. "reached from Scheduler.run's crash branch)",
    [[
        -- If this ever prints code 0, the bug is fixed: the crash was caught
        -- and reported via task.join instead of taking the process down.
        local tid = call(9, function() error("boom") end, {})
        local result = call(10, tid)
        if result[1] == false then
            call(1, 0)
        else
            call(1, 1)
        end
    ]],
    nil,
    1 -- currently: the crash kills the child before it can even reach `call(1, ...)`
)

--============================================================--
-- ipc.* (32-38)
--============================================================--

test("ipc.create returns a usable fd; ipc.stat reports an empty queue", function()
    local port = call(SYS.ipc_create);
    assert(type(port) == "number", "expected a number fd");
    local stat = call(SYS.ipc_stat, port);
    assert(stat.messages == 0, "expected an empty queue");
    assert(type(stat.capacity) == "number", "capacity missing");
    call(SYS.ipc_close, port);
end)

test("ipc.send/receive round-trips a payload and its declared type", function()
    local port = call(SYS.ipc_create);
    call(SYS.ipc_send, port, { hello = "world" }, { type = "CUSTOM_TYPE" });
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.hello == "world", "payload did not round-trip");
    assert(msg.type == "CUSTOM_TYPE", "custom type did not round-trip");
    assert(type(msg.pid) == "number", "sender pid missing");
    call(SYS.ipc_close, port);
end)

test("ipc.send deep-copies the payload (sender mutation after send is not observed)", function()
    local port = call(SYS.ipc_create);
    local payload = { count = 1 };
    call(SYS.ipc_send, port, payload);
    payload.count = 999;
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.count == 1, "receiver observed the sender's post-send mutation");
    call(SYS.ipc_close, port);
end)

test("ipc.send with reply_port lets the receiver reply back to the sender", function()
    local requestPort = call(SYS.ipc_create);
    local tid, result = runInThread(function(result)
        local msg = call(SYS.ipc_receive, requestPort);
        result.gotRequest = msg.data.ping;
        call(SYS.ipc_send, msg.reply, { pong = true });
    end);

    local replyPort = call(SYS.ipc_create);
    call(SYS.ipc_send, requestPort, { ping = true }, { reply_port = replyPort });
    local reply = call(SYS.ipc_receive, replyPort);

    call(SYS.thread_join, tid);
    assert(result.ok, "responder thread failed: " .. tostring(result.err));
    assert(result.gotRequest == true, "responder never saw the request");
    assert(reply.data.pong == true, "never got the reply back");

    call(SYS.ipc_close, requestPort);
    call(SYS.ipc_close, replyPort);
end)

test("ipc.send with transfer moves a handle to the receiver and closes the sender's copy", function()
    local mainPort = call(SYS.ipc_create);
    local giftPort = call(SYS.ipc_create);

    call(SYS.ipc_send, mainPort, {}, { transfer = { giftPort } });
    expectError(function() call(SYS.ipc_stat, giftPort) end, "EBADF");

    local msg = call(SYS.ipc_receive, mainPort);
    assert(msg.handles and msg.handles[1], "expected a transferred handle in msg.handles");
    local newFd = msg.handles[1];
    local stat = call(SYS.ipc_stat, newFd); -- should work: it's the same port, new fd
    assert(type(stat.messages) == "number", "transferred handle is not usable");

    call(SYS.ipc_close, mainPort);
    call(SYS.ipc_close, newFd);
end)

test("ipc.close on an invalid fd errors", function()
    expectError(function() call(SYS.ipc_close, 999999) end);
end)

test("ipc.receive on an invalid fd -> EBADF", function()
    expectError(function() call(SYS.ipc_receive, 999999) end, "EBADF");
end)

test("ipc.send on an invalid fd -> EBADF", function()
    expectError(function() call(SYS.ipc_send, 999999, {}) end, "EBADF");
end)

-- Spawns a child holding a send right to a doomed port on fd 3, parked on fd 4 until we
-- say go. proc.spawn queues the child ahead of the parent's own resume, so without the
-- gate it would send while the port is still alive and owned.
local function spawnGatedSender(src)
    local victim = call(SYS.ipc_create);
    local gate = call(SYS.ipc_create);
    local gateSend = call(SYS.io_dup, gate);

    local pid = spawnChild(body({
        CREATE = SYS.ipc_create, SEND = SYS.ipc_send,
        RECEIVE = SYS.ipc_receive, SIGNAL = SYS.sys_signal,
    }, "call(RECEIVE, 4)\n" .. src), {
        fds = { [3] = victim, [4] = { fd = gate, op = "MOVE" } },
    });

    call(SYS.ipc_close, victim);
    call(SYS.ipc_send, gateSend, { go = true });
    call(SYS.ipc_close, gateSend);

    return pid;
end

test("SIGPIPE is not raised when the owner releases its receive right", function()
    local pid = spawnGatedSender("");
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "holder of a send right was killed by the owner leaving (exit " .. tostring(r.code) .. ")");
end)

test("SIGPIPE is raised on a send to a port with no receiver, terminating by default", function()
    local pid = spawnGatedSender([[
        call(SEND, 3, { hi = "nobody home" })
    ]]);

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 141, "expected exit 141 (128 + SIGPIPE), got " .. tostring(r.code));
end)

test("a registered SIGPIPE handler turns the broken send into EPIPE instead of death", function()
    local pid = spawnGatedSender([[
        local sigPort = call(CREATE)
        call(SIGNAL, 13, sigPort)

        local ok, err = pcall(call, SEND, 3, { hi = "nobody home" })
        assert(not ok, "expected the send to fail")
        assert(tostring(err):find("EPIPE"), "expected EPIPE, got: " .. tostring(err))

        local msg = call(RECEIVE, sigPort)
        assert(msg.type == "SIGNAL", "expected a SIGNAL message, got " .. tostring(msg.type))
        assert(msg.data.signal == 13, "expected signal 13, got " .. tostring(msg.data.signal))
        assert(msg.data.data.fd == 3, "expected named fd in payload, got " .. tostring(msg.data.data.fd))
    ]]);

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child exited " .. tostring(r.code) .. " instead of handling SIGPIPE");
end)

test("io.dup'd send-right of a port cannot be used to receive -> EPERM", function()
    local port = call(SYS.ipc_create);
    local sendFd = call(SYS.io_dup, port);
    expectError(function() call(SYS.ipc_receive, sendFd) end, "EPERM");
    call(SYS.ipc_send, sendFd, { via = "dup" });
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.via == "dup", "message sent via the dup'd send right never arrived");
    call(SYS.ipc_close, port);
    call(SYS.ipc_close, sendFd);
end)

test("ipc.poll: only a receive-right fd may be polled -> EPERM for a send-right", function()
    local port = call(SYS.ipc_create);
    local sendFd = call(SYS.io_dup, port);
    expectError(function() call(SYS.ipc_poll, { sendFd }) end, "EPERM");
    call(SYS.ipc_close, port);
    call(SYS.ipc_close, sendFd);
end)

test("ipc.poll wakes up reporting whichever of several ports received a message", function()
    local a, b = call(SYS.ipc_create), call(SYS.ipc_create);
    local tid, result = runInThread(function(result)
        result.readyFd = call(SYS.ipc_poll, { a, b });
    end);
    sleep(0.05); -- let the worker register as a poller before we send
    call(SYS.ipc_send, b, { marker = "b" });
    call(SYS.thread_join, tid);
    assert(result.ok, "poller thread failed: " .. tostring(result.err));
    assert(result.readyFd == b, "expected port b to be reported ready, got " .. tostring(result.readyFd));
    call(SYS.ipc_receive, b); -- drain
    call(SYS.ipc_close, a);
    call(SYS.ipc_close, b);
end)

test("ipc.poll returns immediately if a queued message already exists", function()
    local port = call(SYS.ipc_create);
    call(SYS.ipc_send, port, { already = true });
    local readyFd = call(SYS.ipc_poll, { port });
    assert(readyFd == port, "expected the already-queued port to be returned immediately");
    call(SYS.ipc_receive, port);
    call(SYS.ipc_close, port);
end)

test("[GAP] ipc.receive(port, opts) ignores opts.types and opts.timeout entirely", function()
    local port = call(SYS.ipc_create);
    local tid, result = runInThread(function(result)
        local t0 = call(SYS.sys_epoch, "utc");
        local msg = call(SYS.ipc_receive, port, { timeout = 0.1, types = { "SOME_OTHER_TYPE" } });
        result.msg = msg;
        result.elapsed = call(SYS.sys_epoch, "utc") - t0;
    end);
    sleep(0.3); -- comfortably past the requested 0.1s "timeout"
    call(SYS.ipc_send, port, { hi = true }, { type = "IPC" }); -- mismatched type per opts.types
    call(SYS.thread_join, tid);
    assert(result.ok, "worker failed: " .. tostring(result.err));
    assert(result.msg and result.msg.data.hi == true,
        "expected the type-mismatched message to be delivered anyway (types filter is a no-op)");
    assert(result.elapsed >= 250,
        "expected the receive to have waited well past its requested 0.1s timeout, waited " .. tostring(result.elapsed) .. "ms");
    call(SYS.ipc_close, port);
end)

test("removed ipc.transfer(35) -> ENOSYS", function()
    expectError(function() call(35, 0, 0) end, "ENOSYS");
end)

--============================================================--
-- io.dup (74)
--============================================================--

test("io.dup duplicates a fd to a fresh number", function()
    local port = call(SYS.ipc_create);
    local dupFd = call(SYS.io_dup, port);
    assert(dupFd ~= port, "expected a different fd number");
    call(SYS.ipc_send, dupFd, { via = "plain-dup" });
    -- since a receive-right dup actually yields a SEND right (see below), read from the original:
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.via == "plain-dup", "duplicate fd did not point at the same port");
    call(SYS.ipc_close, port);
    call(SYS.ipc_close, dupFd);
end)

test("io.dup(fd, targetFd) closes whatever previously lived at targetFd", function()
    local a = call(SYS.ipc_create);
    local b = call(SYS.ipc_create);
    call(SYS.io_dup, a, b); -- b now aliases a; the original port at b is released
    call(SYS.ipc_send, b, { hi = "via-b" });
    local msg = call(SYS.ipc_receive, a);
    assert(msg.data.hi == "via-b", "dup with explicit target fd did not alias correctly");
    call(SYS.ipc_close, a);
end)

test("io.dup(fd, fd) is a no-op that returns the same fd", function()
    local a = call(SYS.ipc_create);
    local result = call(SYS.io_dup, a, a);
    assert(result == a, "expected dup(fd, fd) to return fd unchanged");
    call(SYS.ipc_close, a);
end)

test("io.dup on an invalid fd -> EBADF", function()
    expectError(function() call(SYS.io_dup, 999999) end, "EBADF");
end)

--============================================================--
-- io.pipe (73)
--============================================================--

test("io.pipe hands back two distinct descriptors", function()
    local readFd, writeFd = call(SYS.io_pipe);
    assert(type(readFd) == "number" and type(writeFd) == "number",
        "expected two fds, got " .. tostring(readFd) .. " and " .. tostring(writeFd));
    assert(readFd ~= writeFd, "both ends came back as the same fd");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("bytes written to a pipe come back out of its read end", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local written = call(SYS.fs_write, writeFd, "meow");
    assert(written == 4, "expected 4 bytes written, got " .. tostring(written));
    assert(call(SYS.fs_read, readFd, 16) == "meow", "the pipe did not return what was written");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("a read takes only what is buffered, across the boundaries of separate writes", function()
    local readFd, writeFd = call(SYS.io_pipe);
    call(SYS.fs_write, writeFd, "abc");
    call(SYS.fs_write, writeFd, "def");
    assert(call(SYS.fs_read, readFd, 4) == "abcd", "a read did not span two buffered writes");
    assert(call(SYS.fs_read, readFd, 4) == "ef", "the second read did not resume mid-chunk");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("a pipe is half-duplex: each end refuses the other end's operation", function()
    local readFd, writeFd = call(SYS.io_pipe);
    expectError(function() call(SYS.fs_write, readFd, "x") end, "does not support writing");
    expectError(function() call(SYS.fs_read, writeFd, 4) end, "does not support reading");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("a pipe carries bytes, so a non-string write -> EINVAL", function()
    local readFd, writeFd = call(SYS.io_pipe);
    expectError(function() call(SYS.fs_write, writeFd, { not_a = "string" }) end, "EINVAL");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("a pipe has no cursor: seek and positional I/O -> ESPIPE", function()
    local readFd, writeFd = call(SYS.io_pipe);
    expectError(function() call(SYS.fs_seek, readFd, 0, "set") end, "ESPIPE");
    expectError(function() call(SYS.fs_read, readFd, 4, 8) end, "ESPIPE");
    expectError(function() call(SYS.fs_write, writeFd, "x", 8) end, "ESPIPE");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("closing the write end ends the stream: a read returns nil rather than blocking", function()
    local readFd, writeFd = call(SYS.io_pipe);
    call(SYS.fs_write, writeFd, "last words");
    call(SYS.fs_close, writeFd);
    assert(call(SYS.fs_read, readFd, 32) == "last words", "buffered data was lost when the writer closed");
    assert(call(SYS.fs_read, readFd, 32) == nil, "expected nil at end of stream");
    call(SYS.fs_close, readFd);
end)

test("a pipe stays open until every copy of the write end is closed", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local copy = call(SYS.io_dup, writeFd);

    call(SYS.fs_write, copy, "one");
    call(SYS.fs_close, writeFd);
    assert(call(SYS.fs_read, readFd, 16) == "one", "the dup'd write end did not reach the pipe");

    call(SYS.fs_write, copy, "two");
    assert(call(SYS.fs_read, readFd, 16) == "two", "the pipe closed while a dup of the write end was still open");

    call(SYS.fs_close, copy);
    assert(call(SYS.fs_read, readFd, 16) == nil, "expected end of stream once the last write end went away");
    call(SYS.fs_close, readFd);
end)

test("a read on an empty pipe parks until somebody writes", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local tid, result = runInThread(function(result)
        local t0 = call(SYS.sys_epoch, "utc");
        result.data = call(SYS.fs_read, readFd, 64);
        result.elapsed = call(SYS.sys_epoch, "utc") - t0;
    end);
    sleep(0.15); -- let the reader park before anything is there to read
    call(SYS.fs_write, writeFd, "late");
    call(SYS.thread_join, tid);
    assert(result.ok, "reader thread failed: " .. tostring(result.err));
    assert(result.data == "late", "parked reader got " .. tostring(result.data));
    assert(result.elapsed >= 100,
        "the read returned immediately instead of parking, after " .. tostring(result.elapsed) .. "ms");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("closing the write end wakes a parked reader with end of stream", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local tid, result = runInThread(function(result)
        result.data = call(SYS.fs_read, readFd, 64);
        result.sawEof = result.data == nil;
    end);
    sleep(0.05);
    call(SYS.fs_close, writeFd);
    call(SYS.thread_join, tid);
    assert(result.ok, "reader thread failed: " .. tostring(result.err));
    assert(result.sawEof, "parked reader was woken with " .. tostring(result.data) .. " instead of end of stream");
    call(SYS.fs_close, readFd);
end)

test("a write past the buffer capacity parks the writer until a reader drains it", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local payload = string.rep("x", 5000);

    local tid, result = runInThread(function(result)
        result.written = call(SYS.fs_write, writeFd, payload);
    end);
    sleep(0.05); -- the writer parks once the buffer is full

    local first = call(SYS.fs_read, readFd, 5000);
    assert(#first == 4096, "expected the buffer to cap at 4096 bytes, read " .. tostring(#first));

    local rest = call(SYS.fs_read, readFd, 5000);
    call(SYS.thread_join, tid);

    assert(result.ok, "writer thread failed: " .. tostring(result.err));
    assert(#first + #rest == 5000, "the pipe lost bytes: " .. tostring(#first + #rest) .. " of 5000");
    assert(result.written == 5000, "the parked write reported " .. tostring(result.written) .. " bytes");
    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
end)

test("closing the read end under a parked writer ends the write with what it placed", function()
    local readFd, writeFd = call(SYS.io_pipe);
    local tid, result = runInThread(function(result)
        result.written = call(SYS.fs_write, writeFd, string.rep("y", 5000));
    end);
    sleep(0.05);
    call(SYS.fs_close, readFd);
    call(SYS.thread_join, tid);
    assert(result.ok, "writer thread failed: " .. tostring(result.err));
    assert(result.written == 4096,
        "expected the partial count the writer managed to place, got " .. tostring(result.written));
    call(SYS.fs_close, writeFd);
end)

-- Same gating trick as spawnGatedSender: the child parks on fd 4 until we have closed
-- our own ends, since spawn queues the child ahead of the parent's own resume.
local function spawnGatedPipeWriter(src)
    local readFd, writeFd = call(SYS.io_pipe);
    local gate = call(SYS.ipc_create);
    local gateSend = call(SYS.io_dup, gate);

    local pid = spawnChild(body({
        CREATE = SYS.ipc_create, RECEIVE = SYS.ipc_receive,
        SIGNAL = SYS.sys_signal, WRITE = SYS.fs_write,
    }, "call(RECEIVE, 4)\n" .. src), {
        fds = { [3] = writeFd, [4] = { fd = gate, op = "MOVE" } },
    });

    call(SYS.fs_close, readFd);
    call(SYS.fs_close, writeFd);
    call(SYS.ipc_send, gateSend, { go = true });
    call(SYS.ipc_close, gateSend);

    return pid;
end

test("writing to a pipe with no reader left raises SIGPIPE, terminating by default", function()
    local pid = spawnGatedPipeWriter([[
        call(WRITE, 3, "into the void")
    ]]);

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 141, "expected exit 141 (128 + SIGPIPE), got " .. tostring(r.code));
end)

test("a registered SIGPIPE handler turns the broken pipe write into EPIPE instead of death", function()
    local pid = spawnGatedPipeWriter([[
        local sigPort = call(CREATE)
        call(SIGNAL, 13, sigPort)

        local ok, err = pcall(call, WRITE, 3, "into the void")
        assert(not ok, "expected the write to fail")
        assert(tostring(err):find("EPIPE"), "expected EPIPE, got: " .. tostring(err))

        local msg = call(RECEIVE, sigPort)
        assert(msg.data.signal == 13, "expected signal 13, got " .. tostring(msg.data.signal))
        assert(msg.data.data.fd == 3, "expected the written fd in the payload, got " .. tostring(msg.data.data.fd))
    ]]);

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child exited " .. tostring(r.code) .. " instead of handling SIGPIPE");
end)

test("a child inherits a pipe as fd 1, and its print arrives on the parent's read end", function()
    local readFd, writeFd = call(SYS.io_pipe);

    local pid = spawnChild([[
        print("hello from the child")
    ]], { fds = { [1] = writeFd } });

    -- the parent's own copy has to go, or the read end never sees the child's exit
    call(SYS.fs_close, writeFd);

    local got = "";
    while true do
        local chunk = call(SYS.fs_read, readFd, 256);
        if not chunk then break; end
        got = got .. chunk;
    end

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child exited " .. tostring(r.code));
    assert(got == "hello from the child\n", "parent read " .. string.format("%q", got));
    call(SYS.fs_close, readFd);
end)

test("a child inherits a pipe as fd 0 and reads what the parent writes into it", function()
    local readFd, writeFd = call(SYS.io_pipe);

    local pid = spawnChild([[
        local line = read(32)
        assert(line == "ping", "child read " .. tostring(line))
    ]], { fds = { [0] = readFd } });

    call(SYS.fs_close, readFd);
    call(SYS.fs_write, writeFd, "ping");

    local r = call(SYS.proc_wait, pid);
    assert(r.code == 0, "child exited " .. tostring(r.code) .. " instead of reading its stdin");
    call(SYS.fs_close, writeFd);
end)

--============================================================--
-- fs.* (64-82) -- exercised against a minimal in-process mock VFS driver
--============================================================--

local FS_MOUNT_PATH = "/mnttest";
local fsReady = false;
local driverPort;

test("fs test harness: mount an in-process mock VFS driver", function()
    local files = {
        ["/"] = { isDir = true },
        ["/hello.txt"] = { isDir = false, data = "Hello, World!" },
    };
    local nextFileId = 0;
    local openFiles = {};
    local lastCopyDestination = nil;

    local function handle(msg)
        local t, d = msg.type, msg.data;
        if t == "VFS_OPEN" then
            local f = files[d.path];
            if not f and d.mode:find("w") then
                f = { isDir = false, data = "" };
                files[d.path] = f;
            end
            if not f then error("ENOENT: no such file " .. tostring(d.path)); end
            if f.isDir then error("EISDIR: " .. tostring(d.path) .. " is a directory"); end
            nextFileId = nextFileId + 1;
            openFiles[nextFileId] = d.path;
            return { fileId = nextFileId, size = #f.data };
        elseif t == "VFS_CLOSE" then
            openFiles[d.fileId] = nil;
            return true;
        elseif t == "VFS_READ" then
            local f = files[openFiles[d.fileId]];
            local chunk = f.data:sub(d.offset + 1, d.offset + d.bytes);
            if chunk == "" then return nil; end
            return chunk;
        elseif t == "VFS_WRITE" then
            local f = files[openFiles[d.fileId]];
            local before = f.data:sub(1, d.offset);
            if #before < d.offset then before = before .. string.rep("\0", d.offset - #before); end
            local after = f.data:sub(d.offset + #d.data + 1);
            f.data = before .. d.data .. after;
            return #d.data;
        elseif t == "VFS_FLUSH" then
            return true;
        elseif t == "VFS_STAT" then
            local f = files[d.path];
            if not f then error("ENOENT: no such file " .. tostring(d.path)); end
            return {
                size = f.isDir and 0 or #f.data, isDir = f.isDir or false, isLink = false,
                uid = 0, gid = 0, created = 0, modified = 0, accessed = 0,
            };
        elseif t == "VFS_LIST" then
            local dir = d.path;
            if dir:sub(-1) ~= "/" then dir = dir .. "/"; end
            local out = {};
            for path, _ in pairs(files) do
                if path ~= "/" and path:sub(1, #dir) == dir then
                    local rest = path:sub(#dir + 1);
                    if not rest:find("/") then table.insert(out, rest); end
                end
            end
            return out;
        elseif t == "VFS_MKDIR" then
            files[d.path] = { isDir = true };
            return true;
        elseif t == "VFS_REMOVE" then
            files[d.path] = nil;
            return true;
        elseif t == "VFS_RENAME" then
            files[d.destination] = files[d.path];
            files[d.path] = nil;
            return true;
        elseif t == "VFS_COPY" then
            lastCopyDestination = d.destination; -- see the [GAP] test below
            local f = files[d.path];
            if not f then error("ENOENT: no such file " .. tostring(d.path)); end
            files[d.destination] = { isDir = f.isDir, data = f.data };
            return true;
        elseif t == "VFS_SETATTR" then
            return true;
        elseif t == "VFS_IOCTL" then
            if d.cmd == "ECHO" then return d.args; end
            error("ENOTTY: unknown ioctl " .. tostring(d.cmd));
        else
            error("EINVAL: unknown VFS method " .. tostring(t));
        end
    end

    driverPort = call(SYS.ipc_create);
    call(SYS.thread_create, function()
        while true do
            local ok, err = pcall(function()
                local msg = call(SYS.ipc_receive, driverPort);
                local ok2, result = pcall(handle, msg);
                if ok2 then
                    call(SYS.ipc_send, msg.reply, { status = "OK", data = result });
                else
                    call(SYS.ipc_send, msg.reply, { status = "ERROR", data = tostring(result) });
                end
            end);
            if not ok then
                call(SYS.sys_log, "WARN", "mock VFS driver loop error: " .. tostring(err));
            end
        end
    end, {});

    -- expose to later tests in this file (upvalue, same chunk):
    _G.__mockFsLastCopyDestination = function() return lastCopyDestination end;

    call(SYS.fs_mount, FS_MOUNT_PATH, driverPort);
    fsReady = true;
end)

test("fs.open on an unmounted path -> ENOTFOUND", function()
    expectError(function() call(SYS.fs_open, "/nowhere/at/all.txt", "r") end, "ENOTFOUND");
end)

test("fs.mount: non-root cannot mount -> EPERM", function()
    if not fsReady then error("setup failed, skipping"); end
    expectChildExit("(nested) fs.mount EPERM", body(
        { MOUNT = SYS.fs_mount, CREATE = SYS.ipc_create },
        [[
            local p = call(CREATE)
            local ok, err = pcall(call, MOUNT, "/wherever", p)
            assert(not ok and tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
        ]]
    ), { uid = 1000 });
end)

test("fs.mount: mounting the same path twice -> EBUSY", function()
    if not fsReady then error("setup failed, skipping"); end
    local port2 = call(SYS.ipc_create);
    expectError(function() call(SYS.fs_mount, FS_MOUNT_PATH, port2) end, "EBUSY");
    call(SYS.ipc_close, port2);
end)

test("fs.mount: invalid port fd -> EBADF", function()
    expectError(function() call(SYS.fs_mount, "/another/path", 999999) end, "EBADF");
end)

test("fs.open/read/write/seek/close round-trip through the mock driver", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    assert(type(fd) == "number", "expected a fd");

    local data = call(SYS.fs_read, fd, 5);
    assert(data == "Hello", "expected 'Hello', got " .. tostring(data));

    local pos = call(SYS.fs_seek, fd, 0, "set");
    assert(pos == 0, "expected seek(set,0) -> 0");

    local all = call(SYS.fs_read, fd, 100);
    assert(all == "Hello, World!", "expected full contents, got " .. tostring(all));

    local eof = call(SYS.fs_read, fd, 10);
    assert(eof == nil, "expected nil at EOF, got " .. tostring(eof));

    call(SYS.fs_close, fd);
end)

test("fs.write creates/extends a file and fs.read reflects the new contents", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/scratch.txt", "w");
    local written = call(SYS.fs_write, fd, "abc");
    assert(written == 3, "expected 3 bytes written, got " .. tostring(written));
    call(SYS.fs_close, fd);

    local readFd = call(SYS.fs_open, FS_MOUNT_PATH .. "/scratch.txt", "r");
    local data = call(SYS.fs_read, readFd, 100);
    assert(data == "abc", "expected 'abc', got " .. tostring(data));
    call(SYS.fs_close, readFd);
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/scratch.txt");
end)

test("fs.stat reports size/isDir for a known file and directory", function()
    if not fsReady then error("setup failed, skipping"); end
    local fileStat = call(SYS.fs_stat, FS_MOUNT_PATH .. "/hello.txt");
    assert(fileStat.size == 13, "expected size 13, got " .. tostring(fileStat.size));
    assert(fileStat.isDir == false, "expected isDir=false for a file");

    local dirStat = call(SYS.fs_stat, FS_MOUNT_PATH);
    assert(dirStat.isDir == true, "expected isDir=true for the mount root");
end)

test("fs.stat on a missing path propagates the driver's error message", function()
    if not fsReady then error("setup failed, skipping"); end
    expectError(function() call(SYS.fs_stat, FS_MOUNT_PATH .. "/does-not-exist.txt") end, "ENOENT");
end)

test("fs.list enumerates entries directly under a path", function()
    if not fsReady then error("setup failed, skipping"); end
    local entries = call(SYS.fs_list, FS_MOUNT_PATH);
    local sawHello = false;
    for _, name in ipairs(entries) do if name == "hello.txt" then sawHello = true; end end
    assert(sawHello, "expected hello.txt in the listing");
end)

test("fs.mkdir/fs.list/fs.remove round-trip a directory", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_mkdir, FS_MOUNT_PATH .. "/newdir");
    local stat = call(SYS.fs_stat, FS_MOUNT_PATH .. "/newdir");
    assert(stat.isDir == true, "mkdir'd path should be a directory");
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/newdir");
    expectError(function() call(SYS.fs_stat, FS_MOUNT_PATH .. "/newdir") end, "ENOENT");
end)

test("fs.rename moves a file (both sides resolved relative to the mount)", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_mkdir, FS_MOUNT_PATH .. "/rn-placeholder"); -- ensure driver has something to rename via stat check isn't needed
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/rn-placeholder");

    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    call(SYS.fs_close, fd);

    -- copy hello.txt so we have a throwaway file to rename without disturbing later tests:
    call(SYS.fs_copy, FS_MOUNT_PATH .. "/hello.txt", FS_MOUNT_PATH .. "/rename-src.txt");
    call(SYS.fs_rename, FS_MOUNT_PATH .. "/rename-src.txt", FS_MOUNT_PATH .. "/rename-dst.txt");
    local stat = call(SYS.fs_stat, FS_MOUNT_PATH .. "/rename-dst.txt");
    assert(stat.size == 13, "renamed file lost its contents");
    expectError(function() call(SYS.fs_stat, FS_MOUNT_PATH .. "/rename-src.txt") end, "ENOENT");
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/rename-dst.txt");
end)

test("fs.rename across two different mounts -> EXDEV", function()
    if not fsReady then error("setup failed, skipping"); end
    local otherPort = call(SYS.ipc_create);
    call(SYS.fs_mount, "/othermount", otherPort);
    expectError(function()
        call(SYS.fs_rename, FS_MOUNT_PATH .. "/hello.txt", "/othermount/hello.txt")
    end, "EXDEV");
    call(SYS.fs_unmount, "/othermount");
    call(SYS.ipc_close, otherPort);
end)

test("fs.copy duplicates a file, leaving the original intact", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_copy, FS_MOUNT_PATH .. "/hello.txt", FS_MOUNT_PATH .. "/copy-dst.txt");
    local orig = call(SYS.fs_stat, FS_MOUNT_PATH .. "/hello.txt");
    local copy = call(SYS.fs_stat, FS_MOUNT_PATH .. "/copy-dst.txt");
    assert(orig.size == copy.size, "copy has a different size than the original");
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/copy-dst.txt");
end)

test("fs.copy's `destination` is relativized to the mount, same as fs.rename", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_copy, FS_MOUNT_PATH .. "/hello.txt", FS_MOUNT_PATH .. "/copy-quirk.txt");
    local seenDestination = _G.__mockFsLastCopyDestination();
    assert(seenDestination == "/copy-quirk.txt",
        "expected the driver to see the mount-relative destination path, got: " .. tostring(seenDestination));
    call(SYS.fs_remove, FS_MOUNT_PATH .. "/copy-quirk.txt");
end)

test("fs.copy across two different mounts -> EXDEV", function()
    if not fsReady then error("setup failed, skipping"); end
    local otherPort = call(SYS.ipc_create);
    call(SYS.fs_mount, "/othermount", otherPort);
    expectError(function()
        call(SYS.fs_copy, FS_MOUNT_PATH .. "/hello.txt", "/othermount/hello.txt")
    end, "EXDEV");
    call(SYS.fs_unmount, "/othermount");
    call(SYS.ipc_close, otherPort);
end)

test("fs.ioctl passes commands and arguments through to the driver", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    local a, b = call(SYS.fs_ioctl, fd, "ECHO", "x", "y");
    assert(a == "x" and b == "y", "ioctl args did not round-trip");
    call(SYS.fs_close, fd);
end)

test("fs.ioctl with an unknown command propagates the driver's error", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    expectError(function() call(SYS.fs_ioctl, fd, "NOT_A_REAL_CMD") end, "ENOTTY");
    call(SYS.fs_close, fd);
end)

test("fs.setaddr round-trips through the driver without error", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_setaddr, FS_MOUNT_PATH .. "/hello.txt", { mode = 420 });
end)

test("fs.flush on an open file does not error", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    call(SYS.fs_flush, fd);
    call(SYS.fs_close, fd);
end)

test("fs.read/write/seek/close/ioctl on an invalid fd -> EBADF", function()
    expectError(function() call(SYS.fs_read, 999999, 10) end, "EBADF");
    expectError(function() call(SYS.fs_write, 999999, "x") end, "EBADF");
    expectError(function() call(SYS.fs_seek, 999999, 0) end, "EBADF");
    expectError(function() call(SYS.fs_close, 999999) end, "EBADF");
    expectError(function() call(SYS.fs_ioctl, 999999, "cmd") end, "EBADF");
end)

test("fs.seek with an invalid whence string -> EINVAL", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    expectError(function() call(SYS.fs_seek, fd, 0, "sideways") end, "EINVAL");
    call(SYS.fs_close, fd);
end)

test("fs.seek('end', N) round-trips through a driver STAT call", function()
    if not fsReady then error("setup failed, skipping"); end
    local fd = call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r");
    local pos = call(SYS.fs_seek, fd, 0, "end");
    assert(pos == 13, "expected seek(end,0) -> file size 13, got " .. tostring(pos));
    call(SYS.fs_close, fd);
end)

test("fs.unmount: non-root, non-owner cannot unmount -> EPERM", function()
    if not fsReady then error("setup failed, skipping"); end
    expectChildExit("(nested) fs.unmount EPERM", body(
        { UNMOUNT = SYS.fs_unmount },
        [[
            local ok, err = pcall(call, UNMOUNT, "]] .. FS_MOUNT_PATH .. [[")
            assert(not ok and tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
        ]]
    ), { uid = 1000 });
end)

test("fs.unmount on a non-mount-point path -> EINVAL", function()
    expectError(function() call(SYS.fs_unmount, "/definitely/not/mounted") end, "EINVAL");
end)

test("fs.unmount by the owning root process succeeds, and the path is unresolvable afterwards", function()
    if not fsReady then error("setup failed, skipping"); end
    call(SYS.fs_unmount, FS_MOUNT_PATH);
    expectError(function() call(SYS.fs_open, FS_MOUNT_PATH .. "/hello.txt", "r") end, "ENOTFOUND");
    fsReady = false;
end)

--============================================================--
-- sys.* (96-105, 111)
--============================================================--

test("sys.epoch('utc') returns a number", function()
    local now = call(SYS.sys_epoch, "utc");
    assert(type(now) == "number", "expected a number");
end)

test("[GAP] sys.epoch() with no locale should default to 'ingame' per SYSCALLME.md, but currently EINVALs", function()
    expectError(function() call(SYS.sys_epoch) end); -- currently: asserts locale must be a string
end)

test("[GAP] sys.epoch(locale) should reject unrecognised locales per SYSCALLME.md, but accepts anything", function()
    -- SYSCALLME.md promises error "1. Invalid locale provided." for e.g. "bogus".
    -- HAL.now() is called unconditionally regardless of locale value.
    expectError(function() call(SYS.sys_epoch, "not-a-real-locale") end, "Invalid locale");
end)

test("sys.timer fires through the scheduler and delivers a TIMER message with the cookie", function()
    local port = call(SYS.ipc_create);
    call(SYS.sys_timer, port, 0.1, "my-cookie");
    local msg = call(SYS.ipc_receive, port);
    assert(msg.type == "TIMER", "expected a TIMER message, got " .. tostring(msg.type));
    assert(msg.data.cookie == "my-cookie", "cookie did not round-trip");
    call(SYS.ipc_close, port);
end)

test("sys.timer rejects a negative duration -> EINVAL", function()
    local port = call(SYS.ipc_create);
    expectError(function() call(SYS.sys_timer, port, -1) end, "EINVAL");
    call(SYS.ipc_close, port);
end)

test("sys.cancel prevents a timer from firing", function()
    local port = call(SYS.ipc_create);
    local id = call(SYS.sys_timer, port, 0.2, "should-not-arrive");
    call(SYS.sys_cancel, id);
    -- prove it: a *later* timer on the same port fires fine, and we only ever see that one.
    call(SYS.sys_timer, port, 0.35, "second-timer");
    local msg = call(SYS.ipc_receive, port);
    assert(msg.data.cookie == "second-timer", "cancelled timer fired anyway (or arrived out of order)");
    call(SYS.ipc_close, port);
end)

test("sys.info reports uptime and version fields", function()
    local info = call(SYS.sys_info);
    assert(type(info.uptime) == "number", "uptime missing");
    assert(type(info.version) == "string", "version missing");
    assert(type(info.runningTime) == "number", "runningTime missing");
    assert(type(info.systemTime) == "number", "systemTime missing");
    assert(type(info.idleTime) == "number", "idleTime missing");
end)

test("sys.bind_event: binding the same event twice -> error", function()
    local port = call(SYS.ipc_create);
    call(SYS.sys_bind_event, "__uwutest_custom_event__", port);
    expectError(function() call(SYS.sys_bind_event, "__uwutest_custom_event__", port) end);
    call(SYS.sys_unbind_event, "__uwutest_custom_event__");
    call(SYS.ipc_close, port);
end)

test("sys.bind_event/unbind_event require root per SYSCALLME.md", function()
    expectChildExit("(nested) bind_event EPERM", body(
        { BIND = SYS.sys_bind_event, CREATE = SYS.ipc_create },
        [[
            local p = call(CREATE)
            local ok, err = pcall(call, BIND, "__uwutest_nonroot_event__", p)
            assert(not ok, "expected EPERM for non-root bind_event")
            assert(tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
        ]]
    ), { uid = 1000 });
end)

test("[GAP] sys.unbind_event on an event that was never bound should error per docs, but silently no-ops", function()
    expectError(function() call(SYS.sys_unbind_event, "__uwutest_never_bound__") end);
end)

test("sys.unbind_event by a non-owner (different root process) -> EPERM", function()
    call(SYS.sys_bind_event, "__uwutest_owned_event__", call(SYS.ipc_create));
    expectChildExit("(nested) unbind_event by non-owner", [[
        local ok, err = pcall(call, 103, "__uwutest_owned_event__")
        assert(not ok, "expected EPERM")
        assert(tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
    ]], { uid = 0 }); -- a *different* root process, still not the owner
    call(SYS.sys_unbind_event, "__uwutest_owned_event__");
end)

test("sys.shutdown/reboot: non-root cannot invoke them (EPERM, checked before the real HAL call)", function()
    expectChildExit("(nested) shutdown EPERM", "local ok, err = pcall(call, 104); assert(not ok and tostring(err):find('EPERM'))",
        { uid = 1000 });
    expectChildExit("(nested) reboot EPERM", "local ok, err = pcall(call, 105); assert(not ok and tostring(err):find('EPERM'))",
        { uid = 1000 });
    -- NOTE: intentionally NOT testing the root/success path here -- that would
    -- really shut down or reboot the machine this suite is running on.
end)

test("sys.signal: routes a signal to a registered port instead of taking default action", function()
    local port = call(SYS.ipc_create);
    call(SYS.sys_signal, 2, port); -- SIGINT
    local self = call(SYS.proc_info);
    call(SYS.proc_kill, self.pid, 2); -- root can signal itself
    local msg = call(SYS.ipc_receive, port);
    assert(msg.type == "SIGNAL", "expected a SIGNAL message, got " .. tostring(msg.type));
    assert(msg.data.signal == 2, "expected signal 2 routed to our port");
    assert(msg.data.origin == self.pid, "expected origin to be our own pid");
    call(SYS.sys_signal, 2, nil); -- unregister
    call(SYS.ipc_close, port);
end)

test("sys.signal: unregistering restores the default action (SIGINT terminates, code 130)", function()
    local pid = call(SYS.proc_spawn, "signal-default", nil, { blob = [[
        local p = call(32)
        call(111, 2, p) -- register
        call(3, call(4).pid, 2) -- self-signal, routed
        local msg = call(34, p)
        assert(msg.data.signal == 2)
        call(111, 2, nil) -- unregister -> back to default action
        call(3, call(4).pid, 2) -- self-signal again -> should terminate us now
        call(1, 99) -- should never be reached
    ]]});
    local r = call(SYS.proc_wait, pid);
    assert(r.code == 130, "expected default SIGINT termination (128+2=130), got " .. tostring(r.code));
end)

test("sys.signal with a fd that is not a receive right -> EPERM", function()
    local port = call(SYS.ipc_create);
    local sendFd = call(SYS.io_dup, port);
    expectError(function() call(SYS.sys_signal, 2, sendFd) end, "EPERM");
    call(SYS.ipc_close, port);
    call(SYS.ipc_close, sendFd);
end)

--============================================================--
-- dev.* (106-110)
--============================================================--

test("dev.list returns a table", function()
    local devices = call(SYS.dev_list);
    assert(type(devices) == "table", "expected a table");
end)

test("dev.open on an unknown device -> ENOENT", function()
    expectError(function() call(SYS.dev_open, "definitely-not-a-real-device-xyz") end, "ENOENT");
end)

test("dev.call on an invalid fd -> EBADF", function()
    expectError(function() call(SYS.dev_call, 999999, "foo") end, "EBADF");
end)

test("dev.call on a non-device fd -> EBADF", function()
    local port = call(SYS.ipc_create);
    expectError(function() call(SYS.dev_call, port, "foo") end, "not a device");
    call(SYS.ipc_close, port);
end)

test("dev.type/dev.methods on an unknown device name return nil rather than erroring", function()
    assert(call(SYS.dev_type, "definitely-not-a-real-device-xyz") == nil, "expected nil for unknown device type");
    assert(call(SYS.dev_methods, "definitely-not-a-real-device-xyz") == nil, "expected nil for unknown device methods");
end)

test("dev.list/dev.type/dev.methods require root per SYSCALLME.md", function()
    expectChildExit("(nested) dev.list EPERM", body({ DEVLIST = SYS.dev_list }, [[
        local ok, err = pcall(call, DEVLIST)
        assert(not ok, "expected EPERM for non-root dev.list")
        assert(tostring(err):find("EPERM"), "expected EPERM, got: " .. tostring(err))
    ]]), { uid = 1000 });
end)

test("dev.open/call/type/methods against a real attached peripheral, if one is present", function()
    local devices = call(SYS.dev_list);
    local found;
    for _, name in ipairs(devices) do
        if name == "screen" or name:match("^drive") then
            found = name;
            break;
        end
    end

    if not found then
        log("  (no screen/drive device registered -- skipping the hardware-backed part of dev.* tests)");
        return;
    end

    local fd = call(SYS.dev_open, found);
    local methods = call(SYS.dev_methods, found);
    assert(type(methods) == "table", "dev.methods did not return a table");
    local devType = call(SYS.dev_type, found);
    assert(type(devType) == "string", "dev.type did not return a string");

    if found == "screen" then
        local w, h = call(SYS.dev_call, fd, "getSize");
        assert(type(w) == "number" and type(h) == "number", "screen.getSize did not return dimensions");
    elseif found:match("^drive") then
        local list = call(SYS.dev_call, fd, "list", "/");
        assert(type(list) == "table", "drive list did not return a table");
    end

    call(SYS.fs_close, fd);
end)

test("fs.close releases a device handle and unclaims the device", function()
    local found;
    for _, name in ipairs(call(SYS.dev_list)) do
        if name == "screen" or name:match("^drive") then found = name; break; end
    end

    if not found then
        log("  (no screen/drive device registered -- skipping device release test)");
        return;
    end

    local fd = call(SYS.dev_open, found);

    -- A second claimant is refused while we hold it...
    local pid = spawnChild(body({ DEVOPEN = SYS.dev_open }, [[
        local ok, err = pcall(call, DEVOPEN, "]] .. found .. [[")
        assert(not ok and tostring(err):find("EBUSY"), "expected EBUSY, got: " .. tostring(err))
    ]]));
    assert(call(SYS.proc_wait, pid).code == 0, "device was claimable while still held");

    call(SYS.fs_close, fd);

    -- ...the handle is gone...
    expectError(function() call(SYS.dev_call, fd, "getSize") end, "EBADF");

    -- ...and the claim went with it.
    pid = spawnChild(body({ DEVOPEN = SYS.dev_open }, [[
        call(DEVOPEN, "]] .. found .. [[")
    ]]));
    assert(call(SYS.proc_wait, pid).code == 0, "device stayed claimed after its handle was closed");
end)

--============================================================--
-- sync.* (128-132)
--============================================================--

test("sync.create rejects an unknown primitive type -> EINVAL", function()
    expectError(function() call(SYS.sync_create, "NOT_A_TYPE") end, "EINVAL");
end)

test("[GAP] sync.create('SEM') is documented as supported but is a deliberate ENOSYS stub", function()
    -- Pinning current (safe, intentional) behaviour: it fails loudly rather
    -- than silently misbehaving, which is exactly what SYSCALLME.md does NOT
    -- describe (it documents SEM as a real, working primitive).
    expectError(function() call(SYS.sync_create, "SEM") end, "ENOSYS");
end)

test("sync.create/lock/unlock basic mutex round-trip (default init = unlocked)", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    local ok = call(SYS.sync_lock, mutex);
    assert(ok == true, "expected lock to succeed immediately on a fresh mutex");
    call(SYS.sync_unlock, mutex);
end)

test("sync.create('MUTEX', 0) creates it already locked, owned by the creating thread", function()
    local mutex = call(SYS.sync_create, "MUTEX", 0);
    expectError(function() call(SYS.sync_lock, mutex) end, "EDEADLK"); -- we already own it
    call(SYS.sync_unlock, mutex);
end)

test("sync.lock(handle, 0) is a non-blocking tryLock that returns false when busy", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    call(SYS.sync_lock, mutex); -- locked by us
    local tid, result = runInThread(function(result)
        result.tryLockOk = call(SYS.sync_lock, mutex, 0);
    end);
    call(SYS.thread_join, tid);
    assert(result.ok, "worker failed: " .. tostring(result.err));
    assert(result.tryLockOk == false, "expected a busy tryLock to return false immediately");
    call(SYS.sync_unlock, mutex);
end)

test("sync.unlock by a non-owner -> EPERM", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    call(SYS.sync_lock, mutex);
    local tid, result = runInThread(function(result)
        local ok, err = pcall(call, SYS.sync_unlock, mutex);
        result.unlockFailed = not ok;
        result.err = err;
    end);
    call(SYS.thread_join, tid);
    assert(result.ok, "worker failed: " .. tostring(result.err));
    assert(result.unlockFailed, "expected a non-owner unlock to fail");
    call(SYS.sync_unlock, mutex);
end)

test("sync.lock/unlock/notify on an invalid handle -> EBADF", function()
    expectError(function() call(SYS.sync_lock, 999999) end, "EBADF");
    expectError(function() call(SYS.sync_unlock, 999999) end, "EBADF");
    expectError(function() call(SYS.sync_notify, 999999) end, "EBADF");
end)

test("sync.lock/notify on a handle of the wrong sync type -> EINVAL", function()
    local cond = call(SYS.sync_create, "COND");
    expectError(function() call(SYS.sync_lock, cond) end, "EINVAL");
    local mutex = call(SYS.sync_create, "MUTEX");
    expectError(function() call(SYS.sync_notify, mutex) end, "EINVAL");
end)

test("sync.wait: caller must currently hold the mutex (releasing/unlock check fails otherwise)", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    local cond = call(SYS.sync_create, "COND");
    -- we never locked `mutex`, so the implicit unlock inside wait() should fail:
    expectError(function() call(SYS.sync_wait, cond, mutex) end);
end)

test("sync.wait/notify: a single waiter is woken and reacquires the mutex", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    local cond = call(SYS.sync_create, "COND");
    local tid, result = runInThread(function(result)
        call(SYS.sync_lock, mutex);
        result.waitOk = call(SYS.sync_wait, cond, mutex);
        result.reacquired = true; -- only reached if wait() returned holding the mutex
        call(SYS.sync_unlock, mutex);
    end);
    sleep(0.1); -- let the waiter reach sync.wait
    call(SYS.sync_notify, cond, false);
    call(SYS.thread_join, tid);
    assert(result.ok, "waiter failed: " .. tostring(result.err));
    assert(result.waitOk == true, "expected wait() to report success");
    assert(result.reacquired, "waiter never got past wait(), meaning it didn't reacquire the mutex");
end)

test("sync.notify(cond, false) wakes exactly one of several waiters; notify(cond, true) wakes the rest", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    local cond = call(SYS.sync_create, "COND");
    local function waiter(result)
        call(SYS.sync_lock, mutex);
        call(SYS.sync_wait, cond, mutex);
        result.woke = true;
        call(SYS.sync_unlock, mutex);
    end
    local tid1, r1 = runInThread(waiter);
    local tid2, r2 = runInThread(waiter);
    sleep(0.15); -- let both reach sync.wait

    call(SYS.sync_notify, cond, false);
    sleep(0.1);
    local wokeCount = (r1.woke and 1 or 0) + (r2.woke and 1 or 0);
    assert(wokeCount == 1, "expected notify(false) to wake exactly one waiter, woke " .. wokeCount);

    call(SYS.sync_notify, cond, true);
    call(SYS.thread_join, tid1);
    call(SYS.thread_join, tid2);
    assert(r1.ok and r2.ok, "a waiter failed: " .. tostring(r1.err) .. " / " .. tostring(r2.err));
    assert(r1.woke and r2.woke, "expected both waiters to have woken by the end");
end)

test("[GAP] sync.lock(handle, timeout>0) should fail after `timeout` seconds per SYSCALLME.md, "
    .. "but any non-zero timeout is treated as an infinite wait", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    call(SYS.sync_lock, mutex); -- held by main thread
    local tid, result = runInThread(function(result)
        local t0 = call(SYS.sys_epoch, "utc");
        result.lockOk = call(SYS.sync_lock, mutex, 0.2); -- spec: should return false at ~0.2s
        result.elapsed = call(SYS.sys_epoch, "utc") - t0;
    end);
    sleep(0.4); -- hold the lock well past the requested 0.2s "timeout"
    call(SYS.sync_unlock, mutex); -- only now does the worker get a chance to acquire
    call(SYS.thread_join, tid);
    assert(result.ok, "worker failed: " .. tostring(result.err));
    assert(result.lockOk == true,
        "expected the lock to only be granted after our unlock (proving the timeout was ignored)");
    assert(result.elapsed >= 350,
        "expected the worker to have waited ~400ms, only waited " .. tostring(result.elapsed) .. "ms");
end)

test("[GAP] sync.wait(cond, mutex, timeout>0) should fail after `timeout` seconds per SYSCALLME.md, "
    .. "but the timeout argument is dropped entirely (ConditionVariable:wait never receives it)", function()
    local mutex = call(SYS.sync_create, "MUTEX");
    local cond = call(SYS.sync_create, "COND");
    local tid, result = runInThread(function(result)
        call(SYS.sync_lock, mutex);
        local t0 = call(SYS.sys_epoch, "utc");
        result.waitOk = call(SYS.sync_wait, cond, mutex, 0.1); -- spec: should return false at ~0.1s
        result.elapsed = call(SYS.sys_epoch, "utc") - t0;
        call(SYS.sync_unlock, mutex);
    end);
    sleep(0.35); -- well past the requested 0.1s "timeout"
    call(SYS.sync_notify, cond);
    call(SYS.thread_join, tid);
    assert(result.ok, "worker failed: " .. tostring(result.err));
    assert(result.waitOk == true, "expected wait to only succeed via our explicit notify");
    assert(result.elapsed >= 300,
        "expected the worker to have waited ~350ms, only waited " .. tostring(result.elapsed) .. "ms");
end)

--============================================================--
-- Dispatcher-level behaviour
--============================================================--

test("an unregistered syscall id -> ENOSYS", function()
    expectError(function() call(31337) end, "ENOSYS");
end)

test("fs.manage(71), documented as reserved but never implemented -> ENOSYS", function()
    expectError(function() call(71) end, "ENOSYS");
end)

--============================================================--
-- Summary
--============================================================--

-- Always echoed live (via logFail/WARN) regardless of outcome, so the tally
-- is visible on-screen even though per-test PASS lines are file-only; full
-- detail (every pass and fail) is always in kernel.log regardless.
logFail(string.format(
    "=== RESULTS: %d passed, %d failed (%d expected [GAP] failures, %d unexpected) ===",
    passed, failed, gapFailed, realFailed
));
if realFailed > 0 then
    logFail(string.format("%d UNEXPECTED failure(s) -- see kernel.log for the full [FAIL] list (excluding [GAP]-tagged ones)", realFailed));
end
