-- seek_preview.lua
-- Seek bar preview pictures for the patched ModernZ, made ahead of time so a
-- hover only ever shows a picture that already exists.
--
-- WHY NOT THUMBFAST. thumbfast runs a second mpv that cannot see this
-- player's cache, so it downloads the stream again for every hover, and for
-- YouTube it opens the stream the main player picked, 4K AV1 included. Its
-- first answer is the nearest keyframe (about 0.3 s), but once the mouse rests
-- it seeks to the exact frame, which decodes every frame from that keyframe on
-- the CPU. Measured on a 4K AV1 60 fps video that took 3.1 to 5.5 s per
-- picture, and it happened on parts that were already in the cache.
--
-- WHERE THE PICTURES COME FROM
--
--   1. The demuxer cache. `dump-cache a b file` copies a slice of the cache to
--      a file without touching the network, and ffmpeg decodes only its
--      keyframes. A slice starts at the last keyframe at or before a and ends
--      just before the first keyframe after b, with its timestamps rebased to
--      zero. So each slice starts where the previous one's last keyframe was,
--      and that keyframe, whose time is known, anchors the next slice. A chain
--      that starts at the beginning of a cached range is anchored by the
--      range start. Measured against the keyframes of a whole dump, chained
--      times were within 7 ms. A 5 s slice of 4K AV1 is about 35 MB and took
--      8 to 26 ms to dump, and 30 dumps in 30 s cost no dropped or delayed
--      frame. Decoding the 28 keyframes of two minutes took 0.26 s of CPU.
--   2. YouTube storyboards, for what is not cached yet. They are the small
--      picture sheets youtube.com uses for its own seek bar, listed in the
--      yt-dlp JSON that ytdl_hook already fetched, so they cost no extra
--      yt-dlp call. One picture every 1 to 2 s on short videos, about 5 s at
--      ten minutes and 10 s on long ones.
--
-- A keyframe picture is shown from its keyframe until the next one, 1 to 5 s
-- apart on average. Exact frames would mean decoding from the keyframe to the
-- hover point, which is the slow step above, so previews snap to keyframes.
--
-- Everything lives in $XDG_RUNTIME_DIR, which is RAM, never on a drive. A
-- 480x270 picture is 518 KB, so a ten minute video holds about 110 MB of
-- keyframe pictures, and ram_mb caps a long one by keeping fewer of them.
-- Storyboard pictures stay at YouTube's 320x180 and are stretched on screen,
-- 230 KB each. The folder of a file is removed when the file ends, and
-- folders left by a player that crashed are removed when the next one starts.
--
-- HDR sources are tone mapped, since a PQ picture converted straight to RGB
-- looks grey and washed out.
--
-- ModernZ asks with `script-message-to seek_preview thumb <sec> <x> <y>` and
-- `clear`, and listens for `seek_preview-info`, which is thumbfast's protocol
-- under this script's name. Overlay id 42 is this script's, chat_overlay.lua
-- keeps its emotes off it.

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'

local o = {
    max_width  = 480,
    max_height = 480,
    -- a dump stalls the playback thread for as long as it writes, so slices
    -- are cut to about this many megabytes (13 ms median for 35 MB)
    slice_mb   = 24,
    -- keyframe pictures of one video stay under this, a long file then keeps
    -- fewer of them rather than filling the RAM folder
    ram_mb     = 512,
}
options.read_options(o, "seek_preview")

local OVERLAY_ID = 42
local BASE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/mpv-seek-preview"
local PID_DIR = BASE .. "/" .. utils.getpid()

-- Slices are cut by size, so a low bitrate stream gets long ones. These bound
-- them in seconds.
local SLICE_MIN, SLICE_MAX = 4, 90
-- YouTube keyframes measured 7 s apart at most. A picture past the last
-- keyframe of a chain is only trusted this far.
local MAX_GOP = 10

