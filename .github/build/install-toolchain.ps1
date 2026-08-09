<#
.SYNOPSIS
    Installs FPC 3.2.2 and builds Lazarus 2.2.2's lazbuild from source on a Windows runner.

.DESCRIPTION
    The upstream README tells you to install Lazarus from the SourceForge installers.
    That is no longer scriptable: every SourceForge download host now redirects to
    downloads.sourceforge.net, which answers non-browser clients with a Cloudflare
    "Just a moment..." challenge (HTTP 403). Mirror hosts, browser-like headers and the
    /download interstitial all end at the same wall, from GitHub runners and from
    ordinary machines alike.

    So the toolchain is assembled from sources that are actually reachable:

      * FPC 3.2.2 (native i386-win32 plus the x86_64-win64 cross) from
        downloads.freepascal.org, which serves plain HTTP with no bot wall.
      * Lazarus 2.2.2 source from its GitLab tag, then `make lazbuild`.

    Versions stay pinned to what the upstream README specifies, so this is the same
    toolchain, just obtained differently.

    lazbuild itself is built as a native i386-win32 binary. It drives 64-bit builds
    through the cross compiler - exactly how the official "32-bit Lazarus + cross
    x86_64 add-on" combination works.
#>
[CmdletBinding()]
param(
    [string]$FpcVersion     = '3.2.2',
    [string]$LazarusVersion = '2.2.2',
    [string]$FpcDir         = 'C:\FPC',
    [string]$LazarusDir     = 'C:\lazarus',
    [string]$CacheDir       = 'C:\toolchain-cache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MinimumMegabytes,
        [string[]]$MagicBytes,      # e.g. @('4D','5A') for a PE image
        [int]$Attempts = 4
    )

    if (Test-Path -LiteralPath $Destination) {
        if (Test-Download -Path $Destination -MinimumMegabytes $MinimumMegabytes -MagicBytes $MagicBytes) {
            Write-Info "cache hit: $(Split-Path -Leaf $Destination)"
            return
        }
        Write-Info 'cached copy is unusable, re-downloading'
        Remove-Item -LiteralPath $Destination -Force
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Info "GET $Url (attempt $attempt/$Attempts)"
        & curl.exe --location --fail --silent --show-error `
            --retry 2 --retry-delay 5 --connect-timeout 30 --max-time 1800 `
            --output $Destination $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Download -Path $Destination -MinimumMegabytes $MinimumMegabytes -MagicBytes $MagicBytes)) {
            return
        }
        Write-Info "attempt failed (curl exit $LASTEXITCODE)"
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
    }

    throw "Could not download $Url"
}

function Test-Download {
    param([string]$Path, [int]$MinimumMegabytes, [string[]]$MagicBytes)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $sizeMb = (Get-Item -LiteralPath $Path).Length / 1MB
    if ($sizeMb -lt $MinimumMegabytes) {
        Write-Info "rejected: $([math]::Round($sizeMb,1)) MB < $MinimumMegabytes MB"
        return $false
    }

    if ($MagicBytes) {
        # -AsByteStream, not the Windows PowerShell 5.1 '-Encoding Byte'; CI runs pwsh 7.
        $header = Get-Content -LiteralPath $Path -AsByteStream -TotalCount $MagicBytes.Count
        for ($i = 0; $i -lt $MagicBytes.Count; $i++) {
            if ($header[$i] -ne [Convert]::ToByte($MagicBytes[$i], 16)) {
                Write-Info 'rejected: wrong magic bytes (an error page, not the file)'
                return $false
            }
        }
    }

    Write-Info "ok: $([math]::Round($sizeMb,1)) MB"
    return $true
}

function Install-InnoSetup {
    param([string]$Path, [string]$TargetDir)

    Write-Info "installing $(Split-Path -Leaf $Path) -> $TargetDir"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$TargetDir")
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$(Split-Path -Leaf $Path) failed with exit code $($process.ExitCode)"
    }
}

function Find-One {
    <# Locates exactly one tool under a root, and says something useful when it cannot. #>
    param([string]$Root, [string]$FileName, [string]$Because)

    $hit = Get-ChildItem -Path $Root -Recurse -Filter $FileName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $hit) { throw "$FileName not found under $Root - $Because" }
    return $hit.FullName
}

# --------------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

$fpcBase  = "https://downloads.freepascal.org/fpc/dist/$FpcVersion/i386-win32"
$lazTag   = "lazarus_$($LazarusVersion -replace '\.', '_')"
$lazUrl   = "https://gitlab.com/freepascal.org/lazarus/lazarus/-/archive/$lazTag/lazarus-$lazTag.tar.gz"

$fpcInstaller   = Join-Path $CacheDir "fpc-$FpcVersion.i386-win32.exe"
$fpcCrossX64    = Join-Path $CacheDir "fpc-$FpcVersion.i386-win32.cross.x86_64-win64.exe"
$lazarusTarball = Join-Path $CacheDir "lazarus-$LazarusVersion.tar.gz"

Write-Step "Downloading FPC $FpcVersion"
Get-RemoteFile -Url "$fpcBase/fpc-$FpcVersion.i386-win32.exe" `
    -Destination $fpcInstaller -MinimumMegabytes 40 -MagicBytes @('4D', '5A')
Get-RemoteFile -Url "$fpcBase/fpc-$FpcVersion.i386-win32.cross.x86_64-win64.exe" `
    -Destination $fpcCrossX64 -MinimumMegabytes 10 -MagicBytes @('4D', '5A')

