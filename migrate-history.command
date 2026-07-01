#!/bin/zsh

# ==============================================================================
# Migrate history (ONE-TIME) — converts transfer_history.txt from the OLD format
# (plain "path" per line) to the NEW format ("path|size" per line).
# ------------------------------------------------------------------------------
# Run this ONCE per folder (e.g. "Phone A", "Phone B") BEFORE the next
# run of the main transfer script. After migrating, delete this file — it is not
# needed again.
#
# HOW TO USE:
#   1. Save with the .command extension.
#   2. chmod +x "Migrate history (one-time).command"   (once)
#   3. Double-click in Finder -> pick the SAME folder you transfer from.
#
# WHAT IT DOES (and does NOT do):
#   • Reads transfer_history.txt, and for each SOURCE file path recorded there,
#     appends its current byte size -> "path|size".
#   • The size is taken from the SOURCE file (the original iPhone file). The
#     transcoded copies under mp4_h264_fast/ and mp4_hevc_reencoded/ are NOT in
#     history and are never touched — so the "two copies exist" situation causes
#     no ambiguity: we only ever stat the original that history points to.
#   • Lines whose source file no longer exists are DROPPED (reported below), same
#     as the main script's pruning would do — you said nothing is deleted yet, so
#     this should be zero.
#   • Idempotent: a line that is already "path|size" is left as-is, so running
#     this twice is harmless.
#   • Makes a backup at transfer_history.txt.bak before writing anything.
# ==============================================================================

# ---- resolve source folder (same logic as the main script) -------------------
SCRIPT_DIR="${0:A:h}"
if [[ -n "$1" ]]; then
    SOURCE_DIR="$1"
else
    SOURCE_DIR=$(osascript <<EOF 2>/dev/null
try
    set defaultPath to POSIX file "$SCRIPT_DIR" as alias
    set chosenFolder to choose folder with prompt "Select the SAME folder whose history you want to migrate:" default location defaultPath
    return POSIX path of chosenFolder
on error
    return ""
end try
EOF
)
    if [[ -z "$SOURCE_DIR" ]]; then
        echo "Folder selection cancelled. Nothing migrated."
        exit 0
    fi
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "❌ Error: '$SOURCE_DIR' is not a directory."
    echo "Press Return to close this window..."; read
    exit 1
fi
SOURCE_DIR="${SOURCE_DIR:A}"

setopt NULL_GLOB
setopt NOCASEGLOB

zmodload -F zsh/stat b:zstat 2>/dev/null || {
    echo "❌ zsh/stat module unavailable — cannot read file sizes. Aborting."
    echo "Press Return to close this window..."; read
    exit 1
}

HISTORY_FILE="$SOURCE_DIR/transfer_history.txt"

cd "$SOURCE_DIR" || { echo "❌ Cannot access: $SOURCE_DIR"; echo "Press Return..."; read; exit 1; }

echo "========================================================="
echo "🔧 History migration (old 'path' -> new 'path|size')"
echo "📂 Folder: $SOURCE_DIR"
echo "========================================================="

if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "ℹ️ No transfer_history.txt here — nothing to migrate."
    echo "Press Return to close this window..."; read
    exit 0
fi
if [[ ! -s "$HISTORY_FILE" ]]; then
    echo "ℹ️ transfer_history.txt is empty — nothing to migrate."
    echo "Press Return to close this window..."; read
    exit 0
fi

# ---- backup ------------------------------------------------------------------
cp "$HISTORY_FILE" "${HISTORY_FILE}.bak"
echo "🗄️  Backup written: ${HISTORY_FILE}.bak"
echo ""

# ---- migrate -----------------------------------------------------------------
tmp_out=$(mktemp)
migrated=0
already=0
dropped=0
dropped_list=()

typeset -A _st
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue

    # Already new format? keep verbatim (idempotent).
    if [[ "$entry" == *"|"* ]]; then
        print -r -- "$entry" >> "$tmp_out"
        (( already += 1 ))
        continue
    fi

    # Old format: entry is a source path relative to this folder.
    if [[ -f "$entry" ]]; then
        if zstat -H _st -- "$entry" 2>/dev/null; then
            print -r -- "${entry}|${_st[size]}" >> "$tmp_out"
            (( migrated += 1 ))
        else
            # exists but unreadable metadata — keep path with size 0 so it is
            # neither silently lost nor falsely matched (main script will
            # re-verify and re-transfer if needed).
            print -r -- "${entry}|0" >> "$tmp_out"
            (( migrated += 1 ))
        fi
    else
        # Source file gone -> drop (matches the main script's prune behavior).
        (( dropped += 1 ))
        dropped_list+=("$entry")
    fi
done < "$HISTORY_FILE"

mv "$tmp_out" "$HISTORY_FILE"

# ---- report ------------------------------------------------------------------
echo "✅ Migration complete."
echo "   • Converted to path|size : $migrated"
echo "   • Already new format      : $already"
echo "   • Dropped (source missing): $dropped"

if (( dropped > 0 )); then
    echo ""
    echo "🚨 These history entries had NO matching source file and were removed"
    echo "   (they will re-transfer next run if the files reappear):"
    for d in "${dropped_list[@]}"; do echo "   • $d"; done
fi

echo ""
echo "👉 New history saved. Original preserved at transfer_history.txt.bak"
echo "   You can now delete this migration script and run the main transfer script."
echo ""
echo "Press Return to close this window..."; read
