<#
.SYNOPSIS
    Build and run the C reference harness self-checks (--mode check).

.DESCRIPTION
    Compiles bench/c with the PINNED Zig nightly (`zig cc`) for
    FDB_WRITE_GRAN=8 and FDB_WRITE_GRAN=1 (-O2) and runs

        <exe> --mode check

    for each variant.  `--mode check` exercises the simulator invariants
    (NOR AND-write semantics, erase alignment, fault injection), the FAL
    partition table, KVDB format / set / get / delete / iterate / remount
    behaviour, TSDB append / rollover / remount / query-count behaviour and
    the harness's checksum/JSON plumbing.  The executable exits non-zero on
    the first failed invariant.

    The script exits non-zero when a compile or a check run fails, printing
    which variant failed.

.PARAMETER Zig
    Path to the pinned zig executable (default <repo>/.tools/zig/zig.exe).

.EXAMPLE
    pwsh -NoProfile -File scripts/check_bench_c.ps1
#>
[CmdletBinding()]
param(
    [string]$Zig = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($Zig -eq '') { $Zig = Join-Path $repoRoot '.tools/zig/zig.exe' }

function Fail([string]$msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    throw $msg
}

if (-not (Test-Path -LiteralPath $Zig)) {
    Fail "pinned zig compiler not found: $Zig"
}
$zigVersion = (& $Zig version).Trim()
if ($LASTEXITCODE -ne 0) { Fail "cannot execute '$Zig version'" }

$buildDir = Join-Path $repoRoot 'build/c'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$sources = @(
    'bench/c/bench.c',
    'bench/c/bench_common.c',
    'bench/c/bench_kv.c',
    'bench/c/bench_ts.c',
    'bench/c/sim_flash.c',
    'reference/FlashDB/src/fdb.c',
    'reference/FlashDB/src/fdb_kvdb.c',
    'reference/FlashDB/src/fdb_tsdb.c',
    'reference/FlashDB/src/fdb_utils.c',
    'reference/FlashDB/port/fal/src/fal.c',
    'reference/FlashDB/port/fal/src/fal_flash.c',
    'reference/FlashDB/port/fal/src/fal_partition.c'
) | ForEach-Object { Join-Path $repoRoot $_ }

$includes = @(
    '-I', (Join-Path $repoRoot 'bench/c'),
    '-I', (Join-Path $repoRoot 'reference/FlashDB/inc'),
    '-I', (Join-Path $repoRoot 'reference/FlashDB/port/fal/inc')
)
foreach ($src in $sources) {
    if (-not (Test-Path -LiteralPath $src)) { Fail "source not found: $src" }
}

Write-Host '== C reference harness self-check (--mode check) =='
Write-Host "  zig cc : $Zig ($zigVersion)"
Write-Host ''

$failed = @()
foreach ($wg in 8, 1) {
    $exe = Join-Path $buildDir "c_check_wg$wg.exe"
    $flags = @('-std=c99', '-O2', '-w', "-DFDB_WRITE_GRAN=$wg")
    $ccArgs = @('cc') + $flags + $includes + $sources + @('-o', $exe)

    Write-Host "[wg$wg] cc -> $([System.IO.Path]::GetFileName($exe))"
    & $Zig @ccArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[wg$wg] COMPILE FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed += "wg$wg (compile)"
        continue
    }

    Write-Host "[wg$wg] run --mode check"
    & $exe --mode check
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "[wg$wg] CHECK FAILED (exit $code)" -ForegroundColor Red
        $failed += "wg$wg (check)"
    } else {
        Write-Host "[wg$wg] PASS" -ForegroundColor Green
    }
    Write-Host ''
}

if ($failed.Count -ne 0) {
    Fail ("self-checks failed: " + ($failed -join ', '))
}

Write-Host 'PASS: all C harness self-checks succeeded (wg8, wg1)' -ForegroundColor Green