local gen = 0           -- bumped per file, a late answer for an old file is dropped
local dir = nil         -- this file's folder, nil while previews are off
local W, H = 0, 0
local tonemap = false
local duration = nil
local pics = {}         -- keyframe pictures, sorted by t: { t, file, off }
local chains = {}       -- stretches whose keyframes are all known: { a, b, limit, last_b, final }
local board = nil       -- storyboard: { file, interval, count, w, h }
local busy = false      -- a slice is being dumped or decoded
local failures = 0
local slice_n = 0
local jobs = {}         -- running async commands, aborted when the file ends
local hover = nil       -- last thumb request: { t, x, y }
local shown = nil       -- what is on screen, so a repeated request costs nothing
local pump_timer = nil
local loaded = false    -- file-loaded has fired for the current file

local function run(cmd, cb)
    local id
    id = mp.command_native_async(cmd, function(ok, res, err)
        jobs[id] = nil
        if cb then cb(ok, res, err) end
    end)
    jobs[id] = true
    return id
end

local function sh(args)
    return mp.command_native({ name = "subprocess", args = args, playback_only = false,
                               capture_stdout = true, capture_stderr = true })
end

local function publish(disabled)
    mp.commandv("script-message", "seek_preview-info", utils.format_json({
        width = W, height = H, disabled = disabled, available = true }))
end

-- newest picture at or before t, by index
local function find(t)
    local lo, hi, best = 1, #pics, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if pics[mid].t <= t then best, lo = mid, mid + 1 else hi = mid - 1 end
    end
    return best
end

local function chain_at(t)
    for _, c in ipairs(chains) do
        if t >= c.a - 0.05 and t <= c.limit then return c end
    end
end

local function lookup(t)
    local i, c = find(t), chain_at(t)
    if i and c and pics[i].t >= c.a - 0.05 then return pics[i] end
    if board and board.count > 0 then
        local n = math.min(math.max(math.floor(t / board.interval), 0), board.count - 1)
        return { file = board.file, off = n * board.w * board.h * 4, w = board.w, h = board.h }
    end
end

local function draw()
    if not hover or not dir then return end
    local p = lookup(hover.t)
    if not p then
        if shown then
            mp.command_native_async({ "overlay-remove", OVERLAY_ID }, function() end)
            shown = nil
        end
        return
    end
    local key = p.file .. ":" .. p.off .. ":" .. hover.x .. ":" .. hover.y
    if key == shown then return end
    shown = key
    -- a storyboard picture is stored at its own smaller size and stretched
    -- here, which is the same picture for less than half the RAM
    local w, h = p.w or W, p.h or H
    mp.command_native_async({ "overlay-add", OVERLAY_ID, hover.x, hover.y, p.file, p.off,
                              "bgra", w, h, 4 * w, W, H }, function() end)
end

---------------------------------------------------------------- cache slices

local function add_picture(t, file, off, min_gap)
    local i = find(t)
    if i and t - pics[i].t < min_gap then return end
    if pics[(i or 0) + 1] and pics[(i or 0) + 1].t - t < min_gap then return end
    table.insert(pics, (i or 0) + 1, { t = t, file = file, off = off })
end

local function merge_chains()
    table.sort(chains, function(x, y) return x.a < y.a end)
    local i = 1
    while chains[i + 1] do
        local c, n = chains[i], chains[i + 1]
        if n.a <= c.b + 0.05 then
            if n.b > c.b then c.b, c.limit, c.last_b, c.final = n.b, n.limit, n.last_b, n.final end
            table.remove(chains, i + 1)
        else
            i = i + 1
        end
    end
end

-- The chain that can be continued from t: it covers t and its last keyframe
-- is still at or after t, so that keyframe is still in the cache.
local function covering(t)
    local best
    for _, c in ipairs(chains) do
        if c.a - 0.05 <= t and c.b >= t - 0.01 and (not best or c.b > best.b) then best = c end
    end
    return best
end

