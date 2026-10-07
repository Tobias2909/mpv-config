-- spawn.lua
-- Starts helper programs without forking the player.
--
-- mpv's `subprocess` command forks mpv, and a fork copies the page tables of
-- the whole process. With a full demuxer cache that is gigabytes, and every
-- thread of the player waits while it happens. Measured with 6.7 GB in the
-- cache, playing 1080p60 on a 4K display: each `subprocess` took 104 to 108
-- ms, and one every 0.3 s dropped 65 to 89 frames in 20 s. With 0.45 GB it
-- took 10 ms and dropped none. posix_spawn() starts the child without copying
-- anything (glibc uses CLONE_VFORK): 0.1 ms and no dropped frame with the
-- 6.7 GB cache, even at ten spawns a second.
--
-- A script loads it with
--
--   package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
--                  .. ";" .. package.path
--   local spawn = require "spawn"
--
-- spawn.start(args, opts) starts args[1], looked up in PATH, and returns a
-- handle, or nil when it could not start. opts.stdout and opts.stderr name
-- files for the output, anything else goes to /dev/null, and stdin is
-- /dev/null. opts.done(status) is called with the exit code once the child
-- ends, or with -1 when a signal ended it.
-- spawn.kill(handle) kills a child. Its done is never called.
-- spawn.wait(args, opts) starts a child and blocks until it ends, then
-- returns the status, or -1 when it could not start.
--
-- Without LuaJIT's ffi, or off Linux, it falls back to `subprocess`, which
-- works the same way but forks.

local mp  = require 'mp'
local msg = require 'mp.msg'

local M = {}

local has_ffi, ffi = pcall(require, "ffi")

if not has_ffi or ffi.os ~= "Linux" then
    local function write(file, text)
        local f = file and io.open(file, "wb")
        if f then f:write(text or ""); f:close() end
    end
    local function command(args, opts)
        return { name = "subprocess", args = args, playback_only = false,
                 capture_stdout = opts.stdout ~= nil, capture_stderr = opts.stderr ~= nil }
    end
    function M.start(args, opts)
        opts = opts or {}
        local h = {}
        h.id = mp.command_native_async(command(args, opts), function(_, res)
            if h.killed then return end
            res = res or {}
            write(opts.stdout, res.stdout)
            write(opts.stderr, res.stderr)
            if opts.done then opts.done(res.status or -1) end
        end)
        return h
    end
    function M.kill(h)
        h.killed = true
        mp.abort_async_command(h.id)
    end
    function M.wait(args, opts)
        opts = opts or {}
        local res = mp.command_native(command(args, opts)) or {}
        write(opts.stdout, res.stdout)
        write(opts.stderr, res.stderr)
        return res.status or -1
    end
    return M
end

local bit = require "bit"
local C = ffi.C

-- The glibc types are only ever passed by pointer, so each is declared as a
-- block at least as large as the real one (sigset_t 128 bytes,
-- posix_spawnattr_t 336, posix_spawn_file_actions_t 80).
ffi.cdef [[
typedef int pid_t;
typedef struct { uint64_t v[16]; } spawn_sigset_t;
typedef struct { uint64_t v[64]; } spawn_attr_t;
typedef struct { uint64_t v[16]; } spawn_actions_t;
int posix_spawnp(pid_t *pid, const char *file, const spawn_actions_t *actions,
                 const spawn_attr_t *attr, char *const argv[], char *const envp[]);
int posix_spawnattr_init(spawn_attr_t *attr);
int posix_spawnattr_destroy(spawn_attr_t *attr);
int posix_spawnattr_setflags(spawn_attr_t *attr, short flags);
int posix_spawnattr_setsigmask(spawn_attr_t *attr, const spawn_sigset_t *set);
int posix_spawnattr_setsigdefault(spawn_attr_t *attr, const spawn_sigset_t *set);
int posix_spawn_file_actions_init(spawn_actions_t *actions);
int posix_spawn_file_actions_destroy(spawn_actions_t *actions);
int posix_spawn_file_actions_addopen(spawn_actions_t *actions, int fd, const char *path,
                                     int flags, unsigned int mode);
int posix_spawn_file_actions_addclosefrom_np(spawn_actions_t *actions, int from);
int sigemptyset(spawn_sigset_t *set);
int sigfillset(spawn_sigset_t *set);
int waitpid(pid_t pid, int *status, int options);
int kill(pid_t pid, int sig);
char *strerror(int errnum);
extern char **environ;
]]

