local color = {}

function color.packRGB(r, g, b)
    return bit32.bor(
        a or 0,
        bit32.lshift(b or 0, 8),
        bit32.lshift(g or 0, 16)
    )
end

function color.unpackRGB(packed)
    return table.unpack({
        bit32.band(0xff, bit32.rshift(packed, 16)),
        bit32.band(0xff, bit32.rshift(packed, 8)),
        bit32.band(0xff, packed)
    })
end

function color.packRGBA(r, g, b, a)
    return bit32.bor(
        a or 0,
        bit32.lshift(b or 0, 8),
        bit32.lshift(g or 0, 16),
        bit32.lshift(r or 0, 24)
    )
end

function color.unpackRGBA(packed)
    return table.unpack({
        bit32.band(0xff, bit32.rshift(packed, 24)),
        bit32.band(0xff, bit32.rshift(packed, 16)),
        bit32.band(0xff, bit32.rshift(packed, 8)),
        bit32.band(0xff, packed)
    })
end

return color
