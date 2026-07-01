# Metadata Repair PRD

## Why This Matters

The transfer script copies photos and videos from my Mac to a Pixel/Android phone
with `adb`. After that, Google Photos indexes the copied files from the phone.

The current script is already doing the important basics: it avoids copying the
same file again, it handles videos that need to be remuxed or converted, and it
tries to leave the original files alone. The weak spot is still date metadata.

Some older files can end up showing in Google Photos with the day I transferred
them, not the day they were actually taken. That makes the whole workflow less
useful. I am doing this so the media stays searchable and browsable by the
original capture date, not so a whole batch appears as if it happened today.

GPS is useful too, but I do not want the script to guess locations. If GPS is
missing, it is missing. Dates are a little different because the Mac may still
have a credible file creation or modification date that is better than the
Android transfer date.

## The Current Gap

Right now, the script only runs `exiftool` during video conversion or remuxing.
Photos and already-compatible videos are pushed directly.

That means a few risky cases can slip through:

1. A photo with missing or blank embedded dates gets copied as-is.
2. An already-compatible `.mp4` gets copied as-is.
3. Google Photos may fall back to the file date if it cannot find a good embedded
   capture date.
4. Since `adb push` creates or updates the file on the phone, that fallback date
   can become the transfer date.

The script does try to preserve metadata when it creates a converted video, but
it does not yet have a general "is this file safe to push?" check.

## What I Want

The script should catch this before `adb push`, not warn me after the file is
already on the phone. Once Google Photos indexes a bad date, the damage is
annoying to undo.

The intended flow is:

1. Look at the actual file that will be pushed.
2. Push it normally if it already has a usable embedded capture date.
3. If the embedded date is blank, zero, or missing, try to repair a generated
   copy using credible filesystem dates from the original source file.
4. Push the repaired copy instead of the original.
5. Skip and log the file if there is no credible date to use.
6. Preserve GPS when it already exists, but never invent GPS.

The original source files should stay untouched. Any metadata repair should
happen on a generated copy, or on a generated converted/remuxed video file that
the script already created.

## What This Is Not

This should stay a small practical improvement, not turn into a full photo
library manager.

This plan does not include:

1. Full content hashing for every file.
2. Heavy deduplication logic.
3. Guessing GPS locations.
4. Editing original iPhone exports in place.
5. Interactive prompts during a large transfer.
6. Maintaining a full metadata database.

The goal is narrower: avoid pushing files that are likely to show up in Google
Photos with today's date when the Mac has a better date available.

## Repair Rules

The first rule is to trust embedded metadata when it is usable. The script should
only repair dates when the embedded date fields are missing or suspicious.

The fallback order should be:

1. Existing embedded capture date.
2. macOS `FileCreateDate`.
3. macOS `FileModifyDate`.
4. Optional filename or folder parsing, but only for very obvious patterns.

The script should not use the current date as a fallback unless the file really
does appear to have been created today.

For GPS, the rules are simpler:

1. Copy existing GPS metadata when it exists.
2. Log missing GPS only if that is useful for troubleshooting.
3. Do not block a transfer just because GPS is missing.
4. Do not generate fake GPS.

## Files That Need Special Handling

### Converted or Remuxed Videos

These are already generated files, so they are safe to modify before pushing.

Examples:

```text
mp4_h264_fast/...
mp4_hevc_reencoded/...
```

For these files, the script can write repaired metadata directly to the generated
`.mp4` before it pushes the file.

### Direct-Transfer Photos and Videos

These are riskier because the current script pushes the original file. If one of
these files needs date repair, the script should copy it into a generated repair
folder first.

Example:

```text
metadata_repaired/...
```

The repaired copy should keep the relative source path so files with the same
name do not collide.

Example:

```text
Source:
Trips/Day 1/IMG_0001.HEIC

Repair copy:
metadata_repaired/Trips/Day 1/IMG_0001.HEIC
```

The script would push the repaired copy, but still record transfer history
against the original source file.

## Metadata Fields

These fields may need to be tested with a few real files, especially because
Google Photos may prefer different tags for HEIC and MP4 files. For a first pass,
I want to keep the field list simple and explicit.

