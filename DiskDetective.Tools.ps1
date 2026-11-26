#requires -Version 5.1
<#
    Disk Detective - drive tools
    Drive listing, folder measuring, junction inspection, a verified copy that
    survives long paths, and moving a folder to another drive while leaving a
    junction behind so programs still find it.

    Loaded by DiskDetective.ps1 (the window). Runs on its own only for tests:
        powershell -ExecutionPolicy Bypass -File .\DiskDetective.Tools.ps1 -SelfTest
#>
param([switch]$SelfTest)

$script:DDToolsLoaded = $true

. (Join-Path $PSScriptRoot "DiskDetective.Core.ps1")

# ---------------------------------------------------------------- drives

function Get-FixedDrives {
    $drives = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            # Fixed disks and USB/external disks; network and optical drives are skipped.
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -and $drive.DriveType -ne [System.IO.DriveType]::Removable) { continue }
            $drives += [pscustomobject]@{
                Root      = $drive.RootDirectory.FullName
                Label     = $drive.Name.TrimEnd("\")
                Total     = [int64]$drive.TotalSize
                Free      = [int64]$drive.AvailableFreeSpace
                Removable = ($drive.DriveType -eq [System.IO.DriveType]::Removable)
            }
        } catch { }
    }
    return @($drives | Sort-Object Label)
}

function Get-FreeSpace {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        $drive = New-Object System.IO.DriveInfo($root)
        return [pscustomobject]@{
            Total = [int64]$drive.TotalSize
            Free  = [int64]$drive.AvailableFreeSpace
            Label = $drive.Name.TrimEnd("\")
        }
    } catch {
        return [pscustomobject]@{ Total = [int64]0; Free = [int64]0; Label = "" }
    }
}

# ---------------------------------------------------------------- change lock

# One named lock shared by every window and process. A long copy must never
# overlap with another move, delete or restore.
$script:OperationMutex = $null

function Enter-OperationLock {
    if (-not $script:OperationMutex) {
        try { $script:OperationMutex = New-Object System.Threading.Mutex($false, "Local\DiskDetective.Operation") } catch { return $true }
    }
    try { return $script:OperationMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Exit-OperationLock {
    if ($script:OperationMutex) {
        try { [void]$script:OperationMutex.ReleaseMutex() } catch { }
    }
}

# ---------------------------------------------------------------- move journal

function Get-MoveJournalPath {
    $folder = $env:DISKDETECTIVE_DATA
    if (-not $folder) {
        if ($env:LOCALAPPDATA) { $folder = [System.IO.Path]::Combine($env:LOCALAPPDATA, "DiskDetective") }
        else { $folder = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "DiskDetective") }
    }
    return [System.IO.Path]::Combine($folder, "pending-moves.json")
}

function Read-MoveJournal {
    $path = Get-MoveJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        # The journal is written as UTF-8 without a BOM; PS 5.1 would otherwise
        # read non-English folder names in the system code page and corrupt them.
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return @() }
        return @($data)
    } catch { return @() }
}

function Write-MoveJournal {
    param([object[]]$Entries)
    $path = Get-MoveJournalPath
    $list = @($Entries)
    $json = if ($list.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject $list -Depth 6 }
    try {
        $folder = [System.IO.Path]::GetDirectoryName($path)
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void][System.IO.Directory]::CreateDirectory($folder) }
        $temp = "$path.tmp"
        [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) {
            try { [System.IO.File]::Replace($temp, $path, $null) }
            catch {
                [System.IO.File]::Copy($temp, $path, $true)
                [System.IO.File]::Delete($temp)
            }
        } else {
            [System.IO.File]::Move($temp, $path)
        }
        return $true
    } catch { return $false }
}

function Set-MoveJournalStage {
    param([string]$Id, [string]$Stage, [string]$Backup = "")
    $all = @(Read-MoveJournal)
    foreach ($entry in $all) {
        if ($entry.Id -eq $Id) {
            $entry.Stage = $Stage
            if ($Backup) { $entry.Backup = $Backup }
        }
    }
    return [bool](Write-MoveJournal $all)
}

function Remove-MoveJournalEntry {
    param([string]$Id)
    $all = @(Read-MoveJournal | Where-Object { $_.Id -ne $Id })
    return [bool](Write-MoveJournal $all)
}

# Removes a copy made during a failed move. The journal is kept when the copy
# cannot be removed, so the next start can try again.
function Clear-MoveTarget {
    param([string]$Target, [string]$Id)
    if (-not (Remove-TreeQuietly $Target)) { return $false }
    [void](Remove-MoveJournalEntry $Id)
    return $true
}

function Test-SameFolderPath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        $left = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
        $right = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
        return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# Finishes or rolls back a move that was cut off by a crash or power loss.
# Safe by design: the original is either still in place or in the .moving backup.
function Repair-PendingMoves {
    # Recovery changes files too, so it must not run beside another move.
    if (-not (Enter-OperationLock)) { return @() }
    try {
        return (Invoke-PendingMoveRepair)
    } finally {
        Exit-OperationLock
    }
}

