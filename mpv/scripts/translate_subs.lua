-- English subtitles for Japanese YouTube videos
--
-- WHAT IT DOES. On a YouTube video whose original speech is Japanese, one key
-- starts a background worker that fetches the original audio track, transcribes
-- it, translates it and writes a growing SRT which is added as a normal
-- subtitle track. The worker runs far ahead of playback, so subtitles are
-- simply there when their moment arrives.
--
-- OFF BY DEFAULT, deliberately. Nothing is downloaded, no model is loaded and
-- no GPU work happens until the key is pressed. The only thing that runs by
-- itself is the language probe, which is a metadata lookup with no audio and
-- no GPU.
--
-- WHY A NATIVE SUBTITLE TRACK RATHER THAN AN OSD OVERLAY. The chat overlay's
-- "beside" mode shrinks the video with video-margin-ratio-right. Subtitles
-- drawn by mpv live in the video rectangle and follow that shrink for free,
-- and mpv's own sub-use-margins then places them in the black bar rather than
-- on top of the picture. An overlay would have to track the margin itself.
-- The two features share no state; this one only ever reads.
--
-- WHY RELOADS ARE RARE AND TIMED. Re-reading the file blanks the displayed cue
-- briefly. Measured: at two reloads a second, 0,83% of samples were blank
-- while a cue was due, every episode under one frame at 60 Hz; at one reload
-- per five seconds, 3 samples in 4282. Deferring each reload into a gap
-- between cues measured zero. Since the worker is minutes ahead there is no
-- reason to reload often, so it does both -- rarely, and in a gap.

local mp      = require "mp"
local msg     = require "mp.msg"
local utils   = require "mp.utils"
local options = require "mp.options"

local o = {
    -- run the language probe on every youtube file
    probe = true,
    -- announce on screen when a video is eligible
    announce = true,

    -- what to do with speech that was already in english
    -- "suppress" drops those cues, "off" keeps everything
    filter_english = "suppress",
    -- share of latin letters above which a line counts as english
    latin_threshold = 0.5,
    -- lines shorter than this are never judged
    min_chars = 3,

    asr_model = "large-v3",
    mt_model = "entai2965/sugoi-v4-ja-en-ctranslate2",
    device = "cuda",
    beam_size = 5,

    -- a gap this far ahead of the playhead counts as urgent and is
    -- transcribed at full speed; everything else is filled in the background
    lookahead = 180,
    -- what the worker does once the window in front of the playhead is
    -- covered. "whole" carries on and transcribes the entire video, so
    -- seeking is instant afterwards, at the cost of the gpu being busy for
    -- several minutes. "ahead" stops there and idles, keeping the gpu nearly
    -- free, at the cost of a short wait when seeking somewhere unvisited.
    fill = "whole",
    -- drop cached audio untouched for this many days; 0 keeps it for ever
    audio_cache_days = 7,
    -- seconds of audio per transcription pass
    chunk = 120,
    -- never hand the recogniser less audio than this. A short clip is where it
    -- invents closing lines, and clip length is not a free choice: it is
    -- whatever gap is left to fill, and seeking leaves small ones
    -- Never do less work than this in one pass. The gap left to fill at the
    -- leading edge of the window is whatever playback has just uncovered, a
    -- second or two, and transcribing that on its own made the worker
    -- recognise the same speech again and again with slightly different
    -- boundaries.
    min_clip = 120,
    -- Already covered audio handed to the recogniser before the gap, as a
    -- running start, so no sentence is cut at a cold clip boundary.
    clip_back = 15,
    -- Voice activity detection. Off on purpose: the detector removes what it
    -- judges to be non-speech before the recogniser sees it, so anything it
    -- misjudges produces no subtitle at all. Against a human track, 7% of the
    -- speech in a noisy video went missing with it on against 3% with it off, in
    -- stretches of up to 24 seconds. It costs throughput, which is spare.
    vad = false,
    -- keep total cached audio under this many megabytes, oldest dropped
    -- first; 0 disables. Cues are never dropped, they cost gpu time to rebuild
    audio_cache_mb = 2000,
    -- group recogniser segments into whole clauses before translating, so the
    -- translator sees a sentence with its predicate rather than a fragment
    merge = true,
    -- silence between words that ends a group
    merge_gap = 0.4,
    -- show a translated clause on the timings of the speech it came from,
    -- rather than as one cue lasting the whole clause
    split_cues = true,
    -- a cue is never displayed longer than this, and never shorter than the
    -- minimum unless the next cue starts sooner
    max_cue = 7,
    min_cue = 1,
    -- translate a partial batch after this long, so the first subtitle after a
    -- seek does not wait for a full batch of clauses
    emit_after = 2.5,
    -- japanese term to english replacements applied before translation, tab
    -- separated. Empty uses the file next to this config if there is one
    glossary = "",
    -- share of the wall clock the background fill may use, so the video
    -- shaders keep the gpu they need
    duty = 0.8,
    -- restart transcription this far before the playback position after a seek
    rewind = 5,

    -- never reload the subtitle file more often than this
    reload_interval = 20,
    -- how long to wait for a gap between cues before reloading anyway
    reload_defer_max = 5,
    -- how often to publish the playback position and look for new cues
    poll = 1.0,
    -- treat the video as watched through when the playhead got this close to
    -- the end. The cached audio is then dropped, since it is only needed again
    -- for a stretch that was skipped and refetching costs seconds
    watched_slack = 60,
}
options.read_options(o, "translate_subs")

