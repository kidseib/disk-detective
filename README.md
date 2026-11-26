# Disk Detective

**A local Windows storage cleaner with a visual space map, safe quarantine, and verified cross-drive moves.**

[![Latest release](https://img.shields.io/github/v/release/kidseib/disk-detective?style=flat-square&label=release&color=2f81f7)](https://github.com/kidseib/disk-detective/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea043?style=flat-square)](LICENSE)
[![Windows checks](https://github.com/kidseib/disk-detective/actions/workflows/windows-check.yml/badge.svg?branch=main)](https://github.com/kidseib/disk-detective/actions/workflows/windows-check.yml)
[![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)](#requirements)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)](#requirements)
[![No network](https://img.shields.io/badge/network-none-2ea043?style=flat-square)](#privacy)
[![VirusTotal](https://img.shields.io/badge/VirusTotal-0%20detections-2ea043?style=flat-square&logo=virustotal&logoColor=white)](#virustotal)

Disk Detective scans your drives, shows what is using space, and lets you clean up or move large folders without a server, installer, or internet connection.

## Quick start

1. [Download Disk Detective.zip](Disk%20Detective.zip).
2. Extract all seven files into one folder.
3. Double-click `Disk Detective.bat`.

Windows may show a security prompt because the app is not code-signed. Confirm the SHA-256 below and allow it to run only if you downloaded it from this repository. If Windows or PowerShell blocks it, see [Troubleshooting](#troubleshooting).

## What it does

- Shows a visual map of what is using space on each drive.
- Finds large files and duplicates.
- Cleans up through quarantine instead of silent deletion.
- Moves large folders to another drive with verification and leaves a junction (folder link) at the old location.
- Recovers interrupted moves with a crash-recovery journal.
- Produces a report and offers a larger-text mode.

## Seeing what is using your space

The **Space map** tab draws a coloured block for each folder in the current view. A bigger block means more bytes.
 Click a block to select that folder; double-click to open it; **Up one level** goes back. The breadcrumb shows where you are, and the table lists each folder's name, size, file count, last-used date, and type.

- **Scan drive** measures the selected place and redraws the map.
- **Whole drive scan** reads the entire drive once and lists the biggest folders anywhere, plus the biggest files. It can take several minutes; **Stop** is available at any time.
- **What is this folder?** explains a folder in plain language.

Scanning only reads. It does not delete, move, or change anything.

## Cleaning up safely

The **Clean Up** tab looks for known caches and leftovers such as browser and Windows temporary files, GPU shader caches, installers, and old game files. Press **Scan my PC** first; it only looks and changes nothing.

Each result has a colour:

- **Green — Safe to delete:** rebuilds itself when needed.
- **Blue — Low risk:** leftover installers and game files.
- **Amber — Ask before deleting:** may hold settings; read the explanation first.
- **Pink — Protected:** save games and similar data; the app never offers these for deletion.

Use the filter to show one risk level. Tick items and press **Delete ticked items**, or press **Clean up safe items** for the green ones. A confirmation lists exactly what will move. **What is this?** explains an item; **Move this folder...** relocates a cache instead of deleting it; **Leave this alone** hides it from future scans; use **Ignored folders** at the bottom to bring it back.

Removed items go to Disk Detective's **Trash**, a hidden folder on the same drive, rather than the Recycle Bin. **What I did** can put them back. **Delete for good** removes one Trash item permanently after a second confirmation. It is a normal delete, not a secure eraser.

**Windows reserves...** explains space Windows keeps for itself—such as old Windows installations, hibernation, the page file, the Recycle Bin, and WinSxS—and points to the correct Windows tool. Disk Detective does not change those automatically.

## Finding duplicate files

**Duplicate files...** finds files with identical content. It keeps the newest copy of each group and lets you tick the others for the Trash. Review the names and locations before confirming: identical content does not always mean the extra copy is unwanted.

## Moving big folders to another drive

Disk Detective can move a large folder to another drive and leave a **junction** at the original location. A junction is a Windows folder link: programs still use the original `C:\...` path, but the files themselves live on the other drive.

This is intended for large, self-contained folders such as GPU shader caches:

- `C:\Users\<you>\AppData\Local\NVIDIA\DXCache`
- `C:\Users\<you>\AppData\Local\D3DSCache`
- other large cache or game folders outside protected system locations

The move is verified: Disk Detective copies the folder, checks the file count and total size, creates the junction, and only then removes the old copy. If Windows interrupts the move, the crash-recovery journal finishes it or puts the folder back.

**Junctions, not symbolic links.** A junction is directory-only, works on NTFS, and normally does not need administrator rights. Disk Detective does not offer a separate "create a symlink" command; it creates the junction as part of a move.

**It refuses to move:**

- a drive root
- the Windows or Program Files folders, or the ProgramData root
- the entire user profile, the AppData, AppData\Local, and AppData\Roaming roots, Desktop, Documents, Downloads, Pictures, Videos, or Music
- OneDrive, Dropbox, Google Drive, and other cloud-synced folders
- a folder that already contains a junction or link
- a folder that a program is using
- a move to the same drive
- an empty folder

**The original and destination drives should be NTFS.** FAT/exFAT moves fail safely. The whole AppData or Program Files folder cannot be moved, but a specific cache inside AppData can be.

Most programs follow junctions without noticing, but some installers, updaters, backup tools, and games do not. Keep a backup, and use **Undo** or **Repair** in "What I did" if a junction needs to be checked or reversed.

## Checking, undoing, and repairing changes

The **What I did** tab lists items in the Trash and folders moved to another drive, with the date, size, and current health—for example, `Works -> D:\...` or `BROKEN`.

- **Put it back** returns a trashed item to its original place, if that place is free.
- **Undo this move** puts the folder back, verifies it, and removes the junction and the extra copy. If the copy fails, the junction is restored so the folder still works.
- **Repair shortcut...** points a move at the folder's new location if a drive letter changed or the folder was moved by hand.
- **Check all shortcuts** tests every recorded move.

The move tools verify the folder before removing the extra copy. If the destination drive is disconnected or the old place has been recreated, they stop and explain what needs checking.

## Reports, larger text, and administrator mode

- **Save a report** writes a standalone HTML page with the scan findings, change history, and actions. It is useful when asking someone for help. The report can contain file names and folder paths, so review it before sharing it publicly.
- **Larger text** closes and reopens the window with bigger writing; everything else works the same.
- **Restart as administrator** is optional. It lets the app see Windows' own temporary folders that are hidden from a normal account. The app works without it.

## Safety

- Files are cleaned up through quarantine, not silently deleted.
- Cross-drive moves are verified and leave a junction at the original location.
- A crash-recovery journal completes or reverses interrupted moves.
- One copy of the app and one file-changing operation can run at a time.
- Folders containing junctions or links are refused for moves.
- Same-drive moves are refused, and free space at the destination is checked before a move.

## Privacy

Disk Detective runs entirely on your PC. It has no server, no telemetry, and no internet connection; your file names and scan results stay on your computer.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1

## Troubleshooting

First, make sure the zip came from this repository. If you do not know how to check the SHA-256, ask someone you trust to compare it before you continue.

### “Windows protected your PC” (SmartScreen)

This warning appears because Disk Detective is not code-signed. Click **More info**, check that the file is `Disk Detective.bat` and that you downloaded the zip from this repository, then click **Run anyway** only if you trust it and the SHA-256 matches the one below. If you are not sure, close the warning and delete the download.

### Windows says the downloaded file is blocked

Right-click the downloaded zip, choose **Properties**, tick **Unblock**, click **Apply**, then extract it again. If you already extracted it, do the same for `DiskDetective.ps1` and `Disk Detective.bat`. Keep all seven files together in one folder.

### PowerShell says “running scripts is disabled on this system”

Start the app with **`Disk Detective.bat`**, not by double-clicking `DiskDetective.ps1`. The `.bat` starts PowerShell with a bypass for that one launch, so you do not need to change Windows settings.

If it still happens, the computer may be managed by an employer or school, or security software may be enforcing a policy. Do not turn off PowerShell security for the whole PC; ask the person who manages the computer.

### Antivirus says it found a threat

Unsigned PowerShell tools are sometimes flagged because of how they behave, not because a known virus was found. Check the zip's SHA-256 (the long code in the VirusTotal section) and open the report.
 If the hash matches and the report is clean, allow **only this file** in your antivirus—never disable real-time protection or exclude your whole Downloads folder. If the hash does not match, do not run it; delete it and download a fresh copy.

In Windows Security, open **Protection history**, select the item, and choose **Allow on device** only after you have checked the hash.

### Still stuck

Open an [issue](https://github.com/kidseib/disk-detective/issues) and say what you were doing and the exact message you saw. Do not post personal file names or folder paths; a saved report can contain them.

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

## License

Released under the [MIT License](LICENSE). Copyright © 2026 kidseib.

See `HOW TO USE.txt` and `FEATURES.txt` inside the zip for the full guide.
