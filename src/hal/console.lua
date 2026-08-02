-- Minimal debug console for NEET, backing HAL.print.
local loadFont = require("hal.font.psf");

local FONT_PATH = "system:/Core/kernel/hal/font/default.psf";

local console = {};
local font;
local cursorY = 0;

local function ensureFont()
    if not font then
        font = loadFont(FONT_PATH);
        if not font then
            error("HAL console: failed to load font at " .. FONT_PATH);
        end
    end
    return font;
end

function console.clear()
    screen.fill(0, 0, 0);
    cursorY = 0;
    screen.draw();
end

function console.print(text)
    local f = ensureFont();
    local _, screenHeight = screen.getSize();

    if cursorY + f.getHeight() > screenHeight then
        cursorY = 0;
    end

    f.drawLine(0, cursorY, tostring(text));
    cursorY = cursorY + f.getHeight();
    screen.draw();
end

return console;
