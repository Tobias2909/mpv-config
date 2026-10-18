-- follower.lua
-- A second mpv, in a window of its own, that plays in step with this one.
--
-- pov_sync.lua uses it to show one view on another screen. The second player
-- is started with spawn.lua and driven over a socket pair it gets as its IPC
-- connection (--input-ipc-client). No socket file is made, and mpv quits when
-- that connection closes, so the second player goes away with this one, even
-- when this one crashes.
--
-- KEEPING IN STEP. Both play the same timeline, each on its own clock, so this
-- one passes on every pause, seek and speed change, and measures the distance
-- five times a second, at random points of a frame:
--   * closer than CALM, nothing is done;
--   * up to NUDGE, the other one plays a little faster or slower, by at most
--     MAX_NUDGE, until the distance is made up;
--   * further ahead, it pauses on its frame until this one gets there;
--   * further behind, it is put a little ahead, paused, and started when this
--     one gets there.
-- While this one stands still (paused, buffering, seeking) the other one
-- waits paused on the same frame, and starts when this one plays again. How
-- far off a start lands is measured each time and taken off the next one.
-- Measured on a 60 fps clip, both headless: within one frame after every
-- pause, seek and speed change, on average a few ms.
--
-- M.start(o) returns a handle, or nil:
--   o.file     what to play, an edl:// works
--   o.audio    an audio file to add, optional
--   o.args     more mpv options (window, screen, sound)
--   o.on_exit(status)   the second player ended by itself
--   o.on_message(args)  a script-message sent in the second player, which is
--                       how its key bindings reach this one
-- handle:set(name, value) sets a property there, handle:show(text) shows it
-- on its OSD, handle:stop() ends it.

local mp    = require 'mp'
local msg   = require 'mp.msg'
local utils = require 'mp.utils'
local spawn = require 'spawn'
local ffi   = require 'ffi'

ffi.cdef [[
int socketpair(int domain, int type, int protocol, int sv[2]);
long send(int fd, const void *buf, size_t len, int flags);
long recv(int fd, void *buf, size_t len, int flags);
int close(int fd);
]]
local C = ffi.C
local AF_UNIX, SOCK_STREAM, SOCK_CLOEXEC = 1, 1, 0x80000
local MSG_DONTWAIT, MSG_NOSIGNAL = 0x40, 0x4000

local TICK = 0.2        -- seconds between two measurements, on average
local SAMPLES = 8       -- measurements averaged
local CALM = 0.006      -- in step when closer than this
local NUDGE = 0.25      -- made up by speed up to this, by waiting beyond it
local MAX_NUDGE = 0.04  -- largest change of speed
local CATCH_S = 1.5     -- a distance is made up over about this many seconds
local SETTLE_S = 0.6    -- after a start, measuring waits this long
local SEEK_GUESS = 0.7  -- seconds a seek takes there, until one is measured
local HEAD_START = 3    -- how far ahead the very first start is, which loads

local M = {}
M.__index = M

local buf = ffi.new("char[65536]")

local function here()
    return mp.get_property_number("time-pos")
end

local function standing()
    return mp.get_property_bool("core-idle")
end

---------------------------------------------------------------- talking

