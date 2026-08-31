#!/usr/bin/env bash
# Single-instance mpv launcher for ff2mpv-rust handoff.
# - Twitch URLs are resolved via streamlink (uses TTV-LOL plugin if installed)
#   to a direct HLS playlist, then handed to mpv as a normal URL. This both
#   bypasses SSAI ads and lets us reuse the existing mpv instance via IPC.
# - YouTube watch URLs that carry a &list= param are expanded into the full
#   playlist (mpv's ytdl_hook forces --no-playlist for those by default), then
#   a background job jumps to the clicked video once expansion finishes.
# - All other URLs go straight to mpv (which uses ytdl_hook → yt-dlp).
# - If a previous ff2mpv-spawned mpv is still alive, swap its current file
#   for the new URL via IPC. Otherwise start a fresh mpv.

set -u

SOCK="${XDG_RUNTIME_DIR:-/tmp}/mpv-ff2mpv.sock"

# Queue mode -------------------------------------------------------------------
# Flag file owned by ~/.config/mpv/scripts/queue_mode.lua (F9) and
# ~/.local/bin/mpv-queue-toggle (KDE global shortcut). While it exists this
# handoff APPENDS instead of replacing, and a fresh mpv comes up with
# --loop-playlist=inf — the "queue two music videos and loop them" case.
QUEUE_FLAG="${XDG_RUNTIME_DIR:-/tmp}/mpv-ff2mpv.queue"
QUEUE=0
[[ -e "$QUEUE_FLAG" ]] && QUEUE=1
# -----------------------------------------------------------------------------

URL="${1:-}"
if [[ -z "$URL" ]]; then
    echo "mpv-ff2mpv-single: no URL provided" >&2
    exit 2
fi

ipc() { printf '%s\n' "$1" | socat -t "${2:-0.5}" - "UNIX-CONNECT:$SOCK" 2>/dev/null; }

# Title hint for the OSD; defaults to original URL, overwritten for Twitch.
TITLE=""

