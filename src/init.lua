local HAL = require("hal");
local DeviceManager = require("dev.DeviceManager");
local ProcessManager = require("proc.ProcessManager");
local Scheduler = require("core.Scheduler");

local INIT_PATH_CC   = "/Core/launchd/init.lua";
local INIT_PATH_NEET = "system:/Core/launchd/init.lua";
local TEST_PATH_CC = "/Core/kernel/test.lua";
local TEST_PATH_NEET = "system:/Core/kernel/test.lua";

local Kernel = {};

function Kernel.run()
    HAL.clear();

    DeviceManager.onStartup();

    local blob;
    local testBlob;
    if HAL.backend == "cc" then
        local handle0 = fs.open(INIT_PATH_CC, "r");
        blob = handle0.readAll();
        handle0.close();

        local handle1 = fs.open(TEST_PATH_CC);
        testBlob = handle1.readAll();
        handle1.close();
    elseif HAL.backend == "neet" then
        local handle0 = HAL.files.open(INIT_PATH_NEET, "r", 0);
        blob = handle0.read("a");
        handle0.close();

        local handle1 = HAL.files.open(TEST_PATH_NEET, "r", 0);
        testBlob = handle1.read("a");
        handle1.close();
    end

    -- ProcessManager.spawn(0, "init.lua", {}, { blob = blob, name = "launchd" });
    ProcessManager.spawn(0, "test.lua", {}, { blob = testBlob, name = "tests" });
    Scheduler.run();
end

return Kernel;
