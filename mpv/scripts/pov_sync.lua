-- pov_sync.lua
-- Several views of one session in one window, lined up by their sound.
--
-- Friends who play together often each upload their own view, with the voice
-- chat in all of them. `script-message pov-add <url>` adds such a recording to
-- the file that plays. bin/mpv-pov-sync finds where the recordings line up by
-- their sound (how is written there), and this script shows all of them in
-- the one window, under one seek bar.
--
-- HOW THEY STAY TOGETHER. Each added view becomes an extra video and audio
-- track of the playing file, opened through an EDL that shifts it by its
-- offset. One that started earlier is entered later (start=offset), one that
-- started later gets black and silence first, from a small file the helper
-- makes once. The tracks then run on the playing file's clock, so seeking,
-- pausing and the seek bar move all of them at once and nothing has to be
-- kept in step. Measured on two local files: the shifted view showed the
-- frame of the right timestamp before, during and after the black part,
-- seeked to or played through. An EDL cannot open mpv's av://lavfi sources,
-- which is why the black part is a real file.
--
-- THE PICTURE. --lavfi-complex scales every view and lays it on a black canvas
-- the size of the display. The canvas is as big as the screen, so the ArtCNN
-- shaders see no upscaling and skip themselves (their WHEN wants 1.3x).
-- Setting the graph string again rebuilds it with a seek, a freeze measured at
-- 164 ms on local files, so layouts change without that:
--   * a zmq filter in the graph takes scale and overlay commands while it
--     plays. They are sent without waiting for answers (DEALER socket), so a
--     whole layout lands in the same frame, measured;
--   * mpv builds the graph anew on every seek, which forgets those commands,
--     so every input starts with a sendcmd filter that reads the layout from a
--     file when the graph is built. Without the files a seek brought the old
--     layout back, with them not one frame of it.
--
-- SOUND. One view is heard at a time. Its audio track is selected like any
-- other, which leaves the other views silent. `aid` is in mpv's
-- watch-later-options, so it is taken out of them while views play: otherwise
-- quitting while another view is heard would bring that track number back the
-- next time the file is opened alone, which is no sound at all.
--
-- The filters run on the CPU, so decoding switches to copy back while views
-- play, and the demuxer cache is cut to cache_mib each way, since every view
-- keeps one. Both come back when the file ends.
--
-- Keys while views play: 1 to 9 make that view big and play its sound, the
-- same key again or 0 shows all views the same size, Alt+1 to Alt+9 only
-- switch the sound, Ctrl+1 to Ctrl+9 put that view on the other screen, the
-- same key again or Ctrl+0 brings it back.
--
-- TWO SCREENS. A view on the other screen is played by a second mpv in a
-- window of its own, kept in step with this one by follower.lua (how is
-- written there), and the TV keeps the other views. Its sound is the second
-- player's, so while it is heard this one plays without sound (aid=no) and
-- passes on its volume and mute. Keys pressed in its window come back here
-- as if pressed here, so both windows answer the same keys.
--
-- DRAGGING. A view dragged onto another trades places with it, in whichever
-- layout is showing, and each layout keeps its own order. The clicks come
-- from an input section over the picture. The section enabled last wins
-- where areas overlap (measured), so this one leaves out the bottom strip
-- where ModernZ's seek bar sits, and says so with `input-section-raised`,
-- on which chat_overlay.lua enables its box again to stay on top of it.
-- While a view is held, the section covers the whole window, and a release
-- always goes to the section that saw the press (measured), so a drop is
-- never lost to another script.
--
-- POV MODE. Shift+F9, or `script-message pov-mode-toggle` from
-- bin/mpv-pov-toggle, makes bin/mpv-ff2mpv-single.sh hand a clicked video
-- over as `pov-add` instead of playing it, so views are added from the
-- browser or Weave. The wrapper asks for user-data/pov_sync/adding, so the
-- state lives and dies with this player, and it ends when the file it was
-- turned on for does.

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'
package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
               .. ";" .. package.path
local spawn   = require 'spawn'
local follower = require 'follower'
local ffi     = require 'ffi'

local o = {
    -- share of the width the big view takes
    focus = 0.75,
    -- demuxer cache per stream and direction while views play
    cache_mib = 1024,
    -- seconds the view names stay on screen after a change
    label_secs = 3,
    -- canvas size, 0 follows the display
    canvas_w = 0,
    canvas_h = 0,
    -- share of the window height at the bottom that stays the seek bar's
    bar = 0.15,
    -- the screen a view goes to on Ctrl+1 to Ctrl+9
    screen = "DP-1",
    -- more mpv options for the player on that screen, split at spaces
    screen_args = "",
}
options.read_options(o, "pov_sync")

