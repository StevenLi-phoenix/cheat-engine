<#
.SYNOPSIS
    Builds the Lazarus/FreePascal parts of Cheat Engine with lazbuild.

.DESCRIPTION
    Every target below writes into "Cheat Engine\bin", which is where the rest of the
    portable distribution (the Lua scripts, the D3D hook DLLs, sqlite3, dbghelp, ...)
    already lives in-tree. So a successful run leaves "Cheat Engine\bin" as a ready
    to-zip portable build.

    Two things about build modes are worth knowing before editing the target table:

      * A mode marked Default="True" in the .lpi usually carries no explicit
        <TargetCPU>. On a win64 host that silently resolves to x86_64, which would
        make the "32-bit" modes produce 64-bit binaries. Those targets therefore pass
        Cpu/Os explicitly here.
      * Output names embed $(TargetCPU), so 32- and 64-bit builds of the same project
        do not overwrite each other.

    Targets flagged Required are the actual application. Everything else is a helper
    binary; a failure there is reported loudly and included in the exit summary, but
    does not sink the build, because the main executables remain usable without them.
#>
[CmdletBinding()]
param(
    [string]$LazarusDir = 'C:\lazarus',
    # Path to fpc.exe. Defaults to whatever install-toolchain.ps1 exported, then to a
    # search under C:\FPC.
    [string]$Compiler   = '',
    [string]$LogDir     = 'build-logs',
    # Force a full recompile of every unit (slower, but immune to stale .ppu files).
    [switch]$BuildAll,
    # Build only targets whose name matches this wildcard - handy for local iteration.
    [string]$Filter     = '*'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ceRoot   = Join-Path $repoRoot 'Cheat Engine'
$lazbuild = Join-Path $LazarusDir 'lazbuild.exe'

if (-not (Test-Path -LiteralPath $lazbuild)) { throw "lazbuild.exe not found at $lazbuild" }
if (-not (Test-Path -LiteralPath $ceRoot))   { throw "'Cheat Engine' folder not found under $repoRoot" }

if (-not $Compiler) {
    $Compiler = $env:FPC_EXE
    if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler)) {
        $found = Get-ChildItem -Path 'C:\FPC' -Recurse -Filter 'fpc.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $Compiler = if ($found) { $found.FullName } else { '' }
    }
}

# A lazbuild built from source has no stored configuration, so without --lazarusdir
# every call fails with 'invalid Lazarus directory ""'. Passed on every invocation
# rather than relying on a config file having been written earlier.
$commonArgs = @("--lazarusdir=$LazarusDir")
if ($Compiler) {
    $commonArgs += "--compiler=$Compiler"
    Write-Host "Compiler: $Compiler"
}
else {
    Write-Host 'Compiler: not located; falling back to whatever lazbuild finds' -ForegroundColor Yellow
}

# Name              Project (relative to "Cheat Engine")   BuildMode              Cpu      Os      Required
$targets = @(
    @{ Name = 'cheatengine-x86_64';      Lpi = 'cheatengine.lpi';            Mode = 'Release 64-Bit';      Cpu = 'x86_64'; Os = 'win64'; Required = $true  }
    @{ Name = 'cheatengine-i386';        Lpi = 'cheatengine.lpi';            Mode = 'Release 32-Bit';      Cpu = 'i386';   Os = 'win32'; Required = $true  }
    @{ Name = 'launcher';                Lpi = 'launcher\cheatengine.lpi';   Mode = 'release';             Cpu = 'i386';   Os = 'win32'; Required = $true  }

    @{ Name = 'cheatengine-avx2';        Lpi = 'cheatengine.lpi';            Mode = 'Release 64-Bit O4 AVX2'; Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'runtime-modifier';        Lpi = 'launcher\cheatengine.lpi';   Mode = 'release rtmod';       Cpu = 'i386';   Os = 'win32'; Required = $false }

    @{ Name = 'speedhack-i386';          Lpi = 'speedhack\speedhack.lpi';    Mode = '32-bit';              Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'speedhack-x86_64';        Lpi = 'speedhack\speedhack.lpi';    Mode = '64-bit';              Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'luaclient-i386';          Lpi = 'luaclient\luaclient.lpi';    Mode = 'Release 32';          Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'luaclient-x86_64';        Lpi = 'luaclient\luaclient.lpi';    Mode = 'Release 64';          Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'vehdebug-i386';           Lpi = 'VEHDebug\vehdebug.lpi';      Mode = 'release 32';          Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'vehdebug-x86_64';         Lpi = 'VEHDebug\vehdebug.lpi';      Mode = 'release 64';          Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'winhook-i386';            Lpi = 'winhook\winhook.lpi';        Mode = 'Release 32';          Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'winhook-x86_64';          Lpi = 'winhook\winhook.lpi';        Mode = 'Release 64';          Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'allochook-i386';          Lpi = 'allochook\allochook.lpi';    Mode = '32';                  Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'allochook-x86_64';        Lpi = 'allochook\allochook.lpi';    Mode = '64';                  Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'tutorial-i386';           Lpi = 'Tutorial\tutorial.lpi';      Mode = 'release 32-Bit';      Cpu = 'i386';   Os = 'win32'; Required = $false }
    @{ Name = 'tutorial-x86_64';         Lpi = 'Tutorial\tutorial.lpi';      Mode = 'release 64-Bit';      Cpu = 'x86_64'; Os = 'win64'; Required = $false }
    @{ Name = 'cepack';                  Lpi = 'cepack\cepack.lpi';          Mode = '';                    Cpu = 'i386';   Os = 'win32'; Required = $false }
)