local STATE_DIR = (os.getenv("XDG_STATE_HOME")
                   or ((os.getenv("HOME") or ".") .. "/.local/state"))
                  .. "/mpv/translate-subs"

local eligible   = nil   -- probe result for the current file
local probe_job  = nil
local job        = nil   -- running worker, see start()
local timer      = nil

------------------------------------------------------------------ identity

-- Same keying as the per-file volume store: the video id alone, so the same
-- video opened directly and out of a playlist share one cache entry.
local function identity()
    local path = mp.get_property("path") or ""
    if path == "" then return nil end
    local id = path:match("[?&]v=([%w_%-]+)")
             or path:match("youtube%.com/live/([%w_%-]+)")
             or path:match("youtube%.com/embed/([%w_%-]+)")
             or path:match("^https?://youtu%.be/([%w_%-]+)")
    if id then return "yt:" .. id, path end
    return nil
end

local function is_youtube()
    local p = mp.get_property("path") or ""
    return p:match("youtube%.com/") ~= nil or p:match("youtu%.be/") ~= nil
end

-- mpv started from the browser handoff inherits the browser's environment,
-- whose PATH does not contain ~/.local/bin. Resolve by absolute path first;
-- testing from a login shell hides this completely.
local function helper_cmd()
    local home = os.getenv("HOME") or ""
    for _, cand in ipairs({ home .. "/mpv-config/bin/mpv-translate-source",
                            home .. "/.local/bin/mpv-translate-source",
                            "/usr/local/bin/mpv-translate-source" }) do
        local info = utils.file_info(cand)
        if info and info.is_file then return cand end
    end
    return "mpv-translate-source"
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--------------------------------------------------------------------- probe