local MAX_VIEWS = 9
local BASE = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
local RUN = BASE .. "/mpv-pov-sync-" .. utils.getpid()
local ENDPOINT = RUN .. "/zmq"

ffi.cdef [[
void *zmq_ctx_new(void);
void *zmq_socket(void *ctx, int type);
int zmq_connect(void *s, const char *addr);
int zmq_setsockopt(void *s, int option, const void *value, size_t len);
int zmq_send(void *s, const void *buf, size_t len, int flags);
int zmq_recv(void *s, void *buf, size_t len, int flags);
int zmq_close(void *s);
]]
local ZMQ_DEALER, ZMQ_SNDMORE, ZMQ_DONTWAIT, ZMQ_LINGER = 5, 2, 1, 17
local zmq_ok, zmq = pcall(ffi.load, "libzmq.so.5")
local zctx, zsock = nil, nil
local zbuf = ffi.new("char[256]")

local leader = nil      -- path of the file the views belong to
local urls = {}         -- added urls in order, the leader's not included
local views = {}        -- on screen: { url, name, offset, vid, aid }, [1] is the leader
local job = nil         -- running helper
local again = false     -- urls arrived while the helper ran
local pending = {}      -- async track adds still running
local mode = "grid"     -- "grid" all the same size, "focus" place 1 big
local order = { grid = {}, focus = {} }   -- per layout, place -> view index
local heard = 1         -- index of the view whose sound plays
local saved = nil       -- options changed while views play
local canvas = nil      -- { w, h } the graph was built for
local tiles = nil       -- current layout, per view index: { x, y, w, h }
local slots = nil       -- the same rectangles, per place
local drag = nil        -- a held view: { from, to } places
local placed = {}       -- place -> view index, the views on the TV only
local away = nil        -- index of the view on the other screen
local second = nil      -- the player showing it (follower.lua)
local adding = false    -- POV mode: clicked videos join the file that plays
local SECTION = "pov-views"
local overlay = mp.create_osd_overlay("ass-events")
local label_timer = nil
local progress_timer = nil
local add_timer = nil   -- adds that come in quick succession go to one helper run
local ADD_WAIT = 1.5

-- read by the wrapper and the h sheet
local function publish()
    mp.set_property_native("user-data/pov_sync", { adding = adding, views = #views,
                                                   away = away, screen = o.screen })
end

local function helper_cmd()
    local home = os.getenv("HOME") or ""
    for _, cand in ipairs({ home .. "/.local/bin/mpv-pov-sync",
                            "/usr/local/bin/mpv-pov-sync" }) do
        local info = utils.file_info(cand)
        if info and info.is_file then return cand end
    end
    return "mpv-pov-sync"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function even(x)
    return math.floor(x / 2 + 0.5) * 2
end

-- "all", since the default filter leaves out the zmq socket file
local function remove_dir(dir)
    for _, name in ipairs(utils.readdir(dir, "all") or {}) do
        if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
    end
    os.remove(dir)
end

-- folders of players that are gone, the zmq socket file outlives its player
local function sweep()
    for _, name in ipairs(utils.readdir(BASE, "dirs") or {}) do
        local pid = name:match("^mpv%-pov%-sync%-(%d+)$")
        if pid and not utils.file_info("/proc/" .. pid) then remove_dir(BASE .. "/" .. name) end
    end
end

local function short_name(v)
    local name = v.channel ~= "" and v.channel or v.title or v.url
    -- channel names often end in " Ch. <group>", the part before says it all
    name = name:gsub("%s+Ch%..*$", "")
    if #name > 28 then
        -- cut at a character boundary, not inside a UTF-8 sequence
        local cut = 28
        while cut > 1 and name:byte(cut) >= 0x80 and name:byte(cut) < 0xC0 do cut = cut - 1 end
        name = name:sub(1, cut - 1) .. "…"
    end
    return name
end

---------------------------------------------------------------- layout

local function grid_tiles(n, W, H)
    -- the column count that gives the biggest 16:9 views, ties go to more
    -- columns so two views sit side by side
    local cols, rows, tw = n, 1, 0
    for c = n, 1, -1 do
        local r = math.ceil(n / c)
        local w = math.min(W / c, H / r * 16 / 9)
        if w > tw + 0.5 then cols, rows, tw = c, r, w end
    end
    tw = even(tw)
    local th = even(tw * 9 / 16)
    local out = {}
    local top = (H - rows * th) / 2
    for k = 1, n do
        local r = math.floor((k - 1) / cols)
        local in_row = math.min(cols, n - r * cols)
        local left = (W - in_row * tw) / 2
        out[k] = { x = even(left + ((k - 1) % cols) * tw), y = even(top + r * th), w = tw, h = th }
    end
    return out
