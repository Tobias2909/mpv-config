-- Per-video volume memory
--
-- WHY THIS EXISTS. mpv already stores `volume` in its watch_later file and
-- restores it, so this looks redundant -- it is not. Three measured gaps:
--
--   1. A file that reaches its END stores NOTHING. mpv only writes a resume
--      file for the file that is playing when you quit; a finished file is
--      "done" and its entry is dropped. Measured: single file, volume 21,
--      played to natural EOF -> no watch_later entry at all. A music video
--      always reaches its end, so its volume was never kept.
--   2. `volume` is a GLOBAL property, so it leaks to whatever plays next.
--      Measured twice: a two-entry playlist advancing on EOF started the
--      second file at the first file's 33, and a normal-mode browser handoff
--      (`loadfile B replace` mid-play) started B at A's 55.
--   3. A FRESH player has nothing to inherit. An unseen video takes over
--      whatever is set, which mid-session is the level last listened at, but
--      at startup is mpv's built-in 100 -- louder than anything actually
--      used here. So switching videos inside one session was already right
--      while the first video of a session was loud every time. The level last
--      written is therefore kept globally as well and seeded at startup,
--      which makes the two cases behave the same way.
--
-- Both hit outside queue mode too -- the F9 loop only makes it constant enough
-- to notice -- which is why this runs for every file rather than reading the
-- queue flag. Cost is one property observer plus a debounced write.
--
-- `volume` is removed from `watch-later-options` in mpv.conf so there is one
-- writer, not two. Old watch_later files still carry a `volume=` line and mpv
-- still applies it at load, which is deliberate free migration: on the first
-- open of a known video that value is what "inherit + record" picks up.
--
-- Store: one file per video under $XDG_STATE_HOME/mpv/volume-per-file/,
-- holding the bare number. Readable name + djb2 suffix so entries can be
-- inspected and deleted by hand. Delete a file -> that video forgets. The
-- level last written lives beside them in `last-volume`; a key file always
-- ends in `_` plus 8 hex digits and the sanitiser turns every `-` into `_`,
-- so that name cannot collide with a video's.

local mp  = require "mp"
local msg = require "mp.msg"

-- Volume changes arrive one property event per scroll tick, so a write per
-- event would be dozens of writes for one adjustment. Coalesce them.
local DEBOUNCE = 1.0

local DIR = (os.getenv("XDG_STATE_HOME")
             or ((os.getenv("HOME") or ".") .. "/.local/state"))
            .. "/mpv/volume-per-file"

local LAST_FILE = DIR .. "/last-volume"

local key      = nil    -- identity of the file currently loaded, nil when idle
local pending  = nil    -- volume waiting to be written under `key`
local timer    = nil
local made_dir = false

-- djb2, no bit ops so it stays exact in Lua's doubles -- same scheme as the
-- chat overlay's emote cache.
local function key_file(k)
    local h = 5381
    for i = 1, #k do h = (h * 33 + k:byte(i)) % 4294967296 end
    local name = k:gsub("[^A-Za-z0-9]+", "_")
    if #name > 80 then name = name:sub(-80) end
    return string.format("%s/%s_%08x", DIR, name, h)
end

-- What counts as "the same video".
--   * YouTube -> the video id alone. The same video opened directly and out of
--     a `&list=` playlist or a mix are different URLs but must share a volume;
--     mpv's own watch_later hashing does not do this, hence our own key.
--   * Twitch -> the channel. The wrapper resolves a channel to a fresh HLS
--     m3u8 on every launch, so `path` is useless as a key, and the m3u8 names
--     the channel nowhere. The wrapper hands the name over instead, by a
--     script message for a player that is already running and a script option
--     for one it starts. It titles the stream with what the channel is
--     streaming now, so the old trick of reading the name back out of
--     `force-media-title` only still works for an mpv started by hand.
--   * everything else -> the path or URL as-is.
-- Handed over by the wrapper before its loadfile; taken at file-loaded, so
-- one handover belongs to one file.
local twitch_login = nil
local twitch_next  = nil

mp.register_script_message("twitch-channel", function(login)
    twitch_next = (login ~= "" and login) or nil
end)

