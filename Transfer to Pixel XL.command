#!/bin/zsh

# ==============================================================================
# Transfer to Pixel XL — double-clickable macOS launcher (.command)
# ------------------------------------------------------------------------------
# HOW TO USE:
#   1. Save with the .command extension.
#   2. Make it executable ONCE:  chmod +x "Transfer to Pixel XL.command"
#   3. Double-click in Finder -> opens Terminal and runs.
#
# Folder selection order:
#   1) a path passed as an argument (command line)
#   2) a graphical folder picker (double-click in Finder)
#   3) the folder this .command file lives in (picker cancelled)
# ==============================================================================

# ==============================================================================
# RESOLVE SOURCE FOLDER
# ==============================================================================
SCRIPT_DIR="${0:A:h}"

if [[ -n "$1" ]]; then
    SOURCE_DIR="$1"
else
    SOURCE_DIR=$(osascript <<EOF 2>/dev/null
try
    set defaultPath to POSIX file "$SCRIPT_DIR" as alias
    set chosenFolder to choose folder with prompt "Select the photo folder to transfer to your Pixel XL:" default location defaultPath
    return POSIX path of chosenFolder
on error
    return ""
end try
EOF
)
    [[ -z "$SOURCE_DIR" ]] && SOURCE_DIR="$SCRIPT_DIR"
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "❌ Error: '$SOURCE_DIR' is not a directory."
    echo "Press Return to close this window..."; read
    exit 1
fi
SOURCE_DIR="${SOURCE_DIR:A}"

# ==============================================================================
# CONFIGURATION
# ==============================================================================
HISTORY_FILE="$SOURCE_DIR/transfer_history.txt"
FAILED_FILE="$SOURCE_DIR/transfer_failed.txt"   # machine-readable retry list
FAILED_LOG="$SOURCE_DIR/transfer_failed.log"    # human-readable reasons (why it failed)
TARGET_DIR="/sdcard/DCIM/Camera/"
BUFFER_BYTES=524288000                          # 500MB safety margin on the PHONE
MAC_MIN_FREE_BYTES=2147483648                   # never transcode if Mac has <2GB free
MAC_TRANSCODE_HEADROOM=3                         # require Mac free >= input_size * this

# ffmpeg quality (YOUR proven settings). To go faster, change PRESET to "medium".
ENC_CRF=18
ENC_PRESET=slow
ENC_AUDIO_KBPS=192

# If you MANUALLY move source files into a subfolder literally named "Original",
# this skips them so they aren't transferred twice. Note: you do NOT need such a
# folder — your source files are never moved/altered (converts go to the separate
# mp4_h264_fast/ and mp4_hevc_reencoded/ trees), so the in-place source already
# IS the preserved original. Set to false if you have a legit folder named Original
# whose contents you DO want transferred.
EXCLUDE_ORIGINAL_DIR=true

KNOWN_EXTS=(mp4 mov m4v jpg jpeg png heic heif gif tiff tif dng webp 3gp)
IGNORE_EXTS=(aae dat txt log xtag ds_store)

# Homebrew paths (double-clicked Finder sessions often miss these)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

setopt NULL_GLOB
setopt NOCASEGLOB

# Reusable scratch file for capturing ffmpeg/ffprobe stderr (NO per-file mktemp)
FFERR="${TMPDIR:-/tmp}/transfer_fferr.$$"

cd "$SOURCE_DIR" || { echo "❌ Cannot access: $SOURCE_DIR"; echo "Press Return..."; read; exit 1; }

echo "========================================================="
echo "📂 Source folder: $SOURCE_DIR"
echo "========================================================="

touch "$HISTORY_FILE"
: > "$FAILED_FILE"   # truncate each run: failures are RE-ATTEMPTED, not abandoned
: > "$FAILED_LOG"

# Sweep stale partial outputs from a previous interrupted/crashed run
rm -f mp4_h264_fast/**/*.partial.mp4(.N) mp4_hevc_reencoded/**/*.partial.mp4(.N) 2>/dev/null

# ==============================================================================
# HELPERS
# ==============================================================================
_pause_on_exit() {
    echo ""
    echo "Press Return to close this window..."
    read
}

