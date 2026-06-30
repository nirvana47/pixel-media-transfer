# Transfer to Pixel XL

A macOS `.command` script for transferring photos and videos to an Android phone over `adb`.

## What it does

- Lets you choose a source folder
- Detects media files
- Transfers photos directly
- Remuxes or transcodes videos when needed
- Copies metadata with ExifTool when possible
- Tracks transfer history to avoid duplicates
- Stops early if phone or Mac storage is too low

## Requirements

- macOS
- `adb`
- `ffmpeg`
- `ffprobe`
- `exiftool`

## Usage

1. Make the script executable:
   ```bash
   chmod +x "Transfer to Pixel XL.command"
   ```
