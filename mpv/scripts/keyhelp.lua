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
    F12 = "Japanese to English subtitles (YouTube)",
    ["Shift+F12"] = "Japanese chat to English (F12 too)",
    UP = "Volume +5",
    DOWN = "Volume -5",
    ["+"] = "Speed +10%   (also KP_ADD)",
    ["-"] = "Speed -10%   (also KP_SUBTRACT)",
    BS = "Speed back to 1.0x",
    KP0 = "Restart video from 00:00   (also KP_INS)",
    ESC = "(disabled — does not leave fullscreen)",
}

-- Duplicates of a key already described above; parsed but not shown twice.
-- KP_INS is the same binding as KP0 and its row already says so.
local SKIP = { KP_ADD = true, KP_SUBTRACT = true, KP_INS = true }

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
-- Progress of the subtitle generator, published by translate_subs.lua. Reading
-- a user-data property keeps this file independent of that script: if it is not
-- loaded the property is simply absent.
local function clock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    -- math.floor, not the // operator: mpv runs LuaJIT, which is Lua 5.1 and
    -- has no floor division. A stock luac accepts it and proves nothing.
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600),
                             math.floor((seconds % 3600) / 60), seconds % 60)
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Short form for the key row. Long form lives in translate_lines below.
local function translate_state()
    local t = mp.get_property_native("user-data/translate_subs")
    if type(t) ~= "table" or not t.state or t.state == "off" then return "off" end
    local cues = tonumber(t.cues) or 0
    if t.state == "probing" then return "checking video" end
    if t.state == "downloading" then
        return string.format("fetching audio %d%%",
                             math.floor(tonumber(t.download_pct) or 0))
    end
    if t.state == "loading" or t.state == "starting" then return "starting up" end
    if t.state == "failed" then return "failed" end
    if t.state == "done" then
        return string.format("whole video done, %d lines", cues)
    end
    -- Running or idle. Idle means the window in front of the playhead is
    -- covered, which is the good state, not a stalled one.
    local ahead = tonumber(t.ahead) or 0
    return string.format("%s ahead, %d lines", clock(ahead), cues)
end

