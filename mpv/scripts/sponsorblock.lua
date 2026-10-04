-- sponsorblock.lua
-- SponsorBlock segments for YouTube videos, from https://sponsor.ajay.app.
--
-- Every segment of the categories in LABELS is published to
-- user-data/sponsorblock/segments, where the patched ModernZ draws it on the
-- seek bar, names it in the hover tooltip and offers its start and end as
-- right click snap points. Only the AUTO_SKIP categories are skipped on their
-- own. The rest are marked and left to the viewer.
--
-- b turns automatic skipping off for the current video. The next video starts
-- with it on again.
--
-- The server is asked by the first four hex digits of the video id's sha256,
-- the way the browser extension does it, so it never learns which video
-- plays. The answer covers every video sharing that prefix and is filtered
-- here.

local mp    = require 'mp'
local msg   = require 'mp.msg'
local utils = require 'mp.utils'

local API = "https://sponsor.ajay.app/api/skipSegments"

-- category id -> tooltip label
local LABELS = {
    sponsor     = "Sponsor",
    selfpromo   = "Self promotion",
    interaction = "Interaction reminder",
    intro       = "Intro",
    outro       = "Outro",
    preview     = "Preview / recap",
    filler      = "Filler",
}

local AUTO_SKIP = { sponsor = true, intro = true }

local segments = {}        -- sorted by start: { start, stop, category, label }
local skipping = true      -- reset to true on every new file
local generation = 0       -- bumped per file, so a late answer for the old one is dropped
local requested = false    -- a fetch is running or done for this file
local seek_pending = false -- an automatic skip was issued and has not landed yet

local function publish()
    if #segments == 0 then
        mp.del_property("user-data/sponsorblock/segments")
    else
        mp.set_property_native("user-data/sponsorblock/segments", segments)
    end
end

local function youtube_id(s)
    if not s or s == "" then return nil end
    local id
    if s:match("youtube%.com/watch") then
        id = s:match("[?&]v=([%w_%-]+)")
    else
        id = s:match("youtube%.com/live/([%w_%-]+)")
          or s:match("youtube%.com/shorts/([%w_%-]+)")
          or s:match("youtube%.com/embed/([%w_%-]+)")
          or s:match("youtu%.be/([%w_%-]+)")
          or s:match("^ytdl://([%w_%-]+)$")
    end
    if id and #id == 11 then return id end
end

local function parse(id, body)
    local json = body and utils.parse_json(body)
    if type(json) ~= "table" then return {} end   -- "Not Found" when no video matches
    local list = {}
    for _, video in ipairs(json) do
        if video.videoID == id then
            for _, s in ipairs(video.segments or {}) do
                local a, b = s.segment and s.segment[1], s.segment and s.segment[2]
                if LABELS[s.category] and a and b and b > a then
                    list[#list + 1] = { start = a, stop = b, category = s.category,
                                        label = LABELS[s.category] }
                end
            end
        end
    end
    table.sort(list, function(x, y) return x.start < y.start end)
    return list
end

local function fetch(id)
    requested = true
    local gen = generation
    local cats = {}
    for c in pairs(LABELS) do cats[#cats + 1] = c end
    table.sort(cats)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "sh", "-c",
            'p=$(printf %s "$1" | sha256sum | cut -c1-4) && ' ..
            'exec curl -sL --max-time 10 -G --data-urlencode "$2" --data-urlencode "$3" "$4/$p"',
            "sh", id, "categories=" .. utils.format_json(cats),
            'actionTypes=["skip","mute"]', API },
    }, function(ok, res)
        if gen ~= generation then return end
        if not ok or res.status ~= 0 then
            msg.warn("request failed for " .. id .. ": " .. tostring(res and res.status))
            return
        end
        segments = parse(id, res.stdout)
        msg.info(("%d segment(s) for %s"):format(#segments, id))
        publish()
    end)
end

local function auto_skip(_, pos)
    if not pos or not skipping or seek_pending or mp.get_property_bool("pause") then return end
    for i, s in ipairs(segments) do
        -- the 0.1 s margin keeps a landing just short of the end from skipping again
        if AUTO_SKIP[s.category] and pos >= s.start and pos < s.stop - 0.1 then
            -- skipped segments that follow within a second join this skip,
            -- so an intro straight into a sponsor costs one seek, not two
            local stop, names, seen = s.stop, { s.label:lower() }, { [s.category] = true }
            for j = i + 1, #segments do
                local n = segments[j]
                if AUTO_SKIP[n.category] and n.start <= stop + 1 and n.stop > stop then
                    stop = n.stop
                    if not seen[n.category] then
                        seen[n.category] = true
                        names[#names + 1] = n.label:lower()
                    end
                end
            end
            seek_pending = true
            mp.commandv("seek", stop + 0.01, "absolute+exact")
            mp.osd_message(("Skipped %s (%d s)"):format(table.concat(names, " and "),
                                                        math.floor(stop - pos + 0.5)))
            return
        end
    end
end

mp.register_event("start-file", function()
    generation = generation + 1
    segments, skipping, requested, seek_pending = {}, true, false, false
    publish()
    local id = youtube_id(mp.get_property("path"))
    if id then fetch(id) end
end)

-- a downloaded video carries its source URL in the PURL tag
mp.register_event("file-loaded", function()
    if requested then return end
    local id = youtube_id(mp.get_property("metadata/by-key/PURL"))
    if id then fetch(id) end
end)

mp.register_event("playback-restart", function() seek_pending = false end)
mp.observe_property("time-pos", "number", auto_skip)

mp.add_key_binding("b", "toggle", function()
    skipping = not skipping
    mp.osd_message(skipping and "SponsorBlock: auto skip on"
                             or "SponsorBlock: auto skip off for this video")
end)