function Invoke-PendingMoveRepair {
    $entries = @(Read-MoveJournal)
    $results = New-Object System.Collections.ArrayList
    $separator = [System.IO.Path]::DirectorySeparatorChar

    foreach ($entry in $entries) {
        if (-not $entry -or -not $entry.Source -or -not $entry.Target) {
            if ($entry -and $entry.Id) { [void](Remove-MoveJournalEntry $entry.Id) }
            continue
        }

        $source = [string]$entry.Source
        $target = [string]$entry.Target
        $backup = ""
        if ($entry.PSObject.Properties["Backup"]) { $backup = [string]$entry.Backup }
        $stage = "linked"
        if ($entry.PSObject.Properties["Stage"] -and $entry.Stage) { $stage = [string]$entry.Stage }
        $bytes = [int64]0
        if ($entry.PSObject.Properties["Bytes"]) { $bytes = [int64]$entry.Bytes }
        $files = 0
        if ($entry.PSObject.Properties["Files"]) { $files = [int]$entry.Files }

        # A hand-edited or damaged journal must never be able to point a delete
        # or a rename at the original folder or at one of its parents.
        $safe = $true
        try {
            $source = [System.IO.Path]::GetFullPath($source).TrimEnd($separator)
            $target = [System.IO.Path]::GetFullPath($target).TrimEnd($separator)
            $sourceRoot = [System.IO.Path]::GetPathRoot($source).TrimEnd($separator)
            $targetRoot = [System.IO.Path]::GetPathRoot($target).TrimEnd($separator)
            if (-not $sourceRoot -or -not $targetRoot) { $safe = $false }
            elseif ($source -eq $sourceRoot -or $target -eq $targetRoot) { $safe = $false }
            elseif ([string]::Equals($source, $target, [System.StringComparison]::OrdinalIgnoreCase)) { $safe = $false }
            elseif ($target.StartsWith($source + $separator, [System.StringComparison]::OrdinalIgnoreCase)) { $safe = $false }
            elseif ($source.StartsWith($target + $separator, [System.StringComparison]::OrdinalIgnoreCase)) { $safe = $false }
            if ($backup) {
                $backup = [System.IO.Path]::GetFullPath($backup).TrimEnd($separator)
                if (-not $backup.StartsWith($source + ".moving", [System.StringComparison]::OrdinalIgnoreCase)) { $backup = "" }
            }
        } catch { $safe = $false }
        if (-not $safe) {
            [void](Remove-MoveJournalEntry $entry.Id)
            [void]$results.Add([pscustomobject]@{
                Source = $source; Target = $target; Outcome = "broken"
                Message = "A saved recovery record pointed at unsafe folder paths, so it was ignored and removed. Nothing was changed."
                Completed = $false; Bytes = $bytes; Files = $files
            })
            continue
        }

        # If the source drive is unplugged, keep the record. The backup is on
        # that drive too, so it will still be there when the drive returns.
        $sourceRootPath = [System.IO.Path]::GetPathRoot($source)
        $sourceReady = $false
        try { $sourceReady = [bool](Test-Path -LiteralPath $sourceRootPath) } catch { $sourceReady = $false }
        if (-not $sourceReady) {
            [void]$results.Add([pscustomobject]@{
                Source = $source; Target = $target; Outcome = "waiting"
                Message = "The drive that holds $source is not connected, so the recovery record was kept. Reconnect the drive and open Disk Detective again."
                Completed = $false; Bytes = $bytes; Files = $files
            })
            continue
        }

        $link = Get-LinkInfo $source
        $targetExists = Test-Directory $target
        $backupExists = [bool]($backup -and (Test-Directory $backup))
        $completed = $false
        $keep = $false
        $outcome = ""
        $message = ""

        if ($link.IsLink) {
            $linkTarget = [string]$link.Target
            $pointsHere = Test-SameFolderPath $linkTarget $target
            if ($targetExists -and $pointsHere) {
                $completed = $true
                $outcome = "finished"
                $message = "Finished the interrupted move of $source."
                if ($backupExists -and -not (Remove-TreeQuietly $backup)) {
                    $keep = $true
                    $message += " A spare copy remains at $backup and will be cleaned up next time."
                }
            } elseif ($backupExists -and (-not $link.Target -or $pointsHere)) {
                # The shortcut points at our copy, but that copy is gone. Put the
                # original back instead of leaving a broken shortcut.
                [void](Remove-Link $source)
                try {
                    [System.IO.Directory]::Move($backup, $source)
                    $outcome = "put-back"
                    $message = "Put $source back after an interrupted move. Nothing was lost."
                } catch {
                    $keep = $true
                    $outcome = "stuck"
                    $message = "The only copy of $source is at $backup and could not be put back automatically. Copy it somewhere safe before doing anything else."
                }
            } else {
                $keep = $true
                $outcome = "broken"
                $message = "The shortcut at $source does not point at $target, so the saved copy was left alone$(if ($backupExists) { " at $backup" }). Use Repair shortcut after checking where the data is."
            }
        } elseif (-not $link.Exists -and $backupExists) {
            $targetOk = $false
            $targetPartial = $false
            if ($targetExists) {
                $stats = Get-TreeStats $target
                $targetOk = ($stats.Bytes -eq $bytes -and $stats.Files -eq $files -and $stats.Bytes -gt 0)
                $targetPartial = ($bytes -gt 0 -and $stats.Bytes -lt $bytes -and $stats.Files -le $files)
            }
            if ($targetOk) {
                if (New-Junction -Link $source -Target $target) {
                    $completed = $true
                    $outcome = "finished"
                    $message = "Finished the interrupted move of $source."
                    if (-not (Remove-TreeQuietly $backup)) {
                        $keep = $true
                        $message += " A spare copy remains at $backup and will be cleaned up next time."
                    }
                } else {
                    $keep = $true
                    $outcome = "stuck"
                    $message = "The verified copy is safe at $target and the original backup is at $backup, but the shortcut could not be created. Both were left alone; check them before changing anything."
                }
            } elseif ($targetExists -and -not $targetPartial) {
                $keep = $true
                $outcome = "stuck"
                $message = "The original backup is safe at $backup and the copy at $target was left alone too, because it may hold changes. Check both before moving either."
            } elseif ($targetExists -and -not (Remove-TreeQuietly $target)) {
                $keep = $true
                $outcome = "stuck"
                $message = "The original is safe at $backup, but the unfinished copy at $target could not be removed, so the folder was not put back yet."
            } else {
                try {
                    [System.IO.Directory]::Move($backup, $source)
                    $outcome = "put-back"
                    $message = "Put $source back after an interrupted move. Nothing was lost."
                } catch {
                    $keep = $true
                    $outcome = "stuck"
                    $message = "The only copy of $source is at $backup and could not be put back automatically. Copy it somewhere safe before doing anything else."
                }
            }
        } elseif (-not $link.Exists) {
            $outcome = "missing"
            $message = "The original folder $source is missing and no saved backup was found."
            if ($targetExists) { $message += " A copy from the move is still at $target." }
        } elseif ($backupExists) {
            # Something recreated the original folder while the backup still
            # exists. Do not overwrite it or delete the copy; let the user choose.
            $keep = $true
            $outcome = "stuck"
            $message = "There is a normal folder at $source and a saved backup at $backup. Both were left alone$(if ($targetExists) { ", along with the copy at $target" }). Check which one has your data, then remove the others."
        } else {
            $sourceIsFolder = Test-Directory $source
            $partialCopy = $false
            if ($targetExists) {
                $targetStats = Get-TreeStats $target
                # Only a smaller copy can be an unfinished copy. A complete copy
                # may be the only data left, so it is never deleted automatically.
                $partialCopy = ($stage -eq "copying" -and $bytes -gt 0 -and $targetStats.Bytes -lt $bytes -and $targetStats.Files -le $files)
            }
            if ($sourceIsFolder -and $targetExists -and $partialCopy) {
                if (Remove-TreeQuietly $target) {
                    $outcome = "discarded"
                    $message = "Cleaned up an unfinished copy of $source. The original folder was not changed."
                } else {
                    $keep = $true
                    $outcome = "stuck"
                    $message = "The original folder is in place, but the unfinished copy at $target could not be removed. It will be tried again next time."
                }
            } elseif ($sourceIsFolder -and $targetExists) {
                $outcome = "left"
                $message = "The original folder is in place. A copy from an interrupted move is still at $target; it was left alone. Check it and remove it yourself if it is not needed."
            } elseif ($sourceIsFolder) {
                $outcome = "stale"
                $message = "The original folder is in place and no unfinished copy remains. Nothing needed to be done."
            } else {
                $outcome = "left"
                $message = "The saved recovery record did not match a folder at $source, so nothing was changed."
            }
        }

        if (-not $keep) { [void](Remove-MoveJournalEntry $entry.Id) }
        [void]$results.Add([pscustomobject]@{
            Source = $source; Target = $target; Outcome = $outcome; Message = $message
            Completed = $completed; Bytes = $bytes; Files = $files
        })
    }
    return @($results)
}

function Get-KnownFolderPaths {
    $paths = New-Object System.Collections.ArrayList
    $names = @(
        "UserProfile", "Desktop", "MyDocuments", "MyPictures", "MyVideos", "MyMusic",
        "ApplicationData", "LocalApplicationData", "CommonApplicationData",
        "ProgramFiles", "ProgramFilesX86"
    )
    foreach ($name in $names) {
        try {
            $value = [System.Environment]::GetFolderPath($name)
            if ($value -and (Test-Directory $value)) { [void]$paths.Add($value) }
        } catch { }
    }
    return @($paths)
}