# YouTube URL canonicalization -------------------------------------------------
# ff2mpv hands over whatever href the page had. YouTube's "continue watching"
# shelf appends &t=<n>s — and mark-watched= (mpv.conf) puts every played video
# into that shelf at ~1s — while share/channel links add &si=, &pp=, &index=,
# &ab_channel=. mpv keys its watch_later resume file on MD5 of the exact URL
# string, so each variant gets its own file and resume silently breaks: a video
# saved under watch?v=ID comes back as watch?v=ID&t=1s and replays from zero.
# Rebuild watch URLs from v= only, keeping list= (the playlist expansion below
# needs it). Playlist entries are unaffected — yt-dlp already emits bare
# watch?v=ID for those. Accepted trade: a shared ?t= deep link no longer jumps
# to that timestamp in mpv.
if [[ "$URL" =~ ^https?://([^/]+\.)?youtu\.be/([A-Za-z0-9_-]{11}) ]]; then
    URL="https://www.youtube.com/watch?v=${BASH_REMATCH[2]}"
fi
if [[ "$URL" =~ ^https?://([^/]+\.)?youtube\.com/watch ]]; then
    # NOTE: each [[ =~ ]] resets BASH_REMATCH — capture immediately.
    CANON_V=""
    CANON_LIST=""
    [[ "$URL" =~ [\?\&]v=([A-Za-z0-9_-]{11}) ]] && CANON_V="${BASH_REMATCH[1]}"
    [[ "$URL" =~ [\?\&]list=([^\&#]+) ]] && CANON_LIST="${BASH_REMATCH[1]}"
    if [[ -n "$CANON_V" ]]; then
        URL="https://www.youtube.com/watch?v=$CANON_V"
        [[ -n "$CANON_LIST" ]] && URL="$URL&list=$CANON_LIST"
    fi
fi
# -----------------------------------------------------------------------------

# Twitch handling --------------------------------------------------------------
# Match http(s)://(www.)twitch.tv/<channel>[/...]
if [[ "$URL" =~ ^https?://(www\.)?twitch\.tv/([^/?#]+) ]]; then
    CHANNEL="${BASH_REMATCH[2]}"
    if command -v streamlink >/dev/null 2>&1; then
        # --stream-url prints the resolved HLS m3u8 and exits without playing.
        # The TTV-LOL plugin (AUR streamlink-ttvlol) overrides the upstream
        # twitch plugin so this call transparently goes through the proxy.
        RESOLVED="$(streamlink --stream-url --twitch-disable-ads "$URL" best 2>/dev/null)"
        if [[ -n "$RESOLVED" ]]; then
            URL="$RESOLVED"
            TITLE="twitch.tv/$CHANNEL"
        fi
        # On failure: fall through with original URL → mpv+yt-dlp path.
    fi
fi
# -----------------------------------------------------------------------------

# YouTube playlist handling ----------------------------------------------------
# watch?v=X&list=Y: ytdl_hook passes --no-playlist for these, so only the single
# video would load. Override with yes-playlist; remember the clicked video id
# so we can jump to it after the (async) playlist expansion.
# Mixes/radio (list=RD*) are effectively infinite (1000+ entries, very slow
# extraction) — cap those at MIX_LIMIT entries. Real playlists load in full.
# Pure playlist?list=RD* URLs can't replace this: yt-dlp returns 0 entries for
# Mixes without watch-URL context, so the watch URL + global map stays.
MIX_LIMIT=50
WANT_PLAYLIST=0
IS_MIX=0
CLICKED_VID=""
# In queue mode a watch?v=X&list=Y URL is queued as the SINGLE clicked video:
# you asked for that one video, and expanding someone's 100-entry playlist into
# your two-video loop is never what you meant. Without yes-playlist, ytdl_hook's
# default --no-playlist does exactly that. Pure playlist?list= URLs still expand
# in full (clicking those IS explicit playlist intent).
if ((QUEUE == 0)) &&
   [[ "$URL" =~ ^https?://([^/]+\.)?youtube\.com/watch ]] && [[ "$URL" =~ [\?\&]list=([^\&#]+) ]]; then
    WANT_PLAYLIST=1
    [[ "${BASH_REMATCH[1]}" == RD* ]] && IS_MIX=1
    if [[ "$URL" =~ [\?\&]v=([A-Za-z0-9_-]{11}) ]]; then
        CLICKED_VID="${BASH_REMATCH[1]}"
    fi
fi

# Normalize the running instance's ytdl-raw-options for this load. Per-file
# loadfile options can't carry two list items (comma is the option separator),
# so set the global option map via IPC instead — safe because every ff2mpv
# handoff passes through here and re-normalizes before its loadfile.
set_ytdl_opts() {
    local cur new
    cur="$(ipc '{"command":["get_property","ytdl-raw-options"]}' | jq -c '.data // {}' 2>/dev/null)"
    [[ -n "$cur" ]] || return 0
    new="$(jq -c -n --argjson cur "$cur" \
        --argjson pl "$WANT_PLAYLIST" --argjson mix "$IS_MIX" --arg lim "$MIX_LIMIT" '
        $cur | del(.["yes-playlist"], .["playlist-end"])
        | if $pl == 1 then .["yes-playlist"] = "" else . end
        | if $mix == 1 then .["playlist-end"] = $lim else . end')"
    ipc "$(jq -c -n --argjson v "$new" '{command:["set_property","ytdl-raw-options",$v]}')" >/dev/null
}

# Background: wait for ytdl_hook to expand the playlist, then jump to the
# clicked video. Gives up silently if expansion or lookup fails (e.g. the
# clicked video was removed from the playlist) — mpv then plays from entry 0.
jump_to_clicked() {
    local i idx count=0
    [[ -n "$CLICKED_VID" ]] || return 0
    for ((i = 0; i < 80; i++)); do
        sleep 0.5
        [[ -S "$SOCK" ]] || continue
        count="$(ipc '{"command":["get_property","playlist-count"]}' | jq -r '.data // 0' 2>/dev/null)"
        [[ "$count" =~ ^[0-9]+$ ]] && ((count > 1)) && break
        count=0
    done
    ((count > 1)) || return 0
    idx="$(ipc '{"command":["get_property","playlist"]}' 2 \
        | jq -r --arg vid "$CLICKED_VID" \
            '.data | map(.filename | contains($vid)) | index(true) // empty' 2>/dev/null)"
    [[ "$idx" =~ ^[0-9]+$ ]] && ((idx > 0)) || return 0
    ipc "{\"command\":[\"set_property\",\"playlist-pos\",$idx]}" >/dev/null
}
# -----------------------------------------------------------------------------

is_alive() {
    [[ -S "$SOCK" ]] || return 1
    local reply
    reply="$(ipc '{"command":["get_property","mpv-version"]}')" || return 1
    [[ -n "$reply" ]] && jq -e '.error == "success"' <<<"$reply" >/dev/null 2>&1
}

if is_alive; then
    set_ytdl_opts
    # append-play (not plain append): if the instance sat idle/finished, the
    # queued entry starts playing instead of waiting for a manual next.
    FLAGS=replace
    ((QUEUE)) && FLAGS=append-play
    # ALWAYS send force-media-title, even empty. A Twitch URL starts mpv with
    # --force-media-title=twitch.tv/<chan> as a GLOBAL option (see fresh-launch
    # branch below), and that value otherwise survives every later file in the
    # session -- so a YouTube video handed to a Twitch-started instance kept
    # showing the channel name as its title. An empty per-file value resets it
    # to the real title (verified: global "twitch.tv/FAKE" -> per-file
    # "force-media-title=" -> media-title reads "clip.mp4").
    OPTS="force-media-title=$TITLE"
    cmd="$(jq -c -n --arg url "$URL" --arg f "$FLAGS" --arg opts "$OPTS" \
        '{command:["loadfile",$url,$f,0,$opts]}')"
    printf '%s\n' "$cmd" | socat -t 1 - "UNIX-CONNECT:$SOCK" >/dev/null
    # Unpause: "pause" is a global property, so a new file loaded into a
    # paused instance would otherwise stay paused until manually unpaused.
    # Skipped in queue mode: appending must not touch playback state of the
    # video currently on screen (you queue *during* a break, often paused).
    if ((QUEUE == 0)); then
        ipc '{"command":["set_property","pause",false]}' >/dev/null || true
        ipc '{"command":["set_property","window-minimized",false]}' >/dev/null || true
    fi
    if ((WANT_PLAYLIST)); then
        jump_to_clicked >/dev/null 2>&1 &
        disown
    fi
    exit 0
fi

# No live instance: stale socket file may exist.
rm -f "$SOCK"
# NOTE: --vulkan-swap-mode=immediate is deliberately NOT passed here. It works
# around an NVIDIA/KWin presentation race that can freeze the display on a
# playlist skip with the OSC visible, but it also disables vsync and tears
# visibly in normal videos. Browser handoffs therefore use the default fifo
# swap mode, the same as mpv.conf.
EXTRA=()
# Queue mode was turned on while no mpv was running (or mpv was quit with it
# still on): come up already looping, so queue_mode.lua's state and the actual
# player agree without needing a second toggle.
((QUEUE)) && EXTRA+=(--loop-playlist=inf)
((WANT_PLAYLIST)) && EXTRA+=(--ytdl-raw-options-append=yes-playlist=)
((IS_MIX)) && EXTRA+=(--ytdl-raw-options-append=playlist-end=$MIX_LIMIT)
if [[ -n "$TITLE" ]]; then
    setsid mpv --input-ipc-server="$SOCK" --force-media-title="$TITLE" "${EXTRA[@]}" -- "$URL" \
        >/dev/null 2>&1 &
else
    setsid mpv --input-ipc-server="$SOCK" "${EXTRA[@]}" -- "$URL" >/dev/null 2>&1 &
fi
disown
if ((WANT_PLAYLIST)); then
    jump_to_clicked >/dev/null 2>&1 &
    disown
fi
exit 0
