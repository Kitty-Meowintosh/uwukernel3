-- Minimal debug console for NEET, backing HAL.print.
local loadFont = require("hal.font.psf");

local FONT_PATH = "system:/System/Library/Kernel/hal/font/default.psf";

-- Font.drawLine advances (glyphWidth + charSpacing) per character and defaults
-- charSpacing to 1; mirrored here so the wrap width matches what is drawn.
local CHAR_SPACING = 1;
local TAB_WIDTH = 4;

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

--- How many glyphs fit on one row. The trailing character needs no spacing
--- after it, hence the + CHAR_SPACING before the division.
local function columns(f)
    local screenWidth = screen.getSize();
    local perChar = f.getWidth() + CHAR_SPACING;
    return math.max(1, math.floor((screenWidth + CHAR_SPACING) / perChar));
end

--- Draws one already-fitting row and advances the cursor. Glyphs are drawn
--- with a transparent background, so a full screen is cleared rather than
--- overdrawn -- otherwise the new text lands on top of the old.
local function drawRow(f, str)
    local _, screenHeight = screen.getSize();

    if cursorY + f.getHeight() > screenHeight then
        screen.fill(0, 0, 0);
        cursorY = 0;
    end

    if #str > 0 then
        f.drawLine(0, cursorY, str);
    end

    cursorY = cursorY + f.getHeight();
end

function console.print(text)
    local f = ensureFont();
    local width = columns(f);

    -- Tabs and carriage returns have no glyph -- a Lua traceback is full of
    -- both -- and would otherwise be drawn as whatever sits at index 9/13.
    local body = tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", string.rep(" ", TAB_WIDTH));

    -- gmatch needs every row newline-terminated to see the last one; a caller's
    -- own trailing newline already ends its row, so it isn't doubled.
    if body:sub(-1) ~= "\n" then body = body .. "\n" end

    for line in body:gmatch("([^\n]*)\n") do
        if #line == 0 then
            drawRow(f, "");
        else
            for start = 1, #line, width do
                drawRow(f, line:sub(start, start + width - 1));
            end
        end
    end

    screen.draw();
end

return console;
