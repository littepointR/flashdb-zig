<#
.SYNOPSIS
    Build and run the C<->Zig behavioural differential harness (KV and TSDB).

.DESCRIPTION
    Builds the two implementations of the deterministic differential operation
    script and compares their canonical output:

      bench/diff/c/diff_bench.c   - unmodified C FlashDB 2.2.99 on the bench/c
                                    RAM NOR simulator (compiled with zig cc)
      bench/diff/zig/main.zig     - the Zig FlashDB library (imported as the
                                    "flashdb" module of the pinned toolchain)

    The C executable is a normal host program.  The Zig executable is built
    with the module CLI of the pinned Zig nightly:

        zig build-exe -O ReleaseSafe -femit-bin=build/diff/diff_zig `
            --dep flashdb -Mroot=<abs bench/diff/zig/main.zig> `
            -Mflashdb=<abs src/flashdb.zig>

    (the pinned 0.18.0-dev compiler rejects a file extension on -femit-bin and
    misparses relative -Mroot paths, hence the extensionless output that is
    renamed to .exe afterwards, and the absolute module paths).

    Then tools/diff_model.py compares the outputs: the main script section must
    be identical line for line, the crash-recovery section is validated against
    the allowed post-crash outcome sets (the on-flash formats legitimately
    differ, so cut indexes do not line up).

    Exit status is 0 only when both programs exit 0 and the differential check
    passes.  A build failure, a non-zero program exit, or a divergent line
    fails the run loudly.

.PARAMETER Zig
    Path to the pinned zig executable (default <repo>/.tools/zig/zig.exe).

.PARAMETER BuildOnly
    Build both executables, do not run the comparison.

.PARAMETER ShowLines
    Pass --verbose to tools/diff_model.py (prints every compared line).

.EXAMPLE
    pwsh -NoProfile -File scripts/diff.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/diff.ps1 -ShowLines
#>
[CmdletBinding()]
param(
    [string]$Zig = '',
    [switch]$BuildOnly,
    [switch]$ShowLines
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($Zig -eq '') { $Zig = Join-Path $repoRoot '.tools/zig/zig.exe' }

$buildDir = Join-Path $repoRoot 'build/diff'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

function Fail([string]$msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    throw $msg
}

if (-not (Test-Path -LiteralPath $Zig)) { Fail "pinned zig compiler not found: $Zig" }
$zigVersion = (& $Zig version).Trim()
if ($LASTEXITCODE -ne 0) { Fail "cannot execute '$Zig version'" }

$ref = Join-Path $repoRoot 'reference/FlashDB'
$benchC = Join-Path $repoRoot 'bench/c'
$diffC = Join-Path $repoRoot 'bench/diff/c/diff_bench.c'
$diffZig = Join-Path $repoRoot 'bench/diff/zig/main.zig'
$fdbZig = Join-Path $repoRoot 'src/flashdb.zig'

$cSources = @(
    $diffC,
    (Join-Path $benchC 'sim_flash.c'),
    (Join-Path $ref 'src/fdb.c'),
    (Join-Path $ref 'src/fdb_kvdb.c'),
    (Join-Path $ref 'src/fdb_tsdb.c'),
    (Join-Path $ref 'src/fdb_utils.c'),
    (Join-Path $ref 'port/fal/src/fal.c'),
    (Join-Path $ref 'port/fal/src/fal_flash.c'),
    (Join-Path $ref 'port/fal/src/fal_partition.c')
)
foreach ($src in $cSources) {
    if (-not (Test-Path -LiteralPath $src)) { Fail "source not found: $src" }
}

$cExe = Join-Path $buildDir 'diff_c.exe'
$zigExe = Join-Path $buildDir 'diff_zig.exe'
$zigRaw = [System.IO.Path]::Combine($buildDir, 'diff_zig')

Write-Host '== C<->Zig KV+TS differential harness =='
Write-Host "  zig cc : $Zig ($zigVersion)"
Write-Host ''

# ---- C side ---------------------------------------------------------------
$cFlags = @(
    'cc', '-std=c99', '-O2', '-w', '-DFDB_WRITE_GRAN=8',
    '-I', $benchC,
    '-I', (Join-Path $ref 'inc'),
    '-I', (Join-Path $ref 'port/fal/inc')
)
Write-Host '[build] diff_c.exe (unmodified C FlashDB 2.2.99)'
& $Zig @($cFlags + $cSources + @('-o', $cExe))
if ($LASTEXITCODE -ne 0) { Fail "C build failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $cExe)) { Fail "C build produced no '$cExe'" }

# ---- Zig side -------------------------------------------------------------
Write-Host '[build] diff_zig.exe (Zig library via the "flashdb" module)'
if (Test-Path -LiteralPath $zigRaw) { Remove-Item -LiteralPath $zigRaw -Force }
$zigArgs = @(
    'build-exe', '-O', 'ReleaseSafe',
    "-femit-bin=$zigRaw",
    '--dep', 'flashdb',
    "-Mroot=$diffZig",
    "-Mflashdb=$fdbZig"
)
& $Zig @zigArgs
if ($LASTEXITCODE -ne 0) { Fail "Zig build failed with exit code $LASTEXITCODE" }
if (Test-Path -LiteralPath $zigRaw) {
    Move-Item -LiteralPath $zigRaw -Destination $zigExe -Force
} elseif (-not (Test-Path -LiteralPath $zigExe)) {
    Fail "Zig build produced neither '$zigRaw' nor '$zigExe'"
}

Write-Host ''
if ($BuildOnly) {
    Write-Host "build only: $cExe, $zigExe"
    exit 0
}

# ---- differential comparison ---------------------------------------------
$toolArgs = @((Join-Path $repoRoot 'tools/diff_model.py'), $cExe, $zigExe,
              '--save-dir', $buildDir)
if ($ShowLines) { $toolArgs += '--verbose' }
& python @toolArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) { Fail "differential comparison failed (exit $rc)" }

Write-Host ''
Write-Host 'PASS: C and Zig KV+TS behaviour is identical under the differential script' -ForegroundColor Green
exit 0