Write-Step "Downloading Lazarus $LazarusVersion source ($lazTag)"
Get-RemoteFile -Url $lazUrl -Destination $lazarusTarball `
    -MinimumMegabytes 30 -MagicBytes @('1F', '8B')

Write-Step "Installing FPC to $FpcDir"
Install-InnoSetup -Path $fpcInstaller -TargetDir $FpcDir
Install-InnoSetup -Path $fpcCrossX64  -TargetDir $FpcDir

$ppc386 = Find-One -Root $FpcDir -FileName 'ppc386.exe' `
    -Because 'the native i386 compiler is missing, so nothing can be built'
$fpcBin = Split-Path -Parent $ppc386
Write-Info "fpc bin: $fpcBin"

# Without this the 64-bit targets would fall back to the host compiler and silently
# produce 32-bit binaries under a 64-bit name.
$ppcrossx64 = Join-Path $fpcBin 'ppcrossx64.exe'
if (-not (Test-Path -LiteralPath $ppcrossx64)) {
    Write-Info "contents of $fpcBin :"
    Get-ChildItem -LiteralPath $fpcBin -Filter 'ppc*.exe' | ForEach-Object { Write-Info "  $($_.Name)" }
    throw 'ppcrossx64.exe is missing - the x86_64-win64 cross compiler did not install.'
}
Write-Info 'cross compiler: ppcrossx64.exe present'

$make = Join-Path $fpcBin 'make.exe'
if (-not (Test-Path -LiteralPath $make)) {
    $make = Find-One -Root $FpcDir -FileName 'make.exe' -Because 'GNU make ships with FPC and is needed to build Lazarus'
}

Write-Step "Extracting Lazarus to $LazarusDir"
New-Item -ItemType Directory -Force -Path $LazarusDir | Out-Null
# tar.exe (bsdtar) is part of Windows Server 2019+ images.
& tar.exe -xzf $lazarusTarball -C $LazarusDir --strip-components=1
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath (Join-Path $LazarusDir 'Makefile'))) {
    throw "No Makefile at $LazarusDir - the archive layout is not what was expected."
}

Write-Step 'Building lazbuild'
# FPC's fpcmake-generated Makefiles switch to Unix mode if they find a Unix shell on
# PATH, and the runner image ships Git's sh.exe. Trim PATH down to FPC plus Windows
# for the duration of the make run.
$originalPath = $env:PATH
$env:PATH = "$fpcBin;$env:SystemRoot\system32;$env:SystemRoot"
try {
    Push-Location $LazarusDir
    & $make lazbuild 2>&1 | Tee-Object -FilePath (Join-Path $CacheDir 'make-lazbuild.log')
    $makeExit = $LASTEXITCODE
    Pop-Location
}
finally {
    $env:PATH = $originalPath
}

if ($makeExit -ne 0) { throw "'make lazbuild' failed with exit code $makeExit" }

$lazbuild = Join-Path $LazarusDir 'lazbuild.exe'
if (-not (Test-Path -LiteralPath $lazbuild)) { throw "lazbuild.exe was not produced at $lazbuild" }

Write-Step 'Verifying the toolchain'
& $lazbuild --version
Write-Info "lazbuild: $lazbuild"

# A lazbuild built from a source tree has no configuration yet, so its idea of the
# Lazarus directory is the empty string and every invocation dies with
# 'invalid Lazarus directory "": directory lcl not found'. Passing it explicitly on
# each call is more predictable than depending on a config file appearing.
$fpcExe = Join-Path $fpcBin 'fpc.exe'
$commonArgs = @("--lazarusdir=$LazarusDir")
if (Test-Path -LiteralPath $fpcExe) { $commonArgs += "--compiler=$fpcExe" }

# lazbuild resolves a project's package dependencies through registered package links.
# A source tree has none registered, so add the ones Cheat Engine asks for.
Write-Step 'Registering package links'
# Paths verified against the lazarus_2_2_2 tag by matching each <Name Value="..."/>
# in the .lpk files, not by guessing from directory names - FCL and LCL in particular
# do not live where you would expect.
$packageLinks = @(
    'components\lazutils\lazutils.lpk'                              # LazUtils
    'components\codetools\codetools.lpk'                            # CodeTools
    'components\buildintf\buildintf.lpk'
    'components\debuggerintf\debuggerintf.lpk'
    'components\ideintf\ideintf.lpk'                                # IDEIntf
    'components\lazcontrols\lazcontrols.lpk'                        # LazControls
    'components\synedit\synedit.lpk'                                # SynEdit
    'components\sqldb\sqldblaz.lpk'                                 # SQLDBLaz
    'components\virtualtreeview\laz.virtualtreeview_package.lpk'    # laz.virtualtreeview_package
    'packager\registration\fcl.lpk'                                 # FCL
    'lcl\lclbase.lpk'                                               # LCLBase
    'lcl\interfaces\lcl.lpk'                                        # LCL
)
foreach ($relative in $packageLinks) {
    $lpk = Join-Path $LazarusDir $relative
    if (Test-Path -LiteralPath $lpk) {
        Write-Info "link: $relative"
        & $lazbuild @commonArgs --add-package-link $lpk 2>&1 | Out-Null
    }
    else {
        Write-Info "missing (skipped): $relative"
    }
}

if ($env:GITHUB_ENV) {
    "FPC_BIN=$fpcBin"    | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "FPC_EXE=$fpcExe"    | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "LAZBUILD=$lazbuild" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Step 'Toolchain ready'

# GitHub's pwsh wrapper appends `exit $LASTEXITCODE`, so whatever the last native
# command returned becomes the step's result. lazbuild exits non-zero from
# --add-package-link even when it works, which would fail a step that succeeded.
# Reaching this line means every real error already threw.
exit 0
