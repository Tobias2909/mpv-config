-- Key help overlay — `h` toggles a cheat sheet of the bindings.
--
-- mpv's built-in stats script already binds `?` to a COMPLETE binding list, but
-- that dumps every default plus every script binding with raw commands. This is
-- the curated version: grouped, described, with live state for the toggles.
--
-- Never drifts from input.conf: the key list is PARSED from input.conf, so a
-- binding added there shows up here automatically (with its show-text string or
-- raw command as the description until it gets an entry in DESC below).

local mp = require "mp"
local msg = require "mp.msg"

local KEY = "h"

-- Curated descriptions. Keys not listed here still appear, described from their
-- own show-text / command text.
-- CAUTION: an entry here WINS over the parsed show-text, so the "never drifts"
-- claim above only holds for keys absent from this table. F1 went on claiming
-- "(default)" long after mpv.conf stopped making it the default everywhere.
-- Editing a show-text in input.conf is not enough if the key is listed here.
local DESC = {
    F1 = "Shader C4F32_DS - heavy, base default",
    F2 = "Shader C4F16_DS - light, auto >85 Mpx/s",
    F6 = "Shader C4F32_DN - heavy, softens",
    F7 = "Shader OFF - conventional scaling only",
    F8 = "Luma scaler: ewa_lanczossharp <-> ewa_lanczos",
    F5 = "Deband on/off",
    F3 = "Show stream info (codec, res, bitrate)",
    F4 = "Loop current video",
    F9 = "Queue mode: append + loop playlist",
    F10 = "Chat: off -> beside -> over (streams only)",
    F11 = "Chat emote animation on/off",
    UP = "Volume +5",
    DOWN = "Volume -5",
    ["+"] = "Speed +10%   (also KP_ADD)",
    ["-"] = "Speed -10%   (also KP_SUBTRACT)",
    BS = "Speed back to 1.0x",
    ESC = "(disabled — does not leave fullscreen)",
}

-- Duplicates of a key already described above; parsed but not shown twice.
local SKIP = { KP_ADD = true, KP_SUBTRACT = true }

-- Which shader file is loaded right now. The shader keys are no longer a
-- "press F1 for the default" bank: mpv.conf's [light-shader] profile picks F1's
-- or F2's shader per file from the source pixel rate, so the sheet has to state
-- what is actually loaded instead of naming one of them the default.
local function shader_active(marker)
    local cur = mp.get_property("glsl-shaders") or ""
    if marker == "" then return (cur == "") and "ACTIVE" or nil end
    return cur:find(marker, 1, true) and "ACTIVE" or nil
end

-- Source pixel rate vs the [light-shader] threshold in mpv.conf. Keep the two
-- numbers in sync by hand — the profile-cond is not readable from here.
local PIXEL_RATE_LIMIT = 85e6
local function pixel_rate_note()
    local w = mp.get_property_number("video-params/w")
    local h = mp.get_property_number("video-params/h")
    local fps = mp.get_property_number("container-fps")
    if not (w and h and fps) then return nil end
    local rate = w * h * fps
    return string.format("auto-switch: %dx%d@%.4g = %.0f Mpx/s -> %s (limit %.0f)",
        w, h, fps, rate / 1e6,
        rate > PIXEL_RATE_LIMIT and "light" or "heavy", PIXEL_RATE_LIMIT / 1e6)
end

-- Live state appended to a row, so the sheet says what is actually active.
local STATE = {
    F1 = function() return shader_active("ArtCNN_C4F32_DS") end,
    F2 = function() return shader_active("ArtCNN_C4F16_DS") end,
    F6 = function() return shader_active("ArtCNN_C4F32_DN") end,
    F7 = function() return shader_active("") end,
    F5 = function() return tostring(mp.get_property("deband")) end,
    F4 = function() return tostring(mp.get_property("loop-file")) end,
    F9 = function()
        local flag = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/mpv-ff2mpv.queue"
        local f = io.open(flag, "r")
        if f then
            f:close()
            return "ON, loop " .. tostring(mp.get_property("loop-playlist"))
        end
        return "off"
    end,
}

-- Display order. Keys parsed from input.conf but not named here land in "Other",
-- so nothing can silently go missing.
-- Third element (optional) = function returning a footnote row for the group.
local GROUPS = {
    { "Upscaler / picture", { "F1", "F2", "F6", "F7", "F8", "F5" }, pixel_rate_note },
    { "Playback",           { "F4", "UP", "DOWN", "+", "-", "BS" } },
    { "Queue / loop",       { "F9" } },
    { "Info",               { "F3" } },
}

-- Not from input.conf: mpv defaults and script bindings worth remembering here.
local BUILTIN = {
    { "?",            "FULL binding list (built-in stats script)" },
    { "right-click",  "Pause / unpause (OSC has no play button)" },
    { "wheel",        "Volume" },
    { "b",            "SponsorBlock skipping on/off" },
    { "< / >",        "Previous / next playlist entry" },
    { "LEFT/RIGHT",   "Seek -/+ 5 s" },
    { "m",            "Mute" },
    { "f",            "Fullscreen" },
    { "q / Q",        "Quit  /  quit and save position" },
}

