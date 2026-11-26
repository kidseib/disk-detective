#requires -Version 5.1
<#
    Disk Detective
    A small Windows storage cleaner that explains what each file is before it is removed.

    - No installation, no server, no internet.
    - Removing anything needs your approval, and goes to the Recycle Bin.
    - Run it with the "Disk Detective.bat" file next to this script.
#>
param([switch]$Headless)

$ErrorActionPreference = "Stop"

# If anything unexpected happens while the window is being built, show it instead
# of failing silently behind the hidden console window.
trap {
    $details = "Disk Detective stopped: $($_.Exception.Message)" + [Environment]::NewLine + [Environment]::NewLine + $_.ScriptStackTrace
    try {
        $logPath = Join-Path $PSScriptRoot "DiskDetective-error.txt"
        $details | Set-Content -LiteralPath $logPath -Encoding UTF8
    } catch { }
    # In the automated window check there is nobody to click a message box.
    if ($env:DISKDETECTIVE_SMOKE) { exit 1 }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "Disk Detective could not continue.`n`n$($_.Exception.Message)`n`nDetails were saved to DiskDetective-error.txt next to the app.",
            "Disk Detective", "OK", "Error")
    } catch { }
    exit 1
}

$script:Day = 86400
$script:MinBytes = 1500000
$script:MinProtectedBytes = 100000
$script:MaxItems = 300
$script:BudgetSeconds = 50
$script:Seen = New-Object System.Collections.Generic.HashSet[string]
$script:Candidates = New-Object System.Collections.ArrayList
$script:Roots = New-Object System.Collections.ArrayList
$script:Notes = New-Object System.Collections.ArrayList
$script:StatusCallback = $null
$script:Stopwatch = $null
$script:CancelScan = $false

# ---------------------------------------------------------------- helpers

function Add-Note([string]$Text) {
    if ($Text -and -not $script:Notes.Contains($Text)) { [void]$script:Notes.Add($Text) }
}

function Add-Root([string]$Label, [string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    foreach ($root in $script:Roots) {
        if ($root.Path -eq $Path) { return }
    }
    [void]$script:Roots.Add([pscustomobject]@{ Label = $Label; Path = $Path })
}

function Set-Status([string]$Text) {
    if ($script:StatusCallback) { & $script:StatusCallback $Text }
}

function New-Exp {
    param([string]$Risk, [string]$Category, [string]$What, [string]$Why, [string]$Impact)
    [pscustomobject]@{ Risk = $Risk; Category = $Category; What = $What; Why = $Why; Impact = $Impact }
}

function Test-Directory([string]$Path) { return [System.IO.Directory]::Exists($Path) }
function Test-File([string]$Path) { return [System.IO.File]::Exists($Path) }

# Builds a path without asking PowerShell whether the drive exists yet (Steam
# libraries can live on drives that are not mounted in this session).
function Join-PathSafe([string]$Base, [string]$Child) {
    if (-not $Base) { return $Child }
    if (-not $Child) { return $Base }
    return [System.IO.Path]::Combine($Base, $Child)
}

function Get-ChildEntries([string]$Path) {
    try { return [System.IO.Directory]::GetFileSystemEntries($Path) } catch { return @() }
}

function Add-Candidate {
    param(
        [string]$Path,
        [string]$Title,
        [object]$Exp,
        [string]$Source,
        [object]$Measured
    )
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $key = $Path.ToLowerInvariant()
    if (-not $script:Seen.Add($key)) { return }
    [void]$script:Candidates.Add([pscustomobject]@{
        Path = $Path; Title = $Title; Exp = $Exp; Source = $Source; Measured = $Measured
    })
}

function Measure-Path {
    param([string]$Path)

    $kind = "dir"
    $last = [System.IO.Directory]::GetLastWriteTime($Path)
    if (Test-File $Path) {
        $fi = New-Object System.IO.FileInfo($Path)
        return [pscustomobject]@{ Bytes = [int64]$fi.Length; Files = 1; LastUsed = $fi.LastWriteTime; Kind = "file" }
    }

    $bytes = [int64]0
    $files = 0
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $Path; Depth = 0 })

    while ($stack.Count -gt 0) {
        if ($script:CancelScan) { break }
        if ($script:Stopwatch -and $script:Stopwatch.Elapsed.TotalSeconds -gt $script:BudgetSeconds) { break }
        $current = $stack.Pop()
        $entries = Get-ChildEntries $current.Path
        foreach ($entry in $entries) {
            try {
                if (Test-Directory $entry) {
                    if ($current.Depth -ge 16) { continue }
                    $info = New-Object System.IO.DirectoryInfo($entry)
                    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push([pscustomobject]@{ Path = $entry; Depth = $current.Depth + 1 })
                    continue
                }
                $fileInfo = New-Object System.IO.FileInfo($entry)
                if (-not $fileInfo.Exists) { continue }
                $bytes += $fileInfo.Length
                $files++
                if ($fileInfo.LastWriteTime -gt $last) { $last = $fileInfo.LastWriteTime }
            } catch { }
        }
    }

    return [pscustomobject]@{ Bytes = $bytes; Files = $files; LastUsed = $last; Kind = $kind }
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -le 0) { return "0 B" }
    $units = @("B", "KB", "MB", "GB", "TB")
    $value = [double]$Bytes
    $unit = 0
    while ($value -ge 1024 -and $unit -lt 4) { $value = $value / 1024; $unit++ }
    if ($value -ge 100) { $number = [string][math]::Round($value) }
    elseif ($value -ge 10) { $number = $value.ToString("0.0") }
    else { $number = $value.ToString("0.00") }
    return "$number $($units[$unit])"
}

