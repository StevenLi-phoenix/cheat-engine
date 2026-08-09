<#
.SYNOPSIS
    Packages "Cheat Engine\bin" into a portable zip plus a SHA256 manifest.

.DESCRIPTION
    "Cheat Engine\bin" is already the portable layout: the freshly compiled
    executables sit next to the Lua runtime, language files and helper DLLs that are
    committed to the repository. Packaging is therefore mostly "zip that folder".

    The SHA256 manifest matters more than usual here. These builds are unsigned, so a
    published checksum is the only thing a downloader can check the archive against -
    which means the manifest has to actually be usable:

      * Entries are written with LF line endings. CRLF puts a stray carriage return on
        the end of every filename, and `sha256sum -c` then reports every single line
        as missing.
      * Paths are relative to the archive's own top-level folder, so running
        `sha256sum -c SHA256SUMS.txt` next to the extracted directory just works.

    The archive carries a single top-level folder for the same reason: extracting it
    should not scatter ~300 files across whatever directory the user happened to be in.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutputDir = 'dist'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$binDir   = Join-Path $repoRoot 'Cheat Engine\bin'
$distDir  = Join-Path $repoRoot $OutputDir

if (-not (Test-Path -LiteralPath $binDir)) { throw "Expected build output at $binDir" }

# Refuse to ship an archive that is missing the thing people actually launch.
$mustExist = @('Cheat Engine.exe', 'cheatengine-i386.exe', 'cheatengine-x86_64.exe')
$missing   = $mustExist | Where-Object { -not (Test-Path -LiteralPath (Join-Path $binDir $_)) }
if ($missing) { throw "Refusing to package - missing required binaries: $($missing -join ', ')" }

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$folderName  = "CheatEngine-$Version"
$archiveName = "$folderName-portable-unsigned.zip"
$archivePath = Join-Path $distDir $archiveName
$stagingRoot = Join-Path $distDir '_staging'
$stagingDir  = Join-Path $stagingRoot $folderName

if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }

Write-Host "==> Staging $binDir as $folderName" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
Copy-Item -Path (Join-Path $binDir '*') -Destination $stagingDir -Recurse -Force

Write-Host '==> Compressing' -ForegroundColor Cyan
# ZipFile::CreateFromDirectory rather than Compress-Archive: bin/ holds a few thousand
# files across languages/, autorun/ and include/, where Compress-Archive is both slow
# and prone to tripping over long paths. includeBaseDirectory puts everything under
# the single $folderName root.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stagingDir,
    $archivePath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)

$archiveMb = [math]::Round((Get-Item -LiteralPath $archivePath).Length / 1MB, 1)
Write-Host "    $archiveName ($archiveMb MB)"

Write-Host '==> Writing SHA256 manifest' -ForegroundColor Cyan
$manifestPath = Join-Path $distDir 'SHA256SUMS.txt'
$lines = @()

# The archive itself first, then each compiled binary, so a user can verify either the
# download as a whole or a single extracted executable.
$lines += '{0}  {1}' -f (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLower(), $archiveName

Get-ChildItem -LiteralPath $binDir -File |
    Where-Object { $_.Extension -in @('.exe', '.dll') } |
    Sort-Object Name |
    ForEach-Object {
        $lines += '{0}  {1}/{2}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $folderName, $_.Name
    }

# WriteAllText with an explicit LF join: Out-File would give CRLF, which breaks
# `sha256sum -c` on every non-Windows machine.
[System.IO.File]::WriteAllText($manifestPath, ($lines -join "`n") + "`n", [System.Text.Encoding]::ASCII)
Write-Host "    $($lines.Count) entries -> SHA256SUMS.txt"

# Staging would otherwise be picked up by `gh release create dist/*`.
Remove-Item -LiteralPath $stagingRoot -Recurse -Force

if ($env:GITHUB_OUTPUT) {
    "archive_path=$archivePath"   | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "archive_name=$archiveName"   | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "manifest_path=$manifestPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

Write-Host '==> Package ready' -ForegroundColor Green
exit 0
