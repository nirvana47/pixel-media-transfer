#!/bin/zsh

# ==============================================================================
# Transfer to Pixel XL — double-clickable macOS launcher (.command)
# ------------------------------------------------------------------------------
# HOW TO USE:
#   1. Save this file with the .command extension (already done).
#   2. Make it executable ONCE:  chmod +x "Transfer to Pixel XL.command"
#   3. Double-click it in Finder -> it opens Terminal and runs.
#
# Folder selection order:
#   1) a path passed as an argument (command line)               ./...command /path
#   2) a graphical folder picker (double-click in Finder)        AppleScript dialog
#   3) the folder this .command file lives in (picker cancelled) fallback
# ==============================================================================

# ==============================================================================
# RESOLVE SOURCE FOLDER
# ==============================================================================
# Directory this .command file itself lives in (zsh: ${0:A:h} = abs dir of script)
SCRIPT_DIR="${0:A:h}"

if [[ -n "$1" ]]; then
    # Command-line argument wins if provided
    SOURCE_DIR="$1"
else
    # Double-clicked from Finder -> pop a native folder picker via AppleScript.
    # Default the dialog to the folder the script lives in.
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
    # If the user cancelled the dialog, fall back to the script's own folder
    [[ -z "$SOURCE_DIR" ]] && SOURCE_DIR="$SCRIPT_DIR"
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "❌ Error: '$SOURCE_DIR' is not a directory."
    echo "Press Return to close this window..."; read
    exit 1
fi
SOURCE_DIR="${SOURCE_DIR:A}"   # normalize to a clean absolute path

# ==============================================================================
# CONFIGURATION
# ==============================================================================
HISTORY_FILE="$SOURCE_DIR/transfer_history.txt"
FAILED_FILE="$SOURCE_DIR/transfer_failed.txt"   # review list — NOT a permanent skip
TARGET_DIR="/sdcard/DCIM/Camera/"
BUFFER_BYTES=524288000                          # 500MB safety margin on the PHONE
MAC_MIN_FREE_BYTES=2147483648                   # never transcode if Mac has <2GB free
MAC_TRANSCODE_HEADROOM=3                         # require Mac free >= input_size * this

# Recognized media we will transfer. Anything not here triggers the guard below.
KNOWN_EXTS=(mp4 mov m4v jpg jpeg png heic heif gif tiff tif dng webp 3gp)
# Non-media / sidecars we knowingly ignore (won't be flagged by the guard).
IGNORE_EXTS=(aae dat txt xtag ds_store)

# Common Homebrew locations — double-clicked Finder sessions often have a minimal
# PATH that misses /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Zsh globbing behavior
setopt NULL_GLOB    # unexpanded wildcards vanish instead of erroring
setopt NOCASEGLOB   # match .MOV and .mov alike

cd "$SOURCE_DIR" || { echo "❌ Error: Cannot access source directory: $SOURCE_DIR"; echo "Press Return to close..."; read; exit 1; }

echo "========================================================="
echo "📂 Source folder: $SOURCE_DIR"
echo "========================================================="

touch "$HISTORY_FILE"
: > "$FAILED_FILE"   # truncate: failures are re-attempted each run; this logs THIS run

# ==============================================================================
# EXIT HANDLER — keep the Terminal window open so you can read the summary
# ==============================================================================
_pause_on_exit() {
    echo ""
    echo "Press Return to close this window..."
    read
}

# ==============================================================================
# SIGINT/SIGTERM TRAP CLEANUP
# ==============================================================================
CURRENT_TMPOUT=""
_cleanup() {
    if [[ -n "$CURRENT_TMPOUT" && -f "$CURRENT_TMPOUT" ]]; then
        rm -f "$CURRENT_TMPOUT"
        printf "\r\033[K\n🧹 Cleaned up incomplete temp file: %s\n" "$CURRENT_TMPOUT"
    fi
    printf "\r\033[K⛔ Script execution interrupted by user.\n"
    _pause_on_exit
    exit 130
}
trap _cleanup INT TERM

