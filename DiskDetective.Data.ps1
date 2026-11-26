#requires -Version 5.1
<#
    Disk Detective - data layer
    A reversible "Trash" on each drive, a history of every change, shortcut
    health checks, a whole-drive scan, duplicate finding, Windows reserves and
    a shareable report.

    Loaded by DiskDetective.ps1. Runs on its own only for tests:
        powershell -ExecutionPolicy Bypass -File .\DiskDetective.Data.ps1 -SelfTest
#>
param([switch]$SelfTest)
$runSelfTest = [bool]$SelfTest

$script:DDPeopleLoaded = $true

if (-not $script:DDToolsLoaded) { . (Join-Path $PSScriptRoot "DiskDetective.Tools.ps1") }

# ---------------------------------------------------------------- storage

$script:DataFolder = $null

function Get-DataFolder {
    if ($script:DataFolder) { return $script:DataFolder }
    $candidate = $env:DISKDETECTIVE_DATA
    if (-not $candidate) {
        if ($env:LOCALAPPDATA) { $candidate = [System.IO.Path]::Combine($env:LOCALAPPDATA, "DiskDetective") }
        elseif ($env:APPDATA) { $candidate = [System.IO.Path]::Combine($env:APPDATA, "DiskDetective") }
        else { $candidate = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "DiskDetective") }
    }
    try {
        if (-not (Test-Path -LiteralPath $candidate)) { [void][System.IO.Directory]::CreateDirectory($candidate) }
        $probe = [System.IO.Path]::Combine($candidate, ".writable")
        Set-Content -LiteralPath $probe -Value "ok" -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        $candidate = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "DiskDetective")
        try { if (-not (Test-Path -LiteralPath $candidate)) { [void][System.IO.Directory]::CreateDirectory($candidate) } } catch { }
    }
    $script:DataFolder = $candidate
    return $candidate
}

function Get-DataFile {
    param([string]$Name)
    return [System.IO.Path]::Combine((Get-DataFolder), $Name)
}

function Read-JsonList {
    param([string]$Name)
    $path = Get-DataFile $Name
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        # Files are written as UTF-8; PS 5.1 would otherwise read them in the
        # system code page and corrupt non-English folder names.
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return @() }
        return @($data)
    } catch {
        return @()
    }
}

function Write-JsonList {
    param([string]$Name, [object[]]$Items)
    $path = Get-DataFile $Name
    $list = @($Items)
    if ($list.Count -eq 0) {
        $json = "[]"
    } else {
        $json = ConvertTo-Json -InputObject $list -Depth 8
    }
    $temp = "$path.tmp"
    try {
        Set-Content -LiteralPath $temp -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        try {
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
}

function Get-Settings {
    $settings = [pscustomobject]@{ LargeText = $false; LastDrive = "" }
    $path = Get-DataFile "settings.json"
    if (-not (Test-Path -LiteralPath $path)) { return $settings }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $settings }
        $saved = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($saved.PSObject.Properties["LargeText"]) { $settings.LargeText = [bool]$saved.LargeText }
        if ($saved.PSObject.Properties["LastDrive"]) { $settings.LastDrive = [string]$saved.LastDrive }
    } catch { }
    return $settings
}