end

-- place 1 big on the left, the others in a column on the right
local function focus_tiles(n, W, H)
    local bw = even(W * o.focus)
    local bh = even(bw * 9 / 16)
    if bh > H then bh = H; bw = even(bh * 16 / 9) end
    local m = n - 1
    local sw = W - bw
    local sh = even(sw * 9 / 16)
    if m * sh > H then sh = even(H / m); sw = even(sh * 16 / 9) end
    local out = { { x = 0, y = even((H - bh) / 2), w = bw, h = bh } }
    local top = (H - m * sh) / 2
    for i = 0, m - 1 do
        out[i + 2] = { x = even(bw + (W - bw - sw) / 2), y = even(top + i * sh), w = sw, h = sh }
    end
    return out
end

-- the views the TV shows, in the order they go into the graph
local function on_tv()
    local list = {}
    for k in ipairs(views) do
        if k ~= away then list[#list + 1] = k end
    end
    return list
end

-- sets the places of the current layout and which view sits in each
local function compute_tiles()
    placed = {}
    for _, k in ipairs(order[mode]) do
        if k ~= away then placed[#placed + 1] = k end
    end
    local n = #placed
    if mode == "focus" and n > 1 then
        slots = focus_tiles(n, canvas.w, canvas.h)
    else
        slots = grid_tiles(n, canvas.w, canvas.h)
    end
    tiles = {}
    for s, k in ipairs(placed) do tiles[k] = slots[s] end
end

---------------------------------------------------------------- labels

-- where the canvas sits in the window, in OSD pixels
local function picture()
    local d = mp.get_property_native("osd-dimensions") or {}
    local w, h = d.w or 0, d.h or 0
    if not canvas or w <= 0 or h <= 0 then return nil end
    local ml, mt = d.ml or 0, d.mt or 0
    return { x = ml, y = mt, w = w - ml - (d.mr or 0), h = h - mt - (d.mb or 0), ow = w, oh = h }
end

-- a canvas rectangle in OSD pixels
local function on_screen(p, t)
    local sx, sy = p.w / canvas.w, p.h / canvas.h
    return p.x + t.x * sx, p.y + t.y * sy, t.w * sx, t.h * sy
end

local function box_path(x, y, w, h)
    return ("m %d %d l %d %d l %d %d l %d %d"):format(x, y, x + w, y, x + w, y + h, x, y + h)
end

-- a frame drawn as four bars
local function frame_path(x, y, w, h, b)
    return table.concat({ box_path(x, y, w, b), box_path(x, y + h - b, w, b),
                          box_path(x, y, b, h), box_path(x + w - b, y, b, h) }, " ")
end

local function draw_labels(show)
    local p = picture()
    if not show or not tiles or not p then
        overlay:remove()
        return
    end
    overlay.res_x, overlay.res_y = p.ow, p.oh
    local fs = math.max(16, math.floor(p.oh / 40))
    local ev = {}
    if drag then
        -- the held view dimmed, the place it would go framed
        local x, y, w, h = on_screen(p, slots[drag.from])
        ev[#ev + 1] = ("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H60&\\p1}%s{\\p0}")
            :format(box_path(x, y, w, h))
        if drag.to and drag.to ~= drag.from then
            x, y, w, h = on_screen(p, slots[drag.to])
            ev[#ev + 1] = ("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\1a&H00&\\p1}%s{\\p0}")
                :format(frame_path(x, y, w, h, math.max(4, math.floor(p.oh / 150))))
        end
    end
    for k, v in ipairs(views) do
        local t = tiles[k]
        if t then
            local x, y = on_screen(p, t)
            local text = k .. "  " .. v.name .. (k == heard and "  ♪" or "")
            ev[#ev + 1] = ("{\\an7\\pos(%d,%d)\\fs%d\\bord3\\shad0\\1c&HFFFFFF&\\3c&H000000&}%s")
                :format(x + math.floor(fs / 2), y + math.floor(fs / 3), fs, text)
        end
    end
    if away and views[away] then
        -- bottom left above the seek bar's strip, clear of the view labels
        -- (top centre ran into the top right view's label with three views)
        local text = ("%d  %s  on %s%s"):format(away, views[away].name, o.screen,
                                               away == heard and "  ♪" or "")
        local bottom = math.min(p.y + p.h, p.oh * (1 - o.bar))
        ev[#ev + 1] = ("{\\an1\\pos(%d,%d)\\fs%d\\bord3\\shad0\\1c&HFFFFFF&\\3c&H000000&}%s")
            :format(p.x + math.floor(fs / 2), math.floor(bottom - fs / 3), fs, text)
    end
    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

local function flash_labels()
    draw_labels(true)
    if label_timer then label_timer:kill() end
    label_timer = mp.add_timeout(o.label_secs, function() draw_labels(false) end)
end

---------------------------------------------------------------- graph

-- what each input's sendcmd reads when the graph is built
local function write_layout_files()
    local first = {}
    for k, t in pairs(tiles) do
        first[#first + 1] = ("overlay@o%d x %d, overlay@o%d y %d"):format(k, t.x, k, t.y)
    end
    local head = on_tv()[1]
    for k, t in pairs(tiles) do
        local cmds = ("scale@s%d w %d, scale@s%d h %d"):format(k, t.w, k, t.h)
        if k == head then cmds = cmds .. ", " .. table.concat(first, ", ") end
        write_file(("%s/layout%d.cmd"):format(RUN, k), "0 " .. cmds .. ";\n")
    end
end

local function zmq_connect()
    if zsock or not zmq_ok then return end
    zctx = zctx or zmq.zmq_ctx_new()
    zsock = zmq.zmq_socket(zctx, ZMQ_DEALER)
    local linger = ffi.new("int[1]", 0)
    zmq.zmq_setsockopt(zsock, ZMQ_LINGER, linger, ffi.sizeof("int"))
    zmq.zmq_connect(zsock, "ipc://" .. ENDPOINT)
end

local function zmq_close()
    if zsock then zmq.zmq_close(zsock) end
    zsock = nil
end

-- every command goes out at once, the filter applies all of them before the
-- next frame; the answers are read and dropped
local function zmq_send_layout()
    if not zsock then return end
    while zmq.zmq_recv(zsock, zbuf, 256, ZMQ_DONTWAIT) >= 0 do end
    for k, t in pairs(tiles) do
        for _, c in ipairs({ ("scale@s%d w %d"):format(k, t.w), ("scale@s%d h %d"):format(k, t.h),
                             ("overlay@o%d x %d"):format(k, t.x), ("overlay@o%d y %d"):format(k, t.y) }) do
            zmq.zmq_send(zsock, "", 0, ZMQ_SNDMORE + ZMQ_DONTWAIT)
            zmq.zmq_send(zsock, c, #c, ZMQ_DONTWAIT)
        end
    end
end

local function build_graph()
    local p = {}
    local list = on_tv()
    local n = #list
    for i, k in ipairs(list) do
        local v, t = views[k], tiles[k]
        -- no format filter after the scale: overlay takes yuva420p only, and a
        -- conversion libavfilter adds by itself keeps the size it was built
        -- with, which undid every live resize (measured)
        local scale = ("scale@s%d=w=%d:h=%d:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1")
            :format(k, t.w, t.h)
        local cmd = ("sendcmd=f='%s/layout%d.cmd'"):format(RUN, k)
        if i == 1 then
            p[#p + 1] = ("[vid%d]%s,split[canvas][src%d]"):format(v.vid, cmd, k)
            p[#p + 1] = ("[canvas]scale=2:2,pad=%d:%d:0:0:black,setsar=1,format=yuv420p[bg0]")
                :format(canvas.w, canvas.h)
            p[#p + 1] = ("[src%d]%s[v%d]"):format(k, scale, k)
        else
            p[#p + 1] = ("[vid%d]%s,%s[v%d]"):format(v.vid, cmd, scale, k)
        end
    end
    for i, k in ipairs(list) do
        local t = tiles[k]
        local tail = i == n and (",zmq=b='ipc\\://%s'[vo]"):format(ENDPOINT) or ("[bg%d]"):format(i)
        p[#p + 1] = ("[bg%d][v%d]overlay@o%d=x=%d:y=%d:eof_action=pass%s"):format(i - 1, k, k, t.x, t.y, tail)
    end
    return table.concat(p, ";")
end

local function display_size()
    if o.canvas_w > 0 and o.canvas_h > 0 then return even(o.canvas_w), even(o.canvas_h) end
    local w = mp.get_property_number("display-width")
    local h = mp.get_property_number("display-height")
    if not w or not h or w < 320 or h < 180 then return 1920, 1080 end
    return even(w), even(h)
end

---------------------------------------------------------------- mouse

-- the picture without the seek bar's strip, the whole window while a view
-- is held so the release is caught wherever it happens
local function area_sync()
    local p = picture()
    if not saved or not p then return end
    local x0, y0, x1, y1 = 0, 0, p.ow, p.oh
    if not drag then
        x0, y0 = p.x, p.y
        x1, y1 = p.x + p.w, math.min(p.y + p.h, p.oh * (1 - o.bar))
    end
    mp.set_mouse_area(math.floor(x0), math.floor(y0), math.ceil(x1), math.ceil(y1), SECTION)
end

local function slot_at(m)
    local p = picture()
    if not p or not slots or type(m) ~= "table" then return nil end
    for s, t in ipairs(slots) do
        local x, y, w, h = on_screen(p, t)
        if m.x >= x and m.x < x + w and m.y >= y and m.y < y + h then return s end
    end
end

---------------------------------------------------------------- graph and layout

-- builds the graph anew, needed whenever the inputs or the canvas change
local function rebuild()
    local w, h = display_size()
    canvas = { w = w, h = h }
    compute_tiles()
    write_layout_files()
    mp.set_property("lavfi-complex", build_graph())
    publish()
    zmq_connect()
    area_sync()
    flash_labels()
end

-- a new layout on the running graph, no rebuild
local function relayout()
    if #views < 2 then return end
    compute_tiles()
    write_layout_files()
    zmq_send_layout()
    flash_labels()
end

---------------------------------------------------------------- keys

local function hear(k)
    local v = views[k]
    if not v or not v.aid then return end
    heard = k
    if k == away and second then
        mp.set_property("aid", "no")
        second:set("volume", mp.get_property_number("volume", 100))
        second:set("mute", mp.get_property_bool("mute"))
    else
        if second then second:set("mute", true) end
        mp.set_property_number("aid", v.aid)
    end
    if second then
        second:show(("%d  %s%s"):format(away, views[away].name, away == heard and "  ♪" or ""), o.label_secs)
    end
    flash_labels()
end

-- the view goes to the big place, trading with the one there; the big
-- view's own key goes back to equal sizes
local function choose(k)
    if not views[k] then return end
    -- the one on the other screen cannot be big here, it is only heard
    if k == away then return hear(k) end
    local f = order.focus
    local big = 1
    while f[big] == away do big = big + 1 end
    if mode == "focus" and f[big] == k then
        mode = "grid"
    else
        mode = "focus"
        for s = 1, #f do
            if f[s] == k then f[big], f[s] = f[s], f[big] end
        end
    end
    hear(k)
    relayout()
end

---------------------------------------------------------------- the other screen

-- the keys of the second player's window: every key this player has a
-- binding for comes back here, except the window's own
local function write_second_input()
    local lines = { "CLOSE_WIN quit", "f cycle fullscreen", "MBTN_LEFT_DBL cycle fullscreen" }
    local seen = { CLOSE_WIN = true, f = true, MBTN_LEFT_DBL = true }
    for _, b in ipairs(mp.get_property_native("input-bindings") or {}) do
        local key = b.key
        local up = key and key:upper() or ""
        if key and not seen[key] and key:match("^[%w_+%-<>%[%]{}.,/=!?:']+$")
           and not up:match("^MBTN_LEFT") and not up:match("MOUSE") and not up:match("AXIS") then
            seen[key] = true
            lines[#lines + 1] = ('%s script-message pov-key "%s"'):format(key, key)
        end
    end
    write_file(RUN .. "/second-input.conf", table.concat(lines, "\n") .. "\n")
end

local bring_back

local function start_second(k)
    local v = views[k]
    write_second_input()
    local args = {
        "--vo=" .. (mp.get_property("vo") or "gpu-next"),
        "--gpu-api=" .. (mp.get_property("gpu-api") or "auto"),
        "--hwdec=" .. (saved and saved.hwdec or mp.get_property("hwdec") or "auto"),
        "--fullscreen", "--force-window=yes",
        "--fs-screen-name=" .. o.screen, "--screen-name=" .. o.screen,
        "--force-media-title=" .. v.name,
        "--osc=no", "--ytdl=no",
        "--input-default-bindings=no", "--input-conf=" .. RUN .. "/second-input.conf",
        "--demuxer-max-bytes=" .. o.cache_mib .. "MiB",
        "--demuxer-max-back-bytes=" .. o.cache_mib .. "MiB",
        ("--volume=%g"):format(mp.get_property_number("volume", 100)),
        "--mute=" .. (k == heard and (mp.get_property("mute") or "no") or "yes"),
    }
    for a in o.screen_args:gmatch("%S+") do args[#args + 1] = a end
    local log = RUN .. "/second.log"
    second = follower.start({
        file = v.vedl, audio = v.aedl, args = args, log = log,
        on_message = function(m)
            if m[1] == "pov-key" and m[2] then mp.commandv("keypress", m[2]) end
        end,
        -- closed in its window, or it could not play
        on_exit = function(status)
            second = nil
            if away ~= k then return end
            if status ~= 0 then
                mp.osd_message("POV: the player on " .. o.screen .. " stopped", 5)
                msg.error(read_file(log) or "")
            end
            bring_back()
        end,
    })
end

bring_back = function()
    if not away then return end
    local k = away
    away = nil
    if second then second:stop() end
    second = nil
    rebuild()
    if heard == k then hear(k) end
end

-- the view goes to the other screen, the one there comes back
local function send_away(k)
    local v = views[k]
    if not v or #views < 2 then return end
    if k == away then return bring_back() end
    if not v.vedl then
        mp.osd_message("POV: no stream of that view to play elsewhere", 4)
        return
    end
    if second then second:stop() end
    second = nil
    away = k
    spawn.wait({ "mkdir", "-p", RUN })
    rebuild()
    start_second(k)
    if not second then
        away = nil
        rebuild()
        mp.osd_message("POV: the second player did not start", 5)
        return
    end
    -- the sound goes with its view, to whichever player now shows it
    hear(heard)
end

local function on_down()
    local s = slot_at(mp.get_property_native("mouse-pos"))
    if not s or #views < 2 then return end
    drag = { from = s, to = s }
    area_sync()
    if label_timer then label_timer:kill() end
    draw_labels(true)
end

local function on_up()
    if not drag then return end
    local d = drag
    drag = nil
    area_sync()
    if d.to and d.to ~= d.from then
        local a, b = placed[d.from], placed[d.to]
        local ord = order[mode]
        for i, k in ipairs(ord) do
            if k == a then ord[i] = b elseif k == b then ord[i] = a end
        end
        relayout()
    else
        flash_labels()
    end
end

mp.set_key_bindings({ { "mbtn_left", on_up, on_down } }, SECTION, "force")
-- nothing to click until the first layout exists
mp.set_mouse_area(0, 0, 0, 0, SECTION)

mp.observe_property("mouse-pos", "native", function(_, m)
    if not drag then return end
    local s = slot_at(m)
    if s ~= drag.to then
        drag.to = s
        draw_labels(true)
    end
end)

local function bind_keys()
    for k = 1, MAX_VIEWS do
        mp.add_forced_key_binding(tostring(k), "pov-view-" .. k, function() choose(k) end)
        mp.add_forced_key_binding("Alt+" .. k, "pov-hear-" .. k, function() hear(k) end)
    end
    mp.add_forced_key_binding("0", "pov-grid", function() mode = "grid"; relayout() end)
    for k = 1, MAX_VIEWS do
        mp.add_forced_key_binding("Ctrl+" .. k, "pov-screen-" .. k, function() send_away(k) end)
    end
    mp.add_forced_key_binding("Ctrl+0", "pov-tv", bring_back)
    area_sync()
    mp.enable_key_bindings(SECTION, "allow-hide-cursor")
    mp.commandv("script-message", "input-section-raised")
end

local function unbind_keys()
    for k = 1, MAX_VIEWS do
        mp.remove_key_binding("pov-view-" .. k)
        mp.remove_key_binding("pov-hear-" .. k)
    end
    mp.remove_key_binding("pov-grid")
    for k = 1, MAX_VIEWS do mp.remove_key_binding("pov-screen-" .. k) end
    mp.remove_key_binding("pov-tv")
    mp.disable_key_bindings(SECTION)
    drag = nil
end

---------------------------------------------------------------- enter, leave

local function enter()
    if saved then return end
    saved = {
        hwdec = mp.get_property("hwdec"),
        fwd = mp.get_property("demuxer-max-bytes"),
        back = mp.get_property("demuxer-max-back-bytes"),
    }
    local hw = saved.hwdec
    if hw ~= "no" and not hw:match("copy") then mp.set_property("hwdec", "auto-copy") end
    mp.set_property("demuxer-max-bytes", o.cache_mib .. "MiB")
    mp.set_property("demuxer-max-back-bytes", o.cache_mib .. "MiB")
    mp.commandv("change-list", "watch-later-options", "remove", "aid")
    bind_keys()
end

local function stop_job()
    if job then spawn.kill(job) end
    job = nil
    if progress_timer then progress_timer:kill() end
    progress_timer = nil
end

local function leave()
    if second then second:stop() end
    second, away, placed = nil, nil, {}
    stop_job()
    if add_timer then add_timer:kill() end
    add_timer = nil
    for id in pairs(pending) do mp.abort_async_command(id) end
    pending = {}
    if saved then
        -- the leader's own sound first, so whatever gets saved for it is right
        if views[1] and views[1].aid then mp.set_property_number("aid", views[1].aid) end
        mp.set_property("lavfi-complex", "")
        mp.set_property("hwdec", saved.hwdec)
        mp.set_property("demuxer-max-bytes", saved.fwd)
        mp.set_property("demuxer-max-back-bytes", saved.back)
        mp.commandv("change-list", "watch-later-options", "append", "aid")
        unbind_keys()
    end
    saved = nil
    zmq_close()
    overlay:remove()
    leader, urls, views, heard, tiles, slots, canvas, again = nil, {}, {}, 1, nil, nil, nil, false
    mode, order, drag = "grid", { grid = {}, focus = {} }, nil
    publish()
    remove_dir(RUN)
    -- the zmq filter goes away after the graph does and leaves its socket file
    mp.add_timeout(2, function() if not leader then remove_dir(RUN) end end)
end

---------------------------------------------------------------- adding views

local function esc(s)
    return "%" .. #s .. "%" .. s
end

-- a track that starts `offset` seconds into its stream, or after -offset
-- seconds of black and silence when it started later than the leader
local function shifted(url, offset, blank, blank_secs)
    local parts = { "!no_chapters" }
    if offset >= 0 then
        parts[#parts + 1] = ("%s,start=%.3f,layout=this"):format(esc(url), offset)
    else
        local gap = -offset
        while gap > 0.0005 do
            local len = math.min(gap, blank_secs)
            parts[#parts + 1] = ("%s,length=%.3f"):format(esc(blank), len)
            gap = gap - len
        end
        parts[#parts + 1] = esc(url) .. ",layout=this"
    end
    return "edl://" .. table.concat(parts, ";")
end

local function track_id(kind, file)
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == kind and t["external-filename"] == file then return t.id end
    end
end

local function own_tracks()
    local vid, aid
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if not t.external then
            if t.type == "video" and not t.albumart and not vid then vid = t.id end
            if t.type == "audio" and not aid then aid = t.id end
        end
    end
    return vid, aid
end

local function add_tracks(result)
    local added = {}
    local waiting = 0
    local function finished()
        waiting = waiting - 1
        if waiting > 0 then return end
        for _, v in ipairs(added) do
            v.vid = track_id("video", v.vedl)
            v.aid = track_id("audio", v.aedl)
            if v.vid then
                views[#views + 1] = v
                table.insert(order.grid, #views)
                table.insert(order.focus, #views)
            else
                mp.osd_message("POV: could not open " .. v.name, 5)
            end
        end
        publish()
        if #views > 1 then
            enter()
            rebuild()
        end
    end
    local first = result.videos[1]
    if first and first.error then
        mp.osd_message("POV: the playing video cannot be lined up, " .. first.error, 8)
        return
    end
    if first then
        views[1].name = short_name(first)
        -- what the other screen plays when this one goes there
        views[1].vedl = first.video and shifted(first.video, 0, result.blank, result.blank_secs)
        views[1].aedl = first.audio and shifted(first.audio, 0, result.blank, result.blank_secs)
    end
    local have = {}
    for _, v in ipairs(views) do have[v.url] = true end
    for i, r in ipairs(result.videos) do
        if i > 1 and not have[r.url] then
            if r.error then
                mp.osd_message(("POV: %s left out, %s"):format(short_name(r), r.error), 8)
            elseif not r.matched then
                -- most likely a click that was meant to play something else
                local hint = adding and "\nPOV mode is on, Shift+F9 ends it" or ""
                mp.osd_message(("POV: %s shares no sound with the others, left out%s")
                    :format(short_name(r), hint), 8)
            elseif r.video and #views + #added < MAX_VIEWS then
                local v = { url = r.url, name = short_name(r), offset = r.offset }
                v.vedl = shifted(r.video, r.offset, result.blank, result.blank_secs)
                v.aedl = r.audio and shifted(r.audio, r.offset, result.blank, result.blank_secs)
                added[#added + 1] = v
            end
        end
    end
    if #added == 0 then return end
    for _, v in ipairs(added) do
        for _, c in ipairs({ { "video-add", v.vedl, "auto", v.name },
                             v.aedl and { "audio-add", v.aedl, "auto", v.name } or false }) do
            if c then
                waiting = waiting + 1
                local id
                id = mp.command_native_async(c, function()
                    pending[id] = nil
                    finished()
                end)
                pending[id] = true
            end
        end
    end
end

local start_job

local function job_done(status, out, err)
    stop_job()
    local result = utils.parse_json(read_file(out) or "")
    if not result or not result.videos then
        local text = (read_file(err) or ""):gsub("progress [^\n]*\n", "")
        mp.osd_message("POV sync failed: " .. (text:match("([^\n]+)\n?$") or ("status " .. status)), 8)
        msg.error(text)
    else
        for _, r in ipairs(result.videos) do
            if r.error then msg.warn(r.url .. ": " .. r.error) end
        end
        add_tracks(result)
    end
    if again then
        again = false
        start_job()
    end
end

start_job = function()
    if job then again = true; return end
    spawn.wait({ "mkdir", "-p", RUN })
    local args = { helper_cmd() }
    for k, v in pairs(mp.get_property_native("ytdl-raw-options") or {}) do
        args[#args + 1] = "--raw"
        args[#args + 1] = k .. "=" .. v
    end
    args[#args + 1] = leader
    for _, u in ipairs(urls) do args[#args + 1] = u end
    local out, err = RUN .. "/sync.json", RUN .. "/sync.err"
    job = spawn.start(args, { stdout = out, stderr = err, done = function(status)
        job_done(status, out, err)
    end })
    if not job then
        mp.osd_message("POV sync: mpv-pov-sync did not start", 6)
        return
    end
    local n = #urls + 1
    progress_timer = mp.add_periodic_timer(0.5, function()
        local text = read_file(err) or ""
        local last = nil
        for line in text:gmatch("progress ([^\n]+)") do last = line end
        mp.osd_message(("Lining up %d views: %s"):format(n, last or "starting"), 1)
    end)
end

local function add(url)
    if not url or url == "" then return end
    local path = mp.get_property("path")
    if not path then
        mp.commandv("loadfile", url, "replace")
        return
    end
    if leader and leader ~= path then leave() end
    leader = path
    local known = url == leader
    for _, u in ipairs(urls) do known = known or u == url end
    if known then
        mp.osd_message("POV: that video is already here", 3)
        return
    end
    if #urls + 1 >= MAX_VIEWS then
        mp.osd_message("POV: " .. MAX_VIEWS .. " views at most", 4)
        return
    end
    urls[#urls + 1] = url
    if not views[1] then
        local vid, aid = own_tracks()
        views[1] = { url = leader, vid = vid, aid = aid,
                     name = short_name({ channel = "", title = mp.get_property("media-title") or leader }) }
        order = { grid = { 1 }, focus = { 1 } }
    end
    mp.osd_message(("POV: %d views, lining them up"):format(#urls + 1), 2)
    if add_timer then add_timer:kill() end
    add_timer = mp.add_timeout(ADD_WAIT, function()
        add_timer = nil
        start_job()
    end)
end

---------------------------------------------------------------- pov mode

local function set_adding(on, text)
    adding = on
    publish()
    if text then mp.osd_message(text, 4) end
end

local function toggle()
    if adding then
        set_adding(false, "POV mode OFF — clicks replace the video")
    elseif not mp.get_property("path") then
        mp.osd_message("POV mode needs a video playing first", 4)
    else
        set_adding(true, "POV mode ON — clicks add a view to this video")
    end
end

mp.add_key_binding(nil, "toggle", toggle)
mp.register_script_message("pov-mode-toggle", toggle)
mp.register_script_message("pov-add", add)

-- the file it was turned on for is gone, and the next one is unrelated
mp.register_event("end-file", function(e)
    if adding then
        set_adding(false, e.reason ~= "quit" and "POV mode OFF — its video was closed" or nil)
    end
end)

-- another file replaced the leader
mp.register_event("file-loaded", function()
    if leader and mp.get_property("path") ~= leader then leave() end
end)

mp.add_hook("on_unload", 50, function()
    if leader then leave() end
end)

-- while the other screen's view is heard, its sound follows this one's
mp.observe_property("volume", "number", function(_, v)
    if second and heard == away and v then second:set("volume", v) end
end)
mp.observe_property("mute", "bool", function(_, m)
    if second and heard == away then second:set("mute", m) end
end)

-- a resized window moves the picture, and the clickable area with it
mp.observe_property("osd-dimensions", "native", function()
    area_sync()
end)

-- the canvas follows the display, a window moved to another screen gets a new one
mp.observe_property("display-width", "number", function()
    if saved and canvas then
        local w, h = display_size()
        if w ~= canvas.w or h ~= canvas.h then rebuild() end
    end
end)

mp.register_event("shutdown", leave)

publish()
sweep()
