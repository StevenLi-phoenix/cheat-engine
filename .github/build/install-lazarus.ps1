<#
.SYNOPSIS
    Installs Lazarus + FPC (and the i386-win32 cross compiler) on a Windows CI runner.

.DESCRIPTION
    Mirrors the toolchain documented in the upstream README:
        lazarus-<ver>-fpc-<fpc>-win64.exe
        lazarus-<ver>-fpc-<fpc>-cross-i386-win32-win64.exe

    Both are Inno Setup installers, so /VERYSILENT works. Installers are downloaded
    into -CacheDir so actions/cache can keep them between runs (~257 MB total).

    SourceForge is fronted by an HTML "your download will start shortly" interstitial
    on some paths, so every download is validated as a real PE image (MZ header +
    plausible size) before being accepted. A truncated or HTML response is discarded
    and the next mirror is tried.
#>
[CmdletBinding()]
param(
    [string]$LazarusVersion = '2.2.2',
    [string]$FpcVersion     = '3.2.2',
    [string]$InstallDir     = 'C:\lazarus',
    [string]$CacheDir       = 'C:\lazarus-installers',
    [int]$MaxAttemptsPerUrl = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # a visible progress bar makes Invoke-WebRequest ~10x slower

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

# SourceForge folder that holds the Windows 64-bit builds for this release.
$sfPath = "Lazarus Windows 64 bits/Lazarus $LazarusVersion"

function Get-DownloadUrls {
    param([string]$FileName)
    # Escape once; SourceForge paths contain spaces.
    $escapedPath = [uri]::EscapeUriString($sfPath)
    @(
        "https://downloads.sourceforge.net/project/lazarus/$escapedPath/$FileName"
        "https://netcologne.dl.sourceforge.net/project/lazarus/$escapedPath/$FileName"
        "https://phoenixnap.dl.sourceforge.net/project/lazarus/$escapedPath/$FileName"
        "https://sourceforge.net/projects/lazarus/files/$escapedPath/$FileName/download"
    )
}

function Test-PeImage {
    <# Returns $true only for something that actually looks like a Windows installer. #>
    param([string]$Path, [int]$MinimumMegabytes)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $sizeMb = (Get-Item -LiteralPath $Path).Length / 1MB
    if ($sizeMb -lt $MinimumMegabytes) {
        Write-Info "rejected: $([math]::Round($sizeMb,1)) MB is below the $MinimumMegabytes MB minimum"
        return $false
    }

    # -AsByteStream, not the Windows PowerShell 5.1 '-Encoding Byte', which PowerShell 7
    # removed. CI runs pwsh 7.
    $header = Get-Content -LiteralPath $Path -AsByteStream -TotalCount 2
    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        Write-Info "rejected: missing 'MZ' header (probably an HTML interstitial)"
        return $false
    }

    Write-Info "ok: $([math]::Round($sizeMb,1)) MB, valid PE image"
    return $true
}