$logRoot = Join-Path $repoRoot $LogDir
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

$results  = @()
$selected = $targets | Where-Object { $_.Name -like $Filter }

if (-not $selected) { throw "No targets matched filter '$Filter'." }

Write-Host "Building $($selected.Count) target(s) with $lazbuild" -ForegroundColor Cyan
Write-Host ''

foreach ($target in $selected) {
    $lpiPath = Join-Path $ceRoot $target.Lpi
    $label   = $target.Name

    if (-not (Test-Path -LiteralPath $lpiPath)) {
        Write-Host "SKIP  $label - $($target.Lpi) does not exist in this checkout" -ForegroundColor Yellow
        $results += [pscustomobject]@{ Name = $label; Status = 'skipped'; Seconds = 0; Required = $target.Required; Log = '' }
        continue
    }

    $arguments = $commonArgs + @("--cpu=$($target.Cpu)", "--os=$($target.Os)", '--widgetset=win32')
    if ($target.Mode) { $arguments += "--build-mode=$($target.Mode)" }
    if ($BuildAll)    { $arguments += '--build-all' }
    $arguments += $lpiPath

    $logFile = Join-Path $logRoot "$label.log"
    $descriptor = "$($target.Cpu)-$($target.Os)"
    if ($target.Mode) { $descriptor += " / $($target.Mode)" }
    Write-Host "BUILD $label  [$descriptor]" -ForegroundColor Cyan

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # 2>&1 folds lazbuild's stderr in so the log holds the complete compiler transcript.
    $output = & $lazbuild @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()

    $output | Out-File -FilePath $logFile -Encoding utf8
    $seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

    if ($exitCode -eq 0) {
        Write-Host "  ok    ${seconds}s" -ForegroundColor Green
        $results += [pscustomobject]@{ Name = $label; Status = 'ok'; Seconds = $seconds; Required = $target.Required; Log = $logFile }
    }
    else {
        $severity = if ($target.Required) { 'Red' } else { 'Yellow' }
        Write-Host "  FAILED (exit $exitCode) after ${seconds}s - tail of $label.log:" -ForegroundColor $severity
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host "    $_" }
        $results += [pscustomobject]@{ Name = $label; Status = 'failed'; Seconds = $seconds; Required = $target.Required; Log = $logFile }
    }
}

Write-Host ''
Write-Host '================ build summary ================' -ForegroundColor Cyan
$results |
    Select-Object @{ n = 'Target'; e = { $_.Name } },
                  @{ n = 'Status'; e = { $_.Status } },
                  @{ n = 'Sec';    e = { $_.Seconds } },
                  @{ n = 'Req';    e = { if ($_.Required) { 'yes' } else { '' } } } |
    Format-Table -AutoSize |
    Out-String -Width 120 |
    Write-Host

$binDir = Join-Path $ceRoot 'bin'
Write-Host '================ produced binaries ============' -ForegroundColor Cyan
Get-ChildItem -LiteralPath $binDir -File |
    Where-Object { $_.Extension -in @('.exe', '.dll') } |
    Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-42} {1,10:N0} bytes" -f $_.Name, $_.Length) }

# A GitHub step summary makes the outcome readable without opening the raw log.
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('## Lazarus build results', '', '| Target | Status | Seconds | Required |', '| --- | --- | --- | --- |')
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'ok' { 'ok' } 'failed' { '**FAILED**' } default { 'skipped' } }
        $lines += "| $($r.Name) | $icon | $($r.Seconds) | $(if ($r.Required) { 'yes' } else { 'no' }) |"
    }
    $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

$failedRequired = @($results | Where-Object { $_.Status -ne 'ok' -and $_.Required })
$failedOptional = @($results | Where-Object { $_.Status -ne 'ok' -and -not $_.Required })

if ($failedOptional.Count -gt 0) {
    Write-Host "Optional targets that did not build: $($failedOptional.Name -join ', ')" -ForegroundColor Yellow
}

if ($failedRequired.Count -gt 0) {
    throw "Required target(s) failed: $($failedRequired.Name -join ', ')"
}

Write-Host 'All required targets built.' -ForegroundColor Green

# GitHub's pwsh wrapper appends `exit $LASTEXITCODE`. A failed optional target would
# otherwise leave a non-zero code behind and sink a build that met its requirements.
exit 0
