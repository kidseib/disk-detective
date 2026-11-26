# Disk Detective

A local Windows storage cleaner. Disk Detective scans your drives, shows what is using space, and lets you clean up or move large files without a server, installer, or internet connection.

## Download

Download [Disk Detective.zip](Disk%20Detective.zip), extract all seven files into one folder, and run `Disk Detective.bat`.

The zip contains the app, its two help files, and the launcher.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1

## Safety

- Files are cleaned up through quarantine, not silently deleted.
- Cross-drive moves are verified and leave a shortcut at the original location.
- A crash-recovery journal completes or reverses interrupted moves.
- One copy of the app and one file-changing operation can run at a time.
- Folders containing junctions or links are refused for moves.
- Same-drive moves are refused, and free space at the destination is checked before a move.

## AI disclosure

Disk Detective was built with **Buffy**, the AI coding agent behind **Codebuff**. Buffy wrote and reviewed the application code, tests, documentation, and packaging, and prepared the GitHub release. The project owner directed the work, reviewed the results, and authorized publication.

The app does not use AI at runtime, does not call an AI service, and does not send your data anywhere. AI-assisted code can contain mistakes, so review and test it before relying on it for important files.

See `HOW TO USE.txt` and `FEATURES.txt` inside the zip for the full guide.
