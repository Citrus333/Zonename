-- This is an addon for Ashita v4 that displays zone and region names
-- with fading effects. It is a port of Windowers zonename addon.
-- Original code by [sylandro].

-- Define addon information
addon.name = 'zonename'
addon.author = 'Xenonsmurf. Japanese support and other improvements by onimitch.'
addon.version = '2.3'
addon.desc = 'Displays the zone and region name for a short time while changing zones.'
addon.link = 'https://github.com/onimitch/ffxi-zonename'

-- Import necessary modules and libraries
require('common')  -- Import a common utility module
local chat = require("chat")
local settings = require('settings')  -- Module for managing settings
local gdi = require('gdifonts.include')
local encoding = require('gdifonts.encoding')
local imgui = require('imgui')
local gui = require('gui')
local colorutils = require('colorutils')

local scaling = require('scaling')
local screenCenter = {
    x = scaling.window.w / 2,
    y = scaling.window.h / 2,
}

-- Zone name settings and objects
local zonename = {
    visible = false,
    zone_name_text = nil,
    region_name_text = nil,
    lang_id = 'en',
    fade_start_time = nil,

    -- Tracks whatever string is currently set on each text object (real
    -- zone/region name, or the gui's sample preview text) so the font
    -- size can be re-fitted to it if the user changes the size slider
    -- while previewing.
    current_zone_text = '',
    current_region_text = '',

    -- When gradient_enabled is set for a section, that section is
    -- rendered as one small gdi text object per character (each with
    -- an interpolated color) instead of the single zone_name_text /
    -- region_name_text object, so a smooth left-to-right blend can be
    -- drawn even though the underlying font library only supports one
    -- solid color per object.
    zone_name_chars = {},
    region_name_chars = {},

    regions = require("regions"),
    region_zones = require("regionZones"),

    -- Settings defaults
    defaults = T{
        fade_after = 5,
        fade_duration = 1,
        zone_name = {
            font_alignment = gdi.Alignment.Center,
            font_color = 0xFFFFD700,
            font_family = 'Beleren2016', -- This could be Arial but we need to use a font that is most likely installed by default
            font_flags = gdi.FontFlags.Bold,
            font_height = 50,
            outline_color = 0xFF0041AB,
            outline_width = 2,
            position_x = screenCenter.x,
            position_y = screenCenter.y - 340,
            gradient_enabled = false,
            gradient_start_color = 0xFFFFD700,
            gradient_end_color = 0xFFFFFFFF,
            gradient_letter_spacing = 1.0,
        },
        region_name = {
            font_alignment = gdi.Alignment.Center,
            font_color = 0xFFFFD700,
            font_family = 'Beleren2016', -- This could be Arial but we need to use a font that is most likely installed by default
            font_flags = gdi.FontFlags.Bold,
            font_height = 25,
            outline_color = 0xFF0041AB,
            outline_width = 2,
            position_x = screenCenter.x,
            position_y = screenCenter.y - 370,
            gradient_enabled = false,
            gradient_start_color = 0xFFFFD700,
            gradient_end_color = 0xFFFFFFFF,
            gradient_letter_spacing = 1.0,
        },
    },
}

-- Function to get the region name by region ID
local function getRegionNameById(id)
    for _, region in pairs(zonename.regions) do
        if region.id == id then
            return region[zonename.lang_id]
        end
    end
    return nil
end

-- Function to get the region ID by zone ID
local function getRegionIDByZoneID(zoneID)
    for regionID, zoneIDs in pairs(zonename.region_zones.map) do
        for _, id in ipairs(zoneIDs) do
            if id == zoneID then
                return regionID
            end
        end
    end
    return nil
end

-- Fraction of the screen width text is allowed to occupy before it gets
-- shrunk to fit. Leaves a small margin on both sides.
local TEXT_WIDTH_SCREEN_MARGIN = 0.92

-- Used only if the gdi text object doesn't expose a way to measure its
-- own rendered width (see measureTextWidth below): a rough estimate of
-- average glyph width relative to font height for a typical bold
-- display font. Not exact, but enough to act as a safety clamp.
local FALLBACK_CHAR_WIDTH_RATIO = 0.6

local MIN_FONT_HEIGHT = 8

-- Best-effort measurement of a gdi text object's current rendered pixel
-- width. Prefers the library's own measurement if it exposes one (tried
-- via pcall since we can't be sure which method name, if any, exists);
-- falls back to a rough character-count estimate otherwise.
local function measureTextWidth(text_obj, text, font_height)
    for _, method in ipairs({ 'get_width', 'get_text_width', 'get_extents' }) do
        if type(text_obj[method]) == 'function' then
            local ok, result = pcall(function() return text_obj[method](text_obj) end)
            if ok then
                if type(result) == 'number' and result > 0 then
                    return result
                elseif type(result) == 'table' and type(result.width) == 'number' and result.width > 0 then
                    return result.width
                end
            end
        end
    end
    return (text and #text or 0) * font_height * FALLBACK_CHAR_WIDTH_RATIO
end

-- Sets text on a gdi text object at the given preferred font height, then
-- shrinks the font (on the live object only - never touching the saved
-- setting) just enough that the rendered text stays within the screen
-- width, so long zone/region names never get clipped at the screen edges.
local function setTextFitted(text_obj, text, preferredHeight)
    text_obj:set_text(text)
    text_obj:set_font_height(preferredHeight)

    local maxWidth = scaling.window.w * TEXT_WIDTH_SCREEN_MARGIN
    local width = measureTextWidth(text_obj, text, preferredHeight)
    if width > maxWidth then
        local scale = maxWidth / width
        local newHeight = math.max(MIN_FONT_HEIGHT, math.floor(preferredHeight * scale))
        if newHeight < preferredHeight then
            text_obj:set_font_height(newHeight)
        end
    end
end

-- Destroys all per-character gdi objects for a section (identified by
-- its chars_key, e.g. 'zone_name_chars') and clears the array. Safe to
-- call even if there's nothing to destroy, and deliberately doesn't
-- depend on zonename.settings/text_obj being set up yet, since this
-- also runs during initialise().
local function destroyCharsByKey(chars_key)
    for _, obj in ipairs(zonename[chars_key]) do
        pcall(function() gdi:destroy_object(obj) end)
    end
    zonename[chars_key] = {}
end

local function destroyChars(which)
    destroyCharsByKey(which == 'zone' and 'zone_name_chars' or 'region_name_chars')
end

-- Bundles together the pieces needed to render one section ('zone' or
-- 'region'): its base/scratch text object, its per-character gradient
-- object array key, and its settings table.
local function getWhichState(which)
    if which == 'zone' then
        return {
            text_obj = zonename.zone_name_text,
            chars_key = 'zone_name_chars',
            settings = zonename.settings.zone_name,
        }
    else
        return {
            text_obj = zonename.region_name_text,
            chars_key = 'region_name_chars',
            settings = zonename.settings.region_name,
        }
    end
end

-- Approximate relative advance widths for common Latin characters,
-- relative to a "medium" character's width of 1.0. Used only to
-- distribute a single, trusted whole-string width measurement across
-- individual characters for gradient layout - not to measure width
-- directly, since per-character measurements from the font library
-- turned out to be unreliable (likely rounded/padded texture sizes that
-- distort disproportionately for single characters).
local NARROW_CHARS = "iIljtfr.,:;!'\"|()[]"
local WIDE_CHARS = "mMWw@%"
local function relativeCharWeight(ch)
    if ch == ' ' then
        return 0.5
    elseif NARROW_CHARS:find(ch, 1, true) then
        return 0.42
    elseif WIDE_CHARS:find(ch, 1, true) then
        return 1.35
    elseif ch:match('%u') then
        return 0.95
    elseif ch:match('%d') then
        return 0.85
    else
        return 0.78
    end
end

-- Rebuilds the per-character gdi objects used for gradient text: one
-- small text object per character, each colored by interpolating
-- between gradient_start_color and gradient_end_color, laid out
-- side-by-side (using a trusted whole-string width measurement,
-- distributed by relative character weight) to reconstruct the string
-- centered at position_x. On any failure, cleans up and disables
-- gradient_enabled on the settings table so the caller falls back to
-- solid-color rendering instead of leaving things in a broken state.
local function rebuildGradientChars(which, text, s)
    local state = getWhichState(which)
    destroyChars(which)

    if not text or text == '' then
        return
    end

    local chars = {}

    local ok, err = pcall(function()
        local base_obj = state.text_obj

        -- Relative weight of each character (used for proportional
        -- spacing), and the total weight, computed once.
        local charCount = #text
        local weights = {}
        local weightTotal = 0
        for i = 1, charCount do
            local w = relativeCharWeight(text:sub(i, i))
            weights[i] = w
            weightTotal = weightTotal + w
        end

        -- Measures the WHOLE string as a single object (the same path
        -- already proven correct for solid-color rendering and the
        -- screen-fit clamp), distributes that trusted total width
        -- across characters proportionally to their relative weight,
        -- then applies the user-adjustable letter-spacing multiplier -
        -- a manual escape hatch for cases where the library's own
        -- measurements (or our weight table) don't quite match reality.
        local spacing = s.gradient_letter_spacing
        if type(spacing) ~= 'number' or spacing <= 0 then
            spacing = 1.0
        end

        local function widthsAt(height)
            base_obj:set_text(text)
            base_obj:set_font_height(height)
            local trueTotal = measureTextWidth(base_obj, text, height)

            local widths = {}
            local spacedTotal = 0
            for i = 1, charCount do
                local w = (weights[i] / weightTotal) * trueTotal * spacing
                widths[i] = w
                spacedTotal = spacedTotal + w
            end
            return widths, spacedTotal
        end

        local widths, totalWidth = widthsAt(s.font_height)

        local maxWidth = scaling.window.w * TEXT_WIDTH_SCREEN_MARGIN
        local effectiveHeight = s.font_height
        if totalWidth > maxWidth and totalWidth > 0 then
            local scale = maxWidth / totalWidth
            effectiveHeight = math.max(MIN_FONT_HEIGHT, math.floor(s.font_height * scale))
            widths, totalWidth = widthsAt(effectiveHeight)
        end

        -- Left edge of the whole reconstructed string.
        local cursorX = s.position_x - totalWidth / 2
        for i = 1, charCount do
            local ch = text:sub(i, i)
            local charSettings = {}
            for k, v in pairs(s) do charSettings[k] = v end
            -- Deliberately kept as Center (the alignment value already
            -- confirmed to work in this addon) rather than guessing at
            -- a Left/Near alignment enum name that may not exist in
            -- this font library - instead each character is positioned
            -- by its own center point.
            charSettings.font_alignment = gdi.Alignment.Center
            charSettings.font_height = effectiveHeight
            charSettings.position_x = cursorX + widths[i] / 2
            charSettings.position_y = s.position_y

            local t = charCount > 1 and (i - 1) / (charCount - 1) or 0
            charSettings.font_color = colorutils.interpolate(s.gradient_start_color, s.gradient_end_color, t)

            local obj = gdi:create_object(charSettings)
            obj:set_text(ch)
            obj:set_visible(false)
            table.insert(chars, obj)
            cursorX = cursorX + widths[i]
        end

        -- Restore the base object, which was borrowed above as a
        -- scratch measurement tool.
        base_obj:set_text(text)
        base_obj:set_font_height(s.font_height)
    end)

    if ok then
        zonename[state.chars_key] = chars
    else
        for _, obj in ipairs(chars) do
            pcall(function() gdi:destroy_object(obj) end)
        end
        print(chat.header(addon.name):append(chat.error('Gradient text failed, falling back to solid color: %s'):format(tostring(err))))
        s.gradient_enabled = false
    end
end

-- Single entry point for putting a string on screen for a section,
-- handling both the solid-color path (the shared/fitted text object)
-- and the gradient path (rebuilding per-character objects), and keeping
-- zonename.current_zone_text/current_region_text in sync for later
-- re-fits (e.g. when the size slider changes while previewing).
local function renderContent(which, text)
    local state = getWhichState(which)
    local s = state.settings

    if which == 'zone' then
        zonename.current_zone_text = text
    else
        zonename.current_region_text = text
    end

    -- Keep the base object's family in sync since it doubles as the
    -- measurement scratch object for gradient mode.
    if type(s.font_family) == 'string' and s.font_family ~= '' then
        state.text_obj:set_font_family(s.font_family)
    end

    if s.gradient_enabled then
        rebuildGradientChars(which, text, s)
    end

    if s.gradient_enabled then
        -- Rebuild succeeded. Keep the base/solid object out of the way.
        state.text_obj:set_visible(false)
    else
        -- Either gradient was never on, or the rebuild above failed and
        -- flipped gradient_enabled off - either way, render solid.
        destroyChars(which)
        setTextFitted(state.text_obj, text, s.font_height)
        state.text_obj:set_outline_width(s.outline_width)
        state.text_obj:set_position_x(s.position_x)
        state.text_obj:set_position_y(s.position_y)
        state.text_obj:set_font_color(s.font_color)
        state.text_obj:set_outline_color(s.outline_color)
    end
end

-- Shows/hides whichever representation (solid text object, or the set
-- of per-character gradient objects) is currently active for a section.
local function setContentVisible(which, visible)
    local state = getWhichState(which)
    if state.settings.gradient_enabled and #zonename[state.chars_key] > 0 then
        for _, obj in ipairs(zonename[state.chars_key]) do
            obj:set_visible(visible)
        end
    else
        state.text_obj:set_visible(visible)
    end
end

-- Sets opacity on whichever representation is currently active for a
-- section (used by the fade effect and the gui preview).
local function setContentOpacity(which, alpha)
    local state = getWhichState(which)
    if state.settings.gradient_enabled and #zonename[state.chars_key] > 0 then
        for _, obj in ipairs(zonename[state.chars_key]) do
            obj:set_opacity(alpha)
        end
    else
        state.text_obj:set_opacity(alpha)
    end
end

-- Shows or hides sample text on the zone/region overlay so changes made
-- in the settings gui can be previewed live without needing to actually
-- change zones. Passed to gui.initialise() as the set_preview callback.
local function setPreview(isOpen)
    if isOpen then
        zonename.visible = true
        zonename.fade_start_time = nil -- cancel any in-progress fade
        renderContent('zone', 'Sample Zone Name')
        renderContent('region', 'Sample Region Name')
        setContentVisible('zone', true)
        setContentVisible('region', true)
        setContentOpacity('zone', 1)
        setContentOpacity('region', 1)
    else
        zonename.visible = false
        zonename.fade_start_time = nil
        setContentVisible('zone', false)
        setContentVisible('region', false)
    end
end

local function onZoneChange()
    local currentZoneID = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    local currentZoneName = encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString('zones.names', currentZoneID), true)  -- Get the current zone name
    local regionID = getRegionIDByZoneID(currentZoneID)  -- Get the region ID based on the zone ID
    local currentRegionName = getRegionNameById(regionID)  -- Get the region name based on the region ID
    if currentRegionName then
        zonename.visible = true

        renderContent('zone', currentZoneName)
        renderContent('region', currentRegionName)
    else
        print(chat.header(addon.name):append(chat.error('Unrecognised region. RegionZones data may need to be updated. Region ID: "%s", Zone ID: "%s"'):format(regionID, currentZoneID)))
    end
end

-- Update the fade effect
local function updateFade()
    local maxAlpha = 1 -- Set the maximum alpha to fully visible
    local minAlpha = 0 -- Set the minimum alpha to fully transparent
    local fadeDuration = zonename.settings.fade_duration -- Total duration for fading out in seconds
    local fadeAfter = zonename.settings.fade_after

    if zonename.fade_start_time == nil then
        zonename.fade_start_time = os.clock() -- Record the start time of the fade
        setContentVisible('zone', true)
        setContentVisible('region', true)
    end

    local elapsed = math.max(0, os.clock() - zonename.fade_start_time - fadeAfter)
    local alpha = maxAlpha - (maxAlpha * (elapsed / fadeDuration))

    -- Ensure alpha doesn't go below the minimum value
    alpha = math.max(alpha, minAlpha)

    -- Set the updated alpha
    setContentOpacity('zone', alpha)
    setContentOpacity('region', alpha)

    -- Reset fading when it's fully faded out
    if alpha == minAlpha then
        zonename.fade_start_time = nil
        zonename.visible = false
        setContentVisible('zone', false)
        setContentVisible('region', false)
    end
end

-- A short list of fonts that ship with Windows and are extremely likely
-- to be present, used as a last resort if neither the configured font
-- nor the addon's own default font can be loaded.
local SYSTEM_FALLBACK_FONTS = { 'Arial', 'Segoe UI', 'Tahoma', 'Courier New' }

-- Returns a font family guaranteed to have passed gdi:get_font_available,
-- trying (in order): the candidate itself, the addon's default for this
-- element, then a short list of near-universal system fonts. Never
-- returns an unverified name, since creating/rendering a gdi text object
-- with one crashes the d3d_present loop.
local function resolveFontFamily(candidate, defaultFamily)
    if type(candidate) == 'string' and candidate ~= '' and gdi:get_font_available(candidate) then
        return candidate
    end
    if type(defaultFamily) == 'string' and defaultFamily ~= '' and gdi:get_font_available(defaultFamily) then
        return defaultFamily
    end
    for _, f in ipairs(SYSTEM_FALLBACK_FONTS) do
        if gdi:get_font_available(f) then
            return f
        end
    end
    -- Nothing on the system checked out. Returning the candidate here
    -- would risk the same crash, so surface a clear error instead.
    print(chat.header(addon.name):append(chat.error('No usable font could be found on this system (tried "%s" and several fallbacks). Text may not render.'):format(tostring(candidate)))) 
    return candidate
end

local function initialise()
    if zonename.zone_name_text ~= nil then
        gdi:destroy_object(zonename.zone_name_text)
    end
    if zonename.region_name_text ~= nil then
        gdi:destroy_object(zonename.region_name_text)
    end
    destroyChars('zone')
    destroyChars('region')

    -- Resolve fonts to a confirmed-available family BEFORE creating the
    -- gdi objects, so they never get created with an unloadable font in
    -- the first place.
    local zn = zonename.settings.zone_name
    local resolvedZoneFamily = resolveFontFamily(zn.font_family, zonename.defaults.zone_name.font_family)
    if resolvedZoneFamily ~= zn.font_family then
        print(chat.header(addon.name):append(chat.error('Font not available: %s, reverting to %s.'):format(tostring(zn.font_family), resolvedZoneFamily)))
        zn.font_family = resolvedZoneFamily
    end

    local rn = zonename.settings.region_name
    local resolvedRegionFamily = resolveFontFamily(rn.font_family, zonename.defaults.region_name.font_family)
    if resolvedRegionFamily ~= rn.font_family then
        print(chat.header(addon.name):append(chat.error('Font not available: %s, reverting to %s.'):format(tostring(rn.font_family), resolvedRegionFamily)))
        rn.font_family = resolvedRegionFamily
    end

    zonename.zone_name_text = gdi:create_object(zonename.settings.zone_name)  -- Create a font object for zone name display
    zonename.region_name_text = gdi:create_object(zonename.settings.region_name)  -- Create a font object for region name display

    zonename.zone_name_text:set_visible(false)
    zonename.region_name_text:set_visible(false)
end

-- Re-renders both sections using whatever text is currently displayed
-- (almost always the gui's sample preview text), picking up any
-- setting change: size, position, color, font, or gradient on/off.
-- Used as the gui module's on_change callback so slider/checkbox
-- changes are reflected immediately.
local function applyFontSettings()
    local function apply(which, current_text)
        if not current_text or current_text == '' then
            return
        end
        local ok, err = pcall(function()
            renderContent(which, current_text)
        end)
        if not ok then
            print(chat.header(addon.name):append(chat.error('Failed to apply text settings: %s'):format(tostring(err))))
        end
    end

    apply('zone', zonename.current_zone_text)
    apply('region', zonename.current_region_text)

    -- applyFontSettings only ever runs while the settings gui is open
    -- (i.e. while previewing), so the overlay should stay fully visible
    -- through the rebuild above rather than defaulting to hidden.
    if zonename.visible then
        setContentVisible('zone', true)
        setContentVisible('region', true)
        setContentOpacity('zone', 1)
        setContentOpacity('region', 1)
    end
end

-- Register events to load and unload the addon
ashita.events.register('load', 'zonename_load', function()
    zonename.settings = settings.load(zonename.defaults)  -- Load settings with default values

    -- Get language
    local lang = AshitaCore:GetConfigurationManager():GetInt32('boot', 'ashita.language', 'playonline', 2)
    zonename.lang_id = 'en'
    if lang == 1 then
        zonename.lang_id = 'ja'
    end

    initialise()

    local function buildGuiContext()
        return {
            settings = zonename.settings,
            defaults = zonename.defaults,
            on_change = applyFontSettings,
            save = function() settings.save() end,
            set_preview = setPreview,
            check_font_available = function(family) return gdi:get_font_available(family) end,
        }
    end

    gui.initialise(buildGuiContext())

    settings.register('settings', 'settings_update', function(s)
        if (s ~= nil) then
            zonename.settings = s
            initialise()
            -- The settings table reference may have changed, so make
            -- sure the gui is pointed at the current one.
            gui.initialise(buildGuiContext())
        end
    end)
end)

ashita.events.register('unload', 'zonename_unload', function()
    destroyChars('zone')
    destroyChars('region')
    gdi:destroy_interface()
end)

-- Register a packet_in event to handle zone change information
ashita.events.register('packet_in', 'zonename_packet_in', function(event)
    if event.id == 0x0A then  -- Check if it's a zone change packet
        local moghouse = struct.unpack('b', event.data, 0x80 + 1)
        if moghouse ~= 1 then
            coroutine.sleep(1)
            onZoneChange()
        end
    end
end)

ashita.events.register('command', 'zonename_command', function (e)
    -- Parse the command arguments..
    local args = e.command:args()
    if (#args == 0 or args[1] ~= '/zonename') then
        return
    end

    -- Block all zonename related commands..
    e.blocked = true

    -- Handle: /zonename (reload | rl) - Reloads the settings from disk.
    if (#args == 2 and args[2]:any('reload', 'rl')) then
        settings.reload()
        print(chat.header(addon.name):append(chat.message('Settings reloaded from disk.')))
        onZoneChange()
        return
    end

    -- Handle: /zonename test - Force display the zone info.
    if (#args == 2 and args[2]:any('test')) then
        onZoneChange()
        return
    end

    -- Handle: /zonename gui | config | settings - Toggles the settings window.
    if (#args == 2 and args[2]:any('gui', 'config', 'settings')) then
        gui.toggle()
        return
    end
end)

-- Register a d3d_present event to display the OSD elements
ashita.events.register('d3d_present', 'zonename_present', function()
    -- The settings gui should be usable regardless of zoning state.
    gui.draw()

    -- Don't display unless we have a player entity and we've finished zoning
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local player_ent = GetPlayerEntity()
    if (player == nil or player.isZoning or player_ent == nil) then
		return
	end

    -- Skip the fade-out timer while previewing in the settings gui, so
    -- the sample text stays fully visible until the window is closed.
    if zonename.visible and not gui.is_open[1] then
        updateFade()
    end
end)
