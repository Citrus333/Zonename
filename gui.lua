-- gui.lua
-- ImGui-based settings window for the zonename addon.
-- Lets the user interactively resize, reposition, recolor, and change
-- the font of the zone name and region name text, with a live preview,
-- and persist the changes to disk.

local imgui = require('imgui')
local chat = require('chat')
local scaling = require('scaling')
local colorutils = require('colorutils')

local gui = {}

-- Wrapped in a table because imgui.Begin expects a ref for its
-- "show close button" / open-state argument.
gui.is_open = { false }

-- Injected from zonename.lua via gui.initialise() so this module doesn't
-- need to know about zonename's internals directly.
local ctx = nil
local was_open = false

--- Wires the gui module up with what it needs from the main addon.
---@param context table {
---   settings   = zonename.settings table (persisted settings),
---   defaults   = zonename.defaults table (used for "reset to default"),
---   on_change  = function() -- called whenever a value changes, should
---                             push the new values onto the live gdi
---                             text objects,
---   save       = function() -- called to persist settings to disk,
---   set_preview = function(is_open) -- called when the gui opens/closes
---                                     so the addon can show/hide sample
---                                     text for a live preview,
---   check_font_available = function(family) -- returns true/false,
--- }
function gui.initialise(context)
    ctx = context
end

function gui.toggle()
    gui.is_open[1] = not gui.is_open[1]
end

function gui.open()
    gui.is_open[1] = true
end

function gui.close()
    gui.is_open[1] = false
end

-- gdi:get_font_available() appears to allocate a real font resource
-- under the hood to test availability. Calling it every rendered frame
-- (as the status indicator below used to) leaks a handle per call and
-- will eventually exhaust the process's GDI handle limit, breaking
-- font lookups entirely. This cache makes sure we only ever call it
-- when the font name being checked has actually changed.
local font_availability_cache = {}

local function isFontAvailable(cache_key, family, check_font_available)
    if not check_font_available then
        return true
    end
    if type(family) ~= 'string' or family == '' then
        return false
    end
    local cached = font_availability_cache[cache_key]
    if cached and cached.family == family then
        return cached.available
    end
    local available = check_font_available(family)
    font_availability_cache[cache_key] = { family = family, available = available }
    return available
end