local function probe_file()
    eligible = nil
    if probe_job then
        mp.abort_async_command(probe_job)
        probe_job = nil
    end
    if not o.probe or not is_youtube() then return end

    local key, url = identity()
    if not key then return end

    local h
    h = mp.command_native_async({
        name = "subprocess",
        args = { helper_cmd(), "--detect", url },
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if h ~= probe_job then return end   -- a newer file superseded us
        probe_job = nil
        if not success or not res or res.status ~= 0 then
            msg.warn("language probe failed")
            return
        end
        local ok, data = pcall(utils.parse_json, res.stdout or "")
        if not ok or type(data) ~= "table" then return end
        eligible = data.japanese == true
        msg.info("language probe: japanese=" .. tostring(eligible) ..
                 " (" .. tostring(data.reason) .. ")")
        if eligible and o.announce and not job then
            mp.osd_message("Japanese detected. Press the translate key for English subtitles.", 4)
        end
    end)
    probe_job = h
end

------------------------------------------------------------------- worker

local function our_sid()
    if not job then return nil end
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t["external-filename"] == job.srt then
            return t.id
        end
    end
    return nil
end

-- Publish progress so other scripts can show it without either side knowing
-- anything about the other. The key cheat sheet reads this; nothing writes back.
local function publish()
    if not job then
        mp.set_property_native("user-data/translate_subs", { state = "off" })
        return
    end
    local pct = 0
    if (job.duration or 0) > 0 then
        pct = math.floor(100 * (job.covered or 0) / job.duration + 0.5)
    end
    mp.set_property_native("user-data/translate_subs", {
        state = job.state or "starting",
        download_pct = job.download_pct or 0,
        covered = job.covered or 0,
        duration = job.duration or 0,
        cues = job.cues or 0,
        pct = pct,
        -- Seconds of subtitles in front of the playhead. The number a viewer
        -- actually wants: a percentage of the whole video says nothing about
        -- whether the next minute is covered.
        ahead = job.ahead or 0,
        position = job.last_pos or 0,
    })
end

local function stop(quiet)
    if timer then timer:kill() timer = nil end
    if job then
        if job.handle then mp.abort_async_command(job.handle) end

        -- Drop the cached audio once the video has been watched through. This
        -- has to happen here rather than in the worker: the worker is aborted
        -- rather than asked to stop, so no shutdown code of its own is
        -- guaranteed to run, and the position file it would have read is
        -- removed immediately below. At end-file the position property is
        -- already gone, which is why the last polled value is kept.
        local pos = mp.get_property_number("time-pos") or job.last_pos or 0
        local dur = mp.get_property_number("duration") or job.duration or 0
        if dur > 0 and pos >= dur - o.watched_slack then
            if os.remove(job.srt .. ".audio") then
                msg.info("watched to the end, dropped the cached audio")
            end
        end
        os.remove(job.pos)
        local sid = our_sid()
        if sid then mp.commandv("sub-remove", sid) end
        job = nil
        if not quiet then mp.osd_message("Translation off", 2) end
    end
    publish()
end

-- Publish the playback position for the worker, and pick up new cues.
local function poll()
    if not job then return end

    local pos = mp.get_property_number("time-pos")
    if pos then
        job.last_pos = pos
        local f = io.open(job.pos .. ".tmp", "w")
        if f then
            f:write(string.format("%.3f", pos))
            f:close()
            os.rename(job.pos .. ".tmp", job.pos)
        end
    end

    -- status is advisory only; the subtitle file is the real output
    local raw = read_file(job.srt .. ".status")
    if raw then
        local ok, st = pcall(utils.parse_json, raw)
        if ok and type(st) == "table" then
            if st.state == "failed" and not job.reported then
                job.reported = true
                msg.error("translate worker failed: " .. tostring(st.error))
                mp.osd_message("Translation failed: " .. tostring(st.error), 6)
                stop(true)
                return
            end
            job.cues = tonumber(st.cues) or job.cues
            job.state = st.state or job.state
            job.covered = tonumber(st.covered) or job.covered
            job.duration = tonumber(st.duration) or job.duration
            job.download_pct = tonumber(st.download_pct) or job.download_pct
            job.ahead = tonumber(st.ahead) or job.ahead
        end
    end

    publish()

    local info = utils.file_info(job.srt)
    if not info or info.size == 0 then return end

    if not job.added then
        mp.commandv("sub-add", job.srt, "select", "Japanese to English", "eng")
        job.added = true
        job.size = info.size
        job.last_reload = mp.get_time()
        mp.osd_message("English subtitles on", 2)
        return
    end

    if info.size == job.size then return end     -- nothing new on disk

    -- Only touch OUR track. If a different subtitle track is selected,
    -- sub-reload would reload that one instead.
    local sid = our_sid()
    if not sid or mp.get_property_number("sid") ~= sid then return end

    local now = mp.get_time()
    if now - job.last_reload < o.reload_interval then return end

    -- Reload in a gap between cues; a reload blanks the displayed cue for a
    -- few milliseconds and this makes that unobservable. Do not wait forever.
    local showing = (mp.get_property("sub-text") or "") ~= ""
    job.waiting = job.waiting or now
    if showing and (now - job.waiting) < o.reload_defer_max then return end

    mp.commandv("sub-reload")
    job.size = info.size
    job.last_reload = now
    job.waiting = nil
end

local function start()
    local key, url = identity()
    if not key then
        mp.osd_message("Translation works on YouTube videos only", 3)
        return
    end

    utils.subprocess({ args = { "mkdir", "-p", STATE_DIR }, cancellable = false })

    local slug = key:gsub("[^%w]", "_")
    job = {
        key = key,
        srt = STATE_DIR .. "/" .. slug .. ".srt",
        pos = STATE_DIR .. "/" .. slug .. ".pos",
        added = false, size = -1, cues = 0, state = "starting",
        covered = 0, duration = 0, download_pct = 0,
        last_reload = 0,
    }

    -- Seed the position immediately so the worker starts near the playback
    -- point rather than at the beginning of a long video.
    local pos = mp.get_property_number("time-pos") or 0
    local f = io.open(job.pos, "w")
    if f then f:write(string.format("%.3f", pos)) f:close() end

    local args = { helper_cmd(), url,
                   "--out", job.srt,
                   "--pos-file", job.pos,
                   "--parent-pid", tostring(utils.getpid()),
                   "--asr-model", o.asr_model,
                   "--mt-model", o.mt_model,
                   "--device", o.device,
                   "--beam-size", tostring(o.beam_size),
                   "--lookahead", tostring(o.lookahead),
                   "--rewind", tostring(o.rewind),
                   "--chunk", tostring(o.chunk),
                   "--min-clip", tostring(o.min_clip),
                   "--clip-back", tostring(o.clip_back),
                   "--vad", o.vad and "1" or "0",
                   "--audio-cache-mb", tostring(o.audio_cache_mb),
                   "--merge", o.merge and "1" or "0",
                   "--merge-gap", tostring(o.merge_gap),
                   "--split-cues", o.split_cues and "1" or "0",
                   "--max-cue", tostring(o.max_cue),
                   "--min-cue", tostring(o.min_cue),
                   "--emit-after", tostring(o.emit_after),
                   "--fill", tostring(o.fill),
                   "--audio-cache-days", tostring(o.audio_cache_days),
                   "--duty", tostring(o.duty),
                   "--min-chars", tostring(o.min_chars) }
    if o.glossary ~= "" then
        table.insert(args, "--glossary")
        table.insert(args, o.glossary)
    end
    if o.filter_english == "off" then
        table.insert(args, "--latin-threshold")
        table.insert(args, "2")          -- unreachable ratio, nothing suppressed
    else
        table.insert(args, "--latin-threshold")
        table.insert(args, tostring(o.latin_threshold))
    end

    msg.info("starting translate worker for " .. key)
    mp.osd_message("Preparing English subtitles...", 3)

    local h
    h = mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
    }, function(success, res, err)
        -- The handle is replaced or aborted on purpose when stopping or when
        -- the file changes; only the live handle reports a real failure.
        if not job or h ~= job.handle then return end
        local code = res and res.status
        if success and code == 0 then
            msg.info("translate worker finished")
            return
        end
        local detail = err or (res and res.error_string) or "?"
        local stderr = (res and res.stderr or ""):match("([^\n]*)\n?$") or ""
        msg.error("translate worker failed: " .. tostring(detail) ..
                  " status=" .. tostring(code) .. " " .. stderr)
        mp.osd_message("Translation failed: " .. tostring(detail) ..
                       (stderr ~= "" and ("\n" .. stderr) or ""), 6)
    end)
    job.handle = h

    publish()
    timer = mp.add_periodic_timer(o.poll, poll)
end

local function toggle()
    if job then
        stop(false)
        return
    end
    if eligible == false then
        mp.osd_message("This video is not marked as Japanese. Starting anyway.", 3)
    end
    start()
end

--------------------------------------------------------------------- events

mp.register_event("file-loaded", function()
    stop(true)
    probe_file()
end)

mp.register_event("end-file", function() stop(true) end)
mp.register_event("shutdown", function() stop(true) end)

mp.add_key_binding(nil, "toggle", toggle)
