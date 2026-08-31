-- Show ModernZ's audio-tracks button only when the file has more than one
-- audio track. ModernZ re-reads script-opts at runtime (read_options callback
-- with request_init), so flipping the option here re-layouts the OSC live.
-- Note: "script-opts/<key>" sub-properties aren't writable; update the whole
-- key/value list instead.
mp.observe_property("track-list", "native", function(_, tracks)
    local n = 0
    for _, t in ipairs(tracks or {}) do
        if t.type == "audio" then n = n + 1 end
    end
    local want = n > 1 and "yes" or "no"
    local opts = mp.get_property_native("script-opts") or {}
    if opts["modernz-audio_tracks_button"] ~= want then
        opts["modernz-audio_tracks_button"] = want
        mp.set_property_native("script-opts", opts)
    end
end)
