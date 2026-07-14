local HAL = require("hal")
local color = require("hal.font.color")

function readUInt(handle, size)
    local bytes = handle.read(size)
    if not bytes or #bytes < size then return nil end
    local value = 0
    for i = 1, size do
        value = value + string.byte(bytes, i) * (256 ^ (i - 1))
    end
    return math.floor(value)
end

local PSF1_FONT_MAGIC = 0x0436
local PSF2_FONT_MAGIC = 0x864ab572
function loadFont(path, disk)
    local Font = {}

    local handle = HAL.files.open(path, "rb", disk or 0)

    local numGlyphs, bytesPerGlyph, glyphWidth, glyphHeight

    -- PSF1: 2 byte magic, 1 byte mode, 1 byte charsize. Width is always 8.
    local magic16 = readUInt(handle, 2)
    if magic16 == PSF1_FONT_MAGIC then
        local mode = readUInt(handle, 1)
        local charsize = readUInt(handle, 1)

        numGlyphs = (bit32.band(mode, 0x01) == 1) and 512 or 256
        glyphWidth = 8
        glyphHeight = charsize
        bytesPerGlyph = charsize
    else
        -- PSF2: 4 byte magic (2 already read), version, headerSize, flags, then counts.
        local magic32 = magic16 + readUInt(handle, 2) * 65536
        if magic32 ~= PSF2_FONT_MAGIC then return nil end

        local version = readUInt(handle, 4)
        if version ~= 0 then return nil end
        local headerSize = readUInt(handle, 4)
        local flags = readUInt(handle, 4)
        numGlyphs = readUInt(handle, 4)
        bytesPerGlyph = readUInt(handle, 4)
        glyphHeight = readUInt(handle, 4)
        glyphWidth = readUInt(handle, 4)

        if handle.seek() ~= headerSize then
            handle.seek("set", headerSize)
        end
    end

    local glyphs = {}
    for glyphNum = 0, numGlyphs - 1 do
        local glyph = {}
        for byteNum = 1, bytesPerGlyph do
            local byte = readUInt(handle, 1)
            for bitNum = 7, 0, -1 do
                table.insert(glyph, bit32.band(1, bit32.rshift(byte, bitNum)))
            end
        end
        glyphs[glyphNum] = glyph
    end

    function Font.drawChar(x, y, char, options)
        options = options or {}
        local background = options.background or 0
        local foreground = options.foreground or 0xffffffff
        local layer = options.layer or screen

        local glyph = glyphs[string.byte(char)]
        local buffer = {}
        for _,pixel in ipairs(glyph) do
            local r, g, b, a = color.unpackRGBA(pixel == 1 and foreground or background)
            table.insert(buffer, r)
            table.insert(buffer, g)
            table.insert(buffer, b)
            table.insert(buffer, a)
        end
        layer.drawPixels(x, y, buffer, glyphWidth, glyphHeight)
    end

    function Font.drawLine(x, y, str, options)
        options = options or {}
        local background = options.background or 0
        local foreground = options.foreground or 0xffffffff
        local charSpacing = options.charSpasing or 1
        local layer = options.layer or screen

        for i = 1, #str do
            local char = string.sub(str, i, i+1)
            local glyphX = x + (glyphWidth + charSpacing) * (i - 1)
            Font.drawChar(glyphX, y, char, options)
            local buffer = {}
            for _ = 1, glyphHeight * charSpacing do
                local r, g, b, a = color.unpackRGBA(background)
                table.insert(buffer, r)
                table.insert(buffer, g)
                table.insert(buffer, b)
                table.insert(buffer, a)
            end

            if i ~= #str then
                local spx = glyphX + glyphWidth
                layer.drawPixels(spx, y, buffer, charSpacing, glyphHeight)
            end
        end
    end

    function Font.getWidth()
        return glyphWidth
    end

    function Font.getHeight()
        return glyphHeight
    end

    function Font.getSize()
        return glyphWidth, glyphHeight
    end

    return Font
end

return loadFont