function Save-Settings {
    param([bool]$LargeText, [string]$LastDrive = "")
    $path = Get-DataFile "settings.json"
    $data = [pscustomobject]@{ LargeText = $LargeText; LastDrive = $LastDrive }
    try {
        $json = ConvertTo-Json -InputObject $data -Depth 4
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ---------------------------------------------------------------- trash

function Get-QuarantineFolder {
    param([string]$Path)
    if ($env:DISKDETECTIVE_TRASH) { return $env:DISKDETECTIVE_TRASH }
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if (-not $root) { $root = [System.IO.Path]::GetTempPath() }
    return [System.IO.Path]::Combine($root, ".diskdetective-trash")
}

function Ensure-QuarantineFolder {
    param([string]$Path)
    $folder = Get-QuarantineFolder $Path
    if (-not (Test-Path -LiteralPath $folder)) {
        [void][System.IO.Directory]::CreateDirectory($folder)
        if ($env:OS -eq "Windows_NT") {
            try { & $env:ComSpec /c "attrib +h +s `"$folder`"" 2>&1 | Out-Null } catch { }
        }
    }
    return $folder
}

# Reversible removal: the item is renamed into a hidden folder on the same
# drive, so it is instant, needs no extra space, and can always be put back.
# The Recycle Bin is not used because Windows silently deletes items that do
# not fit inside it.
function Move-ToQuarantine {
    param([object[]]$Items, [string]$Reason = "")

    $removed = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    $entries = @(Read-JsonList "trash.json")

    foreach ($item in $Items) {
        if (-not $item) { continue }
        $path = [string]$item.Path
        try {
            if (-not $path) { continue }
            if ($item.Risk -eq "protected") {
                [void]$failed.Add([pscustomobject]@{ Path = $path; Reason = "Protected: this app never deletes save data." })
                continue
            }
            if (-not (Test-Path -LiteralPath $path)) {
                [void]$failed.Add([pscustomobject]@{ Path = $path; Reason = "It is already gone." })
                continue
            }
            if (Test-ExcludedPath $path) {
                [void]$failed.Add([pscustomobject]@{ Path = $path; Reason = "You asked Disk Detective to leave this one alone." })
                continue
            }

            $bytes = [int64]0
            if ($item.PSObject.Properties["Bytes"] -and $item.Bytes) { $bytes = [int64]$item.Bytes }
            else { $bytes = [int64](Get-TreeStats $path).Bytes }

            $folder = Ensure-QuarantineFolder $path
            $id = [guid]::NewGuid().ToString("N")
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $leaf = [System.IO.Path]::GetFileName($path.TrimEnd('\', '/'))
            if (-not $leaf) { $leaf = "item" }
            $target = [System.IO.Path]::Combine($folder, ("{0}-{1}-{2}" -f $stamp, $id.Substring(0, 6), $leaf))

            Move-Item -LiteralPath $path -Destination $target -Force -ErrorAction Stop

            $entry = [pscustomobject]@{
                Id           = $id
                Name         = $leaf
                OriginalPath = $path
                TrashPath    = $target
                Bytes        = $bytes
                At           = (Get-Date).ToString("s")
                Risk         = [string]$item.Risk
                What         = [string]$item.Title
                Reason       = $Reason
                RestoredAt   = $null
            }
            $entries += $entry
            if (-not (Write-JsonList "trash.json" $entries)) {
                # Without a record the item could never be put back, so undo the move.
                try { Move-Item -LiteralPath $target -Destination $path -Force -ErrorAction Stop } catch { }
                $entries = @($entries | Where-Object { $_.Id -ne $entry.Id })
                [void]$failed.Add([pscustomobject]@{ Path = $path; Reason = "The Trash list could not be saved, so nothing was moved." })
                continue
            }
            [void]$removed.Add([pscustomobject]@{ Path = $path; Bytes = $bytes; Name = $leaf; Entry = $entry })
        } catch {
            [void]$failed.Add([pscustomobject]@{ Path = $path; Reason = $_.Exception.Message })
        }
    }

    return [pscustomobject]@{ Removed = @($removed); Failed = @($failed) }
}

function Get-TrashEntries {
    return @(Read-JsonList "trash.json" | Where-Object { -not $_.RestoredAt })
}

function Set-RecordField {
    param($Record, [string]$Name, $Value)
    if (-not $Record) { return }
    if ($Record.PSObject.Properties[$Name]) { $Record.$Name = $Value }
    else { $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Restore-TrashEntry {
    param([string]$Id)
    $all = @(Read-JsonList "trash.json")
    $entry = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $entry) { return [pscustomobject]@{ Ok = $false; Message = "That item is no longer in the list." } }
    if (-not (Test-Path -LiteralPath $entry.TrashPath)) {
        return [pscustomobject]@{ Ok = $false; Message = "The saved copy is missing from $($entry.TrashPath)." }
    }
    if (Test-Path -LiteralPath $entry.OriginalPath) {
        return [pscustomobject]@{ Ok = $false; Message = "Something already exists at $($entry.OriginalPath). Rename or move it first." }
    }
    try {
        $parent = [System.IO.Path]::GetDirectoryName($entry.OriginalPath)
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        Move-Item -LiteralPath $entry.TrashPath -Destination $entry.OriginalPath -Force -ErrorAction Stop
        Set-RecordField -Record $entry -Name "RestoredAt" -Value ((Get-Date).ToString("s"))
        [void](Write-JsonList "trash.json" $all)
        return [pscustomobject]@{ Ok = $true; Message = "Put back at $($entry.OriginalPath)." }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Remove-TrashEntry {
    param([string]$Id)
    $all = @(Read-JsonList "trash.json")
    $entry = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $entry) { return [pscustomobject]@{ Ok = $false; Message = "That item is no longer in the list." } }
    try {
        if (Test-Path -LiteralPath $entry.TrashPath) {
            if (-not (Remove-TreeQuietly $entry.TrashPath)) {
                return [pscustomobject]@{ Ok = $false; Message = "Windows would not delete it - something may still be using it." }
            }
        }
        Set-RecordField -Record $entry -Name "RestoredAt" -Value "deleted"
        [void](Write-JsonList "trash.json" $all)
        return [pscustomobject]@{ Ok = $true; Message = "Deleted for good." }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- move history

function Get-MoveRecords {
    return @(Read-JsonList "moves.json")
}

function Add-MoveRecord {
    param([string]$Source, [string]$Target, [int64]$Bytes, [int]$Files)
    $record = [pscustomobject]@{
        Id       = [guid]::NewGuid().ToString("N")
        Source   = $Source
        Target   = $Target
        Bytes    = $Bytes
        Files    = $Files
        At       = (Get-Date).ToString("s")
        Status   = "ok"
        Leftover = ""
    }
    $all = @(Read-JsonList "moves.json")
    $all += $record
    [void](Write-JsonList "moves.json" $all)
    return $record
}

function Update-MoveRecord {
    param([string]$Id, [hashtable]$Fields)
    $all = @(Read-JsonList "moves.json")
    foreach ($record in $all) {
        if ($record.Id -eq $Id) {
            foreach ($key in $Fields.Keys) {
                if ($record.PSObject.Properties[$key]) { $record.$key = $Fields[$key] }
                else { $record | Add-Member -NotePropertyName $key -NotePropertyValue $Fields[$key] -Force }
            }
        }
    }
    [void](Write-JsonList "moves.json" $all)
}

function Test-MoveHealth {
    param($Record)
    if (-not $Record) { return [pscustomobject]@{ Status = "unknown"; Text = "No record." } }

    $link = Get-LinkInfo $Record.Source
    if (-not $link.Exists) {
        return [pscustomobject]@{ Status = "missing-source"; Text = "The old place is gone entirely." }
    }
    if (-not $link.IsLink) {
        return [pscustomobject]@{ Status = "not-a-link"; Text = "This is a normal folder again, not a shortcut." }
    }
    if (-not (Test-Path -LiteralPath $Record.Target)) {
        return [pscustomobject]@{ Status = "missing-target"; Text = "The data folder is missing: $($Record.Target)" }
    }
    if (-not $link.Target) {
        return [pscustomobject]@{ Status = "unknown-target"; Text = "The shortcut works, but its target could not be read." }
    }
    return [pscustomobject]@{ Status = "ok"; Text = "Works. Points at $($Record.Target)" }
}

function Repair-Move {
    param([string]$Id, [string]$NewParent, [scriptblock]$Progress)

    $all = @(Read-JsonList "moves.json")
    $record = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $record) { return [pscustomobject]@{ Ok = $false; Message = "That move is not in the history." } }
    if (-not (Test-Path -LiteralPath $record.Target)) {
        return [pscustomobject]@{ Ok = $false; Message = "The data folder itself is missing: $($record.Target). Use Undo only if you know where it went." }
    }

    $target = $record.Target
    if ($NewParent) {
        if (-not (Test-Directory $NewParent)) { return [pscustomobject]@{ Ok = $false; Message = "That new place does not exist." } }
        $leaf = [System.IO.Path]::GetFileName($record.Target)
        $newTarget = [System.IO.Path]::Combine($NewParent, $leaf)
        if (Test-Path -LiteralPath $newTarget) { return [pscustomobject]@{ Ok = $false; Message = "Something already exists at $newTarget." } }
        $before = Get-TreeStats $record.Target
        $copy = Copy-TreeVerified -Source $record.Target -Destination $newTarget -Progress $Progress
        if (-not $copy.Ok) {
            [void](Remove-TreeQuietly $newTarget)
            return [pscustomobject]@{ Ok = $false; Message = "The copy failed: $($copy.Error)" }
        }
        $after = Get-TreeStats $newTarget
        if ($after.Bytes -ne $before.Bytes -or $after.Files -ne $before.Files) {
            [void](Remove-TreeQuietly $newTarget)
            return [pscustomobject]@{ Ok = $false; Message = "The copy at $newTarget did not match, so it was removed. Nothing was changed." }
        }
        if (-not (Remove-TreeQuietly $record.Target)) {
            return [pscustomobject]@{ Ok = $false; Message = "The folder was copied to $newTarget but the old copy could not be removed. Both copies are intact." }
        }
        $target = $newTarget
    }

    $link = Get-LinkInfo $record.Source
    if ($link.IsLink) {
        [void](Remove-Link $record.Source)
    } elseif ($link.Exists) {
        return [pscustomobject]@{ Ok = $false; Message = "There is a normal folder at the old place now, so nothing was changed." }
    }

    if (-not (New-Junction -Link $record.Source -Target $target)) {
        return [pscustomobject]@{ Ok = $false; Message = "The shortcut could not be recreated. Your data is safe at $target." }
    }

    Update-MoveRecord -Id $Id -Fields @{ Target = $target; Status = "ok" }
    return [pscustomobject]@{ Ok = $true; Message = "Shortcut repaired. It now points at $target." }
}

function Undo-Move {
    param([string]$Id, [scriptblock]$Progress)

    $all = @(Read-JsonList "moves.json")
    $record = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $record) { return [pscustomobject]@{ Ok = $false; Message = "That move is not in the history." } }
    if (-not (Test-Directory $record.Target)) {
        return [pscustomobject]@{ Ok = $false; Message = "The data folder is missing from $($record.Target), so it cannot be put back." }
    }

    $link = Get-LinkInfo $record.Source
    if ($link.IsLink) { [void](Remove-Link $record.Source) }
    elseif ($link.Exists) { return [pscustomobject]@{ Ok = $false; Message = "A normal folder already exists at the old place." } }

    $stats = Get-TreeStats $record.Target
    if ($Progress) { & $Progress "Copying $(Format-Size $stats.Bytes) back..." }
    $copy = Copy-TreeVerified -Source $record.Target -Destination $record.Source -Progress $Progress
    if (-not $copy.Ok) {
        [void](Remove-TreeQuietly $record.Source)
        [void](New-Junction -Link $record.Source -Target $record.Target)
        return [pscustomobject]@{ Ok = $false; Message = "The copy back failed ($($copy.Error)), so the shortcut was restored. Nothing was lost." }
    }

    $backStats = Get-TreeStats $record.Source
    if ($backStats.Bytes -ne $stats.Bytes -or $backStats.Files -ne $stats.Files) {
        [void](Remove-TreeQuietly $record.Source)
        [void](New-Junction -Link $record.Source -Target $record.Target)
        return [pscustomobject]@{ Ok = $false; Message = "The copy back did not match, so the folder was removed and the shortcut restored. Nothing was lost." }
    }

    if (-not (Remove-TreeQuietly $record.Target)) {
        Update-MoveRecord -Id $Id -Fields @{ Status = "copied-back" }
        return [pscustomobject]@{ Ok = $false; Message = "The folder is back, but the extra copy at $($record.Target) could not be removed. You can delete it yourself." }
    }

    Update-MoveRecord -Id $Id -Fields @{ Status = "undone" }
    return [pscustomobject]@{ Ok = $true; Message = "Put back at $($record.Source). The shortcut is gone." }
}

# ---------------------------------------------------------------- exclusions

function Get-NormalPath {
    param([string]$Path)
    if (-not $Path) { return "" }
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/') } catch { return $Path.TrimEnd('\', '/') }
}

function Get-Exclusions {
    return @(Read-JsonList "exclusions.json")
}

function Add-Exclusion {
    param([string]$Path, [string]$Note = "")
    $full = Get-NormalPath $Path
    if (-not $full) { return $false }
    $all = @(Read-JsonList "exclusions.json")
    foreach ($existing in $all) {
        if ((Get-NormalPath $existing.Path) -eq $full) { return $false }
    }
    $all += [pscustomobject]@{ Path = $full; Note = $Note; At = (Get-Date).ToString("s") }
    [void](Write-JsonList "exclusions.json" $all)
    return $true
}

function Remove-Exclusion {
    param([string]$Path)
    $full = Get-NormalPath $Path
    $all = @(Read-JsonList "exclusions.json")
    $kept = @($all | Where-Object { (Get-NormalPath $_.Path) -ne $full })
    [void](Write-JsonList "exclusions.json" $kept)
    return ($kept.Count -ne $all.Count)
}

function Test-ExcludedPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $full = (Get-NormalPath $Path).ToLowerInvariant()
    foreach ($exclusion in (Get-Exclusions)) {
        $other = (Get-NormalPath $exclusion.Path).ToLowerInvariant()
        if (-not $other) { continue }
        if ($full -eq $other -or $full.StartsWith($other + [System.IO.Path]::DirectorySeparatorChar)) { return $true }
    }
    return $false
}

function Remove-ExcludedItems {
    param([object[]]$Items)
    return @($Items | Where-Object { -not (Test-ExcludedPath $_.Path) })
}

# ---------------------------------------------------------------- drive scan

# One pass over the whole drive: every folder's size is accumulated from its
# children, so the biggest folders can be listed no matter how deep they are.
function Get-DriveScan {
    param(
        [string]$Root,
        [int]$FolderCount = 300,
        [int]$FileCount = 100,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop
    )

    $start = Get-Date
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $sizes = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $bigFiles = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $counter = 0
    $skipNames = @('$Recycle.Bin', 'System Volume Information', '.diskdetective-trash')

    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ Path = $rootFull; Entries = $null; Index = 0; Bytes = [int64]0; Files = 0; Last = $null; Parent = $null })

    while ($stack.Count -gt 0) {
        $frame = $stack.Peek()

        if ($null -eq $frame.Entries) {
            try {
                $frame.Entries = @([System.IO.Directory]::GetFileSystemEntries($frame.Path))
            } catch {
                [void]$errors.Add("$($frame.Path): $($_.Exception.Message)")
                $frame.Entries = @()
            }
            try { $frame.Last = [System.IO.Directory]::GetLastWriteTime($frame.Path) } catch { }
        }

        if ($frame.Index -lt $frame.Entries.Count) {
            $entry = $frame.Entries[$frame.Index]
            $frame.Index++
            $counter++

            if (($counter % 400) -eq 0) {
                if ($ShouldStop -and (& $ShouldStop)) { throw "Cancelled." }
                if ($Progress) { & $Progress $frame.Path }
            }

            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($entry) } catch { continue }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $leaf = [System.IO.Path]::GetFileName($entry)
                if ($skipNames -contains $leaf) { continue }
                $stack.Push(@{ Path = $entry; Entries = $null; Index = 0; Bytes = [int64]0; Files = 0; Last = $null; Parent = $frame })
            } else {
                try {
                    $file = New-Object System.IO.FileInfo($entry)
                    $length = $file.Length
                    $frame.Bytes += $length
                    $frame.Files++
                    if ($length -ge 10485760) {
                        [void]$bigFiles.Add([pscustomobject]@{
                            Path = $entry
                            Name = $file.Name
                            Bytes = [int64]$length
                            LastUsed = $file.LastWriteTime
                        })
                    }
                } catch { }
            }
        } else {
            [void]$stack.Pop()
            $name = [System.IO.Path]::GetFileName($frame.Path)
            if (-not $name) { $name = $frame.Path }
            $sizes[$frame.Path] = [pscustomobject]@{
                Path = $frame.Path
                Name = $name
                Bytes = [int64]$frame.Bytes
                Files = $frame.Files
                LastUsed = $frame.Last
            }
            if ($frame.Parent) {
                $frame.Parent.Bytes += $frame.Bytes
                $frame.Parent.Files += $frame.Files
            }
        }
    }

    $all = @($sizes.Values)
    $joinFolders = @($all | Sort-Object Bytes -Descending | Select-Object -First $FolderCount)
    $joinFiles = @($bigFiles | Sort-Object Bytes -Descending | Select-Object -First $FileCount)

    $rootEntry = $sizes[$rootFull]
    return [pscustomobject]@{
        Root          = $rootFull
        Folders       = $joinFolders
        Files         = $joinFiles
        TotalFolders  = $all.Count
        FolderBytes   = $(if ($rootEntry) { [int64]$rootEntry.Bytes } else { [int64]0 })
        FolderFiles   = $(if ($rootEntry) { [int]$rootEntry.Files } else { 0 })
        Errors        = @($errors)
        Seconds       = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    }
}

function Get-AllFiles {
    param(
        [string]$Root,
        [int64]$MinBytes = 0,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop
    )

    $found = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push([System.IO.Path]::GetFullPath($Root))
    $skipNames = @('$Recycle.Bin', 'System Volume Information', '.diskdetective-trash', 'Windows', 'WinSxS', 'node_modules', 'Program Files', 'Program Files (x86)')
    $count = 0

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($entry in $entries) {
            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($entry) } catch { continue }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if ($skipNames -contains [System.IO.Path]::GetFileName($entry)) { continue }
                $stack.Push($entry)
            } else {
                $count++
                if (($count % 500) -eq 0) {
                    if ($ShouldStop -and (& $ShouldStop)) { throw "Cancelled." }
                    if ($Progress) { & $Progress $dir }
                }
                try {
                    $length = ([System.IO.FileInfo]$entry).Length
                    if ($length -ge $MinBytes) { [void]$found.Add([pscustomobject]@{ Path = $entry; Bytes = [int64]$length }) }
                } catch { }
            }
        }
    }

    return @($found)
}

function Find-Duplicates {
    param(
        [string]$Root,
        [int64]$MinBytes = 1048576,
        [int]$MaxFiles = 8000,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop
    )

    $files = @(Get-AllFiles -Root $Root -MinBytes $MinBytes -Progress $Progress -ShouldStop $ShouldStop)
    if ($files.Count -gt $MaxFiles) {
        $files = @($files | Sort-Object Bytes -Descending | Select-Object -First $MaxFiles)
    }

    $groups = New-Object System.Collections.ArrayList
    $bySize = @{}
    foreach ($file in $files) {
        $key = [string]$file.Bytes
        if (-not $bySize.ContainsKey($key)) { $bySize[$key] = New-Object System.Collections.ArrayList }
        [void]$bySize[$key].Add($file)
    }

    $hashed = 0
    foreach ($key in $bySize.Keys) {
        $bucketFiles = $bySize[$key]
        if ($bucketFiles.Count -lt 2) { continue }
        if ($ShouldStop -and (& $ShouldStop)) { throw "Cancelled." }

        $byHash = @{}
        foreach ($file in $bucketFiles) {
            $hash = $null
            try { $hash = (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { continue }
            if (-not $hash) { continue }
            if (-not $byHash.ContainsKey($hash)) { $byHash[$hash] = New-Object System.Collections.ArrayList }
            [void]$byHash[$hash].Add($file)
            $hashed++
            if ($Progress -and (($hashed % 40) -eq 0)) { & $Progress $file.Path }
        }

        foreach ($hash in $byHash.Keys) {
            $same = $byHash[$hash]
            if ($same.Count -lt 2) { continue }
            [void]$groups.Add([pscustomobject]@{
                Hash  = $hash
                Bytes = [int64]$same[0].Bytes
                Files = @($same)
            })
        }
    }

    return @($groups | Sort-Object { $_.Bytes * ($_.Files.Count - 1) } -Descending)
}

function Get-DuplicateWaste {
    param([object[]]$Groups)
    $total = [int64]0
    foreach ($group in $Groups) { $total += [int64]$group.Bytes * ($group.Files.Count - 1) }
    return $total
}

# ---------------------------------------------------------------- explanation

# Explains a folder that is not in the built-in cache list, by looking for
# markers that identify the app that owns it.
function Get-FolderExplanation {
    param([string]$Path)

    $name = [System.IO.Path]::GetFileName($Path.TrimEnd('\', '/'))
    $lower = $Path.ToLowerInvariant()
    $leaf = $name.ToLowerInvariant()

    $markers = @(
        @{ Match = 'dxcache|d3dscache'; Title = "Graphics shader cache"; Risk = "safe";
           What = "A store of compiled graphics instructions that your graphics card builds while you play.";
           Why = "It is a cache, so it exists only to make games start faster.";
           Impact = "The cache rebuilds itself the next time you play, which is why it grows back over time." },
        @{ Match = 'shadercache|shader_cache'; Title = "Shader cache"; Risk = "safe";
           What = "Compiled graphics programs kept so a game does not have to rebuild them.";
           Why = "Games recreate these files automatically.";
           Impact = "The first launch after removing it is slower, and then it is back to normal." },
        @{ Match = 'npm-cache|npm_cache'; Title = "npm download cache"; Risk = "safe";
           What = "Downloaded copies of JavaScript packages kept by Node.js.";
           Why = "It is a cache: it saves re-downloading the same packages.";
           Impact = "npm downloads packages again when needed. Nothing is lost." },
        @{ Match = '\.gradle|gradle'; Title = "Gradle build cache"; Risk = "safe";
           What = "Downloaded build tools and compiled build outputs from Android or Java projects.";
           Why = "Gradle keeps these so future builds are faster.";
           Impact = "The next build re-downloads and rebuilds what it needs." },
        @{ Match = 'cache_data|cache_data|code cache|gpucache'; Title = "Chromium browser cache"; Risk = "safe";
           What = "Web pages, images and scripts a Chromium-based browser kept to load sites faster.";
           Why = "This is a copy of things that live on the internet.";
           Impact = "Websites load a little slower once; pages you were signed in to stay signed in." },
        @{ Match = 'crashdump|crashpad|wer'; Title = "Crash reports"; Risk = "low";
           What = "Small files written when a program crashed.";
           Why = "They wait for you or the app maker to send them in.";
           Impact = "Old crash reports are only useful to developers. New ones appear if something crashes." },
        @{ Match = '\\temp$|\\tmp$|\\temp\\'; Title = "Temporary files"; Risk = "safe";
           What = "Scratch files programs created and did not clean up.";
           Why = "Programs expect temp files to be disposable.";
           Impact = "A program may briefly re-create what it needs. Nothing important is stored only here." },
        @{ Match = 'logs?$'; Title = "Log files"; Risk = "low";
           What = "Diary files an app writes about what it did.";
           Why = "They are kept for troubleshooting.";
           Impact = "Troubleshooting history is lost. The app keeps working normally." },
        @{ Match = 'packages?$'; Title = "Application packages"; Risk = "caution";
           What = "Installer or update files kept by an app or the Microsoft Store.";
           Why = "Apps keep them so they can repair or update themselves.";
           Impact = "An app may need to re-download an update. Check this one before removing it." },
        @{ Match = 'node_modules'; Title = "Project dependencies"; Risk = "caution";
           What = "Code libraries downloaded for a programming project.";
           Why = "They are needed while the project is being built.";
           Impact = "The project needs 'npm install' again before it runs." },
        @{ Match = 'downloads?$'; Title = "Your Downloads folder"; Risk = "caution";
           What = "Files you downloaded from the internet.";
           Why = "Only you know what you still need.";
           Impact = "Anything removed here is something you chose to keep. Read the list first." },
        @{ Match = 'saved games|savegames|save game'; Title = "Saved games"; Risk = "protected";
           What = "Your game progress.";
           Why = "Games write here when you save.";
           Impact = "This is never deleted: progress cannot be re-downloaded." },
        @{ Match = 'onedrive'; Title = "OneDrive sync folder"; Risk = "caution";
           What = "Files kept in step with your Microsoft account.";
           Why = "OneDrive manages this folder; removing files changes the cloud copy too.";
           Impact = "Deleting here deletes the cloud copy as well. Leave it alone unless you mean it." },
        @{ Match = 'steamapps'; Title = "Steam games"; Risk = "caution";
           What = "Installed games and their data.";
           Why = "Steam stores game files here.";
           Impact = "Removing game files means downloading the game again. Use Steam to uninstall games." }
    )

    $match = $null
    foreach ($marker in $markers) {
        if ($lower -match $marker.Match -or $leaf -match $marker.Match) { $match = $marker; break }
    }

    $publisher = $null
    try {
        $exe = Get-ChildItem -LiteralPath $Path -Filter *.exe -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) {
            $description = $exe.VersionInfo.FileDescription
            $company = $exe.VersionInfo.CompanyName
            if ($company) { $publisher = $company }
            elseif ($description) { $publisher = $description }
        }
    } catch { }

    if ($match) {
        $suffix = ""
        if ($publisher) { $suffix = " It seems to belong to $publisher." }
        return [pscustomobject]@{
            Title  = $match.Title
            Risk   = $match.Risk
            What   = $match.What + $suffix
            Why    = $match.Why
            Impact = $match.Impact
            Known  = $true
        }
    }

    $stats = Get-TreeStats $Path
    $what = "A folder or file called '$name'. Nothing in Disk Detective's list of well-known caches matches it."
    if ($publisher) { $what = "$what It contains a program made by $publisher." }
    return [pscustomobject]@{
        Title  = "Unknown folder: $name"
        Risk   = "caution"
        What   = $what
        Why    = "It holds $(Format-Size $stats.Bytes) in $($stats.Files) file(s). Some apps keep data they need here, not just caches."
        Impact = "Check what is inside before removing it, or move it instead of deleting it - moving keeps a working shortcut."
        Known  = $false
    }
}

# ---------------------------------------------------------------- reserves

$script:RecycleSignature = @'
using System;
using System.Runtime.InteropServices;

public static class DDRecycle
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SHQUERYRBINFO
    {
        public uint cbSize;
        public long i64Size;
        public long i64NumItems;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);
}
'@

function Get-RecycleBinInfo {
    param([string]$Root)
    $info = [pscustomobject]@{ Available = $false; Bytes = [int64]0; Items = 0 }
    if ($env:OS -ne "Windows_NT") { return $info }
    try {
        if (-not ("DDRecycle" -as [type])) { Add-Type -TypeDefinition $script:RecycleSignature }
        $data = [DDRecycle+SHQUERYRBINFO]::new()
        $data.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($data)
        $code = [DDRecycle]::SHQueryRecycleBin($Root, [ref]$data)
        if ($code -eq 0) {
            $info.Available = $true
            $info.Bytes = [int64]$data.i64Size
            $info.Items = [int]$data.i64NumItems
        }
    } catch { }
    return $info
}

function Get-SystemReserves {
    param([scriptblock]$Progress)
    $items = New-Object System.Collections.ArrayList
    if ($env:OS -ne "Windows_NT") { return @() }

    $rootPath = $env:SystemDrive
    if (-not $rootPath) { $rootPath = [System.IO.Path]::GetPathRoot($env:WINDIR) }
    $rootPath = $rootPath.TrimEnd('\') + "\"

    if ($Progress) { & $Progress "Checking Windows folders..." }

    $old = [System.IO.Path]::Combine($rootPath, "Windows.old")
    if (Test-Directory $old) {
        $bytes = [int64]0
        try { $bytes = [int64](Get-TreeStats $old).Bytes } catch { }
        [void]$items.Add([pscustomobject]@{
            Name = "Previous Windows installation"; Where = $old; Bytes = $bytes; NeedsAdmin = $true
            What = "A copy of the Windows that was there before your last big update."
            Why = "Windows keeps it for a few weeks so you could go back."
            Action = "Open Disk Cleanup and tick 'Previous Windows installation(s)'."
            Command = "cleanmgr /d $($rootPath.TrimEnd('\'))"
        })
    }

    $hiber = [System.IO.Path]::Combine($rootPath, "hiberfil.sys")
    if (Test-File $hiber) {
        $bytes = [int64]0
        try { $bytes = (Get-Item -LiteralPath $hiber -Force -ErrorAction Stop).Length } catch { }
        [void]$items.Add([pscustomobject]@{
            Name = "Hibernation file"; Where = $hiber; Bytes = $bytes; NeedsAdmin = $true
            What = "A copy of everything in memory, written to disk for 'hibernate' and fast startup."
            Why = "Windows reserves it so a laptop can hibernate."
            Action = "If you never hibernate, this can be switched off to free the space."
            Command = "powercfg /h off"
        })
    }

    $page = [System.IO.Path]::Combine($rootPath, "pagefile.sys")
    if (Test-File $page) {
        $bytes = [int64]0
        try { $bytes = (Get-Item -LiteralPath $page -Force -ErrorAction Stop).Length } catch { }
        [void]$items.Add([pscustomobject]@{
            Name = "Virtual memory file"; Where = $page; Bytes = $bytes; NeedsAdmin = $true
            What = "Extra memory Windows borrows from the disk when programs need it."
            Why = "It is part of normal Windows operation."
            Action = "Leave this alone unless you have a lot of memory and know what you are doing."
            Command = ""
        })
    }

    $bin = Get-RecycleBinInfo $rootPath
    if ($bin.Available -and $bin.Bytes -gt 0) {
        [void]$items.Add([pscustomobject]@{
            Name = "Recycle Bin"; Where = "Recycle Bin"; Bytes = $bin.Bytes; NeedsAdmin = $false
            What = "Files you deleted that are still waiting to be thrown away."
            Why = "They keep using space until the bin is emptied."
            Action = "Open the Recycle Bin and press 'Empty Recycle Bin'."
            Command = ""
        })
    }

    $winSxs = [System.IO.Path]::Combine($rootPath, "Windows\WinSxS")
    if (Test-Directory $winSxs) {
        [void]$items.Add([pscustomobject]@{
            Name = "Windows component store"; Where = $winSxs; Bytes = [int64]0; NeedsAdmin = $true
            What = "The parts Windows keeps to repair and update itself. Its size looks bigger than it really is because many files are shared."
            Why = "Windows will not start without it. Never delete it by hand."
            Action = "Let Windows clean up old versions it no longer needs."
            Command = "DISM /Online /Cleanup-Image /StartComponentCleanup"
        })
    }

    return @($items)
}

# ---------------------------------------------------------------- treemap layout

function Get-WorstAspect {
    param($Areas, [double]$ShortSide)
    if (-not $Areas -or $Areas.Count -eq 0) { return [double]::MaxValue }
    $sum = 0.0
    $max = 0.0
    $min = [double]::MaxValue
    foreach ($value in $Areas) {
        $sum += $value
        if ($value -gt $max) { $max = $value }
        if ($value -lt $min) { $min = $value }
    }
    if ($sum -le 0 -or $min -le 0 -or $ShortSide -le 0) { return [double]::MaxValue }
    $shortSquared = $ShortSide * $ShortSide
    $sumSquared = $sum * $sum
    return [math]::Max(($shortSquared * $max) / $sumSquared, $sumSquared / ($shortSquared * $min))
}

# Squarified layout: keeps blocks close to square so the map stays readable.
function Get-SquarifiedLayout {
    param([double[]]$Values, [double]$X, [double]$Y, [double]$Width, [double]$Height)

    $rects = New-Object System.Collections.ArrayList
    if (-not $Values -or $Values.Count -eq 0 -or $Width -le 0 -or $Height -le 0) { return @() }

    $total = 0.0
    foreach ($value in $Values) { $total += [double]$value }
    if ($total -le 0) { return @() }

    $scale = ($Width * $Height) / $total
    $areas = @()
    foreach ($value in $Values) { $areas += ([double]$value * $scale) }

    $left = [double]$X
    $top = [double]$Y
    $w = [double]$Width
    $h = [double]$Height
    $index = 0

    while ($index -lt $areas.Count) {
        $short = [math]::Min($w, $h)
        if ($short -le 0) { break }

        $row = New-Object System.Collections.Generic.List[double]
        $row.Add($areas[$index])
        $index++
        $worst = Get-WorstAspect $row $short

        while ($index -lt $areas.Count) {
            $candidate = New-Object System.Collections.Generic.List[double]
            foreach ($value in $row) { $candidate.Add($value) }
            $candidate.Add($areas[$index])
            $candidateWorst = Get-WorstAspect $candidate $short
            if ($candidateWorst -le $worst) {
                $row = $candidate
                $worst = $candidateWorst
                $index++
            } else {
                break
            }
        }

        $rowSum = 0.0
        foreach ($value in $row) { $rowSum += $value }
        if ($rowSum -le 0) { break }

        if ($w -ge $h) {
            $rowWidth = [math]::Min($rowSum / $h, $w)
            if ($rowWidth -le 0) { break }
            $offset = 0.0
            foreach ($value in $row) {
                $itemHeight = $value / $rowWidth
                if ($itemHeight -gt 0) {
                    [void]$rects.Add([pscustomobject]@{ X = [double]$left; Y = [double]($top + $offset); W = [double]$rowWidth; H = [double]$itemHeight })
                }
                $offset += $itemHeight
            }
            $left += $rowWidth
            $w -= $rowWidth
        } else {
            $rowHeight = [math]::Min($rowSum / $w, $h)
            if ($rowHeight -le 0) { break }
            $offset = 0.0
            foreach ($value in $row) {
                $itemWidth = $value / $rowHeight
                if ($itemWidth -gt 0) {
                    [void]$rects.Add([pscustomobject]@{ X = [double]($left + $offset); Y = [double]$top; W = [double]$itemWidth; H = [double]$rowHeight })
                }
                $offset += $itemWidth
            }
            $top += $rowHeight
            $h -= $rowHeight
        }
    }

    return @($rects)
}

# ---------------------------------------------------------------- report

function Export-Report {
    param(
        [string]$Path,
        [object]$Scan,
        [object[]]$Items,
        [object[]]$History,
        [string]$DriveLabel = ""
    )

    $encode = { param($text) [System.Net.WebUtility]::HtmlEncode([string]$text) }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Disk Detective report</title>")
    [void]$builder.AppendLine("<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#101822;background:#f6f9fc}h1{font-size:26px}h2{font-size:19px;margin-top:28px}table{border-collapse:collapse;width:100%;background:#fff}th,td{padding:7px 10px;border-bottom:1px solid #e3e9f0;text-align:left;font-size:14px}th{background:#eef3f9}.muted{color:#5a6676}.risk{white-space:nowrap}</style></head><body>")
    [void]$builder.AppendLine("<h1>Disk Detective report</h1>")
    [void]$builder.AppendLine("<p class='muted'>Created $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Nothing was changed by creating this report.</p>")

    if ($DriveLabel) { [void]$builder.AppendLine("<p><strong>Drive:</strong> $(& $encode $DriveLabel)</p>") }
    if ($Scan) {
        [void]$builder.AppendLine("<h2>Space map</h2>")
        [void]$builder.AppendLine("<p>Folders measured: $($Scan.TotalFolders). Space used: $(Format-Size $Scan.FolderBytes) in $($Scan.FolderFiles) files.</p>")
        [void]$builder.AppendLine("<table><tr><th>Folder</th><th>Size</th><th>Files</th></tr>")
        $count = 0
        foreach ($folder in $Scan.Folders) {
            if ($count -ge 25) { break }
            [void]$builder.AppendLine("<tr><td>$(& $encode $folder.Path)</td><td>$(Format-Size $folder.Bytes)</td><td>$($folder.Files)</td></tr>")
            $count++
        }
        [void]$builder.AppendLine("</table>")
    }

    if ($Items -and $Items.Count -gt 0) {
        [void]$builder.AppendLine("<h2>What Disk Detective found</h2>")
        [void]$builder.AppendLine("<table><tr><th>Item</th><th>What it is</th><th>Size</th><th>Risk</th></tr>")
        foreach ($item in $Items) {
            [void]$builder.AppendLine("<tr><td>$(& $encode $item.Path)</td><td>$(& $encode $item.Title)</td><td>$(Format-Size $item.Bytes)</td><td class='risk'>$(& $encode (Get-RiskLabel $item.Risk))</td></tr>")
        }
        [void]$builder.AppendLine("</table>")
    }

    if ($History -and $History.Count -gt 0) {
        [void]$builder.AppendLine("<h2>What was changed</h2>")
        [void]$builder.AppendLine("<table><tr><th>What</th><th>Where</th><th>Size</th><th>When</th><th>Status</th></tr>")
        foreach ($entry in $History) {
            [void]$builder.AppendLine("<tr><td>$(& $encode $entry.What)</td><td>$(& $encode $entry.Where)</td><td>$(Format-Size $entry.Bytes)</td><td>$(& $encode $entry.When)</td><td>$(& $encode $entry.Status)</td></tr>")
        }
        [void]$builder.AppendLine("</table>")
    }

    [void]$builder.AppendLine("<p class='muted'>Disk Detective explains every item before it changes anything, and keeps a copy of removed items in its own Trash folder.</p>")
    [void]$builder.AppendLine("</body></html>")

    try {
        Set-Content -LiteralPath $Path -Value $builder.ToString() -Encoding UTF8 -ErrorAction Stop
        return $Path
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------- self test

if ($runSelfTest) {
    $script:failures = 0

    function Assert-True {
        param([bool]$Condition, [string]$Label)
        if ($Condition) { Write-Host "  PASS  $Label" } else { Write-Host "  FAIL  $Label"; $script:failures++ }
    }

    Write-Host "Disk Detective - data self test"

    $root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "dd-data-" + [guid]::NewGuid().ToString("N"))
    [void][System.IO.Directory]::CreateDirectory($root)

    $savedData = $env:DISKDETECTIVE_DATA
    $savedTrash = $env:DISKDETECTIVE_TRASH
    $env:DISKDETECTIVE_DATA = [System.IO.Path]::Combine($root, "settings")
    $env:DISKDETECTIVE_TRASH = [System.IO.Path]::Combine($root, "held")
    $script:DataFolder = $null

    $one = [System.IO.Path]::Combine($root, "one")
    $two = [System.IO.Path]::Combine($root, "two")
    [void][System.IO.Directory]::CreateDirectory($one)
    [void][System.IO.Directory]::CreateDirectory($two)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($one, "same.txt"), ("same-content-" * 40))
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($two, "same.txt"), ("same-content-" * 40))
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($two, "other.txt"), ("different-" * 40))

    $junk = [System.IO.Path]::Combine($root, "junk")
    [void][System.IO.Directory]::CreateDirectory($junk)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($junk, "a.tmp"), "junk-a")
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($junk, "b.tmp"), "junk-b")

    # --- trash round trip
    $junkBytes = (Get-TreeStats $junk).Bytes
    $result = Move-ToQuarantine -Items @([pscustomobject]@{ Path = $junk; Bytes = $junkBytes; Risk = "safe"; Title = "Test junk" }) -Reason "self test"
    Assert-True ($result.Removed.Count -eq 1) "an item moves to the Disk Detective trash"
    Assert-True (-not (Test-Path -LiteralPath $junk)) "the original place is empty"
    Assert-True (@(Get-TrashEntries).Count -eq 1) "the trash list has one entry"
    Assert-True (Test-Path -LiteralPath $env:DISKDETECTIVE_TRASH) "the holding folder exists"

    $entryId = $result.Removed[0].Entry.Id
    $restore = Restore-TrashEntry -Id $entryId
    Assert-True ([bool]$restore.Ok) "an item can be put back"
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($junk, "a.tmp"))) "the put-back item still has its files"
    Assert-True (@(Get-TrashEntries).Count -eq 0) "the trash list no longer shows it"

    $result2 = Move-ToQuarantine -Items @([pscustomobject]@{ Path = $junk; Bytes = $junkBytes; Risk = "safe"; Title = "Test junk" })
    $entry2 = $result2.Removed[0].Entry.Id
    $drop = Remove-TrashEntry -Id $entry2
    Assert-True ([bool]$drop.Ok) "an item can be deleted for good from the trash"

    # --- protected and excluded items are refused
    $blocked = Move-ToQuarantine -Items @([pscustomobject]@{ Path = $one; Bytes = 1; Risk = "protected"; Title = "Saves" })
    Assert-True ($blocked.Failed.Count -eq 1 -and $blocked.Removed.Count -eq 0) "protected items are refused"

    [void](Add-Exclusion -Path $two -Note "self test")
    Assert-True (Test-ExcludedPath ([System.IO.Path]::Combine($two, "same.txt"))) "an ignored folder covers its children"
    $excluded = Move-ToQuarantine -Items @([pscustomobject]@{ Path = $two; Bytes = 1; Risk = "safe"; Title = "x" })
    Assert-True ($excluded.Failed.Count -eq 1) "ignored items are refused"
    [void](Remove-Exclusion -Path $two)
    Assert-True (-not (Test-ExcludedPath $two)) "ignoring can be undone"

    # --- move history and health
    $moveData = [System.IO.Path]::Combine($root, "move-data")
    [void][System.IO.Directory]::CreateDirectory($moveData)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($moveData, "payload.txt"), "payload")
    $linkPath = [System.IO.Path]::Combine($root, "moved-here")
    $record = Add-MoveRecord -Source $linkPath -Target $moveData -Bytes 7 -Files 1
    Assert-True (@(Get-MoveRecords).Count -eq 1) "a move is written to the history"

    $linkMade = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $moveData -ErrorAction Stop | Out-Null
        $linkMade = $true
    } catch { $linkMade = $false }

    if ($linkMade) {
        $health = Test-MoveHealth $record
        Assert-True ($health.Status -eq "ok") "a working shortcut reports healthy"

        # A drive letter change is the usual way a shortcut breaks.
        Update-MoveRecord -Id $record.Id -Fields @{ Target = [System.IO.Path]::Combine($root, "missing-target") }
        $broken = Test-MoveHealth (Get-MoveRecords | Where-Object { $_.Id -eq $record.Id })
        Assert-True ($broken.Status -eq "missing-target") "a broken shortcut is reported"
        Update-MoveRecord -Id $record.Id -Fields @{ Target = $moveData }

        $undo = Undo-Move -Id $record.Id
        Assert-True ([bool]$undo.Ok) "a move can be undone"
        Assert-True (Test-Path -LiteralPath ([System.IO.Path]::Combine($linkPath, "payload.txt"))) "the data is back at the old place"
        Assert-True (-not (Test-Path -LiteralPath $moveData)) "the extra copy was removed"
    } else {
        Write-Host "  SKIP  shortcut checks (this system does not allow links)"
    }

    # --- whole drive scan
    $scan = Get-DriveScan -Root $root -FolderCount 50 -FileCount 20
    $expected = Get-TreeStats $root
    Assert-True ($scan.Folders.Count -gt 0) "the whole-drive scan lists folders"
    Assert-True ($scan.FolderBytes -eq $expected.Bytes) "the scan total matches a folder measurement"
    Assert-True ($scan.FolderFiles -eq $expected.Files) "the scan file count matches"
    Assert-True (@($scan.Folders | Where-Object { $_.Name -eq "one" }).Count -eq 1) "deep folders are listed by name"

    # --- duplicates
    $groups = Find-Duplicates -Root $root -MinBytes 10
    $found = @($groups | Where-Object { $_.Files.Count -eq 2 -and ($_.Files | Where-Object { $_.Path -like "*same.txt" }) })
    Assert-True ($found.Count -ge 1) "identical files are found"
    Assert-True ((Get-DuplicateWaste $groups) -gt 0) "the wasted space is calculated"

    # --- layout
    $rects = Get-SquarifiedLayout -Values @(5, 3, 2) -X 0 -Y 0 -Width 100 -Height 50
    $inside = $true
    $area = 0.0
    foreach ($rect in $rects) {
        if ($rect.X -lt -0.5 -or $rect.Y -lt -0.5 -or ($rect.X + $rect.W) -gt 100.5 -or ($rect.Y + $rect.H) -gt 50.5) { $inside = $false }
        $area += ($rect.W * $rect.H)
    }
    Assert-True ($rects.Count -eq 3) "every value gets a block"
    Assert-True $inside "every block stays inside the map"
    Assert-True ([math]::Abs($area - 5000) -lt 5) "the blocks fill the map"

    # --- explanation
    $dx = [System.IO.Path]::Combine($root, "DXCache")
    [void][System.IO.Directory]::CreateDirectory($dx)
    $explained = Get-FolderExplanation $dx
    Assert-True ($explained.Known -and $explained.Title -match "shader") "a known cache folder is explained"
    # Use a path outside this machine's temp folder so the temporary-files rule does not match it.
    $unknownPath = [System.IO.Path]::Combine([System.IO.Path]::GetPathRoot($root), "DiskDetectiveReview", "PlainFolder")
    $unknown = Get-FolderExplanation $unknownPath
    Assert-True (-not $unknown.Known -and $unknown.Title) "an unknown folder still gets an explanation"

    # --- report
    $reportPath = [System.IO.Path]::Combine($root, "report.html")
    $report = Export-Report -Path $reportPath -Scan $scan -Items @() -History @() -DriveLabel "test"
    Assert-True ([bool]$report -and (Test-Path -LiteralPath $reportPath)) "a report can be written"
    Assert-True ((Get-Content -LiteralPath $reportPath -Raw) -match "<html") "the report is HTML"

    # --- settings
    Save-Settings -LargeText $true -LastDrive "C:"
    $loaded = Get-Settings
    Assert-True ($loaded.LargeText -eq $true -and $loaded.LastDrive -eq "C:") "settings are saved and loaded"

    $env:DISKDETECTIVE_DATA = $savedData
    $env:DISKDETECTIVE_TRASH = $savedTrash
    $script:DataFolder = $null
    [void](Remove-TreeQuietly $root)

    if ($script:failures -gt 0) {
        Write-Host "DATATEST_FAILED ($script:failures)"
        exit 1
    }
    Write-Host "DATATEST_OK"
    exit 0
}
