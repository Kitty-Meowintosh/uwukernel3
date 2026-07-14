-- if require then
--     local lastPoint = chip.getUnixTime();
--     local toggled = false;
--     while true do
--         if chip.getUnixTime() - lastPoint > 1 then
--             if toggled then
--                 headsup.clear();
--                 headsup.draw();
--                 toggled = false;
--             else 
--                 headsup.drawPixel(1, 1);
--                 headsup.draw();
--                 toggled = true;
--             end

--             lastPoint = chip.getUnixTime();
--         end

--         coroutine.yield();
--     end
-- else
--     chip.crash("nope!");
-- end

local HAL = require("hal");
local DeviceManager = require("dev.DeviceManager");
local ProcessManager = require("proc.ProcessManager");
local Scheduler = require("core.Scheduler");

HAL.clear();
HAL.print("Booting UwUKernel3...");

DeviceManager.onStartup();

local blob;
if HAL.backend == "cc" then
    local handle = fs.open("test.lua", "r");
    blob = handle.readAll();
    handle.close();
elseif HAL.backend == "neet" then
    local handle = HAL.files.open("system:/test.lua", "r", 0);
    blob = handle.read("a");
    handle.close();
end

ProcessManager.spawn(0, "test.lua", {}, { blob = blob });
Scheduler.run();

