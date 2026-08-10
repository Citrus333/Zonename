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

-- Shows or hides sample text on the zone/region overlay so changes made
-- in the settings gui can be previewed live without needing to actually
-- change zones. Passed to gui.initialise() as the set_preview callback.
local function setPreview(isOpen)
    if isOpen then
        zonename.visible = true
        zonename.fade_start_time = nil -- cancel any in-progress fade
        zonename.current_zone_text = 'Sample Zone Name'
        zonename.current_region_text = 'Sample Region Name'
        setTextFitted(zonename.zone_name_text, zonename.current_zone_text, zonename.settings.zone_name.font_height)
        setTextFitted(zonename.region_name_text, zonename.current_region_text, zonename.settings.region_name.font_height)
        zonename.zone_name_text:set_visible(true)
        zonename.region_name_text:set_visible(true)
        zonename.zone_name_text:set_opacity(1)
        zonename.region_name_text:set_opacity(1)
    else
        zonename.visible = false
        zonename.fade_start_time = nil
        zonename.zone_name_text:set_visible(false)
        zonename.region_name_text:set_visible(false)
    end
end

local function onZoneChange()
    local currentZoneID = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    local currentZoneName = encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString('zones.names', currentZoneID), true)  -- Get the current zone name
    local regionID = getRegionIDByZoneID(currentZoneID)  -- Get the region ID based on the zone ID
    local currentRegionName = getRegionNameById(regionID)  -- Get the region name based on the region ID
    if currentRegionName then
        zonename.visible = true

        zonename.current_zone_text = currentZoneName
        zonename.current_region_text = currentRegionName
        setTextFitted(zonename.zone_name_text, currentZoneName, zonename.settings.zone_name.font_height)
        setTextFitted(zonename.region_name_text, currentRegionName, zonename.settings.region_name.font_height)
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
        zonename.zone_name_text:set_visible(true)
        zonename.region_name_text:set_visible(true)
    end

    local elapsed = math.max(0, os.clock() - zonename.fade_start_time - fadeAfter)
    local alpha = maxAlpha - (maxAlpha * (elapsed / fadeDuration))

    -- Ensure alpha doesn't go below the minimum value
    alpha = math.max(alpha, minAlpha)

    -- Set the updated alpha
    zonename.zone_name_text:set_opacity(alpha)
    zonename.region_name_text:set_opacity(alpha)

    -- Reset fading when it's fully faded out
    if alpha == minAlpha then
        zonename.fade_start_time = nil
        zonename.visible = false
        zonename.zone_name_text:set_visible(false)
        zonename.region_name_text:set_visible(false)
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

-- Applies the current zone_name/region_name settings (font size, outline
-- width) to the already-created gdi text objects, without recreating
-- them. Used as the gui module's on_change callback so slider changes
-- are reflected immediately.
local function applyFontSettings()
    local function apply(text_obj, s, current_text)
        local ok, err = pcall(function()
            -- Never push a nil/empty font family to the renderer - it
            -- will crash the d3d_present loop on the next frame.
            if type(s.font_family) == 'string' and s.font_family ~= '' then
                text_obj:set_font_family(s.font_family)
            end

            if current_text and current_text ~= '' then
                -- Re-fit using whatever text is currently displayed (the
                -- gui's sample preview text) so the screen-width clamp
                -- still applies while dragging the size slider live.
                setTextFitted(text_obj, current_text, s.font_height)
            else
                text_obj:set_font_height(s.font_height)
            end

            text_obj:set_outline_width(s.outline_width)
            text_obj:set_position_x(s.position_x)
            text_obj:set_position_y(s.position_y)
            text_obj:set_font_color(s.font_color)
            text_obj:set_outline_color(s.outline_color)
        end)
        if not ok then
            print(chat.header(addon.name):append(chat.error('Failed to apply text settings: %s'):format(tostring(err))))
        end
    end

    apply(zonename.zone_name_text, zonename.settings.zone_name, zonename.current_zone_text)
    apply(zonename.region_name_text, zonename.settings.region_name, zonename.current_region_text)
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
