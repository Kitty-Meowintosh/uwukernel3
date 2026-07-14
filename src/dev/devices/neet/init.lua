local HAL = require("hal");
local DeviceRegistry = require("dev.DeviceRegistry");
local Screen = require("dev.devices.neet.Screen");
local Headsup = require("dev.devices.neet.Headsup");
local Internet = require("dev.devices.neet.Internet");
local Drive = require("dev.devices.neet.Drive");
local Peripheral = require("dev.devices.neet.Peripheral");

local neet = {};

--- Registers every NEET device that exists at boot: the built-ins, one
--- drive per physical disk, and whatever peripherals are already attached.
function neet.register()
    DeviceRegistry.register("screen", Screen.new());
    DeviceRegistry.register("headsup", Headsup.new());
    DeviceRegistry.register("internet", Internet.new());

    for disk = 0, HAL.files.getNumberOfDisks() - 1 do
        DeviceRegistry.register("drive" .. disk, Drive.new(disk));
    end

    for _, id in ipairs(io.getPeripherals()) do
        DeviceRegistry.register(id, Peripheral.new(id));
    end
end

return neet;