function Format-Age([datetime]$When) {
    if (-not $When) { return "unknown" }
    $days = ((Get-Date) - $When).TotalDays
    if ($days -lt 1) { return "today" }
    if ($days -lt 2) { return "yesterday" }
    if ($days -lt 60) { return "$([math]::Round($days)) days ago" }
    if ($days -lt 365) { return "$([math]::Round($days / 30)) months ago" }
    return "$([math]::Round($days / 365, 1)) years ago"
}

function Get-RiskLabel([string]$Risk) {
    switch ($Risk) {
        "safe" { return "Safe to delete" }
        "low" { return "Low risk" }
        "caution" { return "Ask before deleting" }
        "protected" { return "Keep - protected" }
        default { return $Risk }
    }
}

# ---------------------------------------------------------------- explanations

function Get-TempExp([string]$Name, [bool]$IsDirectory) {
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($ext -in @(".exe", ".msi", ".msix", ".appx")) {
        return New-Exp "low" "Leftover installers" `
            "A setup program that was unpacked or run from the temporary folder." `
            "Installers extract themselves here and normally delete themselves afterwards; this one was interrupted." `
            "The installed program does not need it. You would only download it again to repair or reinstall that version."
    }
    if ($ext -in @(".log", ".txt", ".etl", ".dmp")) {
        return New-Exp "safe" "Logs" `
            "A log written by an installer, updater or application while it ran." `
            "Kept for troubleshooting and never cleaned out of the temporary folder." `
            "Nothing breaks. If you are chasing a problem with that app right now, copy the log somewhere else first."
    }
    if ($ext -in @(".zip", ".7z", ".rar", ".tar", ".gz", ".iso")) {
        return New-Exp "low" "Temporary files" `
            "An archive that was unpacked into the temporary area and left behind." `
            "Unpackers rarely remove their source archive when they finish." `
            "The extracted files are what mattered. If you never saved them, download the archive again instead."
    }
    if ($IsDirectory) {
        return New-Exp "safe" "Temporary files" `
            "A working folder that an application or installer created while it ran." `
            "Programs make these per run and clean up only when they exit normally." `
            "Apps recreate folders like this on demand. Anything still in use is locked by Windows and will be skipped."
    }
    return New-Exp "safe" "Temporary files" `
        "A scratch file written by an application or installer." `
        "It was never cleaned up after the program finished or crashed." `
        "Nothing important. Files that are still open cannot be removed and are skipped."
}

function Get-BrowserCacheExp([string]$Browser, [string]$Kind) {
    switch ($Kind) {
        "cache" {
            return New-Exp "safe" "Browser cache" `
                "Images, scripts and fonts that $Browser downloaded and kept so pages open faster next time." `
                "Browsers limit the size but never clear old copies, so the folder grows for months." `
                "Sites download their pictures once more, so the first visit feels slightly slower. Bookmarks, history, passwords and signed-in sessions are stored in other files and are not touched."
        }
        "code" {
            return New-Exp "safe" "Browser cache" `
                "Web page scripts that $Browser already compiled, so script-heavy sites start faster." `
                "Old compiled copies stay until the cache happens to be trimmed." `
                "They are rebuilt automatically. A page can take a moment longer to become interactive the first time."
        }
        "gpu" {
            return New-Exp "safe" "Browser cache" `
                "Graphics programs that $Browser prepared for your graphics card." `
                "They are rebuilt whenever the browser or driver updates, and the old set is not deleted." `
                "They are recreated when needed. Video or 3D pages may stutter for a second while that happens."
        }
        "offline" {
            return New-Exp "safe" "Browser cache" `
                "Offline copies of web pages that $Browser keeps for installed web apps." `
                "Old copies are kept after a site changes." `
                "The site downloads a fresh copy. Your logins and history are not affected."
        }
    }
    return Get-BrowserCacheExp $Browser "cache"
}

$script:AppNotes = @{
    "discord"          = @{ Name = "Discord"; What = "The Discord desktop app's cache and local store: pictures, pasted images, logs and settings."; Impact = "Discord downloads pictures again, but local settings and cached message text are lost until the server sends them again." }
    "slack"            = @{ Name = "Slack"; What = "Slack's local workspace cache, downloaded files and sign-in state."; Impact = "You sign in again and each workspace reloads its history for a minute." }
    "spotify"          = @{ Name = "Spotify"; What = "Spotify's local cache and any playlists you downloaded for offline listening."; Impact = "Offline downloads are removed and must be downloaded again. Your library stays on Spotify's servers." }
    "code"             = @{ Name = "Visual Studio Code"; What = "VS Code workspace state, installed extensions and cached language tools."; Impact = "Extensions and settings are lost. Your source code files are not stored here." }
    "steam"            = @{ Name = "Steam"; What = "Steam client caches: store pictures, browser cache and downloaded interface files."; Impact = "Steam downloads them again. Installed games live in separate library folders and are not affected." }
    "epicgameslauncher"= @{ Name = "Epic Games Launcher"; What = "The Epic launcher's web cache, downloaded manifests and logs."; Impact = "The launcher downloads what it needs again. Installed games are not affected." }
    "zoom"             = @{ Name = "Zoom"; What = "Zoom's cache, crash logs and recording information."; Impact = "Local recordings and chat history in this folder are lost; everything else is on Zoom's servers." }
    "teams"            = @{ Name = "Microsoft Teams"; What = "The Teams app's cache, downloaded files and local message store."; Impact = "Teams reloads chats from the server, but files you opened locally are removed." }
    "docker"           = @{ Name = "Docker Desktop"; What = "Docker Desktop's settings, logs and cached image information."; Impact = "Docker recreates its settings; containers and images live in a separate folder." }
}

$script:GameHints = "(steam|epicgames|epic games|battle\.net|blizzard|riot games|riotgames|minecraft|roblox|rockstar|ubisoft|gog|electronic arts|ea games|origin|bethesda|valve|unity|unreal|hoyoverse|genshin|wargaming|nexon|jagex|runescape|the sims)"

function Get-AppDataExp([string]$FolderName, [string]$FullPath) {
    $key = $FolderName.ToLowerInvariant()
    $note = $script:AppNotes[$key]
    $isGame = $FullPath -match $script:GameHints

    if ($note) {
        return New-Exp "caution" $(if ($isGame) { "Game data" } else { "Application data" }) `
            $note.What `
            "Nothing in this folder has been written to for over 10 months, which usually means $($note.Name) is not used on this PC any more." `
            $note.Impact
    }
    if ($isGame) {
        return New-Exp "caution" "Game data" `
            "Local data for a game or game launcher: downloaded files, shader caches, logs and sometimes settings." `
            "Game launchers rarely clean up after an uninstall, so data for games you no longer have stays on disk." `
            "Reinstalling the game may recreate it. If this folder holds save files or mods, keep it. Otherwise it is mostly rebuildable cache."
    }
    return New-Exp "caution" "Application data" `
        "Settings, caches, logs and local databases written by this application." `
        "Application data survives uninstalls, and apps you stopped opening keep their files forever." `
        "If the app is still installed it recreates the folder the next time it runs, but its local settings and any unsent data are gone. Open the folder first if you are unsure what it belongs to."
}

