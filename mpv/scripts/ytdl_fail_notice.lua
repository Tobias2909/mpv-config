-- ytdl_fail_notice.lua
-- Turn a yt-dlp load failure into a readable message instead of mpv exiting.
--
-- Main case it exists for: YouTube "post-live" VODs (a finished livestream that
-- YouTube still serves as thousands of ~2 s DASH chunks). yt-dlp -J then emits
-- hundreds of MB of fragment URLs, mpv's subprocess capture stops at 64 MiB,
-- the JSON is truncated and ytdl_hook reports "failed to parse JSON data".
-- Without this script mpv unloads the current video and quits.

local mp  = require 'mp'
local msg = require 'mp.msg'

-- mpv's subprocess capture_size default; a stdout of exactly this size means
-- yt-dlp's output was cut off, not that yt-dlp failed.
local CAPTURE_SIZE = 67108864

local POST_LIVE_MSG =
    "Can't play: long live-stream recording\n" ..
    "\n" ..
    "YouTube still serves this stream as thousands of small chunks, and\n" ..
    "yt-dlp's metadata for it is larger than mpv's 64 MiB limit.\n" ..
    "\n" ..
    "YouTube converts finished streams into normal videos by itself, so\n" ..
    "this usually starts working after a while. Until then, watch it in\n" ..
    "the browser."

local good_path, good_pos = nil, nil   -- last file that actually loaded
local saved_idle = nil
local restoring = false

local function notify(title, body)
    mp.commandv("run", "notify-send", "-a", "mpv", "-i", "mpv", title, body)
end

mp.register_event("file-loaded", function()
    restoring = false
    good_path = mp.get_property("path")
    good_pos  = 0
    if saved_idle ~= nil then          -- failure handled, put idle back
        mp.set_property("idle", saved_idle)
        saved_idle = nil
    end
end)

mp.observe_property("time-pos", "number", function(_, v)
    if v then good_pos = v end
end)

mp.add_hook("on_load_fail", 50, function()
    local url = mp.get_property("stream-open-filename", "")
    local r   = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")

    local post_live = r and r.status == 0 and r.stdout and #r.stdout >= CAPTURE_SIZE
    local text
    if post_live then
        text = POST_LIVE_MSG
    elseif r and r.status ~= 0 then
        local first = (r.stderr or ""):match("^[^\n]*") or ""
        text = "Can't play: yt-dlp failed\n\n" .. (first ~= "" and first or url)
    else
        return   -- not a ytdl failure, leave mpv's normal handling alone
    end

    msg.error((text:gsub("\n", " ")))
    notify(post_live and "mpv: live-stream recording not playable yet"
                      or "mpv: yt-dlp failed", text)

    if not (good_path and good_path ~= url and not restoring) then
        return   -- nothing was playing: let mpv exit as usual, notification is enough
    end

    -- Something WAS playing and `loadfile ... replace` just threw it away.
    -- Keep mpv alive, show the reason, then put the old file back where it was.
    if saved_idle == nil then
        saved_idle = mp.get_property("idle")
    end
    mp.set_property_bool("idle", true)
    mp.osd_message(text, 10)

    restoring = true
    local pos = string.format("%.3f", good_pos or 0)
    msg.info("restoring " .. good_path .. " at " .. pos)
    mp.add_timeout(0.3, function()
        mp.commandv("loadfile", good_path, "replace", "-1", "start=" .. pos)
    end)
end)