# Folders that sync to the cloud must never be moved: the sync client would
# lose track of them and the data would be duplicated.
function Get-CloudRoots {
    $roots = @()
    foreach ($candidate in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, $env:Dropbox, $env:GoogleDrive)) {
        if ($candidate -and (Test-Directory $candidate)) { $roots += $candidate }
    }
    # OneDrive without the environment variable still lives in the profile.
    if ($env:USERPROFILE) {
        $guess = [System.IO.Path]::Combine($env:USERPROFILE, "OneDrive")
        if ((Test-Directory $guess) -and ($roots -notcontains $guess)) { $roots += $guess }
    }
    return @($roots)
}

function Test-CloudPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    foreach ($root in (Get-CloudRoots)) {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($full -eq $rootFull -or $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar)) {
            return "This folder is kept in sync by OneDrive or another cloud app. Moving it would break syncing, so Disk Detective leaves it alone."
        }
    }
    return $null
}

# ---------------------------------------------------------------- processes

function Get-ProcessesUsing {
    param([string]$Path)
    $names = @()
    if (-not $Path) { return @() }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    try {
        foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                $exe = $process.Path
                if (-not $exe) { continue }
                $exeFull = [System.IO.Path]::GetFullPath($exe)
                if ($exeFull.StartsWith($full + [System.IO.Path]::DirectorySeparatorChar)) {
                    if ($names -notcontains $process.ProcessName) { $names += $process.ProcessName }
                }
            } catch { }
        }
    } catch { }
    return @($names)
}

# ---------------------------------------------------------------- measuring

function Get-TreeStats {
    param([string]$Path)

    if (Test-File $Path) {
        $file = New-Object System.IO.FileInfo($Path)
        return [pscustomobject]@{ Bytes = [int64]$file.Length; Files = 1; Folders = 0; Links = 0 }
    }
    if (-not (Test-Directory $Path)) {
        return [pscustomobject]@{ Bytes = [int64]0; Files = 0; Folders = 0; Links = 0 }
    }

    $bytes = [int64]0
    $files = 0
    $folders = 0
    $links = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in (Get-ChildEntries $current)) {
            try {
                $attributes = [System.IO.File]::GetAttributes($entry)
                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    # A shortcut or junction is counted so a move can refuse it.
                    $links++
                    continue
                }
                if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $folders++
                    $stack.Push($entry)
                    continue
                }
                $file = New-Object System.IO.FileInfo($entry)
                if (-not $file.Exists) { continue }
                $bytes += $file.Length
                $files++
            } catch { }
        }
    }

    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Folders = $folders; Links = $links }
}

function Get-FolderChildren {
    param([string]$Path, [scriptblock]$Progress)

    $result = @()
    $savedStopwatch = $script:Stopwatch
    $script:Stopwatch = $null   # no time budget while mapping a drive

    try {
        foreach ($entry in (Get-ChildEntries $Path)) {
            if (-not (Test-Directory $entry)) { continue }
            $info = New-Object System.IO.DirectoryInfo($entry)
            $name = $info.Name
            if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $link = Get-LinkInfo $entry
                $result += [pscustomobject]@{
                    Path = $entry; Name = $name; Bytes = [int64]0; Files = 0;
                    LastUsed = $info.LastWriteTime; IsLink = $true; Target = $link.Target
                }
                continue
            }
            if ($Progress) { & $Progress "Measuring $name ..." }
            $measured = Measure-Path $entry
            $result += [pscustomobject]@{
                Path = $entry; Name = $name; Bytes = [int64]$measured.Bytes; Files = $measured.Files;
                LastUsed = $measured.LastUsed; IsLink = $false; Target = $null
            }
        }
    } finally {
        $script:Stopwatch = $savedStopwatch
    }

    return @($result | Sort-Object Bytes -Descending)
}

# ---------------------------------------------------------------- links

function Test-PathEntry {
    param([string]$Path)
    if (-not $Path) { return $false }
    try { [void][System.IO.File]::GetAttributes($Path); return $true }
    catch { return [bool](Test-Path -LiteralPath $Path) }
}