-- Draws the controls for a single text element (zone name or region name).
-- Returns true if anything changed this frame.
local function draw_font_section(label, font_settings, default_settings, check_font_available)
    local changed = false

    imgui.PushID(label)
    imgui.Text(label)
    imgui.Separator()

    -- Size / outline
    local height = { font_settings.font_height }
    if imgui.SliderInt('Font Size', height, 8, 400) then
        font_settings.font_height = height[1]
        changed = true
    end

    local outline = { font_settings.outline_width }
    if imgui.SliderInt('Outline Width', outline, 0, 10) then
        font_settings.outline_width = outline[1]
        changed = true
    end

    imgui.Spacing()

    -- Position
    local pos_x = { font_settings.position_x }
    if imgui.SliderFloat('Position X', pos_x, 0, scaling.window.w) then
        font_settings.position_x = pos_x[1]
        changed = true
    end

    local pos_y = { font_settings.position_y }
    if imgui.SliderFloat('Position Y', pos_y, 0, scaling.window.h) then
        font_settings.position_y = pos_y[1]
        changed = true
    end

    imgui.Spacing()

    -- Colors
    local text_color = colorutils.to_rgba_floats(font_settings.font_color)
    if imgui.ColorEdit4('Text Color', text_color) then
        font_settings.font_color = colorutils.from_rgba_floats(text_color)
        changed = true
    end

    local outline_color = colorutils.to_rgba_floats(font_settings.outline_color)
    if imgui.ColorEdit4('Outline Color', outline_color) then
        font_settings.outline_color = colorutils.from_rgba_floats(outline_color)
        changed = true
    end

    imgui.Spacing()

    -- Gradient. When enabled, "Text Color" above is ignored in favor of
    -- a left-to-right blend between these two colors.
    local gradient_enabled = { font_settings.gradient_enabled or false }
    if imgui.Checkbox('Gradient Text Color', gradient_enabled) then
        font_settings.gradient_enabled = gradient_enabled[1]
        changed = true
    end

    if font_settings.gradient_enabled then
        local grad_start = colorutils.to_rgba_floats(font_settings.gradient_start_color)
        if imgui.ColorEdit4('Gradient Start', grad_start) then
            font_settings.gradient_start_color = colorutils.from_rgba_floats(grad_start)
            changed = true
        end

        local grad_end = colorutils.to_rgba_floats(font_settings.gradient_end_color)
        if imgui.ColorEdit4('Gradient End', grad_end) then
            font_settings.gradient_end_color = colorutils.from_rgba_floats(grad_end)
            changed = true
        end

        local spacing = { font_settings.gradient_letter_spacing or 1.0 }
        if imgui.SliderFloat('Letter Spacing', spacing, 0.3, 2.5) then
            font_settings.gradient_letter_spacing = spacing[1]
            changed = true
        end
        imgui.TextDisabled('If letters look wrong, adjust this until spacing looks right.')
        imgui.TextDisabled('Character spacing is approximate, not pixel-perfect kerning.')
    end

    imgui.Spacing()

    -- Font family. Applied only when Enter is pressed (not on every
    -- keystroke) and only if the font is actually available, so a
    -- half-typed or invalid font name never reaches the renderer.
    local family = { font_settings.font_family or '' }
    local family_submitted = imgui.InputText('Font Family', family, 64, ImGuiInputTextFlags_EnterReturnsTrue)

    if check_font_available then
        if isFontAvailable(label, font_settings.font_family, check_font_available) then
            imgui.TextColored({ 0.3, 1, 0.3, 1 }, 'Font available')
        else
            imgui.TextColored({ 1, 0.4, 0.4, 1 }, 'Font not available (will fall back)')
        end
    end
    imgui.TextDisabled('Press Enter to apply')

    if family_submitted then
        local candidate = family[1]
        local valid = type(candidate) == 'string' and candidate ~= ''
            and isFontAvailable(label, candidate, check_font_available)
        if valid then
            font_settings.font_family = candidate
            changed = true
        else
            imgui.TextColored({ 1, 0.4, 0.4, 1 }, 'Font not found - not applied')
        end
    end

    imgui.Spacing()
    if imgui.Button('Reset to Default') then
        font_settings.font_height = default_settings.font_height
        font_settings.outline_width = default_settings.outline_width
        font_settings.position_x = default_settings.position_x
        font_settings.position_y = default_settings.position_y
        font_settings.font_color = default_settings.font_color
        font_settings.outline_color = default_settings.outline_color
        font_settings.font_family = default_settings.font_family
        font_settings.gradient_enabled = default_settings.gradient_enabled
        font_settings.gradient_start_color = default_settings.gradient_start_color
        font_settings.gradient_end_color = default_settings.gradient_end_color
        font_settings.gradient_letter_spacing = default_settings.gradient_letter_spacing
        changed = true
    end

    imgui.PopID()
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    return changed
end

function gui.draw()
    if ctx == nil then
        return
    end

    -- Fire the preview callback exactly once when the window opens/closes.
    if gui.is_open[1] ~= was_open then
        was_open = gui.is_open[1]
        if ctx.set_preview then
            ctx.set_preview(gui.is_open[1])
        end
    end

    if not gui.is_open[1] then
        return
    end

    imgui.SetNextWindowSize({ 380, 720 }, ImGuiCond_FirstUseEver)
    local ok, err = pcall(function()
        if imgui.Begin('Zone Name Settings', gui.is_open) then
            local changed = false

            if draw_font_section('Zone Name', ctx.settings.zone_name, ctx.defaults.zone_name, ctx.check_font_available) then
                changed = true
            end

            if draw_font_section('Region Name', ctx.settings.region_name, ctx.defaults.region_name, ctx.check_font_available) then
                changed = true
            end

            if imgui.Button('Save') then
                if ctx.save then ctx.save() end
            end
            imgui.SameLine()
            if imgui.Button('Close') then
                gui.close()
            end

            if changed and ctx.on_change then
                ctx.on_change()
            end
        end
        imgui.End()
    end)

    if not ok then
        -- imgui.End() may not have run if the error happened mid-window;
        -- make a best effort to keep the imgui stack balanced, then bail
        -- out of the gui entirely rather than risk crashing every frame.
        pcall(imgui.End)
        print(chat.header(addon.name):append(chat.error('GUI error, closing settings window: %s'):format(tostring(err))))
        gui.close()
        was_open = false
        return
    end

    -- Window was closed via its own [x] button rather than our Close
    -- button; make sure the preview callback still fires next frame.
    if not gui.is_open[1] and was_open then
        was_open = false
        if ctx.set_preview then
            ctx.set_preview(false)
        end
    end
end

return gui