# ==============================================================================
# DEPENDENCY & DEVICE VERIFICATION
# ==============================================================================
for cmd in adb ffmpeg ffprobe exiftool; do
    command -v "$cmd" &>/dev/null || {
        echo "❌ Error: '$cmd' dependency missing. Install it (e.g. via Homebrew) and ensure it's in PATH."
        _pause_on_exit
        exit 1
    }
done

# Exactly-one-device guard (so adb push is never ambiguous)
device_count=$(adb devices | grep -E "device$" | wc -l | tr -d ' ')
if [[ "$device_count" -eq 0 ]]; then
    echo "❌ Error: No Android device found. Check USB debugging connection."
    _pause_on_exit
    exit 1
elif [[ "$device_count" -gt 1 ]]; then
    echo "❌ Error: $device_count devices attached. Connect only the Pixel XL (or set ANDROID_SERIAL)."
    _pause_on_exit
    exit 1
fi

adb shell mkdir -p "$TARGET_DIR" 2>/dev/null

# ==============================================================================
# HISTORY PRUNING (drops entries whose source file no longer exists -> auto reset)
# ==============================================================================
if [[ -f "$HISTORY_FILE" ]]; then
    tmp_log=$(mktemp)
    while IFS= read -r entry; do
        [[ -f "$entry" ]] && echo "$entry" >> "$tmp_log"
    done < "$HISTORY_FILE"
    mv "$tmp_log" "$HISTORY_FILE"
fi

# ==============================================================================
# FREE-SPACE HELPERS
# ==============================================================================
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
            if (val ~ /[0-9]+/) { print int(val * 1024); exit }   # assume 1K blocks
        }
    }'
}

get_mac_free_space() {
    df -k "$SOURCE_DIR" 2>/dev/null | tail -1 | awk '{print $4 * 1024}'
}

ANDROID_FREE=$(get_android_free_space)
if [[ -z "$ANDROID_FREE" || "$ANDROID_FREE" -eq 0 ]]; then
    echo "❌ Error: Could not query device free storage."
    _pause_on_exit
    exit 1
fi

SPACE_BUDGET=$(( ANDROID_FREE - BUFFER_BYTES ))
if (( SPACE_BUDGET <= 0 )); then
    echo "⚠️ Android storage low! Less than 500MB cushion remains. Clear phone assets and retry."
    _pause_on_exit
    exit 0
fi

# ==============================================================================
# UNKNOWN-EXTENSION GUARD  (prevents silent data loss before you delete originals)
# ==============================================================================
typeset -A _known_ext _ignore_ext
for e in "${KNOWN_EXTS[@]}";  do _known_ext[$e]=1;  done
for e in "${IGNORE_EXTS[@]}"; do _ignore_ext[$e]=1; done