-- The next slice to cut: the range holding the playhead first, then the
-- others by distance. Inside a range, continue the chain that covers its
-- start, or start one at the range start.
local function next_slice(state)
    local ranges = state["seekable-ranges"]
    if not ranges or #ranges == 0 then return end
    local cached = 0
    for _, r in ipairs(ranges) do cached = cached + (r["end"] - r.start) end
    local rate = (state["total-bytes"] or 0) / math.max(cached, 1)
    local span = math.min(math.max(o.slice_mb * 1e6 / math.max(rate, 1), SLICE_MIN), SLICE_MAX)

    local pos = mp.get_property_number("time-pos", 0)
    local order = {}
    for _, r in ipairs(ranges) do order[#order + 1] = r end
    local function dist(r)
        return (pos < r.start and r.start - pos) or (pos > r["end"] and pos - r["end"]) or 0
    end
    table.sort(order, function(x, y) return dist(x) < dist(y) end)

    for _, r in ipairs(order) do
        local r_end = r["end"]
        local at_end = duration and r_end >= duration - 0.5
        local c = covering(r.start + 0.05)
        -- walk along chains that meet, to the last keyframe known in this range
        while c do
            local nxt = covering(c.b + 0.05)
            if not nxt or nxt.b <= c.b then break end
            c = nxt
        end
        if c then
            -- A slice ends just before the first keyframe after its end, so
            -- one cut at the cache front would find nothing new. While the
            -- range grows only whole spans are cut, and a span that held no
            -- keyframe after the anchor is retried longer.
            local b = c.b + span
            if c.last_b and c.last_b >= b then b = c.last_b + span end
            if at_end and not c.final and c.b < r_end - 0.1 then
                return { chain = c, a = c.b + 0.001, b = math.min(b, r_end),
                         range_end = r_end, at_end = true }
            elseif not at_end and b <= r_end then
                return { chain = c, a = c.b + 0.001, b = b, range_end = r_end }
            end
        elseif r_end - r.start >= span or at_end then
            -- a range starts with a keyframe, so the slice starts there too
            return { a = r.start + 0.05, b = math.min(r.start + span, r_end),
                     origin = r.start, range_end = r_end, at_end = at_end }
        end
    end
end

local function filters()
    local scale = ("scale=%d:%d:flags=bilinear"):format(W, H)
    if not tonemap then return scale .. ",format=bgra,showinfo" end
    -- scaled first, so the tone mapping only ever touches preview sized pictures
    return scale .. ",zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,"
                 .. "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,"
                 .. "format=bgra,showinfo"
end

local function decoded(job, my_gen, out, res)
    if my_gen ~= gen then return end
    local times = {}
    for t in (res.stderr or ""):gmatch("pts_time:%s*([%-%d%.]+)") do times[#times + 1] = tonumber(t) end
    local info = utils.file_info(out)
    local n = info and math.floor(info.size / (W * H * 4)) or 0
    -- the frame count comes from both sides, a mismatch means the slice
    -- cannot be mapped to video time and its pictures would be wrong
    local reached = job.b >= job.range_end - 0.01
    if res.status ~= 0 or n == 0 or n ~= #times then
        failures = failures + 1
        msg.verbose(("slice %.1f to %.1f gave %d pictures and %d times"):format(job.a, job.b, n, #times))
        if job.chain then job.chain.last_b = job.b end
        return
    end
    -- A chained slice starts at the anchor keyframe, whose time is known. The
    -- first slice of a range has its timestamps rebased to the range start.
    local offset = job.chain and (job.chain.b - times[1]) or job.origin
    local most = o.ram_mb * 1e6 / (W * H * 4)
    local min_gap = math.max(1, (duration or 0) / most)
    for k, t in ipairs(times) do
        add_picture(offset + t, out, (k - 1) * W * H * 4, min_gap)
    end
    local last = offset + times[#times]
    local c = job.chain
    if not c then
        c = { a = offset + times[1] }
        chains[#chains + 1] = c
    end
    c.last_b = (last <= (c.b or -1) + 0.01) and job.b or nil
    c.b = last
    c.limit = job.at_end and reached and duration or math.min(job.range_end, last + MAX_GOP)
    c.final = job.at_end and reached
    msg.debug(("slice %.1f to %.1f: %d keyframes, chain %.1f to %.1f, %d pictures")
              :format(job.a, job.b, #times, c.a, c.b, #pics))
    merge_chains()
    failures = 0
    draw()
end

local function cut(job)
    busy = true
    local my_gen = gen
    slice_n = slice_n + 1
    local slice = dir .. "/slice.mkv"
    local out = ("%s/k%05d.bgra"):format(dir, slice_n)
    run({ "dump-cache", ("%.3f"):format(job.a), ("%.3f"):format(job.b), slice }, function(ok)
        if my_gen ~= gen then return end
        if not ok then
            failures = failures + 1
            busy = false
            if job.chain then job.chain.last_b = job.b end
            return
        end
        run({ name = "subprocess", playback_only = false, capture_stderr = true,
              args = { "nice", "-n", "10", "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "info",
                       "-threads", "2", "-skip_frame", "nokey", "-i", slice, "-map", "0:v:0",
                       "-vf", filters(), "-fps_mode", "passthrough",
                       "-f", "rawvideo", "-pix_fmt", "bgra", "-y", out } },
            function(ok2, res)
                if my_gen ~= gen then return end
                busy = false
                if ok2 and res then decoded(job, my_gen, out, res) else failures = failures + 1 end
                os.remove(slice)
            end)
    end)
end

local function pump()
    if busy or not dir or W == 0 or failures >= 5 then return end
    local state = mp.get_property_native("demuxer-cache-state")
    if not state then return end
    local job = next_slice(state)
    if job then cut(job) end
end

---------------------------------------------------------------- storyboards

local function youtube_json()
    local res = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if type(res) ~= "table" or res.status ~= 0 or not res.stdout then return end
    local json = utils.parse_json(res.stdout)
    if type(json) ~= "table" or json.extractor_key ~= "Youtube" then return end
    -- the property keeps the last answer, which may belong to another entry
    local path = mp.get_property("path", "")
    if not json.id or not path:find(json.id, 1, true) then return end
    return json
end

local function storyboard()
    local json = youtube_json()
    if not json then return end
    local pick
    for _, f in ipairs(json.formats or {}) do
        if f.format_note == "storyboard" and f.fragments and f.fps and f.columns and f.rows then
            -- the smallest sheet still at least as wide as a picture, else the largest
            if not pick or (pick.width < W and f.width > pick.width)
               or (f.width >= W and f.width < pick.width) then
                pick = f
            end
        end
    end
    if not pick then return end
    local my_gen = gen
    local args = { "curl", "-sS", "--fail", "--max-time", "60", "--parallel", "--parallel-max", "8" }
    for k, frag in ipairs(pick.fragments) do
        args[#args + 1] = "-o"
        args[#args + 1] = ("%s/sb_%04d.jpg"):format(dir, k - 1)
        args[#args + 1] = frag.url
    end
    local out = dir .. "/storyboard.bgra"
    -- never stored larger than YouTube made it, the overlay stretches it
    local bw = math.min(W, pick.width)
    local bh = math.floor(bw * H / W / 2 + 0.5) * 2
    local sheets = {}
    for k = 1, #pick.fragments do sheets[k] = ("%s/sb_%04d.jpg"):format(dir, k - 1) end
    run({ name = "subprocess", playback_only = false, capture_stderr = true, args = args }, function()
        if my_gen ~= gen then return end
        -- One ffmpeg per sheet. The sheets are named .jpg but arrive as WebP,
        -- and the last one is cut down to the pictures it holds, so a single
        -- run over all of them reinitialises its filters mid stream and
        -- aborts on timestamps that go backwards. Each sheet is padded to the
        -- full grid and cut into exactly columns x rows pictures, so picture n
        -- always sits at offset n. A sheet that failed to download ends the
        -- file there, since every later picture would shift.
        local vf = ("pad=%d:%d:0:0:black,untile=%dx%d,scale=%d:%d:flags=lanczos,format=bgra")
                   :format(pick.width * pick.columns, pick.height * pick.rows,
                           pick.columns, pick.rows, bw, bh)
        local cmd = { "nice", "-n", "10", "sh", "-c",
            'out=$1; vf=$2; shift 2; : > "$out"; for f in "$@"; do [ -s "$f" ] || exit 0; ' ..
            'ffmpeg -nostdin -v error -i "$f" -vf "$vf" -f rawvideo -pix_fmt bgra - >> "$out" || exit 1; done',
            "sh", out, vf }
        for _, s in ipairs(sheets) do cmd[#cmd + 1] = s end
        run({ name = "subprocess", playback_only = false, capture_stderr = true, args = cmd },
            function(ok, res)
                if my_gen ~= gen then return end
                sh({ "sh", "-c", 'rm -f -- "$1"/sb_*.jpg', "sh", dir })
                -- only whole sheets count, a sheet that broke off would shift nothing
                -- before it but may be incomplete itself
                local info = utils.file_info(out)
                local per = pick.columns * pick.rows
                local done = info and math.floor(info.size / (bw * bh * 4) / per) * per or 0
                if not ok or res.status ~= 0 then
                    msg.warn("storyboard stopped early: " .. tostring(res and res.stderr))
                end
                if done == 0 then return end
                local total = math.ceil((duration or 0) * pick.fps)
                board = { file = out, interval = 1 / pick.fps, count = math.min(done, total),
                          w = bw, h = bh }
                msg.verbose(("storyboard %s, %d pictures, one per %.1f s")
                            :format(pick.format_id, board.count, board.interval))
                draw()
            end)
    end)
end

---------------------------------------------------------------- file life

local function remove_dir(d)
    if d then sh({ "rm", "-rf", "--", d }) end
end

local function stop()
    gen = gen + 1
    for id in pairs(jobs) do mp.abort_async_command(id) end
    jobs = {}
    if pump_timer then pump_timer:kill() end
    if shown then mp.commandv("overlay-remove", OVERLAY_ID) end
    remove_dir(dir)
    dir, W, H, tonemap, duration = nil, 0, 0, false, nil
    pics, chains, board, busy, failures, slice_n, shown = {}, {}, nil, false, 0, 0, nil
    loaded = false
    publish(true)
end

-- Starts once the video size is known, which is after the first frame.
local function start()
    local params = mp.get_property_native("video-params")
    if dir or not loaded or not params or not params.dw or params.dw == 0 then return end
    local track = mp.get_property_native("current-tracks/video")
    duration = mp.get_property_number("duration")
    if not track or track.image or track.albumart or not duration then return end
    local aspect = params.dw / params.dh
    if aspect >= o.max_width / o.max_height then
        W, H = o.max_width, math.floor(o.max_width / aspect / 2 + 0.5) * 2
    else
        W, H = math.floor(o.max_height * aspect / 2 + 0.5) * 2, o.max_height
    end
    tonemap = params.gamma == "pq" or params.gamma == "hlg"
    dir = PID_DIR .. "/" .. gen
    local res = sh({ "mkdir", "-p", dir })
    if res.status ~= 0 then dir = nil return end
    publish(false)
    storyboard()
    if not pump_timer then
        pump_timer = mp.add_periodic_timer(0.1, pump)
    else
        pump_timer:resume()
    end
end

-- folders of players that are gone, left behind by a crash
local function sweep()
    for _, pid in ipairs(utils.readdir(BASE, "dirs") or {}) do
        if not utils.file_info("/proc/" .. pid) or pid == tostring(utils.getpid()) then
            remove_dir(BASE .. "/" .. pid)
        end
    end
end

mp.register_script_message("thumb", function(t, x, y)
    t, x, y = tonumber(t), tonumber(x), tonumber(y)
    if not t or not x or not y then return end
    hover = { t = t, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
    draw()
end)

mp.register_script_message("clear", function()
    hover = nil
    if shown then
        mp.command_native_async({ "overlay-remove", OVERLAY_ID }, function() end)
        shown = nil
    end
end)

mp.register_event("start-file", stop)
mp.register_event("end-file", stop)
mp.register_event("shutdown", function()
    stop()
    remove_dir(PID_DIR)
end)
mp.register_event("file-loaded", function()
    loaded = true
    start()
end)
mp.observe_property("video-params", "native", start)

sweep()
publish(true)
