-- free_cache.lua
-- Hands the previous video's cache back to the system once the next one plays.
--
-- mpv 0.41 keeps every packet it drops from the demuxer cache in a pool for
-- reuse, and the packet's data stays attached until that packet is reused.
-- A new video takes one packet from the pool for each packet it reads, so
-- after a stream that filled the cache, gigabytes stay held for hours. The
-- pool is emptied only when demuxer-max-bytes plus demuxer-max-back-bytes
-- gets smaller while a demuxer runs. Lowering the back cache limit by one
-- byte while a file plays does that, and the byte is given back when the
-- file ends.
--
-- glibc then keeps the freed memory for itself, because it lies in the
-- arena of the old demuxer thread and the packets are too small for free()
-- to trim it. malloc_trim() returns it.
--
-- Measured with a 2.8 GB cache, headless, switching to a small file:
-- 2832 MiB before, 2826 MiB with the pool emptied, 99 MiB after the trim,
-- which took 131 ms.

local TRIM_AFTER = 3 -- seconds after the next file loaded

local has_ffi, ffi = pcall(require, "ffi")
local trim
if has_ffi and ffi.os == "Linux" then
    ffi.cdef [[ int malloc_trim(size_t pad); ]]
    trim = function()
        local t = mp.get_time()
        ffi.C.malloc_trim(0)
        mp.msg.verbose(("malloc_trim took %.0f ms"):format((mp.get_time() - t) * 1000))
    end
end

local lowered, timer

mp.register_event("file-loaded", function()
    local back = mp.get_property_number("demuxer-max-back-bytes")
    if back and back >= 1 then
        lowered = back - 1
        mp.set_property_number("demuxer-max-back-bytes", lowered)
    end
    if trim then
        if timer then timer:kill() end
        timer = mp.add_timeout(TRIM_AFTER, trim)
    end
end)

mp.register_event("end-file", function()
    if timer then timer:kill() end
    timer = nil
    -- give the byte back only if nothing else changed the limit meanwhile
    if lowered and mp.get_property_number("demuxer-max-back-bytes") == lowered then
        mp.set_property_number("demuxer-max-back-bytes", lowered + 1)
    end
    lowered = nil
end)
