# Disk Detective

**A local Windows storage cleaner with a visual space map, safe quarantine, and verified cross-drive moves.**

[![Latest release](https://img.shields.io/github/v/release/kidseib/disk-detective?style=flat-square&label=release&color=2f81f7)](https://github.com/kidseib/disk-detective/releases)
[![Windows checks](https://github.com/kidseib/disk-detective/actions/workflows/windows-check.yml/badge.svg?branch=main)](https://github.com/kidseib/disk-detective/actions/workflows/windows-check.yml)
[![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)](#requirements)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)](#requirements)
[![No network](https://img.shields.io/badge/network-none-2ea043?style=flat-square)](#privacy)
[![VirusTotal](https://img.shields.io/badge/VirusTotal-0%20detections-2ea043?style=flat-square&logo=virustotal&logoColor=white)](#virustotal)

Disk Detective scans your drives, shows what is using space, and lets you clean up or move large files without a server, installer, or internet connection.

## Quick start

1. [Download Disk Detective.zip](Disk%20Detective.zip).
2. Extract all seven files into one folder.
3. Double-click `Disk Detective.bat`.

Windows may show a security prompt because the app is not code-signed. Confirm the SHA-256 below and allow it to run only if you downloaded it from this repository.

## What it does

- Shows a visual map of what is using space on each drive.
- Finds large files and duplicates.
- Cleans up through quarantine instead of silent deletion.
- Moves files to another drive with verification and leaves a shortcut at the old location.
- Recovers interrupted moves with a crash-recovery journal.
- Produces a report and offers a larger-text mode.

## Safety

- Files are cleaned up through quarantine, not silently deleted.
- Cross-drive moves are verified and leave a shortcut at the original location.
- A crash-recovery journal completes or reverses interrupted moves.
- One copy of the app and one file-changing operation can run at a time.
- Folders containing junctions or links are refused for moves.
- Same-drive moves are refused, and free space at the destination is checked before a move.

## Privacy

Disk Detective runs entirely on your PC. It has no server, no telemetry, and no internet connection; your file names and scan results stay on your computer.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1

## VirusTotal

The published zip has a clean VirusTotal report:

- [View the VirusTotal report](https://www.virustotal.com/gui/file/7b0230650b037e545d15f608b06f0889adbc7c3607e551a7cc9364a57dd7966e)
- Scanned file: `Disk Detective 1.0.0.zip` (same SHA-256 as the published `Disk Detective.zip`)
- SHA-256: `7b0230650b037e545d15f608b06f0889adbc7c3607e551a7cc9364a57dd7966e`
- Last analysis: November 25, 2026
- Result: **No security vendors flagged this file as malicious.**

VirusTotal scans the zip and may inspect its contents. The zip is the right artifact to check because it is exactly what you download; a folder cannot be submitted directly. Some engines cannot process archives, so a clean report is not a guarantee. For a file-by-file check, submit the extracted `.ps1` files separately.

## AI disclosure

Disk Detective was built with **Buffy**, the AI coding agent behind **Codebuff**. Buffy wrote and reviewed the application code, tests, documentation, and packaging, and prepared the GitHub release. The project owner directed the work, reviewed the results, and authorized publication.

The app does not use AI at runtime, does not call an AI service, and does not send your data anywhere. AI-assisted code can contain mistakes, so review and test it before relying on it for important files.

## Contributors

- **kidseib** — project owner
- **Buffy (Codebuff)** — AI coding agent
- **Freebuff** — cloud development workspace

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for details.

See `HOW TO USE.txt` and `FEATURES.txt` inside the zip for the full guide.
