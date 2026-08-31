-- Queue mode
-- One toggle for the "loop two music videos" case:
--   OFF (default): browser handoffs use `loadfile ... replace`, loop-playlist=no
--   ON:            browser handoffs use `loadfile ... append-play`, loop-playlist=inf
--
-- State lives in a flag file so the wrapper (~/.local/bin/mpv-ff2mpv-single.sh)
-- can read it without asking mpv, and so a fresh mpv launched while queue mode
-- is on still comes up looping (wrapper passes --loop-playlist=inf).
-- The flag is deliberately NOT cleared on script load: state is sticky until
-- toggled off, and clearing it here would let an unrelated local-file mpv
-- instance nuke an active queue session.
--
-- Triggers:
--   input.conf        F9 script-binding queue_mode/toggle
--   KDE global shortcut -> ~/.local/bin/mpv-queue-toggle (sends script-message)

local mp = require "mp"

local flag = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/mpv-ff2mpv.queue"

local function is_on()
    local f = io.open(flag, "r")
    if f then f:close() return true end
    return false
end

local function set_state(on)
    if on then
        local f = io.open(flag, "w")
        if f then f:close() end
        mp.set_property("loop-playlist", "inf")
        -- loop-file=inf (F4) would repeat the current entry forever and the
        -- playlist would never advance, i.e. queue mode silently does nothing.
        -- The two are mutually exclusive by intent, so clear it and say so.
        local note = ""
        if mp.get_property("loop-file") ~= "no" then
            mp.set_property("loop-file", "no")
            note = " (loop-file cleared)"
        end
        mp.osd_message("Queue mode ON — handoffs append, playlist loops" .. note, 3)
    else
        os.remove(flag)
        mp.set_property("loop-playlist", "no")
        mp.osd_message("Queue mode OFF — handoffs replace, no loop", 3)
    end
end

local function toggle()
    set_state(not is_on())
end

mp.add_key_binding(nil, "toggle", toggle)
mp.register_script_message("queue-mode-toggle", toggle)