function Get-InstallerExp([string]$Name) {
    return New-Exp "low" "Leftover installers" `
        "$Name is a setup program you downloaded once." `
        "Browsers save installers to Downloads and nothing removes them after the app is installed." `
        "The installed app does not need its installer. You would download it again only to repair or reinstall that version."
}

function Get-SteamLeftoverExp([string]$Name) {
    return New-Exp "low" "Game files" `
        "A folder in a Steam library that no installed Steam game points to." `
        "Steam only removes what it manages; mods, manual copies and games removed outside Steam are left behind." `
        "Nothing Steam knows about uses it. If it is a mod folder or a backup you still play with, keep it."
}

function Get-SaveExp([string]$GameName) {
    return New-Exp "protected" "Game saves" `
        "Save files, settings and profiles written by $GameName." `
        "Games keep your progress here. There is usually no other copy unless the game has cloud saves turned on." `
        "Deleting this erases progress permanently. This app keeps it out of reach on purpose."
}

# ---------------------------------------------------------------- discovery

function Get-ChromiumProfileDirs([string]$UserData) {
    $profiles = @()
    foreach ($entry in (Get-ChildEntries $UserData)) {
        if (-not (Test-Directory $entry)) { continue }
        $name = [System.IO.Path]::GetFileName($entry)
        if ($name -eq "Default" -or $name -match '^Profile \d+$' -or $name -eq "Guest Profile") { $profiles += $entry }
    }
    return $profiles
}

function Find-SteamLibraries {
    $libraries = New-Object System.Collections.ArrayList

    $steamRoots = @()
    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programFiles) { continue }
        $candidate = Join-PathSafe $programFiles "Steam"
        if ((Test-Directory (Join-PathSafe $candidate "steamapps")) -and ($steamRoots -notcontains $candidate)) { $steamRoots += $candidate }
    }
    foreach ($fixed in @("C:\Program Files (x86)\Steam", "C:\Program Files\Steam")) {
        if ((Test-Directory (Join-PathSafe $fixed "steamapps")) -and ($steamRoots -notcontains $fixed)) { $steamRoots += $fixed }
    }

    foreach ($root in $steamRoots) { [void]$libraries.Add((Join-Path $root "steamapps")) }

    $vdfCandidates = @()
    foreach ($root in $steamRoots) { $vdfCandidates += (Join-PathSafe $root "steamapps\libraryfolders.vdf") }
    $vdfCandidates += "C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf"
    $vdfCandidates += "C:\Program Files\Steam\steamapps\libraryfolders.vdf"

    foreach ($vdf in $vdfCandidates) {
        if (-not (Test-File $vdf)) { continue }
        try { $text = [System.IO.File]::ReadAllText($vdf) } catch { continue }
        foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $library = $match.Groups[1].Value -replace '\\\\', '\'
            $steamapps = Join-PathSafe $library "steamapps"
            if (Test-Directory $steamapps) { [void]$libraries.Add($steamapps) }
        }
    }

    foreach ($letter in @("C", "D", "E", "F", "G", "H", "I", "J")) {
        foreach ($suffix in @("SteamLibrary", "Steam", "Games\SteamLibrary", "Games\Steam")) {
            $steamapps = "${letter}:\$suffix\steamapps"
            if (Test-Directory $steamapps) { [void]$libraries.Add($steamapps) }
        }
    }

    return ($libraries | Select-Object -Unique)
}

function Invoke-Discovery {
    $temp = $env:TEMP
    if (-not $temp) { $temp = $env:TMP }

    Set-Status "Checking temporary files..."
    if ($temp -and (Test-Directory $temp)) {
        Add-Root "Your temporary files" $temp
        foreach ($entry in (Get-ChildEntries $temp)) {
            $name = [System.IO.Path]::GetFileName($entry)
            Add-Candidate $entry $name (Get-TempExp $name (Test-Directory $entry)) "Temporary files"
        }
    } else {
        Add-Note "Windows did not report a temporary folder, so temporary files were not checked."
    }

    $winTemp = ""
    if ($env:WINDIR) { $winTemp = Join-Path $env:WINDIR "Temp" }
    if ($winTemp -and (Test-Directory $winTemp) -and $winTemp.ToLowerInvariant() -ne "$temp".ToLowerInvariant()) {
        Add-Root "Windows temporary files" $winTemp
        foreach ($entry in (Get-ChildEntries $winTemp)) {
            $name = [System.IO.Path]::GetFileName($entry)
            Add-Candidate $entry $name (Get-TempExp $name (Test-Directory $entry)) "Windows temp"
        }
    }

    $local = $env:LOCALAPPDATA
    if ($local) {
        Set-Status "Checking crash reports and thumbnails..."
        $crash = Join-Path $local "CrashDumps"
        Add-Root "Crash reports" $crash
        foreach ($entry in (Get-ChildEntries $crash)) {
            $exp = New-Exp "safe" "Crash reports" "A memory dump from an application that crashed, including a copy of its memory contents." "Windows saves these in case a developer asks for one; almost nobody ever reads them." "Nothing stops working. These files can contain pieces of documents or passwords, so removing them is also good for privacy."
            Add-Candidate $entry ([System.IO.Path]::GetFileName($entry)) $exp "Crash reports"
        }

        $wer = Join-Path $local "Microsoft\Windows\WER"
        Add-Root "Windows error reports" $wer
        foreach ($sub in @("ReportArchive", "ReportQueue", "Temp")) {
            $path = Join-Path $wer $sub
            $exp = New-Exp "safe" "Crash reports" "Reports Windows collected when an application failed." "Kept in case a developer asks for one, and never cleaned up automatically." "Nothing breaks. Error reports can contain personal information, so removing them helps privacy too."
            Add-Candidate $path $sub $exp "Crash reports"
        }

        $explorer = Join-Path $local "Microsoft\Windows\Explorer"
        Add-Root "Thumbnail pictures" $explorer
        foreach ($entry in (Get-ChildEntries $explorer)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name -match '^(thumbcache|iconcache)_') {
                $exp = New-Exp "safe" "Thumbnails" "Small preview pictures Windows builds so folders show pictures instantly." "Windows limits the size but never removes the old files." "Windows rebuilds them as you browse; the first look inside a photo folder is briefly slower."
                Add-Candidate $entry $name $exp "Thumbnails"
            }
        }

        $inet = Join-Path $local "Microsoft\Windows\INetCache"
        $exp = New-Exp "safe" "Temporary files" "Web content cached by Windows components and older programs." "Kept for each user and cleaned only by the Disk Cleanup tool." "Programs download it again. No documents or settings are stored here."
        Add-Candidate $inet "INetCache" $exp "Temporary files"

        foreach ($pair in @(
            @{ Path = (Join-Path $local "D3DSCache"); Title = "Direct3D shader cache" },
            @{ Path = (Join-Path $local "NVIDIA\DXCache"); Title = "NVIDIA DirectX cache" },
            @{ Path = (Join-Path $local "NVIDIA\GLCache"); Title = "NVIDIA OpenGL cache" }
        )) {
            $exp = New-Exp "safe" "Graphics cache" "Prepared graphics programs that your graphics card keeps so games start smoothly." "Rebuilt whenever the driver or a game updates, while the old set stays on disk." "Games may stutter for a few seconds while it is rebuilt. Nothing is lost."
            Add-Candidate $pair.Path $pair.Title $exp "Application data"
        }

        Set-Status "Checking browser caches..."
        $browsers = @(
            @{ Vendor = "Google\Chrome"; Name = "Chrome" },
            @{ Vendor = "Microsoft\Edge"; Name = "Edge" },
            @{ Vendor = "BraveSoftware\Brave-Browser"; Name = "Brave" },
            @{ Vendor = "Vivaldi"; Name = "Vivaldi" },
            @{ Vendor = "Chromium"; Name = "Chromium" },
            @{ Vendor = "Opera Software\Opera GX"; Name = "Opera GX" },
            @{ Vendor = "Opera Software\Opera Stable"; Name = "Opera" }
        )
        foreach ($browser in $browsers) {
            $userData = Join-Path $local "$($browser.Vendor)\User Data"
            if (-not (Test-Directory $userData)) { continue }
            Add-Root "$($browser.Name) profile" $userData
            foreach ($profile in (Get-ChromiumProfileDirs $userData)) {
                $profileName = [System.IO.Path]::GetFileName($profile)
                Add-Candidate (Join-Path $profile "Cache") "$($browser.Name) cache ($profileName)" (Get-BrowserCacheExp $browser.Name "cache") "Browser cache"
                Add-Candidate (Join-Path $profile "Code Cache") "$($browser.Name) script cache" (Get-BrowserCacheExp $browser.Name "code") "Browser cache"
                Add-Candidate (Join-Path $profile "GPUCache") "$($browser.Name) graphics cache" (Get-BrowserCacheExp $browser.Name "gpu") "Browser cache"
                Add-Candidate (Join-Path $profile "ShaderCache") "$($browser.Name) shader cache" (Get-BrowserCacheExp $browser.Name "gpu") "Browser cache"
                Add-Candidate (Join-Path $profile "GrShaderCache") "$($browser.Name) shader cache" (Get-BrowserCacheExp $browser.Name "gpu") "Browser cache"
                Add-Candidate (Join-Path $profile "DawnCache") "$($browser.Name) graphics cache" (Get-BrowserCacheExp $browser.Name "gpu") "Browser cache"
                Add-Candidate (Join-Path $profile "Service Worker\CacheStorage") "$($browser.Name) offline pages" (Get-BrowserCacheExp $browser.Name "offline") "Browser cache"
            }
        }

        $firefox = Join-Path $local "Mozilla\Firefox\Profiles"
        if (Test-Directory $firefox) {
            Add-Root "Firefox profiles" $firefox
            foreach ($profile in (Get-ChildEntries $firefox)) {
                if (-not (Test-Directory $profile)) { continue }
                $exp = New-Exp "safe" "Browser cache" "Pages, pictures and startup files that Firefox cached for one profile." "Kept for speed and trimmed late, so profiles collect hundreds of megabytes." "Firefox downloads what it needs again. Bookmarks, logins and history live in other files."
                Add-Candidate (Join-Path $profile "cache2") "Firefox cache" $exp "Browser cache"
                Add-Candidate (Join-Path $profile "startupCache") "Firefox startup cache" $exp "Browser cache"
            }
        }

        Set-Status "Checking program caches..."
        $npmExp = New-Exp "safe" "Programmer cache" "Copies of every npm package version installed on this PC, kept so installs do not download them again." "npm never trims it, so it grows with every project you have built." "The next install downloads those packages again. Your projects and their files are untouched."
        Add-Candidate (Join-Path $local "npm-cache") "npm package cache" $npmExp "Programmer cache"

        $pipExp = New-Exp "safe" "Programmer cache" "Python packages that pip downloaded and built once." "pip reuses them and never removes old versions." "Future installs download them again. Your projects are not affected."
        Add-Candidate (Join-Path $local "pip\Cache") "pip cache" $pipExp "Programmer cache"

        $jsExp = New-Exp "safe" "Programmer cache" "Package files that Yarn, pnpm or Bun share between projects." "They are only ever added to, so old versions stay on disk." "Installing again downloads them. Project files stay as they are."
        Add-Candidate (Join-Path $local "Yarn\Cache") "Yarn cache" $jsExp "Programmer cache"
        Add-Candidate (Join-Path $local "pnpm") "pnpm store" $jsExp "Programmer cache"
        Add-Candidate (Join-Path $local "bun\install\cache") "Bun package cache" $jsExp "Programmer cache"

        $electronExp = New-Exp "safe" "Programmer cache" "Electron runtime files that were downloaded to package desktop apps." "One copy per version is kept forever." "The next packaging run downloads them again, a few hundred megabytes."
        Add-Candidate (Join-Path $local "electron\Cache") "Electron cache" $electronExp "Programmer cache"
        Add-Candidate (Join-Path $local "electron-builder\Cache") "Electron builder cache" $electronExp "Programmer cache"

        $nugetExp = New-Exp "low" "Programmer cache" "A local copy of compiled libraries your build tools download once and reuse." "Every version you have ever used is kept." "The next build downloads them again, which can take minutes and needs internet."
        Add-Candidate (Join-Path $local "NuGet\v3-cache") "NuGet cache" $nugetExp "Programmer cache"
    }

    if ($env:APPDATA) {
        $npmRoaming = Join-Path $env:APPDATA "npm-cache"
        $npmExp2 = New-Exp "safe" "Programmer cache" "Copies of npm package versions, kept so installs do not download them again." "npm never trims it automatically." "The next install downloads them again. Your projects are untouched."
        Add-Candidate $npmRoaming "npm package cache" $npmExp2 "Programmer cache"
    }

    if ($env:USERPROFILE) {
        $buildExp = New-Exp "low" "Programmer cache" "A local copy of libraries that build tools downloaded once." "Gradle, Maven and NuGet keep every version you have ever used." "The next build downloads them again, which can take several minutes."
        Add-Candidate (Join-Path $env:USERPROFILE ".gradle\caches") "Gradle cache" $buildExp "Programmer cache"
        Add-Candidate (Join-Path $env:USERPROFILE ".m2\repository") "Maven cache" $buildExp "Programmer cache"
        Add-Candidate (Join-Path $env:USERPROFILE ".nuget\packages") "NuGet packages" $buildExp "Programmer cache"
    }

    if ($env:USERPROFILE) {
        Set-Status "Checking Downloads..."
        $downloads = Join-Path $env:USERPROFILE "Downloads"
        if (Test-Directory $downloads) {
            Add-Root "Downloads" $downloads
            $leftAlone = 0
            foreach ($entry in (Get-ChildEntries $downloads)) {
                if (-not (Test-File $entry)) { $leftAlone++; continue }
                $info = New-Object System.IO.FileInfo($entry)
                $idle = ((Get-Date) - $info.LastWriteTime).TotalDays
                $installer = $info.Extension.ToLowerInvariant() -in @(".exe", ".msi", ".msix", ".appx", ".iso", ".img")
                if ($installer -and $info.Length -ge 5MB -and $idle -ge 30) {
                    Add-Candidate $entry $info.Name (Get-InstallerExp $info.Name) "Downloads"
                } elseif ($info.Length -ge 500MB -and $idle -ge 365) {
                    $exp = New-Exp "caution" "Downloads" "$($info.Name) is a large file that has sat in Downloads unused for over a year." "Downloads is never cleaned automatically, so old videos, disk images and archives pile up." "The file is gone unless you download it again. Check the name first: this may be a backup you still need."
                    Add-Candidate $entry $info.Name $exp "Downloads"
                } else {
                    $leftAlone++
                }
            }
            if ($leftAlone -gt 0) {
                Add-Note "$leftAlone file(s) in Downloads were left alone: they are recent, small, or personal files this app should not judge."
            }
        }
    }

    Set-Status "Checking programs that have not been used for a while..."
    foreach ($base in @($local, $env:APPDATA)) {
        if (-not $base) { continue }
        Add-Root $(if ($base -eq $local) { "Program data (local)" } else { "Program data (roaming)" }) $base
        $skip = @(
            "microsoft", "packages", "programs", "temp", "google", "mozilla", "bravesoftware", "steam",
            "nvidia", "nvidia corporation", "amd", "intel", "d3dscache", "connecteddevicesplatform", "comms",
            "publish", "virtualstore", "elevateddiagnostics", "placeholdertilelogofolder", "adobe",
            "crashdumps", "windows", "desktop", "history", "temporary internet files"
        )
        foreach ($entry in (Get-ChildEntries $base)) {
            if (-not (Test-Directory $entry)) { continue }
            $folderName = [System.IO.Path]::GetFileName($entry)
            if ($skip -contains $folderName.ToLowerInvariant()) { continue }
            $measured = Measure-Path $entry
            $idle = ((Get-Date) - $measured.LastUsed).TotalDays
            if ($measured.Bytes -lt 60MB -or $idle -lt 300) { continue }
            Add-Candidate $entry $folderName (Get-AppDataExp $folderName $entry) "Program data" $measured
        }
    }

    Set-Status "Checking game folders..."
    foreach ($steamapps in (Find-SteamLibraries)) {
        $common = Join-PathSafe $steamapps "common"
        if (-not (Test-Directory $common)) { continue }
        Add-Root "Steam library" $common

        $installed = New-Object System.Collections.Generic.HashSet[string]
        foreach ($manifest in (Get-ChildEntries $steamapps)) {
            if (-not (Test-File $manifest)) { continue }
            if ([System.IO.Path]::GetFileName($manifest) -notmatch '^appmanifest_\d+\.acf$') { continue }
            try { $text = [System.IO.File]::ReadAllText($manifest) } catch { continue }
            $match = [regex]::Match($text, '"installdir"\s+"([^"]+)"')
            if ($match.Success) { [void]$installed.Add($match.Groups[1].Value.ToLowerInvariant()) }
        }

        foreach ($folder in (Get-ChildEntries $common)) {
            if (-not (Test-Directory $folder)) { continue }
            $name = [System.IO.Path]::GetFileName($folder)
            $key = $name.ToLowerInvariant()
            if ($installed.Contains($key)) { continue }
            if ($key -eq "steamworks common redistributables") { continue }
            Add-Candidate $folder "$name (not installed)" (Get-SteamLeftoverExp $name) "Game files"
        }

        $shaderExp = New-Exp "safe" "Graphics cache" "Prepared graphics programs that Steam builds for your graphics card so games do not stutter." "Steam keeps shaders for games you have uninstalled." "Games rebuild them on the next launch, which can cause a short stutter. Nothing is lost."
        Add-Candidate (Join-PathSafe $steamapps "shadercache") "Steam shader cache" $shaderExp "Game files"

        $partialExp = New-Exp "low" "Game files" "Partly downloaded game data that Steam has not finished writing." "Interrupted downloads and updates leave pieces here." "Steam downloads what it needs again. A download that is running right now is locked and will be skipped."
        Add-Candidate (Join-PathSafe $steamapps "downloading") "Unfinished Steam downloads" $partialExp "Game files"

        $userdataExp = New-Exp "protected" "Game saves" "Steam's local store for your account: synced settings and some game data." "Steam uses this folder while it runs and syncs parts of it online." "Removing it can lose settings that have not synced yet. This app leaves it alone."
        Add-Candidate (Join-PathSafe ([System.IO.Path]::GetDirectoryName($steamapps)) "userdata") "Steam account data" $userdataExp "Game saves"
    }

    if ($env:USERPROFILE) {
        Set-Status "Checking game saves..."
        foreach ($savesRoot in @((Join-Path $env:USERPROFILE "Saved Games"), (Join-Path $env:USERPROFILE "Documents\My Games"))) {
            if (-not (Test-Directory $savesRoot)) { continue }
            Add-Root "Game saves" $savesRoot
            foreach ($entry in (Get-ChildEntries $savesRoot)) {
                if (-not (Test-Directory $entry)) { continue }
                $game = [System.IO.Path]::GetFileName($entry)
                Add-Candidate $entry "$game saves" (Get-SaveExp $game) "Game saves"
            }
        }
    }
}

function Get-ScanResult {
    $script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Invoke-Discovery

    Set-Status "Measuring what was found..."
    $items = New-Object System.Collections.ArrayList
    $skippedSmall = 0
    $expired = $false

    foreach ($candidate in $script:Candidates) {
        if ($script:Stopwatch.Elapsed.TotalSeconds -gt $script:BudgetSeconds) { $expired = $true; break }
        $measured = $candidate.Measured
        if (-not $measured) { $measured = Measure-Path $candidate.Path }
        if (-not $measured) { continue }

        $minimum = $script:MinBytes
        if ($candidate.Exp.Risk -eq "protected") { $minimum = $script:MinProtectedBytes }
        if ($measured.Bytes -lt $minimum) { $skippedSmall++; continue }

        [void]$items.Add([pscustomobject]@{
            Path       = $candidate.Path
            Name       = [System.IO.Path]::GetFileName($candidate.Path)
            Title      = $candidate.Title
            Kind       = $measured.Kind
            Bytes      = [int64]$measured.Bytes
            Files      = $measured.Files
            LastUsed   = $measured.LastUsed
            Risk       = $candidate.Exp.Risk
            Category   = $candidate.Exp.Category
            What       = $candidate.Exp.What
            Why        = $candidate.Exp.Why
            Impact     = $candidate.Exp.Impact
            Source     = $candidate.Source
        })
    }

    $sorted = $items | Sort-Object { $_.Path.Length }
    $kept = New-Object System.Collections.ArrayList
    $separator = [System.IO.Path]::DirectorySeparatorChar
    foreach ($item in $sorted) {
        $nested = $false
        foreach ($parent in $kept) {
            if ($item.Path.ToLowerInvariant().StartsWith($parent.Path.ToLowerInvariant() + $separator)) { $nested = $true; break }
        }
        if (-not $nested) { [void]$kept.Add($item) }
    }

    $final = @($kept | Sort-Object Bytes -Descending)
    if ($final.Count -gt $script:MaxItems) {
        Add-Note "Only the $($script:MaxItems) largest findings are shown; smaller ones were left out to keep the list readable."
        $final = $final[0..($script:MaxItems - 1)]
    }

    if ($skippedSmall -gt 0) {
        Add-Note "$skippedSmall item(s) were under 1.5 MB and left out; together they save very little space."
    }
    if ($expired) {
        Add-Note "The scan reached its time limit, so a few places may be incomplete. Scan again to pick up the rest."
    }
    if ($script:Notes.Count -eq 0) { Add-Note "Scan finished. Nothing has been deleted." }

    $script:Stopwatch.Stop()
    return [pscustomobject]@{
        Items     = $final
        Roots     = @($script:Roots)
        Notes     = @($script:Notes)
        ScannedAt = Get-Date
    }
}

# Removal lives in DiskDetective.Data.ps1: items are renamed into Disk Detective's
# own Trash on the same drive, because Windows silently deletes items that are
# too big for the Recycle Bin instead of asking.

# ---------------------------------------------------------------- headless test mode

if ($Headless) {
    $script:StatusCallback = { param($text) Write-Host "  ... $text" }
    Write-Host "Disk Detective - scan only (nothing will be deleted)"
    $result = Get-ScanResult
    Write-Host ""
    Write-Host ("Found {0} item(s):" -f $result.Items.Count)
    foreach ($item in $result.Items) {
        Write-Host ("  {0,-9} {1,10}  {2}  [{3}]" -f $item.Risk, (Format-Size $item.Bytes), $item.Path, $item.Title)
    }
    Write-Host ""
    foreach ($note in $result.Notes) { Write-Host "  note: $note" }
    exit 0
}