-- The detail block. Written because "ahead of playback" and "25% of video"
-- answer neither question a viewer has: is the part about to be watched
-- covered, and is anything still being worked on.
local function translate_lines()
    local t = mp.get_property_native("user-data/translate_subs")
    if type(t) ~= "table" or not t.state or t.state == "off" then return nil end
    local out = {}
    local cues = tonumber(t.cues) or 0
    local dur = tonumber(t.duration) or 0
    local covered = tonumber(t.covered) or 0
    local ahead = tonumber(t.ahead) or 0
    local pos = tonumber(t.position) or 0
    local state = t.state

    local words = {
        probing = "checking whether the audio is japanese",
        downloading = string.format("fetching the audio track, %d%%",
                                    math.floor(tonumber(t.download_pct) or 0)),
        starting = "starting the worker",
        loading = "loading the recognition and translation models",
        running = "transcribing and translating now",
        idle = "caught up, waiting for playback to move on",
        done = "finished, the whole video is transcribed",
        orphaned = "stopped, the player went away",
        failed = "failed, see the log",
    }
    out[#out + 1] = string.format("%-9s %s", "subs", words[state] or state)

    if state ~= "done" and state ~= "failed" and state ~= "probing" then
        if ahead > 0 then
            out[#out + 1] = string.format("%-9s %s of subtitles past %s",
                                          "ahead", clock(ahead), clock(pos))
        else
            out[#out + 1] = string.format("%-9s nothing yet at %s, working on it",
                                          "ahead", clock(pos))
        end
    end

    if dur > 0 then
        out[#out + 1] = string.format("%-9s %s of %s transcribed, %d lines",
                                      "total", clock(covered), clock(dur), cues)
    else
        out[#out + 1] = string.format("%-9s %d lines", "total", cues)
    end
    return out
end

-- Chat translation, published by chat_overlay.lua as one table. Same
-- one-way read as above: no property, no rows.
local function chat_state()
    local c = mp.get_property_native("user-data/chat_translate")
    if type(c) ~= "table" or not c.on then return nil end
    return c, tonumber(c.japanese) or 0, tonumber(c.english) or 0,
           tonumber(c.lines) or 0, tonumber(c.seen) or 0,
           tonumber(c.waiting) or 0
end

local function chat_translate_state()
    local c, ja, _, _, _, waiting = chat_state()
    if not c then return "off" end
    if ja == 0 then return "on, no japanese yet" end
    -- What is on screen is what can be judged; the totals include chat
    -- buffered hours ahead, which the translator will not touch until
    -- playback gets there.
    if waiting > 0 then return string.format("on, %d lines on screen waiting", waiting) end
    return "on, screen is in english"
end

local function chat_lines()
    local c, ja, en, _, seen, waiting = chat_state()
    if not c then return nil end
    local out = {}
    local doing
    if ja == 0 then
        doing = "nothing japanese in the chat so far"
    elseif waiting > 0 then
        doing = string.format("%d japanese lines on screen are not translated yet",
                              waiting)
    else
        doing = "every japanese line on screen is in english"
    end
    out[#out + 1] = string.format("%-9s %s", "chat", doing)
    -- The totals count the whole buffer, which on a recording runs hours past
    -- the playhead on purpose, so they are stated as a buffer figure rather
    -- than as progress.
    out[#out + 1] = string.format("%-9s %d translated, %d japanese of %d messages buffered",
                                  "chat", en, ja, seen)
    return out
end

local STATE = {
    F12 = function() return translate_state() end,
    ["Shift+F12"] = function() return chat_translate_state() end,
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

-- Both translation features share one area, because they are one topic and
-- their progress rows read together: the subtitle worker and the chat
-- translator are answering the same question about different text.
local function translation_notes()
    local out = {}
    for _, l in ipairs(translate_lines() or {}) do out[#out + 1] = l end
    for _, l in ipairs(chat_lines() or {}) do out[#out + 1] = l end
    if #out == 0 then return nil end
    return out
end

-- Display order. Keys parsed from input.conf but not named here land in "Other",
-- so nothing can silently go missing.
-- Third element (optional) = function returning the group's footnote, either
-- one row or a list of rows.
local GROUPS = {
    { "Upscaler / picture", { "F1", "F2", "F6", "F7", "F8", "F5" }, pixel_rate_note },
    { "Playback",           { "F4", "UP", "DOWN", "+", "-", "BS" } },
    { "Translation",        { "F12", "Shift+F12" }, translation_notes },
    { "Queue / loop",       { "F9" } },
    { "Info",               { "F3" } },
}

-- Groups that live in the RIGHT column, under the built-ins, together with
-- the leftover section. The live state blocks appear exactly when something is
-- running, and the left column had no room for them: it stood at 34 rows idle
-- and 39 with both of them, which crossed a font size step, so the whole sheet
-- got smaller the moment a translation was switched on. The right column had
-- nothing but slack, and these groups are the ones nobody reads mid video.
--
-- Keep what goes here NARROW, around 54 cells. The box is as wide as both
-- columns together and the width is the tight dimension, not the height: at
-- font size 14 there are about three cells of room left over, against eleven
-- spare rows.
local RIGHT_SIDE = { ["Queue / loop"] = true, ["Info"] = true }

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
    local lines, right = { "KEY BINDINGS" }, { "-- Built-in / scripts --" }
    local used = {}

    local function row(key, desc, state, into)
        local text = string.format("%-11s %s", key, desc)
        if state then text = text .. "   [" .. state .. "]" end
        into = into or lines
        into[#into + 1] = text
    end

    for _, b in ipairs(BUILTIN) do row(b[1], b[2], nil, right) end

    for _, group in ipairs(GROUPS) do
        local into = RIGHT_SIDE[group[1]] and right or lines
        into[#into + 1] = ""
        into[#into + 1] = "-- " .. group[1] .. " --"
        for _, key in ipairs(group[2]) do
            local desc = conf[key] or DESC[key]
            if desc then
                used[key] = true
                row(key, desc, STATE[key] and STATE[key]() or nil, into)
            end
        end
        local note = group[3] and group[3]()
        if type(note) == "string" then note = { note } end
        for _, n in ipairs(note or {}) do
            into[#into + 1] = string.format("%-11s %s", "", n)
        end
    end

    -- Anything bound in input.conf that no group claims.
    local rest = {}
    for key in pairs(conf) do
        if not used[key] and not SKIP[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    if #rest > 0 then
        right[#right + 1] = ""
        right[#right + 1] = "-- Other --"
        for _, key in ipairs(rest) do row(key, conf[key], nil, right) end
    end

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
    for size = 14, 10, -1 do
        fs = size
        charw = fs * 0.62
        xr = xl + math.ceil(widest(lines) * charw) + 28
        w = xr - 24 + math.ceil(widest(right) * charw) + 28
        -- Both directions, or the sheet runs off the BOTTOM instead: the two
        -- progress blocks add rows exactly when they matter, and shrinking
        -- only for width left a 41 row sheet 100 units taller than the canvas.
        if w <= avail and rows * (size + 3) + 24 <= 700 then break end
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
-- Both translation blocks are progress, so they go stale within a second of
-- being drawn. The subtitle worker republishes about once a second and the
-- chat translator only when a line lands, so this rebuilds no more often than
-- the numbers actually change.
mp.observe_property("user-data/translate_subs", "native", function()
    if shown then build() ; overlay:update() end
end)
mp.observe_property("user-data/chat_translate", "native", function()
    if shown then build() ; overlay:update() end
end)
