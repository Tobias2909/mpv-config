-- chat_overlay.lua -- live chat next to / over the video.
--
-- Sources (normalised to JSONL by ~/.local/bin/mpv-chat-source):
--   * Twitch live      -- anonymous IRC
--   * YouTube live     -- yt-dlp's live_chat track, tailed while it streams
--   * YouTube VOD      -- same track, replayed against time-pos
--
-- F10 cycles: off -> beside -> over -> off
--   beside : video shrinks into the left 3/4, chat gets its own column
--   over   : video stays full size, chat sits over the top-right corner
--
-- Emote images are deliberately NOT handled yet; emote names render as text.

local mp    = require 'mp'
local msg   = require 'mp.msg'
local utils = require 'mp.utils'

-------------------------------------------------------------------- tunables

-- Column width differs per layout: "beside" also shrinks the video by this
-- much, so a narrower column costs less picture; "over" covers video either
-- way, so it can stay wider.
local COL_BESIDE  = 1 / 6     -- chat column width in "beside", fraction of width
local COL_OVER    = 1 / 6     -- chat column width in "over"
local OVER_GAP_R  = 1 / 6     -- empty strip right of the "over" panel
local OVER_RATIO  = 1 / 4     -- chat height in "over" mode, fraction of height
local FONT_SIZE   = 22        -- in the 1920x1080 virtual canvas below
-- Monospace is not cosmetic: emote images are positioned by column, so the
-- glyph advance has to be exact.
--
-- "Noto Sans Mono" (the system fc-match default) does NOT cover CJK at all, so
-- Japanese fell back to the proportional Noto Sans CJK and measured 2.14-2.19
-- cells per character while the code counted 1 -- that is the "emotes off
-- centre in Japanese chat" bug, ~1.15 cells (9.5 virtual px) of drift PER
-- Japanese character, compounding along the line.
--
-- "Noto Sans Mono CJK JP" (a face inside noto-cjk's NotoSansCJK-Regular.ttc)
-- covers Latin AND CJK in one font with an exact 1:2 cell relationship, so
-- there is no fallback and no drift. Verified through libass at fs22: every
-- one of あ 漢 Ａ カ 、 。 measures 2.0132 cells.
local FONT        = "Noto Sans Mono CJK JP"
-- libass sizes text by the font's OS/2 winAscent+winDescent for VSFilter
-- compatibility, NOT by the em square -- so \fs22 does not mean a 22 px em and
-- the 600/1000 advance from the font file is NOT the column width.
--   Noto Sans Mono: advance 600/1000 em, winAscent+winDescent = 1618/1000
--   column = fs * 0.600 / 1.618 = 0.370828 * fs
-- Confirmed by rendering through libass: 8.1538 px at fs=22 (ratio 0.37063)
-- and 37.1282 px at fs=100 (ratio 0.37128). Using 0.6 made every emote drift
-- right, worsening with column number. Recompute this if FONT changes.
-- MEASURED through libass at the production font size, not computed from the
-- font file: the file's 500/1448 = 0.345304 is 0.5% off what libass actually
-- lays out (0.343561), and 0.5% of a 36-column line is a third of a cell.
-- The same harness reproduces the old font's shipped 0.370828 to five
-- decimals, so it is the trustworthy source. Re-measure if FONT changes.
local CHAR_W_RATIO = 0.343561
local EMOTE_COLS  = 3         -- columns reserved per emote (~one line tall)
-- Emotes are NOT square: real 7TV/BTTV sets run up to 4:1 (192x48). Height is
-- pinned to EMOTE_COLS cells and the width follows the image aspect, so the
-- cell count varies per emote. Capped so one very wide emote cannot eat a
-- whole line of a 36-column panel.
local EMOTE_COLS_MAX = 12
-- Animation. The cost is CPU on mpv's MAIN thread -- one mmap plus one command
-- dispatch per re-issued frame, measured at ~80 us each -- and it is invisible
-- to the GPU: at 63 animated emotes the VO thread does not move (+0.0 points),
-- GPU utilisation stays inside noise and power draw is flat, on both a 1440p165
-- and a 2160p60 output, at 1080p60 and 2160p60 source.
--
-- So the emote COUNT is nearly free and the ceiling is the id pool, not a
-- command budget: ANIM_MAX is set from #OV_IDS below, i.e. everything on
-- screen animates and nothing freezes on frame 0. The worst case ever
-- measured (63 animated, "beside", 8 msg/s of 7 distinct animated emotes)
-- ran at 1467 overlay-add/s for 18% of ONE core and dropped no frames, with
-- ~8.5x headroom before that core would saturate. Even with the GPU pinned at
-- 98% by a deliberately over-budget shader, the drop count was identical with
-- animation off, at 16 and at 63.
--
-- ANIM_FPS is the expensive dimension, because it multiplies both the command
-- rate and the redraws. That is the one to leave alone.
local ANIM        = true      -- master switch, toggled live by toggle-anim
local ANIM_FPS    = 20        -- overlay update rate, NOT the emote's own fps
local ANIM_MAX                -- most animated at once; assigned from OV_IDS
-- overlay-add ids are 0..63; thumbfast owns 42 (/etc/mpv/scripts/thumbfast.lua).
-- Every other id is ours, so 63 images can be on screen at once. That is still
-- far short of the worst case (37 lines x 9 emotes = 333 in "beside"), which is
-- why runs are collapsed, messages are capped, and allocation runs newest-first.
local THUMBFAST_ID = 42
-- Image slots one message may claim in the FULL-HEIGHT layout; the rest
-- collapse into a "+N" token. "over" raises this and drops the run-collapse
-- entirely -- see the cap/merge pair in render(), which derives both from the
-- row count so the product can never drain the id pool.
-- 4 was far too tight for YouTube: the popular pattern is ALTERNATING emoji
-- (":brown_heart::green_heart:" repeated), so the adjacent-run collapse above
-- never fires and 6 distinct slots is the single most common message shape.
-- Measured over one VOD's replay chat (2058 messages carrying emotes):
--   slots/msg  1:609  2:80  3:27  4:506  5:92  6:540  7:26  8:115 ... 30:1
--   cap 4 -> 40.6% of them overflow, cap 5 -> 36.2%, cap 6 -> 9.9%,
--   cap 8 -> 3.1%, cap 10 -> 1.4%, cap 12 -> 0.5%
-- 6 kills three quarters of the overflow for at most 2 extra ids per message.
-- The cost of raising it is NOT a cliff: the id pool is allocated newest-first
-- and degrades off the top of the panel, so a higher cap only means fewer
-- distinct messages hold an image during a genuine emote wall (63/6 ~ 10
-- messages instead of 63/4 ~ 15).
local MAX_PER_MSG  = 6        -- image slots one message may claim
local FETCH_BATCH  = 8
local LINE_SPACE  = 1.25      -- line height multiplier
local PAD         = 12
-- Generous on purpose: real chat is far smaller than it feels. A 7 h 44 m
-- YouTube VOD's complete replay chat is 1823 messages / 287 KB, and a busy
-- Twitch channel runs ~8 msg/s (~150 B each) = ~4 MB/h. 500k messages is
-- roughly 125 MB worst case, which never trims in practice, so seeking back
-- never has to re-read the file.
local MAX_KEEP    = 500000    -- already-shown messages kept behind the cursor
local CHUNK       = 262144    -- bytes read per pass
local MAX_CHUNKS  = 20        -- passes per poll, so a big VOD can't stall mpv
local MAX_SHOW    = 60        -- messages considered for one redraw
local CHAT_DELAY  = 0         -- seconds to hold chat back, relative to video
-- YouTube delivers live chat in ~10 s fragments (measured: 84 messages on only
-- 7 distinct arrival timestamps, fragments 9.9-10.2 s apart), so every message
-- in a fragment is ALREADY late when it reaches us. Scheduling by post time
-- alone would therefore still make a whole fragment due at once. Holding chat
-- back by more than one fragment period is what lets the post times spread the
-- messages out again. Twitch IRC is realtime and needs none of this.
-- Lower it for less latency at the cost of the bursts coming back.
-- Smoothing target: how far behind its POST time a message is displayed.
-- It cannot be lower than YouTube's own pipeline lag -- a message cannot be
-- shown before it arrives -- so it is MEASURED per stream (a - w) rather than
-- guessed, and only a small margin is added on top. Measured on a live
-- stream: the freshest message in a fragment was already 13.3-21.2 s old on
-- arrival, so the floor there was ~21 s. Raising the
-- margin buys robustness against a late fragment; lowering it means the
-- stalest messages of a fragment arrive overdue and appear together.
-- Starting estimate for YouTube before any usable lag sample exists. The
-- opening backlog cannot supply one: its messages are minutes old by
-- definition (measured: up to 804 s), so feeding them to the estimator would
-- peg it at SMOOTH_MAX. Measured steady-state pipeline lag is 13-21 s.
local YT_SEED_DELAY = 15
local SMOOTH_MARGIN = 2       -- seconds added on top of the measured lag
local SMOOTH_MIN    = 2
local SMOOTH_MAX    = 30
local LAG_WINDOW    = 120     -- seconds of lag samples kept
-- Two filters keep the opening backlog out of the estimate. Both are needed:
--   LAG_CAP     - backlog messages are minutes old (measured up to 804 s) and
--                 are meant to dump immediately, not to widen the delay.
--   LAG_WARMUP  - the FIRST batch's freshest message also looked unusually
--                 stale (37.8 s vs 13-21 s steady state), because "arrival" is
--                 when yt-dlp's file first became readable, which lags its
--                 actual fetch. Ignoring the opening seconds avoids baking
--                 that startup cost into the delay forever.
-- An earlier attempt used a "first poll" flag instead; it failed because the
-- backlog spans MANY polls, so 800-second-old messages reached the estimator
-- and pinned it to SMOOTH_MAX.
local LAG_CAP       = 60
local LAG_WARMUP    = 15
local LOOKAHEAD   = 21600     -- stop reading this far (s) ahead of playback
-- This is the CHAT REFRESH RATE, not just a file-read interval: render() only
-- runs from this timer (`if dirty then render() end`), so POLL is the hard cap
-- on how often a new message can appear. At 0.25 s a busy channel delivered
-- 2-3 messages into every tick and they all popped in together, which reads as
-- "chat is not snappy, it loads many at once". 0.05 s puts the granularity
-- below the ~100 ms at which arrivals still look simultaneous.
-- Polling this often is cheap: an idle poll is one read() that returns nil.
local POLL        = 0.05      -- seconds between file polls == chat refresh rate
local FADE_STEPS  = 8
local FADE_TIME   = 0.20      -- seconds for the fade in/out

-- Japanese chat -> English, by ~/.local/bin/mpv-chat-translate. It follows the
-- same JSONL the panel reads and appends {"n", "en"} lines to a sidecar file,
-- keyed by the line number of the message. Nothing here ever waits for it: a
-- message is drawn in Japanese the moment it is due and switches to English
-- when its translation lands, which on a live stream happens inside the
-- smoothing delay chat is already held back by.
local TR_MODEL     = "entai2965/sugoi-v4-ja-en-ctranslate2"
local TR_DEVICE    = "cuda"
-- Measured on the shipping model: 40 msg/s translating one at a time, 286 at
-- 16, 293 at 32 -- so 16 is where the curve flattens, and a bigger batch only
-- buys latency (56 ms per batch against 109 ms). The worst chat wall ever
-- measured here is 8 msg/s, i.e. 3% of this.
local TR_BATCH     = 16
-- How long a partly filled batch waits. A trickle of chat is bounded by this,
-- not by the batch size.
local TR_FLUSH     = 0.3
-- A VOD's replay chat downloads hours faster than realtime; translating all of
-- it up front would spend gpu minutes on chat nobody has reached yet. The
-- translator stops reading this far ahead of the playhead, which it learns
-- from the position file written below.
local TR_LOOKAHEAD = 120
local TR_POS_EVERY = 1.0      -- seconds between position file writes
-- Names are the one thing the translator cannot get right, since it
-- transliterates what it has never seen instead of spelling it. Shared with
-- the subtitle feature, and simply absent if the file is not there.
local TR_GLOSSARY  = "~~/translate-glossary.tsv"

local RES_X, RES_Y = 1920, 1080

--------------------------------------------------------------------- state

local MODES = { "off", "beside", "over" }
-- What a chat-capable file opens in when the PREVIOUS file had no chat.
-- Stream -> stream deliberately keeps the current layout instead.
local DEFAULT_MODE = "over"
local NO_CHAT_MSG  = "No chat for this video"
local mode  = "off"
-- Geometry to use while fading OUT. `mode` is already "off" during the fade,
-- and the panel-height ternary below would otherwise fall through to the
-- full-height "beside" layout -- so leaving "over" briefly redrew chat down
-- the entire right edge before it faded.
local last_layout = "beside"
-- Space the OSC occupies, as screen fractions, published by ModernZ as
-- user-data/osc/margins while it is visible (its dynamic_margins=yes).
-- Chat must keep out of it: emote bitmaps come from overlay-add, and the man
-- page is explicit that "bitmap overlays added by overlay-add are ALWAYS on
-- top of the ASS overlays added by osd-overlay" -- so no z value can put an
-- emote under the seekbar or under the OSC's bottom gradient. Geometry is the
-- only lever, and it fixes the ASS text at the same time.
local osc_t, osc_b = 0, 0

local overlay      = nil
local source       = nil   -- { platform = "twitch"|"youtube", target = "..." }
local helper       = nil   -- async subprocess handle
local path         = nil   -- JSONL file the helper appends to
local read_pos     = 0
local pending      = ""
local msgs         = {}    -- normalised records, oldest first
local vod          = false -- records carry usable time offsets
local cursor       = 0     -- index of the newest message already shown
-- Both assigned in the emote section further down. They are used by code
-- defined above it (ingest / the poll timer), and a Lua local is not visible
-- before its declaration, so they must be declared here.
local want_emote   = nil
local pump_fetch   = nil
-- Same reason: the poll timer calls it, stop_helper tears it down, and both
-- are defined above the translation section.
local tr_poll      = nil
local stop_translate = nil
local publish_translate = nil
local emote_cols   = nil
local lag_samples  = {}    -- {t = arrival, v = pipeline lag} rolling window
local smooth_delay = 0     -- current adaptive target, seconds
local last_show_at = nil   -- monotonicity guard when the target changes
local anchor_a     = nil   -- ARRIVAL wall clock of the anchor message
local lag_warmup_until = nil  -- ignore lag samples before this wall clock
local anchor_pos   = nil   -- playback position that wall-clock maps to
local poll_timer   = nil
local fade_timer   = nil
-- Translation. `tr_on` is the live state; `tr_forced` records an explicit key
-- press for the current file, which is what lets the subtitle feature switch
-- translation on without overriding a deliberate choice, and lets chat be
-- translated with no subtitles anywhere in sight.
local tr_on        = false
local tr_forced    = nil   -- nil = follow the subtitle feature, else the choice
local tr_handle    = nil
local tr_path      = nil   -- sidecar JSONL of translations
local tr_read      = 0
local tr_pending   = ""
local tr_by_n      = {}    -- line number -> English text
local tr_count     = 0
-- Per line number: false = Japanese and still untranslated, true = translated.
-- Keyed by line number rather than counted per record, because a backwards
-- seek re-ingests the same lines and a plain counter would count them twice.
local ja_state     = {}
local ja_total     = 0
local ja_done      = 0
-- Japanese messages ON SCREEN right now that are still untranslated. The
-- plain done/total pair cannot answer "is the chat on screen in English": a
-- recording buffers its whole chat, hours of it, while the translator
-- deliberately stops 120 s ahead of the playhead, so the ratio looks broken
-- when nothing is wrong. Counted over the visible slice at redraw time, which
-- is at most MAX_SHOW records and needs no bookkeeping that a backwards seek
-- or a toggle could corrupt.
local vis_wait     = 0
local by_n         = {}    -- line number -> record, for late arrivals
local line_no      = 0     -- non-empty lines read; the key both sides agree on
local pos_path     = nil   -- playback position, read by the translator
local pos_next     = 0
local alpha        = 255   -- 255 = invisible, 0 = opaque
local target_alpha = 255
local dirty        = true

------------------------------------------------------------------- helpers

-- mpv's own escaping (player/lua/stats.lua): the BOM makes a literal
-- backslash survive libass without starting an override block.
local function ass_escape(s)
    s = s:gsub('\\', '\\\239\187\191')
    s = s:gsub('{', '\\{')
    s = s:gsub('}', '\\}')
    s = s:gsub('\n', ' ')
    return s
end

-- "#RRGGBB" -> ASS "&HBBGGRR&"; nil/garbage falls back to a readable grey-blue.
local function ass_colour(hex)
    if type(hex) ~= "string" then return "&HD0D0D0&" end
    local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return "&HD0D0D0&" end
    return "&H" .. b .. g .. r .. "&"
end

local function alpha_tag(a)
    return string.format("{\\alpha&H%02X&}", a)
end

-- Codepoint length/substring. #s would count UTF-8 bytes and mis-wrap any
-- non-ASCII message.
-- Decode the codepoint starting at byte `i`, plus the byte length.
local function ucode_at(s, i)
    local b = s:byte(i)
    if not b then return nil, 0 end
    if b < 0x80 then return b, 1 end
    local n, cp
    if     b >= 0xF0 then n, cp = 4, b % 8
    elseif b >= 0xE0 then n, cp = 3, b % 16
    elseif b >= 0xC0 then n, cp = 2, b % 32
    else   return b, 1 end                  -- stray continuation byte
    for k = 1, n - 1 do
        local c = s:byte(i + k)
        if not c then return b, 1 end
        cp = cp * 64 + (c % 64)
    end
    return cp, n
end

-- Cell width of one codepoint. ALL of these were measured through libass with
-- FONT at fs22 (see the FONT comment); the numbers in brackets are what they
-- actually render as, the return value is the nearest whole cell.
--   CJK / kana / fullwidth [2.0132] -> 2      hangul [1.85] -> 2
--   emoji [2.60] -> 3                         latin, accents [1.11] -> 1
-- Joiners and combining marks take no space of their own.
-- Perfect alignment for all of Unicode is not achievable with one font: rarer
-- scripts fall back to whatever fontconfig picks (Greek measured 1.52,
-- Cyrillic 1.19) and keep a sub-cell error. Japanese, the reported case, is
-- exact.
local function cwidth(cp)
    if cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F
       or (cp >= 0x0300 and cp <= 0x036F)
       or (cp >= 0x1F3FB and cp <= 0x1F3FF) then return 0 end
    if cp >= 0x1F000 and cp <= 0x1FAFF then return 3 end
    if (cp >= 0x1100  and cp <= 0x115F)
       or (cp >= 0x2E80  and cp <= 0x303E)
       or (cp >= 0x3041  and cp <= 0x33FF)
       or (cp >= 0x3400  and cp <= 0x4DBF)
       or (cp >= 0x4E00  and cp <= 0x9FFF)
       or (cp >= 0xA000  and cp <= 0xA4CF)
       or (cp >= 0xAC00  and cp <= 0xD7A3)
       or (cp >= 0xF900  and cp <= 0xFAFF)
       or (cp >= 0xFE30  and cp <= 0xFE6F)
       or (cp >= 0xFF00  and cp <= 0xFF60)
       or (cp >= 0xFFE0  and cp <= 0xFFE6)
       or (cp >= 0x20000 and cp <= 0x3FFFD) then return 2 end
    return 1
end

-- Width of a string in cells. This is a COLUMN count, not a character
-- count: counting codepoints (what this used to do) is only the same thing
-- for Latin, and that is precisely what broke Japanese.
local function uwidth(s)
    local i, w = 1, 0
    while i <= #s do
        local cp, n = ucode_at(s, i)
        if not cp then break end
        w = w + cwidth(cp)
        i = i + n
    end
    return w
end

-- Longest prefix of `s` that fits `cols` cells, and the rest. Used for the
-- hard break of a single unbroken word; a wide character must not be split
-- across the boundary.
local function ucut(s, cols)
    local i, w = 1, 0
    while i <= #s do
        local cp, n = ucode_at(s, i)
        if not cp then break end
        local cw = cwidth(cp)
        if w + cw > cols then break end
        w = w + cw
        i = i + n
    end
    if i == 1 then                       -- one char wider than the whole line
        local _, n = ucode_at(s, 1)
        i = 1 + math.max(1, n)
    end
    return s:sub(1, i - 1), s:sub(i)
end

-- Split a message into text words and emote tokens.
-- Emote labels are glued straight into the text -- ":a::a::a:" or
-- "guapo:face-red-heart-shape:" -- so splitting on whitespace would never find
-- them. Scan for the labels the helper reported instead.
-- `rec.en` is the translated text when translation is on and this message has
-- come back from the translator. It keeps the emote labels in place, so
-- everything below is unaffected by which of the two is drawn.
-- Does this message contain real Japanese? Same ranges the translator itself
-- triggers on (hiragana, katakana LETTERS, common ideographs), so the counts on
-- the help sheet match what is actually sent to the model: half width katakana
-- and the katakana punctuation are excluded because kaomoji are built from
-- them.
local function looks_japanese(s)
    local i = 1
    while i <= #s do
        -- ucode_at returns the codepoint and its BYTE LENGTH, not the next
        -- index -- so the step is i + n, exactly as in uwidth above.
        local cp, n = ucode_at(s, i)
        if not cp or n < 1 then return false end
        if (cp >= 0x3041 and cp <= 0x3096) or (cp >= 0x30A1 and cp <= 0x30FA)
           or (cp >= 0x4E00 and cp <= 0x9FFF) then
            return true
        end
        i = i + n
    end
    return false
end

local function tokenize(rec, cap, merge)
    local base = (tr_on and rec.en) or rec.text
    local labels = {}
    if type(rec.e) == "table" then
        for _, e in ipairs(rec.e) do
            if type(e) == "table" and type(e.label) == "string"
               and type(e.url) == "string" and #e.label > 0 then
                labels[e.label] = e.url
            end
        end
    end

    local segs = { { text = base } }
    for label, url in pairs(labels) do
        local out = {}
        for _, seg in ipairs(segs) do
            if seg.url then
                out[#out + 1] = seg
            else
                local str, pos = seg.text, 1
                while true do
                    local a, b = str:find(label, pos, true)
                    if not a then break end
                    if a > pos then out[#out + 1] = { text = str:sub(pos, a - 1) } end
                    out[#out + 1] = { url = url, label = label }
                    pos = b + 1
                end
                if pos <= #str then out[#out + 1] = { text = str:sub(pos) } end
            end
        end
        segs = out
    end

    local toks = {}
    for _, seg in ipairs(segs) do
        if seg.url then
            toks[#toks + 1] = { emote = true, url = seg.url, label = seg.label }
        else
            for w in seg.text:gmatch("%S+") do
                toks[#toks + 1] = { emote = false, s = w }
            end
        end
    end

    -- Collapse a run of the same emote into one image plus a count, the way
    -- chat clients do. An emote wall is exactly the case that would otherwise
    -- drain the overlay pool, and "x24" reads better than 24 copies anyway.
    -- Only worth it where a wall really can drain the pool: a short panel
    -- cannot, so it shows the copies instead (`merge` false).
    local merged = toks
    if merge then
        merged = {}
        for _, t in ipairs(toks) do
            local prev = merged[#merged]
            if t.emote and prev and prev.emote and prev.url == t.url then
                prev.count = prev.count + 1
            else
                if t.emote then t.count = 1 end
                merged[#merged + 1] = t
            end
        end
    end

    -- Cap the image slots one message may claim, so a single spammy message
    -- cannot starve every other visible message. The overflow used to render
    -- as its raw text label (":green_heart:x3"), which turned a wall of images
    -- into a wall of ASCII and wrapped over several lines. Instead every
    -- dropped emote is counted into ONE "+N" token, placed where the first
    -- dropped emote stood so it keeps its position in the sentence.
    local out, shown, dropped, chip = {}, 0, 0, nil
    for _, t in ipairs(merged) do
        if t.emote then
            shown = shown + 1
            if shown > cap then
                -- N counts real emotes, not tokens: a token may already stand
                -- for a collapsed run.
                dropped = dropped + (t.count or 1)
                if not chip then
                    chip = { emote = false, s = "" }
                    out[#out + 1] = chip
                end
            else
                out[#out + 1] = t
            end
        else
            out[#out + 1] = t
        end
    end
    if chip then chip.s = "+" .. dropped end
    return out
end

-- Wrap tokens to `cols`, returning { ass = <line>, emotes = {{col, url}} }.
-- An emote occupies EMOTE_COLS cells of U+00A0 (\h): a normal space can be
-- collapsed at the start of a line, which would shift the image off its cell.
local function wrap_tokens(toks, cols, head_ass, head_cols)
    local lines = {}
    local parts, col, emotes = { head_ass }, head_cols, {}

    local function flush()
        lines[#lines + 1] = { ass = table.concat(parts), emotes = emotes }
        parts, col, emotes = {}, 0, {}
    end

    local function put(str, width, url, suffix, cells)
        if col > 0 and col + 1 + width > cols then flush() end
        if col > 0 then parts[#parts + 1] = " "; col = col + 1 end
        if url then
            emotes[#emotes + 1] = { col = col, url = url }
            parts[#parts + 1] = string.rep("\\h", cells)
            if suffix then parts[#parts + 1] = ass_escape(suffix) end
        else
            parts[#parts + 1] = ass_escape(str)
        end
        col = col + width
    end

    for _, t in ipairs(toks) do
        if t.emote then
            local suffix = (t.count or 1) > 1 and ("x" .. t.count) or nil
            -- Cell count follows the emote's aspect; EMOTE_COLS while it is
            -- still uncached, corrected on the redraw after the fetch lands.
            local cells  = emote_cols(t.url)
            put(nil, cells + (suffix and #suffix or 0), t.url, suffix, cells)
        else
            local str = t.s
            while uwidth(str) > cols do        -- a single unbroken word
                local cut, rest = ucut(str, cols)
                put(cut, uwidth(cut), nil)
                flush()
                str = rest
            end
            put(str, uwidth(str), nil)
        end
    end
    flush()
    return lines
end

------------------------------------------------------------------ detection

-- `path` is authoritative; media-title is NOT.
-- The wrapper starts mpv with a GLOBAL --force-media-title=twitch.tv/<chan>
-- whenever the first URL is a Twitch stream, and that value survives every
-- later file in the session (a YouTube handoff passes no title option). So a
-- YouTube video in a session that began on Twitch still reports
-- media-title = twitch.tv/<chan>. Checking the title first reconnected the
-- Twitch chat over a YouTube stream.
-- Does this YouTube video actually HAVE chat? mpv already knows: ytdl_hook
-- turns yt-dlp's subtitle list into tracks, and a live stream or a was-live
-- VOD with replay carries one whose `lang` is exactly "live_chat". A plain
-- upload has none. Verified at file-loaded time (not just later) on all three
-- cases: is_live -> present, was_live -> present, normal upload -> absent.
-- This costs NOTHING -- no probe, no second yt-dlp call -- because the JSON
-- was already fetched to play the video.
-- Note it must match the lang, not merely "has subtitles": an ordinary video
-- with captions has sub tracks too.
local function youtube_has_chat()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.lang == "live_chat" then return true end
    end
    return false
end

local function detect_source()
    local p = mp.get_property("path") or ""

    if p:match("youtube%.com/watch") or p:match("youtu%.be/") then
        if not youtube_has_chat() then return nil end
        return { platform = "youtube", target = p }
    end

    -- Twitch arrives as a streamlink m3u8, so the channel lives only in the
    -- title -- but only trust the title when the path really is that stream.
    if p:match("%.m3u8") or p:match("ttvnw%.net") then
        local chan = (mp.get_property("media-title") or "")
                         :match("^twitch%.tv/([%w_]+)")
        if chan then return { platform = "twitch", target = chan } end
    end

    -- Twitch URL handed to mpv directly (streamlink missing).
    local chan = p:match("^https?://[%w.]*twitch%.tv/([%w_]+)")
    if chan then return { platform = "twitch", target = chan } end

    return nil
end

-------------------------------------------------------------- helper process

local function stop_helper()
    if helper then
        mp.abort_async_command(helper)
        helper = nil
    end
    if poll_timer then poll_timer:kill(); poll_timer = nil end
    if stop_translate then stop_translate() end
    if path then os.remove(path) end
    path, read_pos, pending = nil, 0, ""
    msgs, vod, cursor = {}, false, 0
    -- The line numbering belongs to one file, so it restarts with it.
    by_n, tr_by_n, line_no, tr_count = {}, {}, 0, 0
    ja_state, ja_total, ja_done = {}, 0, 0
    vis_wait = 0
    -- Publish only now: stop_translate() above runs before this reset, so
    -- publishing there would republish the counts of the file being left.
    if publish_translate then publish_translate() end
    anchor_a, anchor_pos, last_show_at = nil, nil, nil
    lag_samples, smooth_delay, lag_warmup_until = {}, 0, nil
    -- Redraw NOW. Without this the previous stream's messages stay on screen
    -- until the new source produces its first line -- forever on an offline
    -- channel, and ~10 s on a YouTube stream.
    dirty = true
    render()
end

-- Every record gets a `show_at` in PLAYBACK time, so live and VOD render
-- through one path. Nothing is trimmed here: messages that arrive while the
-- video is paused must survive until playback reaches them.
-- Track the pipeline lag (arrival - post) and keep the smoothing target just
-- above its recent worst case. Twitch IRC arrives in realtime, so its samples
-- are ~0 and the target collapses to CHAT_DELAY: no delay is added there.
local function note_lag(arrival, post)
    if not (arrival and post) then return end
    if lag_warmup_until and arrival < lag_warmup_until then return end
    local v = arrival - post
    if v < 0 or v > LAG_CAP then return end
    lag_samples[#lag_samples + 1] = { t = arrival, v = v }
    -- The rolling window IS the hysteresis: the estimate falls only when a
    -- high sample ages out of it, so no extra smoothing is needed (an earlier
    -- exponential decay just fought the window).
    local cut, keep, worst = arrival - LAG_WINDOW, {}, 0
    for i = 1, #lag_samples do
        local sm = lag_samples[i]
        if sm.t >= cut then
            keep[#keep + 1] = sm
            if sm.v > worst then worst = sm.v end
        end
    end
    lag_samples = keep
    -- No measurable lag means nothing to smooth: Twitch IRC stamps arrival ==
    -- post, so `worst` is exactly 0 there and it must stay at CHAT_DELAY.
    -- Without this the margin alone would put a 2 s delay on realtime chat.
    if worst < 1 then
        smooth_delay = CHAT_DELAY
        return
    end
    local want = worst + SMOOTH_MARGIN
    if want < SMOOTH_MIN then want = SMOOTH_MIN end
    if want > SMOOTH_MAX then want = SMOOTH_MAX end
    smooth_delay = want
end

-- Live chat delay for the CURRENT source. VOD replay is scheduled off `t` and
-- keeps the plain CHAT_DELAY.
local function live_delay()
    return math.max(smooth_delay, CHAT_DELAY)
end

local function ingest(line, n)
    local rec = utils.parse_json(line)
    if type(rec) ~= "table" or type(rec.text) ~= "string" then return end
    -- Re-reading the file after a backwards seek re-ingests the same lines
    -- with the same numbers, so a translation that arrived earlier is simply
    -- picked up again here rather than being lost or re-requested.
    rec.n, by_n[n], rec.en = n, rec, tr_by_n[n]
    rec.ja = looks_japanese(rec.text)
    if rec.ja then
        if ja_state[n] == nil then
            ja_state[n] = false
            ja_total = ja_total + 1
        end
        -- The translation can arrive before the line is ingested (a seek, or
        -- the translator simply reading first), so both sides count.
        if rec.en and ja_state[n] == false then
            ja_state[n] = true
            ja_done = ja_done + 1
        end
    end
    local now = mp.get_property_number("time-pos") or 0

    if rec.t ~= nil then
        vod = true
        rec.show_at = rec.t + CHAT_DELAY
    else
        -- Live: one anchor pins the helper's wall clock to a playback
        -- position. time-pos stops advancing while paused, so chat stops with
        -- it and then resumes exactly as far behind live as the video is --
        -- no pause handling needed anywhere.
        local w = tonumber(rec.w)
        local arr = tonumber(rec.a) or w
        if w and arr then
            if not anchor_a then
                -- Anchor on ARRIVAL, never on a post time: `w` can be minutes
                -- older than now, and using it as the clock reference added
                -- that whole staleness to every later message's delay.
                anchor_a, anchor_pos = arr, now
                lag_warmup_until = arr + LAG_WARMUP
                if source and source.platform == "youtube" then
                    smooth_delay = math.max(smooth_delay, YT_SEED_DELAY)
                end
            end
            note_lag(arr, w)
            local at = anchor_pos + ((w + live_delay()) - anchor_a)
            -- The target moves, so a later message could otherwise be
            -- scheduled ahead of an earlier one.
            if last_show_at and at < last_show_at then at = last_show_at end
            rec.show_at, last_show_at = at, at
        else
            rec.show_at = now
        end
    end

    -- Queue emote downloads as soon as the message ARRIVES, not when it is
    -- first drawn: a message can sit buffered for minutes (paused, or ahead of
    -- the playhead on a VOD), and drawing may be skipped entirely while chat is
    -- hidden. Fetching here means the image is usually cached by the time the
    -- message is due.
    if want_emote and type(rec.e) == "table" then
        for _, e in ipairs(rec.e) do
            if type(e) == "table" and type(e.url) == "string" then
                want_emote(e.url)
            end
        end
    end

    msgs[#msgs + 1] = rec
    dirty = true
end

-- Are we already buffered far enough past the playhead?
local function far_ahead()
    if #msgs == 0 then return false end
    local now = mp.get_property_number("time-pos") or 0
    return (msgs[#msgs].show_at or 0) > now + LOOKAHEAD
end

-- Read in bounded chunks rather than slurping the file. VOD replay chat
-- downloads far faster than realtime, and re-reading from offset 0 after a
-- backwards seek would otherwise pull a 7 h stream's whole chat into memory
-- in one poll.
local function poll()
    if not path or far_ahead() then return end
    local fh = io.open(path, "r")
    if not fh then return end
    fh:seek("set", read_pos)
    local passes = 0
    while passes < MAX_CHUNKS do
        local chunk = fh:read(CHUNK)
        if not chunk or chunk == "" then break end
        read_pos = read_pos + #chunk
        pending  = pending .. chunk
        while true do
            local nl = pending:find("\n", 1, true)
            if not nl then break end
            local line = pending:sub(1, nl - 1)
            pending = pending:sub(nl + 1)
            if line ~= "" then
                line_no = line_no + 1
                ingest(line, line_no)
            end
        end
        passes = passes + 1
        if far_ahead() then break end
    end
    fh:close()
    -- Only now is the batch complete, so only now can the anchor be the
    -- newest message in it rather than the oldest.
end

-- mpv launched from the browser's native-messaging host inherits the browser's
-- environment, which does NOT contain ~/.local/bin. Resolve by absolute path
-- and only fall back to a PATH lookup.
local function helper_cmd()
    local home = os.getenv("HOME") or ""
    for _, cand in ipairs({ home .. "/.local/bin/mpv-chat-source",
                            "/usr/local/bin/mpv-chat-source" }) do
        local info = utils.file_info(cand)
        if info and info.is_file then return cand end
    end
    return "mpv-chat-source"
end

local function start_helper()
    if helper or not source then return end
    local dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    path = string.format("%s/mpv-chat-%d.jsonl", dir, utils.getpid())
    os.remove(path)
    read_pos, pending, msgs, vod, cursor = 0, "", {}, false, 0
    anchor_a, anchor_pos, last_show_at = nil, nil, nil
    lag_samples, smooth_delay, lag_warmup_until = {}, 0, nil

    local exe  = helper_cmd()
    local args = { exe, "--out", path, source.platform, source.target }
    msg.info("starting chat source: " .. exe .. " " ..
             source.platform .. " " .. source.target)
    local h
    h = mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
    }, function(success, res, err)
        -- `helper` is nil'd/replaced when we abort on purpose (mode change or
        -- stream switch); anything but the live handle is not a real failure.
        if h ~= helper or mode == "off" then return end
        local detail = err or (res and res.error_string) or "?"
        local code   = res and res.status
        -- A clean exit is NOT a failure. A YouTube VOD's replay chat is a
        -- FINITE download: yt-dlp fetches the whole live_chat.json, renames
        -- it and exits, so the helper reaches EOF and exits 0 -- minutes in,
        -- which is why this looked like a delayed error. Nothing is lost:
        -- every message is already in the jsonl and poll() keeps handing it
        -- to the panel in playback time. Same for a live stream that ends.
        -- `helper` deliberately stays set: start_helper() bails on a non-nil
        -- handle, and letting a mode cycle restart it would reset the buffer
        -- and re-download the entire chat.
        if success and code == 0 then
            if read_pos == 0 and #msgs == 0 then
                -- Exited without ever producing a line. detect_source() only
                -- starts the helper when a live_chat track exists, so this is
                -- yt-dlp finding no chat after all -- say that, not "failed".
                msg.warn("chat source exited without any message")
                mp.osd_message(NO_CHAT_MSG, 2)
            else
                msg.info("chat source finished, whole chat buffered")
            end
            return
        end
        local stderr = res and res.stderr or ""
        stderr = stderr:match("^[^\n]*") or ""
        msg.error("chat source failed: " .. tostring(detail) ..
                  " status=" .. tostring(code) .. " " .. stderr)
        mp.osd_message("Chat source failed: " .. tostring(detail) ..
                       (stderr ~= "" and ("\n" .. stderr) or ""), 6)
    end)
    helper = h

    poll_timer = mp.add_periodic_timer(POLL, function()
        poll()
        tr_poll()
        pump_fetch()
        if dirty then render() end
    end)
end

----------------------------------------------------------------- translation

local function tr_cmd()
    local home = os.getenv("HOME") or ""
    for _, cand in ipairs({ home .. "/mpv-config/bin/mpv-chat-translate",
                            home .. "/.local/bin/mpv-chat-translate",
                            "/usr/local/bin/mpv-chat-translate" }) do
        local info = utils.file_info(cand)
        if info and info.is_file then return cand end
    end
    return "mpv-chat-translate"
end

-- One property carries the whole translation state, because render() cannot:
-- it early-returns while chat is hidden, and translation keeps running there.
-- Read by keyhelp.lua for the sheet's translation area, and by the harness.
publish_translate = function()
    mp.set_property_native("user-data/chat_translate",
                           { on = tr_on, lines = tr_count, seen = line_no,
                             japanese = ja_total, english = ja_done,
                             waiting = vis_wait })
end

stop_translate = function()
    tr_on = false
    if tr_handle then
        mp.abort_async_command(tr_handle)
        tr_handle = nil
    end
    if tr_path then os.remove(tr_path) end
    if pos_path then os.remove(pos_path) end
    tr_path, pos_path, tr_read, tr_pending = nil, nil, 0, ""
end

-- Translations are keyed by line number, so the reader is independent of the
-- chat reader: it can run behind it, ahead of a redraw, or catch up after a
-- seek, and every line still lands on the right message.
tr_poll = function()
    if tr_on and pos_path and mp.get_time() >= pos_next then
        pos_next = mp.get_time() + TR_POS_EVERY
        local f = io.open(pos_path, "w")
        if f then
            f:write(string.format("%.3f", mp.get_property_number("time-pos") or 0))
            f:close()
        end
    end
    if not tr_path then return end
    local before = tr_count
    local fh = io.open(tr_path, "r")
    if not fh then return end
    fh:seek("set", tr_read)
    local chunk = fh:read(CHUNK)
    fh:close()
    if not chunk or chunk == "" then return end
    tr_read = tr_read + #chunk
    tr_pending = tr_pending .. chunk
    while true do
        local nl = tr_pending:find("\n", 1, true)
        if not nl then break end
        local line = tr_pending:sub(1, nl - 1)
        tr_pending = tr_pending:sub(nl + 1)
        local rec = utils.parse_json(line)
        if type(rec) == "table" and tonumber(rec.n) and type(rec.en) == "string"
           and rec.en ~= "" then
            local n = tonumber(rec.n)
            -- Count DISTINCT lines: switching translation off and on restarts
            -- the translator, which re-reads the chat from the top and
            -- re-emits every line it already did, so a plain increment
            -- reported three times the work after three toggles.
            if tr_by_n[n] == nil then tr_count = tr_count + 1 end
            tr_by_n[n] = rec.en
            if ja_state[n] == false then
                ja_state[n] = true
                ja_done = ja_done + 1
            end
            local target = by_n[n]
            if target then
                target.en = rec.en
                -- Only a message that is already on screen forces a redraw.
                -- Most translations land while their message is still buffered
                -- ahead of the playhead, and those cost nothing.
                -- `msgs[cursor]` is nil until the first message is due, and
                -- a live translation can land inside the smoothing delay, so
                -- this compared a number against nil and threw.
                local newest = msgs[cursor]
                if tr_on and newest and newest.n and n <= newest.n then
                    dirty = true
                end
            end
        end
    end
    if tr_count ~= before then publish_translate() end
end

local function start_translate()
    if tr_handle or not path then return end
    tr_path  = path .. ".tr"
    pos_path = path .. ".pos"
    os.remove(tr_path)
    tr_read, tr_pending, pos_next = 0, "", 0
    local exe  = tr_cmd()
    local args = { exe, "--in", path, "--out", tr_path,
                   "--pos-file", pos_path,
                   "--parent-pid", tostring(utils.getpid()),
                   "--mt-model", TR_MODEL,
                   "--device", TR_DEVICE,
                   "--batch", tostring(TR_BATCH),
                   "--flush-after", tostring(TR_FLUSH),
                   "--lookahead", tostring(TR_LOOKAHEAD) }
    local gloss = mp.command_native({ "expand-path", TR_GLOSSARY })
    local info  = gloss and utils.file_info(gloss)
    if info and info.is_file then
        args[#args + 1] = "--glossary"
        args[#args + 1] = gloss
    end
    msg.info("starting chat translator: " .. exe)
    local h
    h = mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
    }, function(success, res, err)
        if h ~= tr_handle then return end
        local code = res and res.status
        if success and code == 0 then
            msg.info("chat translator stopped")
            -- Released on purpose, unlike the chat source's handle: a restart
            -- costs nothing here because the sidecar is rebuilt from the same
            -- line numbers, while a stale handle would silently refuse one.
            tr_handle = nil
            return
        end
        local stderr = ((res and res.stderr or ""):match("[^\n]*\n?$")) or ""
        msg.error("chat translator failed: " .. tostring(err or code) .. " " .. stderr)
        mp.osd_message("Chat translation failed: " ..
                       tostring(err or (res and res.error_string) or code) ..
                       (stderr ~= "" and ("\n" .. stderr) or ""), 6)
        tr_on, tr_handle = false, nil
        publish_translate()
        dirty = true
    end)
    tr_handle = h
end

-- `announce` false when the subtitle feature is what turned this on or off, so
-- one key press does not produce two messages on screen.
local function set_translate(on, announce)
    if on == tr_on then return end
    -- Translating a chat nobody is looking at would start the source helper,
    -- and with it a chat download, for a file whose chat was switched off on
    -- purpose. F12 reaches this path too, so it has to be handled here rather
    -- than in the key binding.
    if on and mode == "off" and not path then
        if announce ~= false then
            mp.osd_message("Chat is off. Turn it on with F10 first.", 2)
        end
        return
    end
    tr_on = on
    if on then
        if not path then start_helper() end
        start_translate()
    else
        stop_translate()
    end
    publish_translate()
    if announce ~= false then
        mp.osd_message("Chat translation: " .. (tr_on and "on (Japanese to English)"
                                                      or "off"), 2)
    end
    dirty = true
    render()
end

--------------------------------------------------------------------- render


------------------------------------------------------------------- emotes

local CACHE_DIR = (os.getenv("XDG_CACHE_HOME")
                   or ((os.getenv("HOME") or "") .. "/.cache"))
                  .. "/mpv-chat-emotes"

local OV_IDS = {}             -- usable overlay ids, thumbfast's excluded
for i = 0, 63 do
    if i ~= THUMBFAST_ID then OV_IDS[#OV_IDS + 1] = i end
end
-- Everything that can be on screen animates; see the ANIM block for why the
-- old fixed cap was 4x lower than it needed to be.
ANIM_MAX = #OV_IDS

local emote_known    = {}     -- url -> meta table, or false for "not cached"
local emote_pending  = {}     -- url -> true, waiting to be fetched
local emote_inflight = false
local ov_active      = {}     -- overlay id -> placement signature
local anim_slots     = {}     -- overlay id -> everything anim_tick needs
local anim_timer     = nil
local anim_refreshed = {}     -- url -> true, v1 cache entry re-fetched once

-- djb2, byte-for-byte identical to cache_key() in ~/.local/bin/mpv-chat-emote.
-- No bit ops on purpose: h*33 stays below 2^53 so it is exact in Lua doubles.
local function key_for(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    local safe = url:gsub("[^A-Za-z0-9]+", "_")
    if #safe > 120 then safe = safe:sub(#safe - 119) end
    return string.format("%s_%08x", safe, math.floor(h))
end

local function emote_cmd()
    local home = os.getenv("HOME") or ""
    local cand = home .. "/.local/bin/mpv-chat-emote"
    local info = utils.file_info(cand)
    if info and info.is_file then return cand end
    return "mpv-chat-emote"
end

-- Cached meta, or nil after queueing a background fetch. Never blocks: an
-- uncached emote just stays as its text label until the file lands.
local function emote_meta(url)
    local hit = emote_known[url]
    if hit ~= nil then return hit or nil end

    local key  = key_for(url)
    local bgra = CACHE_DIR .. "/" .. key .. ".bgra"
    local info = utils.file_info(bgra)
    if info and info.is_file then
        local fh = io.open(CACHE_DIR .. "/" .. key .. ".json", "r")
        if fh then
            local body = fh:read("*a")
            fh:close()
            local j = utils.parse_json(body or "")
            if type(j) == "table" and tonumber(j.w) and tonumber(j.h) then
                local n = math.floor(tonumber(j.n) or 1)
                local m = { path = bgra, w = math.floor(tonumber(j.w)),
                            h = math.floor(tonumber(j.h)),
                            n = (n > 0) and n or 1,
                            fps = tonumber(j.fps) or 0,
                            -- v1 entries hold only the first frame, so they
                            -- are usable but need one re-fetch to animate.
                            stale = (tonumber(j.v) or 1) < 2 }
                m.frame_bytes = m.w * m.h * 4
                emote_known[url] = m
                return m
            end
        end
    end
    emote_known[url] = false
    return nil
end

-- How many text cells this emote occupies. Height is fixed at EMOTE_COLS
-- cells, so the width -- and therefore the cell count -- scales with the
-- image's own aspect ratio. Falls back to a square while uncached.
emote_cols = function(url)
    local m = emote_meta(url)
    if not m or m.h <= 0 then return EMOTE_COLS end
    local n = math.ceil(EMOTE_COLS * (m.w / m.h))
    if n < 1 then n = 1 end
    if n > EMOTE_COLS_MAX then n = EMOTE_COLS_MAX end
    return n
end

-- Ask for a URL to exist in the cache; queues a background fetch on a miss.
want_emote = function(url)
    local m = emote_meta(url)
    if m == nil then
        emote_pending[url] = true
    elseif m.stale and not anim_refreshed[url] then
        -- Once per session only: a URL that keeps failing to re-decode must
        -- not be re-queued on every single message that mentions it.
        anim_refreshed[url] = true
        emote_pending[url] = true
    end
end

pump_fetch = function()
    if emote_inflight then return end
    local batch = {}
    for url in pairs(emote_pending) do
        batch[#batch + 1] = url
        emote_pending[url] = nil
        if #batch >= FETCH_BATCH then break end
    end
    if #batch == 0 then return end

    local args = { emote_cmd() }
    for _, u in ipairs(batch) do args[#args + 1] = u end
    emote_inflight = true
    mp.command_native_async({
        name = "subprocess", args = args, playback_only = false,
        capture_stdout = false, capture_stderr = false,
    }, function()
        emote_inflight = false
        for _, u in ipairs(batch) do emote_known[u] = nil end  -- re-test cache
        dirty = true
    end)
end

-- Which frame of an animated emote is due right now. Wall clock, not
-- time-pos: chat freezes while the video is paused (by design), but a frozen
-- emote just looks like a broken image.
local function frame_offset(fps, n, frame_bytes)
    return (math.floor(mp.get_time() * fps) % n) * frame_bytes
end

-- Re-issue only the placements whose frame changed. Deliberately NOT a full
-- render(): rebuilding the ASS text 20x a second would cost far more than the
-- handful of overlay commands this actually needs.
local function anim_tick()
    for id, sl in pairs(anim_slots) do
        local off = frame_offset(sl.fps, sl.n, sl.frame_bytes)
        local sig = table.concat({ sl.path, sl.px, sl.py, sl.dw, sl.dh, off }, "|")
        if ov_active[id] ~= sig then
            mp.command_native_async({
                "overlay-add", id, sl.px, sl.py,
                sl.path, off, "bgra", sl.w, sl.h, sl.w * 4, sl.dw, sl.dh,
            }, function() end)
            ov_active[id] = sig
        end
    end
end

local function anim_sync()
    if next(anim_slots) and not anim_timer then
        anim_timer = mp.add_periodic_timer(1 / ANIM_FPS, anim_tick)
    elseif not next(anim_slots) and anim_timer then
        anim_timer:kill()
        anim_timer = nil
    end
end

local function clear_overlays()
    for id in pairs(ov_active) do
        mp.command_native_async({ "overlay-remove", id }, function() end)
    end
    ov_active = {}
    anim_slots = {}
    anim_sync()
end

-- Which slice of `msgs` is due at the current playback position.
local function visible_slice()
    local now = mp.get_property_number("time-pos") or 0
    -- show_at ascends, so a linear cursor walk suffices going forwards; a
    -- backwards seek rewinds it.
    if cursor > 0 and msgs[cursor] and (msgs[cursor].show_at or 0) > now then
        cursor = 0
    end
    while msgs[cursor + 1] and (msgs[cursor + 1].show_at or 0) <= now do
        cursor = cursor + 1
    end
    -- Trim ONLY what has already scrolled out of view. Anything still ahead of
    -- the cursor is backlog waiting for playback to reach it.
    local excess = cursor - MAX_KEEP
    if excess > 0 then
        for _ = 1, excess do table.remove(msgs, 1) end
        cursor = cursor - excess
    end
    -- Observable state: `shown` only advances while playback advances, so a
    -- frozen counter during pause is the proof that sync works.
    local out = {}
    for i = math.max(1, cursor - MAX_SHOW + 1), cursor do
        out[#out + 1] = msgs[i]
    end
    return out
end

function render()
    dirty = false
    if not overlay then return end
    if mode == "off" and alpha >= 255 then
        overlay.data = ""
        overlay:update()
        clear_overlays()
        if vis_wait ~= 0 then
            vis_wait = 0
            publish_translate()
        end
        return
    end

    -- `layout` must be resolved BEFORE it is used: an earlier version read it
    -- one line above its own `local`, so it picked up a nil global and "over"
    -- silently used COL_BESIDE for its width.
    local layout  = (mode ~= "off") and mode or last_layout
    local over    = (layout == "over")
    local col_w   = RES_X * (over and COL_OVER or COL_BESIDE)
    -- "beside" is flush right (the video is margined out of the way anyway);
    -- "over" is inset by OVER_GAP_R so it does not hug the screen edge.
    local x0      = RES_X - col_w - (over and (RES_X * OVER_GAP_R) or 0)
    local text_x  = x0 + PAD
    local text_w  = col_w - 2 * PAD
    local line_h  = FONT_SIZE * LINE_SPACE
    local char_w  = FONT_SIZE * CHAR_W_RATIO   -- one Latin cell; CJK is two
    local cols    = math.max(8, math.floor(text_w / char_w))
    local top_px  = PAD + osc_t * RES_Y
    local bot_px  = PAD + osc_b * RES_Y
    local y0      = top_px
    local panel_h = over and (RES_Y * OVER_RATIO) or (RES_Y - top_px - bot_px)
    -- "over" is top-anchored and short, so it normally clears the OSC; clamp
    -- anyway in case a future layout makes the bottom bar tall.
    if y0 + panel_h > RES_Y - bot_px then panel_h = RES_Y - bot_px - y0 end
    if panel_h < line_h then panel_h = line_h end
    local max_ln  = math.max(1, math.floor((panel_h - 2 * PAD) / line_h))
    -- A message occupies at least one row, so at most max_ln of them can be on
    -- screen and the images they claim can never exceed max_ln * cap. Deriving
    -- the cap from the pool keeps that product inside #OV_IDS BY CONSTRUCTION,
    -- which is what makes it safe to stop collapsing runs: the short "over"
    -- panel (8 rows -> cap 7 -> 56 <= 63) shows every emote a message sent,
    -- while the full-height layout (37 rows) keeps the collapse and the
    -- measured cap of 6 and degrades off the top as before.
    -- In practice "over" holds fewer than 56 images anyway: emote cell width
    -- follows the image aspect (3-5 cells for real shapes), so some 7-emote
    -- messages wrap onto a second row and the panel self-limits.
    local cap     = MAX_PER_MSG
    local merge   = true
    if over then
        cap   = math.max(MAX_PER_MSG, math.floor(#OV_IDS / max_ln))
        merge = false
    end

    -- Build newest-first until the panel is full, then flip for drawing.
    local list, lines = visible_slice(), {}
    -- Untranslated Japanese among what is actually DRAWN, counted inside the
    -- loop below rather than over `list`: the slice holds up to MAX_SHOW
    -- candidates while the panel fits only `max_ln` rows, so counting the
    -- slice reported 60 waiting lines for an eight row panel.
    local wait = 0
    for i = #list, 1, -1 do
        local rec  = list[i]
        if tr_on and rec.ja and not rec.en then wait = wait + 1 end
        local user = rec.user or "?"
        -- No trailing space: wrap_tokens inserts the separator itself, so
        -- ending the head with ": " would render a double space.
        local head = string.format("{\\b1\\c%s}%s{\\b0\\c&HFFFFFF&}:",
                                   ass_colour(rec.color), ass_escape(user))
        local block = wrap_tokens(tokenize(rec, cap, merge), cols, head,
                                  uwidth(user) + 1)
        for j = #block, 1, -1 do
            table.insert(lines, 1, block[j])
            if #lines >= max_ln then break end
        end
        if #lines >= max_ln then break end
    end
    if wait ~= vis_wait then
        vis_wait = wait
        publish_translate()
    end

    if #lines == 0 and source then
        lines = { { ass = string.format(
            "{\\i1\\c&HA0A0A0&}connecting to %s\\N%s...{\\i0}",
            ass_escape(source.platform), ass_escape(source.target:sub(1, 40))),
            emotes = {} } }
    end

    local a = alpha_tag(alpha)
    local out = {}

    -- overlay-add works in real OSD pixels, not the ASS virtual canvas.
    local osd = mp.get_property_native("osd-dimensions") or {}
    local sx  = (tonumber(osd.w) or 0) > 0 and (osd.w / RES_X) or nil
    local sy  = (tonumber(osd.h) or 0) > 0 and (osd.h / RES_Y) or nil
    local em_px  = char_w * EMOTE_COLS
    local show_e = sx and sy and alpha < 128     -- overlays cannot fade
    local place  = {}                            -- collected, allocated below

    -- "over" grows DOWNWARD from the top edge. The panel is short, so
    -- bottom-anchoring left a visible gap above the first line (the panel's
    -- leftover slack plus padding) and there is no backdrop to hide it any
    -- more. Starts at y0 rather than y0 + PAD to sit that bit closer to the top.
    -- "beside" is a full-height column, so there the newest line stays pinned
    -- to the bottom edge, which is how chat normally reads.
    local y
    if layout == "over" then
        y = y0
    else
        y = y0 + panel_h - PAD - (#lines * line_h)
        if y < y0 + PAD then y = y0 + PAD end
    end
    for _, l in ipairs(lines) do
        out[#out + 1] = string.format(
            "{\\an7\\pos(%.1f,%.1f)\\fn%s\\fs%d\\bord2\\shad0\\q2\\c&HFFFFFF&}%s%s",
            text_x, y, FONT, FONT_SIZE, a, l.ass)
        if show_e then
            for _, em in ipairs(l.emotes or {}) do
                place[#place + 1] = { y = y, col = em.col, url = em.url }
            end
        end
        y = y + line_h
    end

    -- Allocate NEWEST-FIRST. `lines` runs oldest -> newest, so walk the
    -- collected placements backwards: when the pool runs dry the images drop
    -- off the TOP of the panel, not off the messages just arriving.
    local used, animated = 0, 0
    anim_slots = {}
    for i = #place, 1, -1 do
        if used >= #OV_IDS then break end
        local pl   = place[i]
        local meta = emote_meta(pl.url)
        if meta then
            used = used + 1
            local id  = OV_IDS[used]
            local px  = math.floor((text_x + pl.col * char_w) * sx + 0.5)
            local py  = math.floor((pl.y + (line_h - em_px) / 2) * sy + 0.5)
            -- Height pinned to the line, width from the image's own aspect
            -- (never force 1:1 -- wide emotes exist and get mangled by it),
            -- clamped to the cells wrap_tokens actually reserved.
            local ar  = (meta.h > 0) and (meta.w / meta.h) or 1
            local ew  = math.min(em_px * ar, char_w * EMOTE_COLS_MAX)
            local dw  = math.floor(ew * sx + 0.5)
            local dh  = math.floor(em_px * sy + 0.5)
            -- Animate only the newest ANIM_MAX; `place` is walked newest
            -- first, so an emote wall freezes the OLD ones, matching how the
            -- image pool itself degrades.
            local off = 0
            if ANIM and meta.n > 1 and meta.fps > 0 and animated < ANIM_MAX then
                animated = animated + 1
                off = frame_offset(meta.fps, meta.n, meta.frame_bytes)
                anim_slots[id] = {
                    path = meta.path, px = px, py = py, dw = dw, dh = dh,
                    w = meta.w, h = meta.h, n = meta.n, fps = meta.fps,
                    frame_bytes = meta.frame_bytes,
                }
            end
            local sig = table.concat({ meta.path, px, py, dw, dh, off }, "|")
            -- Skip unchanged placements: re-issuing every visible emote on
            -- every redraw is ~250 commands/s for a picture that has not moved.
            if ov_active[id] ~= sig then
                mp.command_native_async({
                    "overlay-add", id, px, py,
                    meta.path, off, "bgra", meta.w, meta.h, meta.w * 4, dw, dh,
                }, function() end)
                ov_active[id] = sig
            end
        end
    end

    -- Release whatever this frame did not use.
    for k = used + 1, #OV_IDS do
        local id = OV_IDS[k]
        if ov_active[id] then
            mp.command_native_async({ "overlay-remove", id }, function() end)
            ov_active[id] = nil
        end
        anim_slots[id] = nil
    end
    -- The tick timer only exists while something is actually animating.
    anim_sync()

    -- Published for measurement over IPC: `animated` is the number of images
    -- being re-issued ANIM_FPS times a second right now.
    mp.set_property_native("user-data/chat_overlay",
                           { shown = cursor, buffered = #msgs,
                             images = used, animated = animated,
                             delay = math.floor(smooth_delay * 10 + 0.5) / 10,
                             rows = max_ln })

    overlay.res_x, overlay.res_y = RES_X, RES_Y
    overlay.data = table.concat(out, "\n")
    overlay:update()
end

---------------------------------------------------------------------- fade

local function fade_to(target)
    target_alpha = target
    if fade_timer then fade_timer:kill(); fade_timer = nil end
    local step = (target_alpha - alpha) / FADE_STEPS
    if step == 0 then render(); return end
    local n = 0
    fade_timer = mp.add_periodic_timer(FADE_TIME / FADE_STEPS, function()
        n = n + 1
        alpha = math.max(0, math.min(255, math.floor(alpha + step)))
        if n >= FADE_STEPS then
            alpha = target_alpha
            fade_timer:kill(); fade_timer = nil
        end
        render()
    end)
end

--------------------------------------------------------------------- modes

-- `announce` = show the "Chat: <mode>" OSD. Suppressed when chat turns itself
-- off because a plain video was loaded: the user did not ask for that, so it
-- should not talk.
local function apply_mode(announce)
    mp.set_property_number("video-margin-ratio-right",
                           mode == "beside" and COL_BESIDE or 0)
    if mode == "off" then
        -- Deliberately NOT stop_helper(): F10 cycles off -> beside -> over, so
        -- switching layouts passes through "off". Tearing the source down here
        -- dropped the whole buffer and re-downloaded every emote. The helper
        -- now lives until the file changes or mpv exits.
        fade_to(255)
        clear_overlays()
    else
        last_layout = mode
        if not source then source = detect_source() end
        if not source then
            mode = "off"
            mp.osd_message(NO_CHAT_MSG, 2)
            return
        end
        start_helper()
        fade_to(0)
    end
    if announce ~= false then mp.osd_message("Chat: " .. mode, 1.5) end
    -- Separate from user-data/chat_overlay: that one is only written by
    -- render(), which early-returns while chat is off, so it cannot report
    -- the off state.
    mp.set_property_native("user-data/chat_mode", mode)
end

local function toggle()
    -- A file with no chat must not cycle modes at all, just say so.
    if not source then source = detect_source() end
    if not source then
        mp.osd_message(NO_CHAT_MSG, 2)
        return
    end
    local i = 1
    for k, v in ipairs(MODES) do if v == mode then i = k end end
    mode = MODES[(i % #MODES) + 1]
    apply_mode()
end

------------------------------------------------------------------- wiring

-- Chat state follows the FILE, not whatever the user last pressed:
--   stream / VOD  -> always opens in "over", regardless of the previous file
--   plain video   -> chat switches itself off
-- stop_helper() runs unconditionally because the "off" branch of apply_mode()
-- deliberately keeps the helper alive across a mode cycle, so a previous
-- stream's source can still be running even when chat is off.
mp.register_event("file-loaded", function()
    stop_helper()
    tr_forced = nil
    local had_chat = (source ~= nil)
    source = detect_source()
    if source then
        -- DEFAULT_MODE only when arriving from something that had no chat.
        -- Going stream -> stream keeps the layout the user chose, so switching
        -- channels while in "beside" stays in "beside".
        if not had_chat then mode = DEFAULT_MODE end
        apply_mode(mode ~= "off")
    elseif mode ~= "off" then
        mode = "off"
        apply_mode(false)
    end
end)

-- Publish the starting state so the property exists before the first mode
-- change (it is read by scripts and by the test harness).
mp.set_property_native("user-data/chat_mode", mode)
publish_translate()

mp.register_event("end-file", function()
    stop_helper()
end)

mp.register_event("shutdown", function()
    clear_overlays()
    stop_helper()
    mp.set_property_number("video-margin-ratio-right", 0)
end)

-- Playback time advancing only matters when it makes the NEXT message due.
-- This used to set `dirty` unconditionally; at POLL 0.25 that was harmless,
-- but at 0.05 it would rebuild the entire ASS block 20x a second even when
-- nothing on screen could possibly change.
-- The OSC appearing must reflow chat immediately, not at the next message.
mp.observe_property("user-data/osc/margins", "native", function(_, m)
    local t = (type(m) == "table" and tonumber(m.t)) or 0
    local b = (type(m) == "table" and tonumber(m.b)) or 0
    if t ~= osc_t or b ~= osc_b then
        osc_t, osc_b = t, b
        dirty = true
        render()
    end
end)

mp.observe_property("time-pos", "number", function(_, now)
    if mode == "off" or not now then return end
    local nxt = msgs[cursor + 1]
    if nxt and (nxt.show_at or 0) <= now then dirty = true end
end)

-- Seeking must land on the chat that belongs to the part being watched, in
-- BOTH directions. The anchor is deliberately never touched here: it is a
-- fixed wall-clock <-> playback-position mapping, so rewinding time-pos makes
-- exactly the right messages due again, and `show_at` stays reproducible.
mp.register_event("seek", function()
    if mode == "off" then return end
    local now = mp.get_property_number("time-pos") or 0
    -- Seeked back past the oldest message still held? Re-read the JSONL from
    -- the start. The helper's file holds everything since chat began, and
    -- because the anchor does not move, replaying it recomputes identical
    -- show_at values.
    if #msgs == 0 or now < (msgs[1].show_at or 0) then
        -- Re-reading assigns the same line numbers again, so translations
        -- already in tr_by_n are re-attached in ingest() and nothing is
        -- re-requested.
        read_pos, pending, msgs = 0, "", {}
        by_n, line_no = {}, 0
    end
    cursor = 0   -- rebuild the walk from scratch; visible_slice re-advances it
    dirty  = true
end)

overlay = mp.create_osd_overlay("ass-events")
mp.add_key_binding(nil, "toggle", toggle)
-- Chat translation is INDEPENDENT of the subtitle feature: this key works on
-- its own, on Twitch as well, and with no subtitles running anywhere.
mp.add_key_binding(nil, "toggle-translate", function()
    if not source then source = detect_source() end
    if not source then
        mp.osd_message(NO_CHAT_MSG, 2)
        return
    end
    tr_forced = not tr_on
    set_translate(not tr_on)
end)

-- Turning on Japanese subtitles turns on Japanese chat translation, because
-- wanting one and not the other is the unlikely case. It reads the subtitle
-- feature's published state rather than being called by it, so neither script
-- knows about the other. An explicit key press wins for the rest of the file:
-- translation stays on when subtitles are switched off, and stays off when
-- they are switched on.
mp.observe_property("user-data/translate_subs", "native", function(_, v)
    if tr_forced ~= nil or not source then return end
    local subs_on = type(v) == "table" and v.state ~= nil and v.state ~= "off"
    set_translate(subs_on and true or false, false)
end)

mp.add_key_binding(nil, "toggle-anim", function()
    ANIM = not ANIM
    if not ANIM then
        anim_slots = {}
        anim_sync()
    end
    dirty = true
    render()
    mp.osd_message("chat emote animation: " .. (ANIM and "on" or "off"))
end)
