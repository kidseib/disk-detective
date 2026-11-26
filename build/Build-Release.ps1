[CmdletBinding()]
param(
    [string]$Version = "1.1.1"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "Version must have three or four numeric parts, for example 1.1.0 or 1.1.0.0."
}

$root = Split-Path -Parent $PSScriptRoot
$launcherProject = Join-Path $root "launcher\DiskDetectiveLauncher.csproj"
$buildRoot = Join-Path $root "build"
$launcherOutput = Join-Path $buildRoot "launcher"
$stage = Join-Path $buildRoot "stage"
$dist = Join-Path $root "dist"
$zip = Join-Path $dist ("Disk Detective " + $Version + ".zip")

$versionParts = $Version.Split(".")
$fileVersion = if ($versionParts.Count -eq 4) { $Version } else { $Version + ".0" }

$releaseFiles = @(
    "DiskDetective.ps1",
    "DiskDetective.Core.ps1",
    "DiskDetective.Tools.ps1",
    "DiskDetective.Data.ps1",
    "Disk Detective.bat",
    "FEATURES.txt",
    "HOW TO USE.txt",
    "LICENSE"
)

foreach ($file in $releaseFiles) {
    $path = Join-Path $root $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release file is missing: $path"
    }
}

$dotnet = Get-Command dotnet -ErrorAction Stop
if (Test-Path -LiteralPath $launcherOutput) {
    Remove-Item -LiteralPath $launcherOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $launcherOutput -Force | Out-Null

Write-Host "Building launcher $Version..."
& $dotnet.Source build $launcherProject `
    -c Release `
    -o $launcherOutput `
    --nologo `
    "-p:Version=$Version" `
    "-p:AssemblyVersion=$fileVersion" `
    "-p:FileVersion=$fileVersion" `
    "-p:InformationalVersion=$Version" `
    "-p:DebugSymbols=false"
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE."
}

$launcher = Join-Path $launcherOutput "DiskDetectiveLauncher.exe"
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "The launcher was not produced: $launcher"
}

if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Host "Assembling the release folder..."
foreach ($file in $releaseFiles) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $stage $file)
}
Copy-Item -LiteralPath $launcher -Destination (Join-Path $stage "DiskDetectiveLauncher.exe")

$staged = @(Get-ChildItem -LiteralPath $stage -File)
if ($staged.Count -ne 9) {
    throw "The release folder should contain 9 files, but contains $($staged.Count)."
}

if (-not (Test-Path -LiteralPath $dist)) {
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
}
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}

Write-Host "Creating $zip..."
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal

if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
    throw "The candidate ZIP was not created: $zip"
}

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $zip).Length
Write-Host ""
Write-Host "Release candidate built (UNSIGNED):"
Write-Host "  $zip"
Write-Host "  $($staged.Count) files, $size bytes"
Write-Host "  SHA-256: $hash"
Write-Host ""
Write-Host "This script does not sign, commit, or publish anything."