local function identity()
    local path = mp.get_property("path") or ""
    if path == "" then return nil end

    local id
    if path:match("youtube%.com/watch") then
        id = path:match("[?&]v=([%w_%-]+)")
    elseif path:match("youtube%.com/live/") then
        id = path:match("youtube%.com/live/([%w_%-]+)")
    elseif path:match("youtube%.com/embed/") then
        id = path:match("youtube%.com/embed/([%w_%-]+)")
    else
        id = path:match("^https?://youtu%.be/([%w_%-]+)")
    end
    if id then return "yt:" .. id end

    local chan = twitch_login or mp.get_opt("twitch_channel")
    if not chan or chan == "" then
        chan = (mp.get_property("force-media-title") or "")
               :match("^twitch%.tv/([^%s/]+)")
    end
    -- A script option outlives the file it came with, so it only counts while
    -- the path really is a resolved stream.
    if chan and chan ~= "" and (path:match("%.m3u8") or path:match("ttvnw%.net")) then
        return "twitch:" .. chan:lower()
    end

    return path
end

local function read_number(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = tonumber(f:read("*l") or "")
    f:close()
    return v
end

local function write_number(path, v)
    local tmp = path .. ".tmp"
    -- Rename over the old entry so a reader never sees a half-written number,
    -- and so two mpv instances racing on the same video cannot merge digits.
    local f = io.open(tmp, "w")
    if not f and not made_dir then
        os.execute(string.format("mkdir -p %q", DIR))
        made_dir = true
        f = io.open(tmp, "w")
    end
    if not f then
        msg.warn("cannot write volume store: " .. tmp)
        return
    end
    f:write(string.format("%.6f\n", v))
    f:close()
    os.rename(tmp, path)
end

local function load_vol(k)  return read_number(key_file(k)) end
local function store_vol(k, v)  write_number(key_file(k), v) end

-- Clamped against the live ceiling on the way in: --volume-max can be lowered
-- between sessions, and setting a volume above it fails outright instead of
-- saturating.
local function usable(v)
    if type(v) ~= "number" then return nil end
    local max = mp.get_property_number("volume-max") or 100
    if v > max then v = max end
    if v < 0 then v = 0 end
    return v
end

local function flush()
    if timer then timer:kill(); timer = nil end
    if key and pending then
        store_vol(key, pending)
        -- Same number twice on purpose: per video for its own restore, and
        -- globally as the level a never-seen video should start at.
        write_number(LAST_FILE, pending)
        pending = nil
    end
end

-- Restoring a volume re-enters this observer with the value we just applied.
-- That is deliberately NOT guarded: the write is idempotent (same number back
-- into the same file), and a flag would be wrong anyway -- property change
-- events are delivered on a later event-loop iteration, by which time any
-- "applying" flag has already been cleared.
mp.observe_property("volume", "number", function(_, v)
    if not key or type(v) ~= "number" then return end
    pending = v
    if timer then timer:kill() end
    timer = mp.add_timeout(DEBOUNCE, flush)
end)

mp.register_event("file-loaded", function()
    -- Under the OLD key: a volume nudged in the last second before a skip
    -- belongs to the file being left, not the one arriving.
    flush()

    twitch_login, twitch_next = twitch_next, nil
    key = identity()
    if not key then return end

    local saved = usable(load_vol(key))
    local cur   = mp.get_property_number("volume")
    if saved then
        if cur and math.abs(cur - saved) > 0.01 then
            mp.set_property_number("volume", saved)
        end
    elseif cur then
        -- Unknown video: keep whatever is set and adopt it as this video's
        -- value. The level last listened at is the best available guess for an
        -- unseen video, and after one play every video carries its own number.
        -- Through the same writer as a real change, so this level also becomes
        -- the one the next fresh player seeds from -- otherwise a session that
        -- only ever played unseen videos would leave nothing behind.
        pending = cur
        flush()
    end
end)

-- EOF is the case mpv itself drops on the floor, so this is the important one.
mp.register_event("end-file", flush)
mp.register_event("shutdown", flush)

-- Seed the level a fresh player starts at, before any file is loaded, so the
-- "unknown video inherits what is set" branch above inherits the level last
-- listened at rather than mpv's built-in 100. A known video still overrides
-- this with its own value at file-loaded, and nothing is written here: the
-- observer ignores a change while no file is loaded.
--
-- An explicit `--volume=` wins. `set-from-commandline` is what separates it
-- from the same option in mpv.conf, which must not block the seed.
local function seed()
    if mp.get_property_bool("option-info/volume/set-from-commandline") then
        return
    end
    local last = usable(read_number(LAST_FILE))
    if not last then return end
    local cur = mp.get_property_number("volume")
    if cur and math.abs(cur - last) > 0.01 then
        mp.set_property_number("volume", last)
    end
end

seed()
