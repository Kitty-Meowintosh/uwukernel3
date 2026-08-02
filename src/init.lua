local HAL = require("hal");
local DeviceManager = require("dev.DeviceManager");
local ProcessManager = require("proc.ProcessManager");
local Scheduler = require("core.Scheduler");

local INIT_PATH_CC   = "/Core/launchd/init.lua";
local INIT_PATH_NEET = "system:/Core/launchd/init.lua";

local Kernel = {};

function Kernel.run()
    HAL.clear();

    DeviceManager.onStartup();

    local blob;
    if HAL.backend == "cc" then
        local handle = fs.open(INIT_PATH_CC, "r");
        blob = handle.readAll();
        handle.close();
    elseif HAL.backend == "neet" then
        local handle = HAL.files.open(INIT_PATH_NEET, "r", 0);
        blob = handle.read("a");
        handle.close();
    end

    ProcessManager.spawn(0, "init", {}, { blob = blob });
    Scheduler.run();
end

return Kernel;