function Get-LinkInfo {
    param([string]$Path)

    $info = [pscustomobject]@{ Exists = $false; IsLink = $false; Target = $null }
    if (-not (Test-PathEntry $Path)) { return $info }
    $info.Exists = $true

    try {
        # Reading the attributes does not follow the link, so a shortcut whose
        # target is gone is still seen (Test-Path would say it is missing).
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $info }
        $info.IsLink = $true

        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSObject.Properties["Target"] -and $item.Target) {
                $info.Target = [string](@($item.Target)[0])
            } elseif ($item.PSObject.Properties["LinkTarget"] -and $item.LinkTarget) {
                $info.Target = [string]$item.LinkTarget
            }
        } catch { }

        if (-not $info.Target) {
            # Windows PowerShell 5.1: ask Windows for the junction target.
            try {
                $raw = & $env:ComSpec /c "fsutil reparsepoint query `"$Path`"" 2>$null
                foreach ($line in @($raw)) {
                    if ($line -match "Substitute Name:\s*(.+)$") { $info.Target = $Matches[1].Trim(); break }
                    if (-not $info.Target -and $line -match "Print Name:\s*(.+)$") { $info.Target = $Matches[1].Trim() }
                }
                if ($info.Target) { $info.Target = ($info.Target -replace '^\\\?\?\\', '') }
            } catch { }
        }
        if ($info.Target) {
            if ($info.Target.StartsWith('\??\')) { $info.Target = $info.Target.Substring(4) }
            elseif ($info.Target.StartsWith('\\?\')) { $info.Target = $info.Target.Substring(4) }
        }
    } catch { }

    return $info
}

function Remove-Link {
    param([string]$Path)
    if (-not (Test-PathEntry $Path)) { return $false }
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
        # Deleting a junction removes the link only; the data behind it stays.
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            [System.IO.Directory]::Delete($Path, $false)
        } else {
            [System.IO.File]::Delete($Path)
        }
        return (-not (Test-PathEntry $Path))
    } catch {
        return $false
    }
}

function Test-IsAdmin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------- moving

function Test-SafeToMove {
    param([string]$Path)

    if (-not $Path) { return "No folder was chosen." }
    if (-not (Test-Directory $Path)) { return "That folder no longer exists." }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd($separator)
    if (-not $full) { $full = [string]$separator }
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not $root) { $root = $full }
    if ($full.TrimEnd($separator) -eq $root.TrimEnd($separator)) { return "You cannot move an entire drive." }

    $info = New-Object System.IO.DirectoryInfo($full)
    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return "This folder is already a shortcut to another location."
    }

    if ($full -match '(?i)(\\|/)\$Recycle\.Bin$' -or $full -match '(?i)(\\|/)System Volume Information$') {
        return "This is a Windows housekeeping folder; it cannot be moved."
    }
    if ($full -match '(?i)(\\|/)\.diskdetective-trash$') {
        return "This is Disk Detective's own holding folder; it cannot be moved."
    }

    $cloud = Test-CloudPath $full
    if ($cloud) { return $cloud }

    $blocked = @()
    foreach ($candidate in (Get-KnownFolderPaths)) {
        $blocked += ([System.IO.Path]::GetFullPath($candidate).TrimEnd($separator))
    }
    foreach ($candidate in @(
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        (Join-PathSafe $env:USERPROFILE "AppData"),
        (Join-PathSafe $env:USERPROFILE "AppData\Local"),
        (Join-PathSafe $env:USERPROFILE "AppData\Roaming"),
        (Join-PathSafe $env:USERPROFILE "Downloads"),
        (Join-PathSafe $env:USERPROFILE "Desktop"),
        (Join-PathSafe $env:USERPROFILE "Documents")
    )) {
        if ($candidate -and (Test-Directory $candidate)) {
            $blocked += ([System.IO.Path]::GetFullPath($candidate).TrimEnd($separator))
        }
    }
    foreach ($candidate in $blocked) {
        if ($full -eq $candidate) { return "This folder is managed by Windows or is one of your personal folders, so it cannot be moved as a whole." }
    }

    if ($full -match '(?i)^[a-z]:\\Windows(\\|$)') { return "Folders inside the Windows system folder cannot be moved." }
    if ($full -match '(?i)^[a-z]:\\Program Files( \(x86\))?(\\|$)') { return "Folders inside Program Files cannot be moved safely." }

    return $null
}

function Get-Robocopy {
    if ($env:OS -ne "Windows_NT") { return $null }
    foreach ($candidate in @(
        (Join-PathSafe $env:WINDIR "System32\Robocopy.exe"),
        (Join-PathSafe $env:WINDIR "Sysnative\Robocopy.exe")
    )) {
        if ($candidate -and (Test-File $candidate)) { return $candidate }
    }
    try {
        $command = Get-Command robocopy.exe -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    } catch { }
    return $null
}

function Copy-TreeVerified {
    param([string]$Source, [string]$Destination, [scriptblock]$Progress)

    $files = 0
    $bytes = [int64]0
    $skippedLinks = 0

    # Robocopy handles very long paths and file-by-file retries, which caches
    # deep inside AppData need. It is only used on Windows.
    $robocopy = Get-Robocopy
    if ($robocopy) {
        try {
            if (-not (Test-Directory $Destination)) { [void][System.IO.Directory]::CreateDirectory($Destination) }
            if ($Progress) { & $Progress "Copying with Windows (long paths supported)..." }
            & $robocopy $Source $Destination /E /COPY:DAT /DCOPY:T /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
            $code = $LASTEXITCODE
            # 0-7 mean success (including "extra files" and "copied some"); 8+ is a failure.
            if ($code -ge 8) {
                return [pscustomobject]@{ Ok = $false; Files = 0; Bytes = [int64]0; Skipped = 0; Error = "Windows copied what it could but reported a problem (code $code)." }
            }
            $stats = Get-TreeStats $Destination
            return [pscustomobject]@{ Ok = $true; Files = $stats.Files; Bytes = $stats.Bytes; Skipped = 0; Error = "" }
        } catch {
            return [pscustomobject]@{ Ok = $false; Files = 0; Bytes = [int64]0; Skipped = 0; Error = $_.Exception.Message }
        }
    }

    try {
        if (-not (Test-Directory $Destination)) { [void][System.IO.Directory]::CreateDirectory($Destination) }

        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push([pscustomobject]@{ Src = $Source; Dst = $Destination })

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            foreach ($entry in (Get-ChildEntries $current.Src)) {
                $name = [System.IO.Path]::GetFileName($entry)
                $destinationPath = [System.IO.Path]::Combine($current.Dst, $name)

                if (Test-Directory $entry) {
                    $info = New-Object System.IO.DirectoryInfo($entry)
                    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $skippedLinks++; continue }
                    [void][System.IO.Directory]::CreateDirectory($destinationPath)
                    $stack.Push([pscustomobject]@{ Src = $entry; Dst = $destinationPath })
                    continue
                }

                $file = New-Object System.IO.FileInfo($entry)
                if (-not $file.Exists) { continue }
                [System.IO.File]::Copy($entry, $destinationPath, $true)
                $files++
                $bytes += $file.Length
                if ($Progress -and ($files % 250 -eq 0)) { & $Progress "Copied $files files..." }
            }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Files = $files; Bytes = $bytes; Skipped = $skippedLinks; Error = $_.Exception.Message }
    }

    return [pscustomobject]@{ Ok = $true; Files = $files; Bytes = $bytes; Skipped = $skippedLinks; Error = "" }
}

function New-Junction {
    param([string]$Link, [string]$Target)

    $shell = $env:ComSpec
    if (-not $shell) { $shell = "cmd.exe" }

    try {
        & $shell /c mklink /J "$Link" "$Target" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
    } catch {
        return $false
    }

    # Check the target too: cmd expands %NAME% inside quotes, which could
    # otherwise leave a link that points somewhere else.
    $info = Get-LinkInfo $Link
    return [bool]($info.IsLink -and (Test-SameFolderPath ([string]$info.Target) $Target))
}

# Deletes a tree without ever following a junction. Windows PowerShell 5.1's
# Remove-Item -Recurse can walk into a junction and delete the data behind it,
# which would be a silent, permanent loss on another drive.
function Remove-TreeQuietly {
    param([string]$Path)
    if (-not $Path -or -not (Test-PathEntry $Path)) { return $true }
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            # Remove the link itself; never walk into its target.
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                [System.IO.Directory]::Delete($Path, $false)
            } else {
                [System.IO.File]::Delete($Path)
            }
            return (-not (Test-PathEntry $Path))
        }
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) {
                [void](Remove-TreeQuietly -Path $entry)
            }
            [System.IO.Directory]::Delete($Path, $false)
        } else {
            [System.IO.File]::Delete($Path)
        }
        return (-not (Test-PathEntry $Path))
    } catch {
        return $false
    }
}

function Invoke-MoveFolderWithLink {
    param([string]$Source, [string]$DestinationParent, [scriptblock]$Progress, [object]$KnownStats)

    $result = [pscustomobject]@{
        Ok = $false; Message = ""; Source = $Source; Target = ""; Leftover = ""
        Bytes = [int64]0; Files = 0
    }

    $problem = Test-SafeToMove $Source
    if ($problem) { $result.Message = $problem; return $result }
    if (-not $DestinationParent -or -not (Test-Directory $DestinationParent)) {
        $result.Message = "The destination folder does not exist."
        return $result
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd($separator)
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationParent).TrimEnd($separator)
    if ($destinationFull -eq $sourceFull -or $destinationFull.StartsWith($sourceFull + $separator)) {
        $result.Message = "The destination cannot be inside the folder you are moving."
        return $result
    }

    $sourceRoot = [System.IO.Path]::GetPathRoot($sourceFull)
    $destinationRoot = [System.IO.Path]::GetPathRoot($destinationFull)
    if ([string]::Equals($sourceRoot, $destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Message = "The new place is on the same drive ($($sourceRoot.TrimEnd($separator))). Moving a folder inside one drive does not free space there. Choose a folder on another drive."
        return $result
    }

    $sourceStats = $KnownStats
    if (-not $sourceStats) { $sourceStats = Get-TreeStats $sourceFull }
    if ([int]$sourceStats.Links -gt 0) {
        $result.Message = "This folder contains a shortcut or link inside it. Disk Detective cannot copy links safely, so it will not move the folder. Remove the link, or move the folder yourself."
        return $result
    }
    if ($sourceStats.Bytes -le 0) {
        $result.Message = "This folder is empty, so there is nothing to move."
        return $result
    }

    $busy = @(Get-ProcessesUsing $sourceFull)
    if ($busy.Count -gt 0) {
        $result.Message = "These programs are using the folder: $($busy -join ', '). Close them, then try again. Nothing was changed."
        return $result
    }

    $needed = [int64]($sourceStats.Bytes * 1.05)
    $free = Get-FreeSpace $destinationFull
    if ($free -and $free.Total -gt 0 -and $free.Free -lt $needed) {
        $result.Message = "Not enough free space at the destination. Need about $(Format-Size $needed), but only $(Format-Size $free.Free) is free. Nothing was changed."
        return $result
    }

    $backup = "$sourceFull.moving"
    $suffix = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = "$sourceFull.moving$suffix"
        $suffix++
    }

    $leaf = [System.IO.Path]::GetFileName($sourceFull)
    $target = [System.IO.Path]::Combine($destinationFull, $leaf)
    $counter = 1
    while (Test-Path -LiteralPath $target) {
        $target = [System.IO.Path]::Combine($destinationFull, "$leaf ($counter)")
        $counter++
    }

    $journalId = [guid]::NewGuid().ToString("N")
    $journal = [pscustomobject]@{
        Id = $journalId; Source = $sourceFull; Target = $target; Backup = $backup
        Stage = "copying"; At = (Get-Date).ToString("s")
        Bytes = [int64]$sourceStats.Bytes; Files = [int]$sourceStats.Files
    }
    $journalEntries = @(Read-MoveJournal)
    $journalEntries += $journal
    if (-not (Write-MoveJournal $journalEntries)) {
        $result.Message = "The recovery record could not be written, so nothing was changed. Check that the Disk Detective data folder is writable."
        return $result
    }

    if ($Progress) { & $Progress "Copying $(Format-Size $sourceStats.Bytes)..." }
    $copy = Copy-TreeVerified -Source $sourceFull -Destination $target -Progress $Progress
    if (-not $copy.Ok) {
        $cleared = Clear-MoveTarget -Target $target -Id $journalId
        $extra = ""
        if (-not $cleared) { $result.Leftover = $target; $extra = " A partial copy was left at $target; it will be cleaned up next time." }
        $result.Message = "The copy stopped: $($copy.Error). Nothing was changed.$extra"
        return $result
    }
    if ($copy.Skipped -gt 0) {
        $cleared = Clear-MoveTarget -Target $target -Id $journalId
        $extra = ""
        if (-not $cleared) { $result.Leftover = $target; $extra = " A partial copy was left at $target; it will be cleaned up next time." }
        $result.Message = "This folder contains a shortcut or link that cannot be copied safely, so nothing was moved.$extra"
        return $result
    }

    $copiedStats = Get-TreeStats $target
    if ($copiedStats.Bytes -ne $sourceStats.Bytes -or $copiedStats.Files -ne $sourceStats.Files -or $copiedStats.Folders -ne $sourceStats.Folders) {
        $cleared = Clear-MoveTarget -Target $target -Id $journalId
        if ($cleared) {
            $result.Message = "The copy did not match the original, so it was removed and nothing was changed."
        } else {
            $result.Leftover = $target
            $result.Message = "The copy did not match the original. The copy at $target could not be removed; the recovery record was kept so it will be cleaned up next time."
        }
        return $result
    }
    [void](Set-MoveJournalStage -Id $journalId -Stage "copied")

    if ($Progress) { & $Progress "Making sure nothing has the old folder open..." }
    try {
        [System.IO.Directory]::Move($sourceFull, $backup)
    } catch {
        $cleared = Clear-MoveTarget -Target $target -Id $journalId
        $extra = ""
        if (-not $cleared) { $result.Leftover = $target; $extra = " A copy was left at $target; it will be cleaned up next time." }
        $result.Message = "Windows could not let go of this folder. Close the program that is using it, then try again. Nothing was changed.$extra"
        return $result
    }
    [void](Set-MoveJournalStage -Id $journalId -Stage "renamed" -Backup $backup)

    if (-not (New-Junction -Link $sourceFull -Target $target)) {
        $restored = $false
        try { [System.IO.Directory]::Move($backup, $sourceFull); $restored = $true } catch { }
        if (-not $restored) {
            $result.Leftover = $backup
            $result.Message = "The shortcut could not be created. Your folder is safe at $backup; the recovery record was kept, so open Disk Detective again to finish putting it back."
            return $result
        }
        if (Clear-MoveTarget -Target $target -Id $journalId) {
            $result.Message = "The shortcut could not be created, so the folder was put back. Nothing was lost."
        } else {
            [void](Set-MoveJournalStage -Id $journalId -Stage "copied")
            $result.Leftover = $target
            $result.Message = "The shortcut could not be created, so the folder was put back. A copy remains at $target and will be cleaned up next time."
        }
        return $result
    }

    $check = Get-LinkInfo $sourceFull
    if (-not $check.IsLink -or -not (Test-SameFolderPath ([string]$check.Target) $target)) {
        if ($check.Exists) { [void](Remove-Link $sourceFull) }
        $restored = $false
        try { [System.IO.Directory]::Move($backup, $sourceFull); $restored = $true } catch { }
        if (-not $restored) {
            $result.Leftover = $backup
            $result.Message = "The shortcut did not read back correctly. Your folder is safe at $backup; the recovery record was kept, so open Disk Detective again to finish putting it back."
            return $result
        }
        if (Clear-MoveTarget -Target $target -Id $journalId) {
            $result.Message = "The shortcut did not read back as a shortcut, so the folder was put back. Nothing was lost."
        } else {
            [void](Set-MoveJournalStage -Id $journalId -Stage "copied")
            $result.Leftover = $target
            $result.Message = "The shortcut did not read back as a shortcut, so the folder was put back. A copy remains at $target and will be cleaned up next time."
        }
        return $result
    }
    [void](Set-MoveJournalStage -Id $journalId -Stage "linked")

    if (-not (Remove-TreeQuietly $backup)) { $result.Leftover = $backup }
    else { [void](Remove-MoveJournalEntry $journalId) }

    $result.Ok = $true
    $result.Bytes = [int64]$sourceStats.Bytes
    $result.Files = [int]$sourceStats.Files
    $result.Target = $target
    $result.Message = "Moved to $target. A shortcut now sits in the old place, so programs still find it."
    return $result
}

function Move-FolderWithLink {
    param([string]$Source, [string]$DestinationParent, [scriptblock]$Progress, [object]$KnownStats)
    if (-not (Enter-OperationLock)) {
        return [pscustomobject]@{
            Ok = $false; Source = $Source; Target = ""; Leftover = ""; Bytes = [int64]0; Files = 0
            Message = "Another Disk Detective change is already running. Wait for it to finish, then try again. Nothing was changed."
        }
    }
    try {
        return (Invoke-MoveFolderWithLink -Source $Source -DestinationParent $DestinationParent -Progress $Progress -KnownStats $KnownStats)
    } finally {
        Exit-OperationLock
    }
}

# ---------------------------------------------------------------- self test

if ($SelfTest) {
    $script:failures = 0

    function Assert-True {
        param([bool]$Condition, [string]$Label)
        if ($Condition) { Write-Host "  PASS  $Label" } else { Write-Host "  FAIL  $Label"; $script:failures++ }
    }

    Write-Host "Disk Detective - tools self test"
    $root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "dd-selftest-" + [guid]::NewGuid().ToString("N"))
    [void][System.IO.Directory]::CreateDirectory($root)
    $savedDataFolder = $env:DISKDETECTIVE_DATA
    $env:DISKDETECTIVE_DATA = [System.IO.Path]::Combine($root, "state")

    $source = [System.IO.Path]::Combine($root, "source")
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($source, "nested"))
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($source, "a.txt"), "one")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($source, "nested", "b.txt"), "two-two")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($source, "nested", "c.bin"), ("x" * 1000))

    Assert-True ((Test-SafeToMove $source) -eq $null) "a normal folder can be moved"
    if ($env:USERPROFILE) { Assert-True ((Test-SafeToMove $env:USERPROFILE) -ne $null) "the user profile itself is refused" }
    Assert-True ((Test-SafeToMove ([System.IO.Path]::GetPathRoot($root))) -ne $null) "a drive root is refused"

    $destination = [System.IO.Path]::Combine($root, "dest")
    [void][System.IO.Directory]::CreateDirectory($destination)

    $copyPath = [System.IO.Path]::Combine($destination, "copy")
    $copy = Copy-TreeVerified -Source $source -Destination $copyPath
    $sourceStats = Get-TreeStats $source
    $copyStats = Get-TreeStats $copyPath

    Assert-True ([bool]$copy.Ok) "files copy without errors"
    Assert-True ($copyStats.Files -eq $sourceStats.Files -and $copyStats.Bytes -eq $sourceStats.Bytes) "the copy matches size and file count"
    Assert-True (([System.IO.File]::ReadAllText([System.IO.Path]::Combine($copyPath, "nested", "b.txt"))) -eq "two-two") "file contents match"

    # A path longer than the old 260-character limit, like browser and tool caches.
    $longRoot = [System.IO.Path]::Combine($root, "long")
    $deep = $longRoot
    for ($i = 0; $i -lt 14; $i++) { $deep = [System.IO.Path]::Combine($deep, "segment-number-$i") }
    $longCreated = $false
    try {
        [void][System.IO.Directory]::CreateDirectory($deep)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($deep, "deep.txt"), "deep")
        $longCreated = $true
    } catch { $longCreated = $false }

    if ($longCreated) {
        $longOk = $false
        try {
            $longCopy = [System.IO.Path]::Combine($root, "longcopy")
            $copied = Copy-TreeVerified -Source $longRoot -Destination $longCopy
            $relative = $deep.Substring($longRoot.Length).TrimStart('\', '/')
            $longOk = [bool]$copied.Ok -and ($deep.Length -gt 260) -and (Test-Path -LiteralPath ([System.IO.Path]::Combine($longCopy, $relative, "deep.txt")))
        } catch { $longOk = $false }
        Assert-True $longOk "a very long path copies"
    } else {
        Write-Host "  SKIP  very long path (this machine does not allow long paths to be created)"
    }

    # Link inspection is what the repair feature depends on. Windows only lets
    # administrators or Developer Mode create symbolic links, so skip when blocked.
    $linkPath = [System.IO.Path]::Combine($root, "link")
    $linkOk = $false
    $linkBlocked = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $source -ErrorAction Stop | Out-Null
        $info = Get-LinkInfo $linkPath
        $linkOk = $info.IsLink -and ($info.Target -like "*source*")
    } catch { $linkBlocked = $true }
    if ($linkBlocked) {
        Write-Host "  SKIP  shortcut inspection (this system does not allow symbolic links)"
    } else {
        Assert-True $linkOk "a shortcut is recognised and its target is readable"
        if ($linkOk) {
            $removed = Remove-Link $linkPath
            Assert-True ($removed -and -not (Test-Path -LiteralPath $linkPath)) "removing a shortcut keeps the data behind it"
            Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($source, "a.txt"))) "the linked folder still exists"
        }
    }

    # Cloud folders must be refused even when they sit inside an allowed place.
    $savedOneDrive = $env:OneDrive
    $env:OneDrive = $source
    Assert-True ((Test-SafeToMove ([System.IO.Path]::Combine($source, "nested"))) -ne $null) "folders inside a cloud sync folder are refused"
    $env:OneDrive = $savedOneDrive

    Assert-True (@(Get-ProcessesUsing $source).Count -eq 0) "no program is reported for an unused folder"

    $moveSource = [System.IO.Path]::Combine($root, "movable")
    Copy-Item -LiteralPath $source -Destination $moveSource -Recurse

    # Moving within one drive would not free any space, so it must be refused.
    $sameDrive = Move-FolderWithLink -Source $moveSource -DestinationParent $destination
    Assert-True (-not $sameDrive.Ok -and $sameDrive.Message -match "same drive") "a move inside one drive is refused"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($moveSource, "nested", "b.txt"))) "a refused same-drive move changes nothing"

    if ($env:OS -eq "Windows_NT") {
        # Find another writable drive. CI machines often have only C:, so skip there.
        $otherBase = $null
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $drive.IsReady) { continue }
            if ($drive.RootDirectory.FullName -ieq [System.IO.Path]::GetPathRoot($root)) { continue }
            $candidate = $drive.RootDirectory.FullName
            if ($env:USERPROFILE -and ([System.IO.Path]::GetPathRoot($env:USERPROFILE) -ieq $drive.RootDirectory.FullName)) { $candidate = $env:USERPROFILE }
            $probe = [System.IO.Path]::Combine($candidate, "dd-move-probe-" + [guid]::NewGuid().ToString("N"))
            try {
                [void][System.IO.Directory]::CreateDirectory($probe)
                [void][System.IO.Directory]::Delete($probe)
                $otherBase = $candidate
                break
            } catch { }
        }
        if ($otherBase) {
            $otherDest = [System.IO.Path]::Combine($otherBase, "DiskDetectiveMoveTest-" + [guid]::NewGuid().ToString("N"))
            [void][System.IO.Directory]::CreateDirectory($otherDest)

            # A link inside the folder cannot be copied, so the move must refuse it.
            $linkedMoveSource = [System.IO.Path]::Combine($root, "linked-move")
            $linkedMoveTarget = [System.IO.Path]::Combine($root, "linked-move-target")
            [void][System.IO.Directory]::CreateDirectory($linkedMoveSource)
            [void][System.IO.Directory]::CreateDirectory($linkedMoveTarget)
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($linkedMoveSource, "a.txt"), "one")
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($linkedMoveTarget, "b.txt"), "two")
            if (New-Junction -Link ([System.IO.Path]::Combine($linkedMoveSource, "inside")) -Target $linkedMoveTarget) {
                $linkedStats = Get-TreeStats $linkedMoveSource
                Assert-True ($linkedStats.Links -ge 1) "a folder with a link inside is noticed"
                $linkedMove = Move-FolderWithLink -Source $linkedMoveSource -DestinationParent $otherDest
                Assert-True (-not $linkedMove.Ok -and $linkedMove.Message -match "shortcut or link") "a folder with a link inside is refused"
                Assert-True (Test-PathEntry ([System.IO.Path]::Combine($linkedMoveSource, "inside"))) "the refused folder keeps its link"
            } else {
                Write-Host "  SKIP  link-inside move refusal (this system does not allow junctions)"
            }

            $move = Move-FolderWithLink -Source $moveSource -DestinationParent $otherDest
            Assert-True ([bool]$move.Ok) "on Windows the folder is moved and linked"
            Assert-True (Test-Directory $moveSource) "the old location still exists as a shortcut"
            if ($move.Ok) {
                $movedInfo = Get-LinkInfo $moveSource
                Assert-True ($movedInfo.IsLink -and $movedInfo.Target) "the new shortcut points at the copied folder"
            }
            [void](Remove-TreeQuietly $otherDest)
        } else {
            Write-Host "  SKIP  real move (no second writable drive is available)"
        }
    } else {
        $move = Move-FolderWithLink -Source $moveSource -DestinationParent $destination
        Assert-True (-not $move.Ok) "a failed shortcut is reported instead of assumed"
        Assert-True (Test-Directory $moveSource) "the original folder is put back after a failed shortcut"
        Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($moveSource, "nested", "b.txt"))) "the put-back folder still has its files"
    }

    # Crash recovery: the source was renamed, the copy is complete, no shortcut yet.
    if ($env:OS -eq "Windows_NT") {
        $recoverRoot = [System.IO.Path]::Combine($root, "recover")
        $recoverSource = [System.IO.Path]::Combine($recoverRoot, "item")
        [void][System.IO.Directory]::CreateDirectory($recoverSource)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($recoverSource, "keep.txt"), "keep")
        $recoverCopy = [System.IO.Path]::Combine($recoverRoot, "copy")
        [void][System.IO.Directory]::CreateDirectory($recoverCopy)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($recoverCopy, "keep.txt"), "keep")
        $recoverBackup = "$recoverSource.moving"
        [System.IO.Directory]::Move($recoverSource, $recoverBackup)
        $recoverStats = Get-TreeStats $recoverCopy
        $entry = [pscustomobject]@{
            Id = [guid]::NewGuid().ToString("N"); Source = $recoverSource; Target = $recoverCopy
            Backup = $recoverBackup; Stage = "renamed"; At = (Get-Date).ToString("s")
            Bytes = [int64]$recoverStats.Bytes; Files = [int]$recoverStats.Files
        }
        [void](Write-MoveJournal @($entry))
        $fixed = @(Repair-PendingMoves)
        Assert-True ($fixed.Count -eq 1 -and $fixed[0].Completed) "an interrupted move is finished from the journal"
        Assert-True ((Get-LinkInfo $recoverSource).IsLink) "the recovered shortcut works"
        Assert-True (-not (Test-Path -LiteralPath $recoverBackup)) "the backup is removed after recovery"
        Assert-True (@(Read-MoveJournal).Count -eq 0) "the journal is cleared after recovery"
    } else {
        Write-Host "  SKIP  move recovery (needs Windows shortcuts)"
    }

    # Crash recovery: the copy was interrupted; the original never moved.
    $partialRoot = [System.IO.Path]::Combine($root, "partial")
    $partialSource = [System.IO.Path]::Combine($partialRoot, "original")
    $partialTarget = [System.IO.Path]::Combine($partialRoot, "partial-copy")
    [void][System.IO.Directory]::CreateDirectory($partialSource)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($partialSource, "safe.txt"), "safe")
    [void][System.IO.Directory]::CreateDirectory($partialTarget)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($partialTarget, "half.txt"), "ha")
    $partialSourceStats = Get-TreeStats $partialSource
    $partialEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $partialSource; Target = $partialTarget
        Backup = "$partialSource.moving"; Stage = "copying"; At = (Get-Date).ToString("s")
        Bytes = [int64]$partialSourceStats.Bytes; Files = [int]$partialSourceStats.Files
    }
    [void](Write-MoveJournal @($partialEntry))
    $partialFixed = @(Repair-PendingMoves)
    Assert-True ($partialFixed.Count -eq 1 -and $partialFixed[0].Outcome -eq "discarded") "an interrupted copy is cleaned up"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($partialSource, "safe.txt"))) "the original survives an interrupted copy"
    Assert-True (-not (Test-Path -LiteralPath $partialTarget)) "the unfinished copy is removed"

    # A completed move whose shortcut was later replaced by a normal folder:
    # the moved copy may be the only data, so it must not be deleted.
    $leftSource = [System.IO.Path]::Combine($root, "left-source")
    $leftTarget = [System.IO.Path]::Combine($root, "left-target")
    [void][System.IO.Directory]::CreateDirectory($leftSource)
    [void][System.IO.Directory]::CreateDirectory($leftTarget)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($leftSource, "keep.txt"), "keep")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($leftTarget, "keep.txt"), "keep")
    $leftStats = Get-TreeStats $leftTarget
    $leftEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $leftSource; Target = $leftTarget
        Backup = "$leftSource.moving"; Stage = "linked"; At = (Get-Date).ToString("s")
        Bytes = [int64]$leftStats.Bytes; Files = [int]$leftStats.Files
    }
    [void](Write-MoveJournal @($leftEntry))
    $leftFixed = @(Repair-PendingMoves)
    Assert-True ($leftFixed.Count -eq 1 -and $leftFixed[0].Outcome -eq "left") "a normal original leaves a completed move's copy alone"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($leftTarget, "keep.txt"))) "the completed copy is not deleted"
    Assert-True (@(Read-MoveJournal).Count -eq 0) "the journal is cleared after leaving the copy"

    # Even a complete copy labelled "copying" must not be deleted: the label
    # can be stale after a crash between the copy and the journal update.
    $fullSource = [System.IO.Path]::Combine($root, "full-source")
    $fullTarget = [System.IO.Path]::Combine($root, "full-target")
    [void][System.IO.Directory]::CreateDirectory($fullSource)
    [void][System.IO.Directory]::CreateDirectory($fullTarget)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($fullSource, "keep.txt"), "keep")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($fullTarget, "keep.txt"), "keep")
    $fullStats = Get-TreeStats $fullSource
    $fullEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $fullSource; Target = $fullTarget
        Backup = "$fullSource.moving"; Stage = "copying"; At = (Get-Date).ToString("s")
        Bytes = [int64]$fullStats.Bytes; Files = [int]$fullStats.Files
    }
    [void](Write-MoveJournal @($fullEntry))
    $fullFixed = @(Repair-PendingMoves)
    Assert-True ($fullFixed.Count -eq 1 -and $fullFixed[0].Outcome -eq "left") "a complete copy labelled copying is left alone"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($fullTarget, "keep.txt"))) "the complete copy survives a stale label"
    Assert-True (@(Read-MoveJournal).Count -eq 0) "the stale record is cleared"

    # A damaged record that points at the original folder must be ignored.
    $guardSource = [System.IO.Path]::Combine($root, "guard-source")
    [void][System.IO.Directory]::CreateDirectory($guardSource)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($guardSource, "keep.txt"), "keep")
    $guardEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $guardSource; Target = $guardSource
        Backup = "$guardSource.moving"; Stage = "copying"; At = (Get-Date).ToString("s")
        Bytes = [int64]4; Files = 1
    }
    [void](Write-MoveJournal @($guardEntry))
    $guardFixed = @(Repair-PendingMoves)
    Assert-True ($guardFixed.Count -eq 1 -and $guardFixed[0].Outcome -eq "broken") "a record that points at the original is refused"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($guardSource, "keep.txt"))) "the original survives a damaged recovery record"
    Assert-True (@(Read-MoveJournal).Count -eq 0) "the damaged record is removed"

    # A shortcut whose target is gone must still be recognised and put back.
    if ($env:OS -eq "Windows_NT") {
        $brokenRoot = [System.IO.Path]::Combine($root, "broken")
        $brokenSource = [System.IO.Path]::Combine($brokenRoot, "item")
        $brokenBackup = "$brokenSource.moving"
        $brokenTarget = [System.IO.Path]::Combine($brokenRoot, "copy")
        [void][System.IO.Directory]::CreateDirectory($brokenSource)
        [void][System.IO.Directory]::CreateDirectory($brokenTarget)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($brokenSource, "keep.txt"), "keep")
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($brokenTarget, "keep.txt"), "keep")
        [System.IO.Directory]::Move($brokenSource, $brokenBackup)
        if (New-Junction -Link $brokenSource -Target $brokenTarget) {
            [void](Remove-TreeQuietly $brokenTarget)
            $brokenInfo = Get-LinkInfo $brokenSource
            Assert-True ($brokenInfo.IsLink) "a shortcut whose target is gone is still recognised"
            $brokenStats = Get-TreeStats $brokenBackup
            $brokenEntry = [pscustomobject]@{
                Id = [guid]::NewGuid().ToString("N"); Source = $brokenSource; Target = $brokenTarget
                Backup = $brokenBackup; Stage = "linked"; At = (Get-Date).ToString("s")
                Bytes = [int64]$brokenStats.Bytes; Files = [int]$brokenStats.Files
            }
            [void](Write-MoveJournal @($brokenEntry))
            $brokenFixed = @(Repair-PendingMoves)
            Assert-True ($brokenFixed.Count -eq 1 -and $brokenFixed[0].Outcome -eq "put-back") "a broken shortcut is put back from the backup"
            Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($brokenSource, "keep.txt"))) "the put-back folder has its file"
            Assert-True (-not (Test-PathEntry $brokenBackup)) "the backup is gone after putting it back"
        } else {
            Write-Host "  SKIP  broken-shortcut recovery (this system does not allow junctions)"
        }
    }

    # Non-English folder names must survive the journal on PS 5.1.
    $unicodeSource = [System.IO.Path]::Combine($root, ("caf" + [char]0x00E9))
    [void][System.IO.Directory]::CreateDirectory($unicodeSource)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($unicodeSource, "keep.txt"), "keep")
    $unicodeEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $unicodeSource; Target = "$unicodeSource-copy"
        Backup = "$unicodeSource.moving"; Stage = "copying"; At = (Get-Date).ToString("s")
        Bytes = [int64]4; Files = 1
    }
    [void](Write-MoveJournal @($unicodeEntry))
    $unicodeRead = @(Read-MoveJournal)
    Assert-True ($unicodeRead.Count -eq 1 -and $unicodeRead[0].Source -eq $unicodeSource) "a non-English folder name survives the journal"
    [void](Remove-MoveJournalEntry $unicodeEntry.Id)

    # A recreated original folder alongside a backup must not cause deletion.
    $conflictRoot = [System.IO.Path]::Combine($root, "conflict")
    $conflictSource = [System.IO.Path]::Combine($conflictRoot, "item")
    $conflictTarget = [System.IO.Path]::Combine($conflictRoot, "copy")
    $conflictBackup = "$conflictSource.moving"
    [void][System.IO.Directory]::CreateDirectory($conflictSource)
    [void][System.IO.Directory]::CreateDirectory($conflictTarget)
    [void][System.IO.Directory]::CreateDirectory($conflictBackup)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($conflictSource, "new.txt"), "new")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($conflictTarget, "keep.txt"), "keep")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($conflictBackup, "old.txt"), "old")
    $conflictStats = Get-TreeStats $conflictTarget
    $conflictEntry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString("N"); Source = $conflictSource; Target = $conflictTarget
        Backup = $conflictBackup; Stage = "renamed"; At = (Get-Date).ToString("s")
        Bytes = [int64]$conflictStats.Bytes; Files = [int]$conflictStats.Files
    }
    [void](Write-MoveJournal @($conflictEntry))
    $conflictFixed = @(Repair-PendingMoves)
    Assert-True ($conflictFixed.Count -eq 1 -and $conflictFixed[0].Outcome -eq "stuck") "a recreated original and a backup are left alone"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($conflictSource, "new.txt"))) "the recreated original survives"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($conflictTarget, "keep.txt"))) "the copy survives the conflict"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($conflictBackup, "old.txt"))) "the backup survives the conflict"
    Assert-True (@(Read-MoveJournal).Count -eq 1) "the conflict record is kept"
    [void](Remove-MoveJournalEntry $conflictEntry.Id)

    # An unplugged source drive is not a missing folder; the record must wait.
    $freeLetter = ""
    foreach ($letter in @("Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
        if (-not (Test-Path -LiteralPath "${letter}:\")) { $freeLetter = $letter; break }
    }
    if ($freeLetter) {
        $goneSource = "${freeLetter}:\DiskDetectiveMissing\item"
        $goneEntry = [pscustomobject]@{
            Id = [guid]::NewGuid().ToString("N"); Source = $goneSource; Target = $leftTarget
            Backup = "$goneSource.moving"; Stage = "copying"; At = (Get-Date).ToString("s")
            Bytes = [int64]4; Files = 1
        }
        [void](Write-MoveJournal @($goneEntry))
        $goneFixed = @(Repair-PendingMoves)
        Assert-True ($goneFixed.Count -eq 1 -and $goneFixed[0].Outcome -eq "waiting") "an unplugged source drive keeps its recovery record"
        Assert-True (@(Read-MoveJournal).Count -eq 1) "the record waits for the unplugged drive"
        [void](Remove-MoveJournalEntry $goneEntry.Id)
    } else {
        Write-Host "  SKIP  unplugged-drive recovery (every drive letter is in use)"
    }

    Assert-True (Enter-OperationLock) "the change lock can be taken"
    Exit-OperationLock

    [void](Remove-MoveJournalEntry $partialEntry.Id)
    $env:DISKDETECTIVE_DATA = $savedDataFolder
    [void](Remove-TreeQuietly $root)

    if ($script:failures -gt 0) {
        Write-Host "SELFTEST_FAILED ($script:failures)"
        exit 1
    }
    Write-Host "SELFTEST_OK"
    exit 0
}
