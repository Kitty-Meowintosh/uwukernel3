local KERNEL_DIR_CC   = "/System/Library/Kernel";
local KERNEL_DIR_NEET = "0:system:/System/Library/Kernel";

local function detectBackend()
    if _G.chip and chip.version then
        return "neet";
    end

    if _G.os and os.version and os.version():find("CraftOS") then
        return "cc";
    end

    error("boot: unable to detect a supported platform");
end

local kernelDir = detectBackend() == "neet" and KERNEL_DIR_NEET or KERNEL_DIR_CC;

package.path = table.concat({
    package.path,
    kernelDir .. "/?.lua",
    kernelDir .. "/?/init.lua",
}, ";");

require("init").run();
