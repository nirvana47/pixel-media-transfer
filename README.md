# Transfer to Pixel

A macOS `.command` script for transferring photos and videos to an Android phone over `adb`. The script is optimized for reliability over elegance, which is the right tradeoff for me for bulk media transfer. 

I am working on this problem while re-learning software engineering with the help of AI. The actual use case is personal: I want to move my iPhone media onto a Pixel XL so it can be backed up through Google Photos using the Pixel XL's free, unlimited, full-size, backup benefit.

## What it does

- Lets you choose a source folder
- Detects media files
- Transfers photos directly
- Remuxes or transcodes videos when needed (and copying metadata with ExifTool if possible)
- Tracks transfer history to avoid duplicates
- Stops early if Pixel or Mac storage is too low

## Requirements

- macOS
- `adb`
- `ffmpeg`
- `ffprobe`
- `exiftool`
- Android phone

## Usage

1. Make the script executable:
   ```bash
   chmod +x "Transfer to Pixel XL.command"
   ```
2. Double-click the file in Finder, or run it from Terminal:
   ```bash
   ./Transfer\ to\ Pixel\ XL.command
   ```

## System Design

### My Problems

- I want to point the script at a folder and trust it to do the work.
- I do not want one bad file to ruin the whole transfer.
- I do not want to manually transfer a few files at a time just to guess whether the phone is full enough.
- I want the files to be uploaded successfully to Google Photos
- I want to presever metadata as much as possible, so I can easily search/retrieve photos on Google photo website
- I want to be able to run the script again without duplicate copying

### Design Choices

- Check the basics first: required tools, connected phone, and available storage.
- Scan the selected folder and its subfolders, but skip the folders created for converted videos so it does not process its own output again.
- It keeps a small history file so a second run can pick up where the last one left off.
- It treats a file as already transferred only when the path and file size still match. This is not fully robust, and there are ways it can fail, but it is a practical first version for this workflow.
- It stops when storage is getting full on the Pixel (~500MB left - configurable) because else the phone slows to a crawl. Also check my mac's storage to make sure there's enough storage for re-encoding video files.

I plan to add a separate section later that documents edge cases and where this script is still fragile.

### Why Some Videos Are Converted

Not all iPhone videos are recognized and paresed correctly by Google Photos backup service. After lot of manual trial-and-error, I identified the issue and the file-format markers.

- If a photo or video is already Android-friendly, the script just transfers it.
- If a `.mov` video already uses friendly codecs, the script can repackage it as an `.mp4` without re-encoding the video.
- If a video uses a format that is less reliable on Android, the script converts it to H.264/AAC because that is a safer common format.
- Converted files are saved separately so the original source files are left alone.
- Partial conversion files are not treated as real output, which makes interrupted runs safer. 

### What This Project Is Teaching Me

This started as a utility script, but it has turned into a small systems design exercise. I am learning that even a personal script needs product decisions: what to automate, what to skip, when to stop, and how to make the next run easier than the first one.

The main tradeoff is that the script is intentionally cautious. It is not trying to be the fastest possible transfer tool or cover all of my manual work scenarios. It is trying to be understandable, repeatable, and safe enough that I can trust it with a large media archive.

### Known Limitations

- History is reliant on me not deleting the text files storing file transfer information
- Some files have missing metadata that can be inferred from file data, but currently that is not being fixed
- Relying on name + path + filesize for de-duping (i.e., checking whether the file has already been transferred to Pixel or not), which is not as robust


## Notes
This script was built for a personal workflow and is still being refined.
