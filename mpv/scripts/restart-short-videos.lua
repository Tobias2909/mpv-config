-- Short videos (music videos etc.) always start from the beginning instead of
-- resuming at the saved position (save-position-on-quit=yes). Resume stays
-- active for anything longer than the threshold.
local THRESHOLD = 600 -- seconds; videos shorter than this never resume

mp.register_event("file-loaded", function()
    local dur = mp.get_property_number("duration")
    local pos = mp.get_property_number("time-pos")
    if dur and pos and dur < THRESHOLD and pos > 1 then
        mp.commandv("seek", "0", "absolute", "exact")
        mp.osd_message("Short video: starting from beginning")
    end
end)