function M:send(cmd, reply)
    if self.fd < 0 then return end
    local m = { command = cmd }
    if reply then
        self.rid = self.rid + 1
        m.request_id = self.rid
        self.replies[self.rid] = reply
    end
    local line = utils.format_json(m) .. "\n"
    if C.send(self.fd, line, #line, MSG_DONTWAIT + MSG_NOSIGNAL) ~= #line then
        msg.warn("follower: not sent: " .. line)
    end
end

function M:read()
    while self.fd >= 0 do
        -- nothing more for now, or the other end closed, which its exit reports
        local n = tonumber(C.recv(self.fd, buf, 65536, MSG_DONTWAIT))
        if n <= 0 then break end
        self.pending = self.pending .. ffi.string(buf, n)
    end
    while true do
        local nl = self.pending:find("\n", 1, true)
        if not nl then break end
        local m = utils.parse_json(self.pending:sub(1, nl - 1))
        self.pending = self.pending:sub(nl + 1)
        if m then self:dispatch(m) end
    end
end

function M:dispatch(m)
    if m.event == "playback-restart" then
        self:restarted()
    elseif m.event == "file-loaded" then
        self:send({ "get_property", "duration" }, function(r) self.duration = tonumber(r.data) end)
    elseif m.event == "client-message" then
        if self.o.on_message then self.o.on_message(m.args or {}) end
    elseif m.request_id then
        local f = self.replies[m.request_id]
        self.replies[m.request_id] = nil
        if f then f(m) end
    end
end

function M:set(name, value)
    self:send({ "set_property", name, value })
end

function M:show(text, secs)
    self:send({ "show-text", text, math.floor((secs or 3) * 1000) })
end

---------------------------------------------------------------- in step

function M:cancel()
    if self.wait then self.wait:kill() end
    self.wait = nil
end

function M:speed_to(s)
    if self.speed and math.abs(self.speed - s) < 0.0002 then return end
    self.speed = s
    self:set("speed", s)
end

-- how far ahead to put it so it is ready before this one gets there: half as
-- much again as the middle one of its last three seeks, since one seek that
-- waited for the network would otherwise freeze it for seconds every time
function M:lead()
    local t = { unpack(self.seeks) }
    table.sort(t)
    local typical = t[math.ceil(#t / 2)] or SEEK_GUESS
    return math.min(typical * 1.5 + 0.2, 5)
end

-- paused on the frame at pos, ready once it has restarted there
function M:hold_at(pos)
    if not pos then return end
    self:cancel()
    local same = not self.running and self.at and math.abs(self.at - pos) < 0.001
    self.running = false
    if same then return end
    self.ready = false
    self.at = pos
    self.gen = self.gen + 1
    self.asked = mp.get_time()
    msg.debug(("follower: waits at %.3f"):format(pos))
    self:set("pause", true)
    self:send({ "seek", pos, "absolute+exact" })
end

-- a restart can be an older seek's, so the position decides
function M:restarted()
    if self.running or not self.at then return end
    local at, gen = self.at, self.gen
    self:send({ "get_property", "time-pos" }, function(r)
        if self.running or self.gen ~= gen or self.ready then return end
        local pos = tonumber(r.data)
        local past_end = self.duration and at >= self.duration - 0.1
        if pos and (math.abs(pos - at) < 0.1 or past_end) then
            self.ready = true
            if self.asked then
                table.insert(self.seeks, mp.get_time() - self.asked)
                if #self.seeks > 3 then table.remove(self.seeks, 1) end
            end
            self:settle()
        else
            -- a seek sent before the file was loaded is lost
            self:send({ "seek", at, "absolute+exact" })
        end
    end)
end

-- ahead of this one: paused where it is until this one gets there, which
-- needs no seek and stands still no longer than the distance
function M:wait_here()
    self:cancel()
    self.running, self.ready = false, false
    self.gen = self.gen + 1
    local gen = self.gen
    self:set("pause", true)
    self:send({ "get_property", "time-pos" }, function(r)
        local pos = tonumber(r.data)
        if self.gen ~= gen or self.running or not pos then return end
        self.at, self.ready = pos, true
        self:settle()
    end)
end

-- this one plays and the other waits ready at self.at: start it when this
-- one gets there, or put it further ahead when that is already past
function M:settle()
    if self.running or not self.ready or self.wait or standing() then return end
    if self.duration and self.at >= self.duration - 0.1 then return end
    local pos = here()
    if not pos then return end
    local gap = self.at - pos
    if gap >= -0.02 and gap < 10 then
        self.wait = mp.add_timeout(math.max(gap / self.base + self.bias, 0), function()
            self.wait = nil
            self:go()
        end)
    else
        self:hold_at(pos + self:lead())
    end
end

-- this one restarted after a seek. A seek that is not exact lands on a
-- keyframe up to seconds away from where it asked for, so only now is it
-- known where this one really is.
function M:caught_up()
    local pos = here()
    if self.running or not pos then return end
    if standing() then
        self:hold_at(pos)
    elseif self.ready then
        self:settle()
    elseif self.at < pos - 0.02 then
        self:hold_at(pos + self:lead())
    end
end

function M:go()
    if standing() then return end
    -- the timer assumed this one plays on at its speed, but a player waiting
    -- for the network falls behind that (measured: started 4.4 s early)
    local gap = self.at - (here() or self.at)
    if gap > 0.03 then
        self.wait = mp.add_timeout(gap / self.base, function()
            self.wait = nil
            self:go()
        end)
        return
    end
    msg.debug(("follower: starts at %.3f, here %.3f"):format(self.at, here() or -1))
    self.running, self.ready = true, false
    self.samples, self.learned = {}, false
    self.fix, self.slip, self.slip_t = 0, 0, mp.get_time()
    self.quiet = mp.get_time() + SETTLE_S
    self:speed_to(self.base)
    self:set("pause", false)
end

function M:tick()
    if not self.running or mp.get_time() < self.quiet then return end
    local pos = here()
    if not pos then return end
    self:send({ "get_property", "time-pos" }, function(r)
        local there = tonumber(r.data)
        if not self.running or not there then return end
        -- how much the speed changes have taken off since it started, so
        -- older measurements count as they would be now, else the mean lags
        -- behind the correction and overshoots (measured: two frames)
        local now = mp.get_time()
        self.slip = self.slip + self.fix * self.base * (now - self.slip_t)
        self.slip_t = now
        local s = self.samples
        s[#s + 1] = there - pos + self.slip
        if #s > SAMPLES then table.remove(s, 1) end
        if #s < 3 then return end
        if #s == 3 and not self.learned then
            -- it starts this far ahead of where it should, measured: about
            -- two frames, so the next start waits half of that longer
            self.learned = true
            self.bias = math.max(-0.1, math.min(0.2, self.bias + (s[1] + s[2] + s[3]) / 6))
        end
        local last = { s[#s], s[#s - 1], s[#s - 2] }
        table.sort(last)
        local off = last[2] - self.slip
        if off >= NUDGE and off < 10 then
            msg.debug(("follower: %.3f ahead, waits"):format(off))
            self:wait_here()
            return
        elseif math.abs(off) >= NUDGE then
            msg.debug(("follower: %.3f off, jumps"):format(off))
            self:hold_at((here() or pos) + self:lead())
            return
        end
        -- both positions move in whole frames, the mean of measurements
        -- taken at random points of a frame does not
        local mean = 0
        for _, d in ipairs(s) do mean = mean + d end
        mean = mean / #s - self.slip
        self.fix = 0
        if math.abs(mean) >= CALM then
            self.fix = math.max(-MAX_NUDGE, math.min(MAX_NUDGE, mean / CATCH_S))
        end
        msg.trace(("follower: %+.1f ms, mean %+.1f, speed %.4f"):format((there - pos) * 1000, mean * 1000,
                                                                       self.base * (1 - self.fix)))
        self:speed_to(self.base * (1 - self.fix))
    end)
end

-- at random intervals: at a fixed one, five a second is twelve frames at
-- 60 fps, every measurement fell on the same point of a frame and the
-- rounding to whole frames never averaged out (measured: one frame off for
-- good)
function M:next_tick()
    self.ticker = mp.add_timeout(TICK * (0.5 + math.random()), function()
        if self.stopped then return end
        self:tick()
        self:next_tick()
    end)
end

---------------------------------------------------------------- start, stop

function M:cleanup()
    self:cancel()
    if self.reader then self.reader:kill() end
    if self.ticker then self.ticker:kill() end
    mp.unobserve_property(self.on_idle)
    mp.unobserve_property(self.on_speed)
    mp.unregister_event(self.on_seek)
    mp.unregister_event(self.on_restart)
    if self.fd >= 0 then C.close(self.fd) end
    self.fd = -1
end

-- closing the connection quits it, the kill is for one that hangs
function M:stop()
    if self.stopped then return end
    self.stopped = true
    self:cleanup()
    local job = self.job
    mp.add_timeout(5, function() spawn.kill(job) end)
end

function M.start(o)
    local sv = ffi.new("int[2]")
    if C.socketpair(AF_UNIX, SOCK_STREAM + SOCK_CLOEXEC, 0, sv) ~= 0 then
        msg.error("follower: no socket pair")
        return nil
    end
    local self = setmetatable({ o = o, fd = sv[0], rid = 0, replies = {}, pending = "",
                                base = mp.get_property_number("speed") or 1,
                                samples = {}, seeks = {}, bias = 0, gen = 0,
                                fix = 0, slip = 0, slip_t = 0 }, M)
    self.speed = self.base
    -- a paused player gets the same frame, a playing one gets time to load
    self.at = (here() or 0) + (standing() and 0 or HEAD_START)
    local args = { "mpv", "--no-config", "--input-ipc-client=fd://3", "--idle=no",
                   "--keep-open=yes", "--hr-seek=yes", "--pause",
                   ("--start=%.3f"):format(self.at), ("--speed=%.6f"):format(self.base) }
    if o.audio then args[#args + 1] = "--audio-file=" .. o.audio end
    for _, a in ipairs(o.args or {}) do args[#args + 1] = a end
    args[#args + 1] = "--"
    args[#args + 1] = o.file
    self.job = spawn.start(args, { fd = sv[1], stderr = o.log, done = function(status)
        if self.stopped then return end
        self.stopped = true
        self:cleanup()
        if o.on_exit then o.on_exit(status) end
    end })
    C.close(sv[1])
    if not self.job then
        C.close(sv[0])
        return nil
    end
    self.on_idle = function(_, idle)
        if idle then self:hold_at(here()) else self:settle() end
    end
    self.on_speed = function(_, s)
        self.base = s or 1
        self.samples, self.fix, self.slip = {}, 0, 0
        if self.running then self:speed_to(self.base) end
    end
    self.on_seek = function() self:hold_at(here()) end
    self.on_restart = function() self:caught_up() end
    mp.observe_property("core-idle", "bool", self.on_idle)
    mp.observe_property("speed", "number", self.on_speed)
    mp.register_event("seek", self.on_seek)
    mp.register_event("playback-restart", self.on_restart)
    self.reader = mp.add_periodic_timer(0.05, function() self:read() end)
    self:next_tick()
    return self
end

return M
