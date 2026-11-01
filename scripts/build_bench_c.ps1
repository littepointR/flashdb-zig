<#
.SYNOPSIS
    Build and run the C reference host benchmark harness (upstream FlashDB).

.DESCRIPTION
    Builds bench/c (upstream FlashDB 2.2.99 + RAM NOR simulator) with the
    PINNED Zig nightly compiler acting as the C compiler (`zig cc`) for write
    granularity 8 and 1, each at -O2 and -Os, then runs

        <exe> --mode bench --runs <Runs> --out <json>

    and writes the four result documents

        bench/results/c_wg8_host.json      (-O2, FDB_WRITE_GRAN=8)
        bench/results/c_wg1_host.json      (-O2, FDB_WRITE_GRAN=1)
        bench/results/c_wg8_host_os.json   (-Os, FDB_WRITE_GRAN=8)
        bench/results/c_wg1_host_os.json   (-Os, FDB_WRITE_GRAN=1)

    Finally it prints the compact summary table produced by
    tools/bench_summary.py.

    The script fails loudly (non-zero exit) when a compile fails, a run exits
    non-zero, a JSON file is missing / not valid JSON, or the summary tool
    fails.  It does not modify anything under reference/FlashDB/ (the upstream
    sources are compiled unmodified).

.PARAMETER Runs
    Measured-phase repetitions per scenario (default 5, as in the protocol).

.PARAMETER WriteGran
    Write granularities to build (default 8,1).

.PARAMETER Opt
    Optimization levels to build (default O2,Os).

.PARAMETER Zig
    Path to the pinned zig executable (default <repo>/.tools/zig/zig.exe).

.PARAMETER NoSummary
    Skip the tools/bench_summary.py table.

.EXAMPLE
    pwsh -NoProfile -File scripts/build_bench_c.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/build_bench_c.ps1 -Runs 3 -WriteGran 8
#>
[CmdletBinding()]
param(
    [int]$Runs = 5,
    [int[]]$WriteGran = @(8, 1),
    [string[]]$Opt = @('O2', 'Os'),
    [string]$Zig = '',
    [switch]$NoSummary
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
$resDir = Join-Path $repoRoot 'bench/results'
New-Item -ItemType Directory -Force -Path $buildDir, $resDir | Out-Null

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

Write-Host "== C reference host benchmark =="
Write-Host "  repo   : $repoRoot"
Write-Host "  zig cc : $Zig ($zigVersion)"
Write-Host "  runs   : $Runs"
Write-Host ''

$produced = New-Object System.Collections.Generic.List[string]
$errors = 0

foreach ($opt in $Opt) {
    foreach ($wg in $WriteGran) {
        $tag = "wg$wg-$opt"
        $exe = Join-Path $buildDir "c_bench_wg$($wg)_$opt.exe"
        $suffix = if ($opt -eq 'Os') { '_host_os' } else { '_host' }
        $json = Join-Path $resDir "c_wg$($wg)$suffix.json"

        $flags = @(
            '-std=c99', "-$opt", '-w',
            "-DFDB_WRITE_GRAN=$wg",
            "-DBENCH_OPT=$opt",
            "-DBENCH_HOST=`"zig-cc-$zigVersion-windows-x86_64`"",
            "-DBENCH_BUILD_FLAGS=`"zig cc -std=c99 -$opt -w -DFDB_WRITE_GRAN=$wg`""
        )
        $ccArgs = @('cc') + $flags + $includes + $sources + @('-o', $exe)

        Write-Host "[$tag] cc -> $([System.IO.Path]::GetFileName($exe))"
        $t0 = Get-Date
        & $Zig @ccArgs
        if ($LASTEXITCODE -ne 0) {
            Fail "[$tag] zig cc failed with exit code $LASTEXITCODE"
        }
        $buildMs = [int]((Get-Date) - $t0).TotalMilliseconds

        if (-not (Test-Path -LiteralPath $exe)) {
            Fail "[$tag] compiler reported success but '$exe' does not exist"
        }

        if (Test-Path -LiteralPath $json) { Remove-Item -LiteralPath $json -Force }

        $log = Join-Path $buildDir "bench_wg$($wg)_$opt.log"
        Write-Host "[$tag] run --mode bench --runs $Runs --out $([System.IO.Path]::GetFileName($json))"
        $t1 = Get-Date
        & $exe --mode bench --runs $Runs --out $json *> $log
        $runCode = $LASTEXITCODE
        $runMs = [int]((Get-Date) - $t1).TotalMilliseconds
        if ($runCode -ne 0) {
            if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 20 }
            Fail "[$tag] benchmark exited with code $runCode (log: $log)"
        }
        if (-not (Test-Path -LiteralPath $json)) {
            Fail "[$tag] benchmark did not write '$json'"
        }

        try {
            $doc = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        } catch {
            Fail "[$tag] '$json' is not valid JSON: $_"
        }
        if ($null -eq $doc.scenarios -or @($doc.scenarios).Count -eq 0) {
            Fail "[$tag] '$json' contains no scenarios"
        }
        if ([int]$doc.write_gran -ne $wg) {
            Fail "[$tag] JSON write_gran=$($doc.write_gran), expected $wg"
        }
        if (@($doc.scenarios).Count -ne 16) {
            Write-Host "  WARNING: expected 16 scenarios, found $(@($doc.scenarios).Count)" -ForegroundColor Yellow
        }

        $produced.Add($json)
        Write-Host ("  PASS {0}: {1} scenarios, build {2} ms, run {3} ms" -f `
            $tag, @($doc.scenarios).Count, $buildMs, $runMs) -ForegroundColor Green
        Write-Host ''
    }
}

if ($produced.Count -eq 0) { Fail 'no result documents were produced' }

if (-not $NoSummary) {
    Write-Host '== summary (tools/bench_summary.py) =='
    & python (Join-Path $repoRoot 'tools/bench_summary.py') @produced
    if ($LASTEXITCODE -ne 0) { Fail "bench_summary.py failed with exit code $LASTEXITCODE" }
}

Write-Host ''
Write-Host "PASS: C host benchmark complete ($($produced.Count) JSON documents)" -ForegroundColor Green
Write-Host "  results dir: $resDir"