unknown_files=()
for f in **/*(.N); do                                   # (.N) = regular files, null-glob
    [[ "$f" == mp4_h264_fast/* || "$f" == mp4_hevc_reencoded/* ]] && continue
    [[ "$f" == */Original/* || "$f" == Original/* ]] && continue
    [[ "$f" == "$(basename "$HISTORY_FILE")" || "$f" == "$(basename "$FAILED_FILE")" ]] && continue

    base="$(basename "$f")"
    ext="${base##*.}"
    ext="${ext:l}"
    [[ "$base" == "$ext" ]] && ext=""   # no dot at all -> no extension

    [[ -n "${_known_ext[$ext]}"  ]] && continue
    [[ -n "${_ignore_ext[$ext]}" ]] && continue
    unknown_files+=("$f")
done

if (( ${#unknown_files[@]} > 0 )); then
    echo "========================================================="
    echo "🚨 UNRECOGNIZED FILE TYPES DETECTED"
    echo "========================================================="
    echo "These files are NOT being transferred and are NOT tracked."
    echo "Review them BEFORE you delete any originals:"
    for uf in "${unknown_files[@]}"; do echo "   • $uf"; done
    echo "---------------------------------------------------------"
    echo "Add their extension to KNOWN_EXTS (to transfer) or IGNORE_EXTS"
    echo "(to silence), then rerun. Continuing with known files only..."
    echo "========================================================="
fi

# ==============================================================================
# QUEUE BUILDER
# ==============================================================================
typeset -A _history_set
while IFS= read -r entry; do
    [[ -n "$entry" ]] && _history_set[$entry]=1
done < "$HISTORY_FILE"

files=( **/*.mp4 **/*.mov **/*.m4v **/*.3gp \
        **/*.jpg **/*.jpeg **/*.png **/*.heic **/*.heif \
        **/*.gif **/*.tiff **/*.tif **/*.dng **/*.webp )

files_to_transfer=()
skipped_count=0

for f in "${files[@]}"; do
    [[ "$f" == mp4_h264_fast/* || "$f" == mp4_hevc_reencoded/* ]] && continue
    [[ "$f" == */Original/* || "$f" == Original/* ]] && continue

    if [[ -n "${_history_set[$f]}" ]]; then
        (( skipped_count += 1 ))
    else
        files_to_transfer+=("$f")
    fi
done

TOTAL_TO_TRANSFER=${#files_to_transfer[@]}
if (( TOTAL_TO_TRANSFER == 0 )); then
    echo "ℹ️ Synchronization complete! $skipped_count item(s) already in history."
    _pause_on_exit
    exit 0
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
pushed_dests=()

# ==============================================================================
# MAIN LOOP
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

    dir_part=$(dirname "$f")

    if [[ "${f:l}" == *.mov || "${f:l}" == *.mp4 ]]; then
        is_video_conversion=true
        filename=$(basename "$f")
        raw_name="${filename%.*}"
        fast_output="mp4_h264_fast/${dir_part}/${raw_name}.mp4"
        reencoded_output="mp4_hevc_reencoded/${dir_part}/${raw_name}.mp4"

        if [[ -f "$fast_output" ]]; then
            FILE_TO_PUSH="$fast_output"; already_converted=true
        elif [[ -f "$reencoded_output" ]]; then
            FILE_TO_PUSH="$reencoded_output"; already_converted=true
        else
            PRE_SIZE=$(stat -f%z "$f" 2>/dev/null)
            if (( PRE_SIZE > SPACE_BUDGET )); then
                budget_blocked=true; break
            fi

            # --- Mac free-space guard: abort run (don't poison the failed list) ---
            MAC_FREE=$(get_mac_free_space)
            NEEDED=$(( PRE_SIZE * MAC_TRANSCODE_HEADROOM ))
            (( NEEDED < MAC_MIN_FREE_BYTES )) && NEEDED=$MAC_MIN_FREE_BYTES
            if [[ -z "$MAC_FREE" ]] || (( MAC_FREE < NEEDED )); then
                printf "\r\033[K"
                echo "🛑 Low disk space on the Mac — pausing before transcode."
                printf "   Need ~%d MB free, have %d MB. Free up space and rerun.\n" \
                    "$(( NEEDED / 1048576 ))" "$(( MAC_FREE / 1048576 ))"
                mac_disk_blocked=true
                break
            fi

            printf "\r\033[K🔍 [%d/%d] Analyzing codecs: %s..." "$current_index" "$TOTAL_TO_TRANSFER" "$f"

            v_codec=$(ffprobe -v error -select_streams v:0 \
                        -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>/dev/null)
            a_codec=$(ffprobe -v error -select_streams a:0 \
                        -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>/dev/null)

            if [[ -z "$v_codec" ]]; then
                echo "$f" >> "$FAILED_FILE"
                printf "\r\033[K⚠️  ffprobe could not read video stream: %s. Logged for review (will retry next run).\n" "$f"
                (( conversion_fail_count += 1 )); continue
            fi

            if [[ "$v_codec" == "h264" && ( "$a_codec" == "aac" || -z "$a_codec" ) ]]; then
                if [[ "${f:l}" == *.mp4 ]]; then
                    FILE_TO_PUSH="$f"; is_pre_compliant=true
                else
                    mkdir -p "mp4_h264_fast/${dir_part}"
                    conversion_type="fast"
                    printf "\r\033[K⚡ [%d/%d] Remuxing: %s..." "$current_index" "$TOTAL_TO_TRANSFER" "$f"
                    TMPOUT="${fast_output}.tmp"; CURRENT_TMPOUT="$TMPOUT"
                    if ! ffmpeg -y -i "$f" -c copy -movflags +faststart "$TMPOUT" >/dev/null 2>&1; then
                        rm -f "$TMPOUT"; CURRENT_TMPOUT=""
                        echo "$f" >> "$FAILED_FILE"
                        printf "\r\033[K⚠️  Remux failed: %s. Logged for review (will retry next run).\n" "$f"
                        (( conversion_fail_count += 1 )); continue
                    fi
                    CURRENT_TMPOUT=""; mv "$TMPOUT" "$fast_output"; FILE_TO_PUSH="$fast_output"
                fi
            else
                mkdir -p "mp4_hevc_reencoded/${dir_part}"
                conversion_type="slow"
                printf "\r\033[K⚙️ [%d/%d] Transcoding: %s (please wait)..." "$current_index" "$TOTAL_TO_TRANSFER" "$f"
                TMPOUT="${reencoded_output}.tmp"; CURRENT_TMPOUT="$TMPOUT"
                if ! ffmpeg -y -i "$f" -c:v libx264 -crf 20 -preset medium \
                        -c:a aac -b:a 160k -movflags +faststart "$TMPOUT" >/dev/null 2>&1; then
                    rm -f "$TMPOUT"; CURRENT_TMPOUT=""
                    echo "$f" >> "$FAILED_FILE"
                    printf "\r\033[K⚠️  Transcode failed: %s. Logged for review (will retry next run).\n" "$f"
                    (( conversion_fail_count += 1 )); continue
                fi
                CURRENT_TMPOUT=""; mv "$TMPOUT" "$reencoded_output"; FILE_TO_PUSH="$reencoded_output"
            fi
        fi

        # Sidecar .xtag prevents re-tagging on subsequent runs
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
                -overwrite_original "$FILE_TO_PUSH" >/dev/null 2>&1; then
                printf "\r\033[K⚠️  ExifTool metadata copy failed: %s → %s. Pushing as-is.\n" "$f" "$FILE_TO_PUSH"
            else
                touch "${FILE_TO_PUSH}.xtag"
            fi
        fi
    fi

    FILE_SIZE=$(stat -f%z "$FILE_TO_PUSH" 2>/dev/null)
    FILE_MB=$(( FILE_SIZE / 1048576 ))

    if (( FILE_SIZE > SPACE_BUDGET )); then
        budget_blocked=true
        if [[ "$is_video_conversion" == true && \
              ( "$FILE_TO_PUSH" == mp4_hevc_reencoded/* || \
                ( "$already_converted" == false && "$conversion_type" == "slow" ) ) ]]; then
            printf "\r\033[K⚠️  Output is %d MB — larger than remaining phone budget.\n" "$FILE_MB"
            printf "   Free at least %d MB on the phone, then rerun.\n" "$FILE_MB"
        fi
        break
    fi

    # Path-preserving destination name to avoid Sid/Shivani collisions
    if [[ "$dir_part" == "." ]]; then
        push_basename="$(basename "$FILE_TO_PUSH")"
    else
        safe_prefix="${dir_part//\//_}"
        safe_prefix="${safe_prefix// /_}"
        push_basename="${safe_prefix}_$(basename "$FILE_TO_PUSH")"
    fi
    PUSH_DEST="${TARGET_DIR}${push_basename}"

    printf "\r\033[K📤 [%d/%d] Copying: %s (%d MB)..." "$current_index" "$TOTAL_TO_TRANSFER" "$f" "$FILE_MB"

    ADB_ERR=$(adb push "$FILE_TO_PUSH" "$PUSH_DEST" 2>&1 >/dev/null)
    ADB_STATUS=$?

    if [ $ADB_STATUS -eq 0 ]; then
        echo "$f" >> "$HISTORY_FILE"
        SPACE_BUDGET=$(( SPACE_BUDGET - FILE_SIZE ))
        TOTAL_BYTES_SENT=$(( TOTAL_BYTES_SENT + FILE_SIZE ))
        (( success_count += 1 ))
        pushed_dests+=("$PUSH_DEST")
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
        echo "========================================================="
        echo "📁 Target Item : $f"
        echo "📋 ADB Message : ${ADB_ERR:-Unknown USB interface disconnect}"
        echo "========================================================="
        _pause_on_exit
        exit 1
    fi
done

printf "\r\033[K"

# ==============================================================================
# MEDIA SCAN (best-effort; Google Photos also scans DCIM/Camera on its own)
# ==============================================================================
if (( ${#pushed_dests[@]} > 0 )); then
    printf "📡 Requesting media scan for %d file(s) (best-effort on Android 10)...\n" "${#pushed_dests[@]}"
    for dest in "${pushed_dests[@]}"; do
        adb shell am broadcast \
            -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://${dest}" >/dev/null 2>&1
    done
    printf "✅ Media scan requested (Google Photos will also auto-index DCIM/Camera).\n"
fi

# ==============================================================================
# 🏁 SUMMARY
# ==============================================================================
FILES_LEFT=$(( TOTAL_TO_TRANSFER - success_count - conversion_fail_count ))
ELAPSED_TIME=$(( SECONDS - START_TIME ))
MINUTES=$(( ELAPSED_TIME / 60 ))
SECONDS_REM=$(( ELAPSED_TIME % 60 ))
TOTAL_MB_SENT=$(( TOTAL_BYTES_SENT / 1048576 ))

echo "========================================================="
echo "📊 PIPELINE EXECUTION SUMMARY"
echo "========================================================="
echo "✅ Files Pushed This Run       : $success_count"
echo "⏭️ Already in History          : $skipped_count"
(( ${#unknown_files[@]} > 0 )) && echo "🚨 Unrecognized (NOT sent)     : ${#unknown_files[@]}  (see list above)"
(( conversion_fail_count > 0 )) && echo "⚠️ Failed This Run (will retry): $conversion_fail_count  (see transfer_failed.txt)"

if [ "$mac_disk_blocked" = true ]; then
    echo "🛑 Remaining for Next Run     : $FILES_LEFT file(s) (Paused: Mac disk low)"
elif [ "$budget_blocked" = true ]; then
    echo "🛑 Remaining for Next Run     : $FILES_LEFT file(s) (Paused: Phone storage full)"
elif (( conversion_fail_count > 0 && FILES_LEFT == 0 )); then
    echo "✅ Remaining for Next Run     : 0 file(s) ($conversion_fail_count to review/retry)"
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
echo "⏱️ Total Time Elapsed          : ${MINUTES}m ${SECONDS_REM}s"
if (( success_count > 0 && ELAPSED_TIME > 0 )); then
    echo "⚡ Average Pipeline Speed      : ~$(( TOTAL_MB_SENT / ELAPSED_TIME )) MB/s"
fi
echo "========================================================="

if [ "$mac_disk_blocked" = true ]; then
    echo "👉 Free up space on your Mac (originals + the convert folders eat ~2× during transcode), then rerun."
elif [ "$budget_blocked" = true ]; then
    echo "👉 Phone is at its safe limit. Run Google Photos 'Free up space' on the phone, then rerun!"
fi

_pause_on_exit