function Get-Installer {
    param([string]$FileName, [int]$MinimumMegabytes)

    $target = Join-Path $CacheDir $FileName

    if (Test-Path -LiteralPath $target) {
        Write-Info "cache hit: $FileName"
        if (Test-PeImage -Path $target -MinimumMegabytes $MinimumMegabytes) { return $target }
        Write-Info 'cached copy is corrupt, re-downloading'
        Remove-Item -LiteralPath $target -Force
    }

    foreach ($url in (Get-DownloadUrls -FileName $FileName)) {
        for ($attempt = 1; $attempt -le $MaxAttemptsPerUrl; $attempt++) {
            Write-Info "GET $url (attempt $attempt/$MaxAttemptsPerUrl)"
            try {
                # curl.exe ships with Windows Server images and handles SourceForge's
                # mirror redirects more predictably than Invoke-WebRequest.
                & curl.exe --location --fail --silent --show-error `
                    --retry 2 --retry-delay 5 --connect-timeout 30 --max-time 1800 `
                    --user-agent 'Mozilla/5.0' `
                    --output $target $url
                if ($LASTEXITCODE -ne 0) { throw "curl exited with $LASTEXITCODE" }
            }
            catch {
                Write-Info "download failed: $($_.Exception.Message)"
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                Start-Sleep -Seconds 5
                continue
            }

            if (Test-PeImage -Path $target -MinimumMegabytes $MinimumMegabytes) { return $target }
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
    }

    throw "Could not download a valid $FileName from any mirror."
}

function Install-Silently {
    param([string]$Path, [string]$ExpectedFile, [int]$SettleSeconds = 120)

    Write-Info "running $(Split-Path -Leaf $Path)"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$InstallDir")
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$(Split-Path -Leaf $Path) failed with exit code $($process.ExitCode)"
    }

    # Inno Setup re-launches itself from a temp directory, so the process we waited on
    # can exit slightly before the files land. Give the expected artefact a moment.
    if ($ExpectedFile) {
        $deadline = (Get-Date).AddSeconds($SettleSeconds)
        while (-not (Test-Path -LiteralPath $ExpectedFile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
        }
    }
}

# --------------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

$baseInstaller  = "lazarus-$LazarusVersion-fpc-$FpcVersion-win64.exe"
$crossInstaller = "lazarus-$LazarusVersion-fpc-$FpcVersion-cross-i386-win32-win64.exe"

Write-Step "Fetching Lazarus $LazarusVersion / FPC $FpcVersion installers"
$basePath  = Get-Installer -FileName $baseInstaller  -MinimumMegabytes 150
$crossPath = Get-Installer -FileName $crossInstaller -MinimumMegabytes 30

$lazbuild = Join-Path $InstallDir 'lazbuild.exe'

Write-Step "Installing Lazarus to $InstallDir"
Install-Silently -Path $basePath -ExpectedFile $lazbuild

Write-Step 'Installing the i386-win32 cross compiler'
# Must run after the base install: the add-on locates Lazarus through the registry key
# the base installer writes.
Install-Silently -Path $crossPath -ExpectedFile (Join-Path $InstallDir "fpc\$FpcVersion\bin\x86_64-win64\ppcross386.exe")

Write-Step 'Verifying the toolchain'
if (-not (Test-Path -LiteralPath $lazbuild)) {
    throw "lazbuild.exe not found at $lazbuild - the installer did not lay down a usable tree."
}
& $lazbuild --version
Write-Info "lazbuild: $lazbuild"

$fpcRoot = Join-Path $InstallDir 'fpc'
$compilers = @(
    Get-ChildItem -Path $fpcRoot -Recurse -Filter 'ppc*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^ppc(ross)?(386|x64)\.exe$' }
)
foreach ($compiler in $compilers) { Write-Info "compiler: $($compiler.FullName)" }

# On a win64 host the i386 back end installs as ppcross386.exe; a native win32 install
# would name it ppc386.exe. Accept either, but insist one of them exists - without it
# the 32-bit targets would quietly come out as 64-bit binaries.
$has386 = @($compilers | Where-Object { $_.Name -in @('ppc386.exe', 'ppcross386.exe') }).Count -gt 0
$hasX64 = @($compilers | Where-Object { $_.Name -in @('ppcx64.exe', 'ppcrossx64.exe') }).Count -gt 0

if (-not $has386) { throw 'No i386 compiler (ppc386.exe / ppcross386.exe) found - the cross compiler add-on did not install.' }
if (-not $hasX64) { throw 'No x86_64 compiler (ppcx64.exe) found - the base install is incomplete.' }

# Register the packages Cheat Engine depends on that are not linked by default on a
# fresh install. lazbuild resolves project dependencies through these package links.
Write-Step 'Registering bundled package links'
$packageLinks = @(
    'components\virtualtreeview\laz.virtualtreeview_package.lpk'
    'components\lazcontrols\lazcontrols.lpk'
    'components\sqldb\sqldblaz.lpk'
    'components\synedit\synedit.lpk'
)
foreach ($relative in $packageLinks) {
    $lpk = Join-Path $InstallDir $relative
    if (Test-Path -LiteralPath $lpk) {
        Write-Info "link: $relative"
        & $lazbuild --add-package-link $lpk 2>&1 | Out-Null
    }
    else {
        Write-Info "skip (not present in this Lazarus release): $relative"
    }
}

Write-Step 'Lazarus is ready'
