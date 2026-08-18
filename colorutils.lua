-- colorutils.lua
-- Small shared helpers for packing/unpacking 0xAARRGGBB colors (the
-- format used throughout gdifonts settings) and interpolating between
-- two of them, used by both gui.lua (color pickers) and zonename.lua
-- (gradient text rendering).

local bit = require('bit')

local M = {}

function M.unpack(color)
    local a = bit.band(bit.rshift(color, 24), 0xFF)
    local r = bit.band(bit.rshift(color, 16), 0xFF)
    local g = bit.band(bit.rshift(color, 8), 0xFF)
    local b = bit.band(color, 0xFF)
    return a, r, g, b
end

function M.pack(a, r, g, b)
    return bit.bor(bit.lshift(a, 24), bit.lshift(r, 16), bit.lshift(g, 8), b)
end

-- Converts a packed 0xAARRGGBB color into an {r, g, b, a} table of
-- floats in the 0..1 range, as expected by imgui.ColorEdit4.
function M.to_rgba_floats(color)
    local a, r, g, b = M.unpack(color)
    return { r / 255, g / 255, b / 255, a / 255 }
end

-- Converts an {r, g, b, a} table of floats in the 0..1 range back into
-- a packed 0xAARRGGBB color.
function M.from_rgba_floats(rgba)
    local r = math.floor(rgba[1] * 255 + 0.5)
    local g = math.floor(rgba[2] * 255 + 0.5)
    local b = math.floor(rgba[3] * 255 + 0.5)
    local a = math.floor(rgba[4] * 255 + 0.5)
    return M.pack(a, r, g, b)
end

-- Linearly interpolates between two packed colors. t=0 returns colorA,
-- t=1 returns colorB.
function M.interpolate(colorA, colorB, t)
    local aA, rA, gA, bA = M.unpack(colorA)
    local aB, rB, gB, bB = M.unpack(colorB)
    return M.pack(
        math.floor(aA + (aB - aA) * t + 0.5),
        math.floor(rA + (rB - rA) * t + 0.5),
        math.floor(gA + (gB - gA) * t + 0.5),
        math.floor(bA + (bB - bA) * t + 0.5)
    )
end

return M