CURRENT_TMPOUT=""
_cleanup() {
    [[ -n "$CURRENT_TMPOUT" && -f "$CURRENT_TMPOUT" ]] && rm -f "$CURRENT_TMPOUT"
    rm -f "$FFERR"
    printf "\r\033[K⛔ Interrupted by user.\n"
    _pause_on_exit
    exit 130
}
trap _cleanup INT TERM

# Self-overwriting status line. Plain ASCII + hard-truncated to terminal width so
# it can NEVER wrap onto a second row (wrapping was what stranded fragments and
# made the bar look frozen). No emoji here: they render 2 cols but count as 1,
# which breaks width math.
draw_status() {
    local idx=$1 tot=$2 msg=$3
    local pct=$(( tot > 0 ? idx * 100 / tot : 0 ))
    local filled=$(( pct / 5 )); (( filled > 20 )) && filled=20
    local pad h d
    printf -v pad '%*s' $filled '';          h=${pad// /#}
    printf -v pad '%*s' $((20 - filled)) ''; d=${pad// /-}
    local tail=""
    (( conversion_fail_count > 0 )) && tail=" | ${conversion_fail_count} failed"
    # Assemble, then hard-cap to (terminal width - 1) so the cursor never wraps.
    local cols=${COLUMNS:-80}
    local line="[${h}${d}] ${pct}% [${idx}/${tot}] ${msg}${tail}"
    printf "\r\033[K%s" "${line[1,$((cols - 1))]}"
}

log_failure() {
    local src="$1" reason="$2"
    echo "$src" >> "$FAILED_FILE"
    {
        echo "===== $(date '+%Y-%m-%d %H:%M:%S')  $src ====="
        echo "$reason"
        echo ""
    } >> "$FAILED_LOG"
    (( conversion_fail_count += 1 ))
}

get_android_free_space() {
    adb shell df "$TARGET_DIR" 2>/dev/null | awk '
    {
        gsub(/\r/, "", $0)
        val = ""
        if ($4 ~ /^[0-9]+[GMK]?$/) val = $4
        else if ($3 ~ /^[0-9]+[GMK]?$/ && $1 ~ /^\//) val = $3
        else if ($(NF-2) ~ /^[0-9]+[GMK]?$/) val = $(NF-2)
        if (val != "") {
            if (val ~ /G/) { sub(/G/, "", val); print int(val * 1073741824); exit }
            if (val ~ /M/) { sub(/M/, "", val); print int(val * 1048576); exit }
            if (val ~ /K/) { sub(/K/, "", val); print int(val * 1024); exit }
            if (val ~ /[0-9]+/) { print int(val * 1024); exit }
        }
    }'
}

get_mac_free_space() {
    df -k "$SOURCE_DIR" 2>/dev/null | tail -1 | awk '{print $4 * 1024}'
}

# ==============================================================================
# DEPENDENCY & DEVICE VERIFICATION
# ==============================================================================
for cmd in adb ffmpeg ffprobe exiftool; do
    command -v "$cmd" &>/dev/null || {
        echo "❌ '$cmd' missing. Install via Homebrew and ensure it's in PATH."
        _pause_on_exit; exit 1
    }
done

device_count=$(adb devices | grep -E "device$" | wc -l | tr -d ' ')
if [[ "$device_count" -eq 0 ]]; then
    echo "❌ No Android device found. Check USB debugging."; _pause_on_exit; exit 1
elif [[ "$device_count" -gt 1 ]]; then
    echo "❌ $device_count devices attached. Connect only the Pixel XL."; _pause_on_exit; exit 1
fi

adb shell mkdir -p "$TARGET_DIR" 2>/dev/null

# ==============================================================================
# HISTORY PRUNING (drops entries whose source no longer exists -> auto reset)
# ==============================================================================
if [[ -s "$HISTORY_FILE" ]]; then
    tmp_log=$(mktemp)
    while IFS= read -r entry; do
        [[ -f "$entry" ]] && echo "$entry" >> "$tmp_log"
    done < "$HISTORY_FILE"
    mv "$tmp_log" "$HISTORY_FILE"
fi

ANDROID_FREE=$(get_android_free_space)
if [[ -z "$ANDROID_FREE" || "$ANDROID_FREE" -eq 0 ]]; then
    echo "❌ Could not query device free storage."; _pause_on_exit; exit 1
fi
SPACE_BUDGET=$(( ANDROID_FREE - BUFFER_BYTES ))
if (( SPACE_BUDGET <= 0 )); then
    echo "⚠️ Android storage low (<500MB cushion). Clear the phone and retry."; _pause_on_exit; exit 0
fi

# ==============================================================================
# SINGLE-PASS SCAN  (one glob, pure zsh expansions, no per-file subshells)
# ==============================================================================
printf "🔍 Scanning folder for media files (one quick pass)...\n"

typeset -A _known_ext _ignore_ext _history_set
for e in "${KNOWN_EXTS[@]}";  do _known_ext[$e]=1;  done
for e in "${IGNORE_EXTS[@]}"; do _ignore_ext[$e]=1; done
while IFS= read -r entry; do
    [[ -n "$entry" ]] && _history_set[$entry]=1
done < "$HISTORY_FILE"

all_files=( **/*(.N) )   # one disk walk; (.N) = regular files only, null-glob

files_to_transfer=()
unknown_files=()
skipped_count=0

for f in $all_files; do
    # Exclude our own outputs/logs and the originals archive
    [[ "$f" == mp4_h264_fast/* || "$f" == mp4_hevc_reencoded/* ]] && continue
    [[ "$EXCLUDE_ORIGINAL_DIR" == true && ( "$f" == */Original/* || "$f" == Original/* ) ]] && continue
    [[ "$f" == transfer_history.txt || "$f" == transfer_failed.txt || "$f" == transfer_failed.log ]] && continue

    ext="${f:e:l}"                       # extension, lowercased — no subshell
    [[ "${f:t}" == .* && "$ext" == "${f:t:l}" ]] && ext=""   # dotfile w/ no real ext

    [[ -n "${_ignore_ext[$ext]}" ]] && continue
    if [[ -z "${_known_ext[$ext]}" ]]; then
        unknown_files+=("$f"); continue
    fi
    if [[ -n "${_history_set[$f]}" ]]; then
        (( skipped_count += 1 )); continue
    fi
    files_to_transfer+=("$f")
done

TOTAL_TO_TRANSFER=${#files_to_transfer[@]}

printf "✅ Scan complete: %d to transfer, %d already done, %d unrecognized.\n\n" \
    "$TOTAL_TO_TRANSFER" "$skipped_count" "${#unknown_files[@]}"

if (( ${#unknown_files[@]} > 0 )); then
    echo "🚨 UNRECOGNIZED FILE TYPES (NOT transferred, NOT tracked) — review before deleting originals:"
    for uf in "${unknown_files[@]}"; do echo "   • $uf"; done
    echo "   (Add their extension to KNOWN_EXTS or IGNORE_EXTS, then rerun.)"
    echo ""
fi

if (( TOTAL_TO_TRANSFER == 0 )); then
    echo "ℹ️ Nothing to do. $skipped_count item(s) already in history."
    rm -f "$FFERR"; _pause_on_exit; exit 0
fi

# ==============================================================================
# METRICS
# ==============================================================================
START_TIME=$SECONDS
TOTAL_BYTES_SENT=0
success_count=0
fast_remux_count=0
slow_encode_count=0
pre_converted_pushed=0
pre_compliant_pushed=0
conversion_fail_count=0
typeset -A _seen_dest          # tracks flattened device names used this run (fix #2)

# ==============================================================================
# MAIN LOOP — stream files one-by-one, append to history register as we go
# ==============================================================================
current_index=0
budget_blocked=false
mac_disk_blocked=false

for f in "${files_to_transfer[@]}"; do
    (( current_index += 1 ))
    FILE_TO_PUSH="$f"

    is_video_conversion=false
    conversion_type=""
    already_converted=false
    is_pre_compliant=false

    dir_part="${f:h}"        # dirname, no subshell

    if [[ "${f:l}" == *.mov || "${f:l}" == *.mp4 ]]; then
        is_video_conversion=true
        # Embed the SOURCE extension in the convert name so clip.mov and clip.mp4
        # in the same folder don't collide (fix #5). e.g. clip_mov.mp4 / clip_mp4.mp4
        raw_name="${${f:t}:r}_${f:e:l}"
        fast_output="mp4_h264_fast/${dir_part}/${raw_name}.mp4"
        reencoded_output="mp4_hevc_reencoded/${dir_part}/${raw_name}.mp4"

        if [[ -f "$fast_output" ]]; then
            FILE_TO_PUSH="$fast_output"; already_converted=true
        elif [[ -f "$reencoded_output" ]]; then
            FILE_TO_PUSH="$reencoded_output"; already_converted=true
        else
            PRE_SIZE=$(stat -f%z "$f" 2>/dev/null)
            if (( PRE_SIZE > SPACE_BUDGET )); then budget_blocked=true; break; fi

            # Mac free-space guard: PAUSE the run (do NOT mark the file failed)
            MAC_FREE=$(get_mac_free_space)
            NEEDED=$(( PRE_SIZE * MAC_TRANSCODE_HEADROOM ))
            (( NEEDED < MAC_MIN_FREE_BYTES )) && NEEDED=$MAC_MIN_FREE_BYTES
            if [[ -z "$MAC_FREE" ]] || (( MAC_FREE < NEEDED )); then
                printf "\r\033[K🛑 Low Mac disk space — pausing before transcode. Need ~%dMB, have %dMB.\n" \
                    "$(( NEEDED / 1048576 ))" "$(( MAC_FREE / 1048576 ))"
                mac_disk_blocked=true; break
            fi

            draw_status "$current_index" "$TOTAL_TO_TRANSFER" "probing ${f:t}"

            # Explicit stream selectors avoid mebx/metadata-stream confusion
            v_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>"$FFERR")
            a_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>/dev/null)

            if [[ -z "$v_codec" ]]; then
                log_failure "$f" "ffprobe found no video stream. ffprobe stderr:\n$(cat "$FFERR")"
                draw_status "$current_index" "$TOTAL_TO_TRANSFER" "skipped (unreadable) ${f:t}"
                continue
            fi

            if [[ "$v_codec" == "h264" && ( "$a_codec" == "aac" || -z "$a_codec" ) ]]; then
                if [[ "${f:l}" == *.mp4 ]]; then
                    FILE_TO_PUSH="$f"; is_pre_compliant=true
                else
                    # FAST REMUX (lossless). Temp keeps a .mp4 extension + -f mp4 so
                    # ffmpeg can pick the muxer (the old ".tmp" name broke this).
                    # -map v:0 + a:0? + -dn drops iPhone 'mebx' timed-metadata
                    # streams that otherwise make ffmpeg abort ("no decoder for none").
                    mkdir -p "mp4_h264_fast/${dir_part}"
                    conversion_type="fast"
                    draw_status "$current_index" "$TOTAL_TO_TRANSFER" "remuxing ${f:t}"
                    TMPOUT="${fast_output:r}.partial.mp4"; CURRENT_TMPOUT="$TMPOUT"
                    if ! ffmpeg -y -i "$f" -map 0:v:0 -map 0:a:0? -dn -map_metadata 0 \
                            -c copy -movflags +faststart -f mp4 "$TMPOUT" >/dev/null 2>"$FFERR"; then
                        rm -f "$TMPOUT"; CURRENT_TMPOUT=""
                        log_failure "$f" "ffmpeg remux failed. ffmpeg stderr (last lines):\n$(tail -n 12 "$FFERR")"
                        draw_status "$current_index" "$TOTAL_TO_TRANSFER" "remux FAILED ${f:t}"
                        continue
                    fi
                    CURRENT_TMPOUT=""; mv "$TMPOUT" "$fast_output"; FILE_TO_PUSH="$fast_output"
                fi
            else
                # HQ TRANSCODE (HEVC etc. -> H.264). Same .mp4 temp + -f mp4 fix.
                # -map v:0 + a:0? + -dn drops 'mebx' metadata streams (the cause of
                # the "no decoder for none" failures). Quality flags unchanged.
                mkdir -p "mp4_hevc_reencoded/${dir_part}"
                conversion_type="slow"
                draw_status "$current_index" "$TOTAL_TO_TRANSFER" "transcoding ${f:t}"
                TMPOUT="${reencoded_output:r}.partial.mp4"; CURRENT_TMPOUT="$TMPOUT"
                if ! ffmpeg -y -i "$f" -map 0:v:0 -map 0:a:0? -dn -map_metadata 0 \
                        -c:v libx264 -crf "$ENC_CRF" -preset "$ENC_PRESET" \
                        -c:a aac -b:a "${ENC_AUDIO_KBPS}k" -movflags +faststart -f mp4 "$TMPOUT" >/dev/null 2>"$FFERR"; then
                    rm -f "$TMPOUT"; CURRENT_TMPOUT=""
                    log_failure "$f" "ffmpeg transcode failed. ffmpeg stderr (last lines):\n$(tail -n 12 "$FFERR")"
                    draw_status "$current_index" "$TOTAL_TO_TRANSFER" "transcode FAILED ${f:t}"
                    continue
                fi
                CURRENT_TMPOUT=""; mv "$TMPOUT" "$reencoded_output"; FILE_TO_PUSH="$reencoded_output"
            fi
        fi

        # Copy metadata onto the converted file (matches your original passes)
        if [[ "$is_pre_compliant" == false && ! -f "${FILE_TO_PUSH}.xtag" ]]; then
            if ! exiftool -TagsFromFile "$f" \
                -all:all \
                "-FileCreateDate<QuickTime:CreateDate" \
                "-FileModifyDate<QuickTime:CreateDate" \
                "-DateTimeOriginal<QuickTime:CreateDate" \
                "-CreateDate<QuickTime:CreateDate" \
                "-ModifyDate<QuickTime:CreateDate" \
                "-GPSLatitude<Composite:GPSLatitude" \
                "-GPSLongitude<Composite:GPSLongitude" \
                "-GPSAltitude<Composite:GPSAltitude" \
                "-Make<Make" \
                "-Model<Model" \
                -overwrite_original "$FILE_TO_PUSH" >/dev/null 2>&1; then
                : # non-fatal; push with whatever metadata ffmpeg preserved
            else
                touch "${FILE_TO_PUSH}.xtag"
            fi
        fi
    fi

    FILE_SIZE=$(stat -f%z "$FILE_TO_PUSH" 2>/dev/null)
    FILE_MB=$(( FILE_SIZE / 1048576 ))

    if (( FILE_SIZE > SPACE_BUDGET )); then
        budget_blocked=true
        if [[ "$is_video_conversion" == true && "$conversion_type" == "slow" ]]; then
            printf "\r\033[K⚠️  Converted output is %dMB — larger than remaining phone budget. Free space and rerun.\n" "$FILE_MB"
        fi
        break
    fi

    # Path-preserving destination name (avoids filename collisions)
    if [[ "$dir_part" == "." ]]; then
        push_basename="${FILE_TO_PUSH:t}"
    else
        safe_prefix="${dir_part//\//_}"; safe_prefix="${safe_prefix// /_}"
        push_basename="${safe_prefix}_${FILE_TO_PUSH:t}"
    fi

    # Dedupe flattened names within this run (fix #2): if two different source
    # paths flatten to the same device name, append _2, _3, ... to later ones.
    if [[ -n "${_seen_dest[$push_basename]}" ]]; then
        name_root="${push_basename:r}"; name_ext="${push_basename:e}"
        n=2
        while [[ -n "${_seen_dest[${name_root}_${n}.${name_ext}]}" ]]; do (( n += 1 )); done
        push_basename="${name_root}_${n}.${name_ext}"
    fi
    _seen_dest[$push_basename]=1
    PUSH_DEST="${TARGET_DIR}${push_basename}"

    draw_status "$current_index" "$TOTAL_TO_TRANSFER" "pushing ${f:t} (${FILE_MB}MB)"

    # Single clean push. (The earlier per-file adb live-% line was removed: its
    # cursor-up cleanup could strand stray lines, and the real bottleneck here is
    # transcode CPU, not the USB push.)
    ADB_ERR=$(adb push "$FILE_TO_PUSH" "$PUSH_DEST" 2>&1 >/dev/null)
    ADB_STATUS=$?

    if [ $ADB_STATUS -eq 0 ]; then
        echo "$f" >> "$HISTORY_FILE"          # the register: noted immediately on success
        SPACE_BUDGET=$(( SPACE_BUDGET - FILE_SIZE ))
        TOTAL_BYTES_SENT=$(( TOTAL_BYTES_SENT + FILE_SIZE ))
        (( success_count += 1 ))
        if [[ "$is_video_conversion" == true ]]; then
            if   [[ "$already_converted" == true ]]; then (( pre_converted_pushed += 1 ))
            elif [[ "$is_pre_compliant"  == true ]]; then (( pre_compliant_pushed += 1 ))
            elif [[ "$conversion_type"   == "fast" ]]; then (( fast_remux_count += 1 ))
            elif [[ "$conversion_type"   == "slow" ]]; then (( slow_encode_count += 1 ))
            fi
        fi
    else
        printf "\r\033[K"
        echo "========================================================="
        echo "🛑 CRITICAL TRANSFER ERROR"
        echo "📁 Item     : $f"
        echo "📋 ADB says : ${ADB_ERR:-Unknown USB disconnect}"
        echo "========================================================="
        rm -f "$FFERR"; _pause_on_exit; exit 1
    fi
done

printf "\r\033[K"
rm -f "$FFERR"

# ==============================================================================
# 🏁 SUMMARY
#   (No media-scan loop: it fired thousands of slow adb broadcasts that are
#    no-ops on Android 10. Google Photos / MediaScanner index DCIM/Camera on
#    their own; just open Google Photos if anything is slow to appear.)
# ==============================================================================
FILES_LEFT=$(( TOTAL_TO_TRANSFER - success_count - conversion_fail_count ))
ELAPSED_TIME=$(( SECONDS - START_TIME ))
TOTAL_MB_SENT=$(( TOTAL_BYTES_SENT / 1048576 ))

echo "========================================================="
echo "📊 PIPELINE EXECUTION SUMMARY"
echo "========================================================="
echo "✅ Files Pushed This Run       : $success_count"
echo "⏭️ Already in History          : $skipped_count"
(( ${#unknown_files[@]} > 0 )) && echo "🚨 Unrecognized (NOT sent)     : ${#unknown_files[@]}  (listed above)"
(( conversion_fail_count > 0 )) && echo "⚠️ Failed This Run (will retry): $conversion_fail_count  (reasons in transfer_failed.log)"

if [ "$mac_disk_blocked" = true ]; then
    echo "🛑 Remaining for Next Run     : $FILES_LEFT file(s) (Paused: Mac disk low)"
elif [ "$budget_blocked" = true ]; then
    echo "🛑 Remaining for Next Run     : $FILES_LEFT file(s) (Paused: Phone storage full)"
else
    echo "⏳ Remaining for Next Run     : $FILES_LEFT file(s) (All caught up!)"
fi

echo "--------------------------------------------------------"
echo "🎬 Video Conversion Breakdown This Run:"
echo "   ⚡ Fast Remuxed (H.264/AAC) : $fast_remux_count"
echo "   ⚙️ Transcoded (HEVC→H.264)  : $slow_encode_count"
echo "   🔄 Pre-Converted Assets     : $pre_converted_pushed"
echo "   🍏 Pre-Compliant iPhone MP4 : $pre_compliant_pushed"
(( conversion_fail_count > 0 )) && echo "   ⚠️ Failed (logged for retry): $conversion_fail_count"

echo "--------------------------------------------------------"
echo "📦 Total Data Moved            : $TOTAL_MB_SENT MB"
echo "⏱️ Total Time Elapsed          : $(( ELAPSED_TIME / 60 ))m $(( ELAPSED_TIME % 60 ))s"
(( success_count > 0 && ELAPSED_TIME > 0 )) && echo "⚡ Average Pipeline Speed      : ~$(( TOTAL_MB_SENT / ELAPSED_TIME )) MB/s"
echo "========================================================="

if [ "$mac_disk_blocked" = true ]; then
    echo "👉 Free space on your Mac (convert folders ~2× during transcode), then rerun."
elif [ "$budget_blocked" = true ]; then
    echo "👉 Phone at safe limit. Run Google Photos 'Free up space', then rerun!"
fi

_pause_on_exit