local SETSIGDEF, SETSIGMASK = 0x04, 0x08
local O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC = 0, 1, 64, 512
local WNOHANG, SIGKILL, EINTR = 1, 9, 4

-- glibc 2.34 and later. Without it the child keeps every descriptor a script
-- opened with io.open, which Lua does not mark close on exec.
local has_closefrom = pcall(function() return C.posix_spawn_file_actions_addclosefrom_np end)

local kids = {}          -- pid -> handle
local timer = nil
local status = ffi.new("int[1]")

local function exit_code(st)
    if bit.band(st, 0x7f) == 0 then return bit.band(bit.rshift(st, 8), 0xff) end
    return -1
end

-- Returns the status once the child has ended, nil while it runs.
local function reap(pid, options)
    while true do
        local r = C.waitpid(pid, status, options)
        if r == pid then return exit_code(status[0]) end
        if r == 0 then return nil end
        if ffi.errno() ~= EINTR then return -1 end
    end
end

local function poll()
    local ended = {}
    for pid, h in pairs(kids) do
        local st = reap(pid, WNOHANG)
        if st then ended[#ended + 1] = { h, st } end
    end
    for _, e in ipairs(ended) do kids[e[1].pid] = nil end
    if next(kids) == nil then timer:kill() end
    -- after the loop, since a callback may start the next child
    for _, e in ipairs(ended) do
        local h, st = e[1], e[2]
        if not h.killed and h.done then h.done(st) end
    end
end

local function launch(args, opts)
    opts = opts or {}
    local n = #args
    local argv = ffi.new("char *[?]", n + 1)    -- zeroed, so argv[n] is the NULL end
    local keep = {}
    for i = 1, n do
        local s = tostring(args[i])
        keep[i] = ffi.new("char[?]", #s + 1, s)
        argv[i - 1] = keep[i]
    end
    local actions = ffi.new("spawn_actions_t")
    local attr = ffi.new("spawn_attr_t")
    local set = ffi.new("spawn_sigset_t")
    local out = bit.bor(O_WRONLY, O_CREAT, O_TRUNC)
    C.posix_spawn_file_actions_init(actions)
    C.posix_spawn_file_actions_addopen(actions, 0, "/dev/null", O_RDONLY, 0)
    C.posix_spawn_file_actions_addopen(actions, 1, opts.stdout or "/dev/null", out, 384)
    C.posix_spawn_file_actions_addopen(actions, 2, opts.stderr or "/dev/null", out, 384)
    if has_closefrom then C.posix_spawn_file_actions_addclosefrom_np(actions, 3) end
    -- the same clean start mpv's own subprocess gives a child: default signal
    -- handlers and nothing blocked
    C.posix_spawnattr_init(attr)
    C.sigfillset(set)
    C.posix_spawnattr_setsigdefault(attr, set)
    C.sigemptyset(set)
    C.posix_spawnattr_setsigmask(attr, set)
    C.posix_spawnattr_setflags(attr, bit.bor(SETSIGDEF, SETSIGMASK))
    local pid = ffi.new("pid_t[1]")
    local rc = C.posix_spawnp(pid, argv[0], actions, attr, argv, C.environ)
    C.posix_spawnattr_destroy(attr)
    C.posix_spawn_file_actions_destroy(actions)
    if rc ~= 0 then
        msg.warn(("cannot start %s: %s"):format(args[1], ffi.string(C.strerror(rc))))
        return nil
    end
    return pid[0]
end

function M.start(args, opts)
    local pid = launch(args, opts)
    if not pid then return nil end
    local h = { pid = pid, done = opts and opts.done }
    kids[pid] = h
    if not timer then
        timer = mp.add_periodic_timer(0.05, poll)
    else
        timer:resume()
    end
    return h
end

-- The child stays in kids until it is reaped, else it would stay a zombie.
function M.kill(h)
    if h.killed or not kids[h.pid] then return end
    h.killed = true
    C.kill(h.pid, SIGKILL)
end

function M.wait(args, opts)
    local pid = launch(args, opts)
    if not pid then return -1 end
    return reap(pid, 0)
end

return M