For photos, write repaired dates to:

```text
EXIF:DateTimeOriginal
EXIF:CreateDate
EXIF:ModifyDate
XMP:CreateDate
XMP:ModifyDate
```

For videos, write repaired dates to:

```text
QuickTime:CreateDate
QuickTime:ModifyDate
QuickTime:TrackCreateDate
QuickTime:TrackModifyDate
QuickTime:MediaCreateDate
QuickTime:MediaModifyDate
Keys:CreationDate
```

For location, preserve existing values where possible:

```text
GPSLatitude
GPSLongitude
GPSAltitude
Keys:GPSCoordinates
```

Missing GPS should not be treated as a failure.

## Implementation Plan

### 1. Add a metadata check

Add a function that inspects a file and returns one of these states:

```text
date_ok
date_repair_needed
date_unrepairable
```

The check should look for embedded capture dates first. Blank values, zero dates,
`0000:00:00`, `1970`, and obvious transfer-date values should be treated as
suspicious.

### 2. Add a fallback date check

Add a function that reads fallback dates from the original source file.

Start with:

```text
FileCreateDate
FileModifyDate
```

The function should choose the best usable date and return nothing if neither
date looks credible.

### 3. Create repaired copies for direct-transfer files

For photos and already-compatible videos that need repair:

1. Create `metadata_repaired/<relative source path>`.
2. Copy the source file there.
3. Write repaired embedded date metadata to the copy.
4. Set `FILE_TO_PUSH` to the repaired copy.

The original source file stays untouched.

### 4. Repair generated videos in place

For remuxed or transcoded videos:

1. Convert or remux the video as the script already does.
2. Check the generated output metadata.
3. If needed, write date metadata to the generated output using fallback dates
   from the original source.
4. Push the generated output only after the repair check passes.

### 5. Re-check before pushing

After any repair attempt, run the metadata check again on `FILE_TO_PUSH`.

Only push if the date is now usable. If it is still not usable, skip the file and
write the reason to the log.

### 6. Add a metadata repair log

Create a simple log file in the source folder:

```text
metadata_repair.log
```

Each entry should include:

1. Source path.
2. File pushed, if different from the source.
3. Date chosen.
4. Date source, such as `FileCreateDate` or `FileModifyDate`.
5. Whether GPS existed.
6. Final action: pushed, repaired, or skipped.

### 7. Keep transfer history simple

Transfer history should still be keyed to the original source file, not the
repair copy.

That keeps the flow understandable:

```text
original source -> maybe repair copy -> push -> record original source in history
```

## Default Behavior

For the first implementation, the defaults should be:

1. Repair missing or blank dates automatically.
2. Leave files alone when they already have valid embedded dates.
3. Never modify originals.
4. Do not block on missing GPS.
5. Skip files with no usable embedded date and no credible filesystem fallback.
6. Log all repairs and skips.

## Questions To Test With Real Files

I should answer these with a small sample before trusting this on a large batch:

1. Which date tags does Google Photos trust most for repaired HEIC files?
2. Which date tags does Google Photos trust most for repaired MP4 files?
3. Does `Keys:CreationDate` need timezone formatting to avoid date shifts?
4. Are there source files where `FileCreateDate` is clearly less trustworthy
   than `FileModifyDate`?
5. Should repaired direct-transfer files be kept after a successful push, or
   deleted to save disk space?

## Test Plan

Use a small test folder before running this on the full archive.

The sample should include:

1. A photo with a valid EXIF date.
2. A photo with a missing EXIF date but a good filesystem creation date.
3. A video that gets remuxed.
4. A video that gets transcoded.
5. A file with GPS metadata.
6. A file without GPS metadata.
7. A file with no usable date.

Expected results:

1. Valid files push without repair.
2. Missing-date files are repaired before push.
3. Generated videos keep or receive usable capture dates.
4. GPS is preserved when present.
5. Unrepairable files are skipped and logged.
6. Google Photos shows the intended capture date after indexing.

## Notes

This is meant to be a practical safety check before transfer. It does not try to
solve every metadata or duplicate-detection problem. It just makes the script
less likely to send Google Photos a file that will be indexed with the wrong
date.