-- input.conf parsing ---------------------------------------------------------
local function parse_input_conf()
    local path = mp.find_config_file("input.conf")
    local found = {}
    if not path then
        msg.warn("input.conf not found — showing built-ins only")
        return found
    end
    local fh = io.open(path, "r")
    if not fh then return found end
    for line in fh:lines() do
        if not line:match("^%s*#") and line:match("%S") then
            local key, cmd = line:match("^%s*(%S+)%s+(.*)$")
            if key and cmd then
                local desc = DESC[key]
                if not desc then
                    -- Fall back to the binding's own show-text string, minus
                    -- ${property} placeholders (they read as noise here).
                    desc = cmd:match('show%-text%s+"([^"]*)"')
                    if desc then desc = desc:gsub("%${[^}]*}", ""):gsub("%s+", " ") end
                    if not desc or desc == "" or desc == " " then
                        desc = cmd:gsub("%s+", " ")
                        if #desc > 52 then desc = desc:sub(1, 49) .. "..." end
                    end
                end
                found[key] = desc
            end
        end
    end
    fh:close()
    return found
end

-- Rendering ------------------------------------------------------------------
local overlay = mp.create_osd_overlay("ass-events")
local shown = false

local function ass_escape(s)
    return (s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

local function build()
    local conf = parse_input_conf()
    -- Two columns: own bindings left, built-ins right. One column at a legible
    -- font size overflowed the 720-unit canvas (39 rows).
    local lines, right = { "KEY BINDINGS" }, {}
    local used = {}

    local function row(key, desc, state, into)
        local text = string.format("%-11s %s", key, desc)
        if state then text = text .. "   [" .. state .. "]" end
        into = into or lines
        into[#into + 1] = text
    end

    for _, group in ipairs(GROUPS) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "-- " .. group[1] .. " --"
        for _, key in ipairs(group[2]) do
            local desc = conf[key] or DESC[key]
            if desc then
                used[key] = true
                row(key, desc, STATE[key] and STATE[key]() or nil)
            end
        end
        local note = group[3] and group[3]()
        if note then lines[#lines + 1] = string.format("%-11s %s", "", note) end
    end

    -- Anything bound in input.conf that no group claims.
    local rest = {}
    for key in pairs(conf) do
        if not used[key] and not SKIP[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    if #rest > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "-- Other --"
        for _, key in ipairs(rest) do row(key, conf[key]) end
    end

    right[#right + 1] = "-- Built-in / scripts --"
    for _, b in ipairs(BUILTIN) do row(b[1], b[2], nil, right) end
    right[#right + 1] = ""
    right[#right + 1] = KEY .. " closes this"

    -- Three ASS events: backdrop, left column, right column. Events separated
    -- by "\n" are rendered independently (that is why each column's own line
    -- breaks use \N), so overlapping them at chosen positions is the mechanism,
    -- not a bug.
    local rows = math.max(#lines, #right + 1)
    local function widest(tbl)
        local n = 0
        for _, l in ipairs(tbl) do n = math.max(n, #l) end
        return n
    end
    -- The overlay canvas is res_y=720 tall and res_y*aspect wide (1280 on 16:9),
    -- so a fixed font size can run the sheet off the right edge — it did at
    -- fs=16 once the F9 row carries its state suffix. Column x, box size AND
    -- font size are therefore all derived: shrink until it fits the real window
    -- aspect. 0.62 em per char is a safe over-estimate for DejaVu Sans Mono
    -- (0.602), which \fnmonospace resolves to via fontconfig here.
    local dim = mp.get_property_native("osd-dimensions") or {}
    local aspect = (dim.w and dim.h and dim.h > 0) and (dim.w / dim.h) or (16 / 9)
    local avail = 720 * aspect - 48
    local xl = 38
    local fs, charw, xr, w
    for size = 16, 10, -1 do
        fs = size
        charw = fs * 0.62
        xr = xl + math.ceil(widest(lines) * charw) + 28
        w = xr - 24 + math.ceil(widest(right) * charw) + 28
        if w <= avail then break end
    end
    local step = fs + 3
    local hgt = rows * step + 24
    local box = string.format(
        "{\\pos(24,18)\\an7\\bord0\\shad0\\1c&H141414&\\alpha&H50&\\p1}" ..
        "m 0 0 l %d 0 l %d %d l 0 %d{\\p0}", w, w, hgt, hgt)
    if hgt > 700 then msg.warn("help sheet is taller than the canvas — trim a row") end

    local function column(tbl, x)
        local body = {}
        for i, l in ipairs(tbl) do body[i] = ass_escape(l) end
        return string.format(
            "{\\pos(%d,30)\\an7\\fnmonospace\\fs%d\\bord1.6\\shad0" ..
            "\\1c&HFFFFFF&\\3c&H000000&}%s", x, fs, table.concat(body, "\\N"))
    end

    overlay.res_y = 720
    overlay.data = box .. "\n" .. column(lines, xl) .. "\n" .. column(right, xr)
end

local function toggle()
    if shown then
        overlay:remove()
        shown = false
    else
        build()
        overlay:update()
        shown = true
    end
end

mp.add_key_binding(KEY, "toggle", toggle)
-- Re-render live state while open (cheap: only when visible).
mp.observe_property("deband", "native", function()
    if shown then build() ; overlay:update() end
end)
mp.observe_property("loop-file", "native", function()
    if shown then build() ; overlay:update() end
end)
-- The ACTIVE marker and the pixel-rate footnote both change on a shader hotkey
-- or a file change, so they need their own re-render or the sheet lies while open.
mp.observe_property("glsl-shaders", "native", function()
    if shown then build() ; overlay:update() end
end)
mp.observe_property("video-params", "native", function()
    if shown then build() ; overlay:update() end
end)
