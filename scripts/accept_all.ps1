#requires -Version 7.0
<#
.SYNOPSIS
    One-command acceptance run: tests, C baseline, Zig benchmark, comparison,
    C<->Zig behavioural diff, and the Cortex-M3/QEMU firmware comparison.

.DESCRIPTION
    Every step must succeed. The script prints a summary table at the end with
    the headline numbers and exits non-zero if any step failed or if a gate
    (KV checksums, behavioural parity, firmware checksums) did not pass.

    Usage:
        pwsh -NoProfile -File scripts/accept_all.ps1
        pwsh -NoProfile -File scripts/accept_all.ps1 -SkipC        # reuse C JSONs/binaries
        pwsh -NoProfile -File scripts/accept_all.ps1 -SkipFirmware # host-only acceptance
#>
param(
    [switch]$SkipC,
    [switch]$SkipFirmware,
    [int]$Runs = 5
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$zig = Join-Path $repo '.tools/zig/zig.exe'
if (-not (Test-Path $zig)) { throw "pinned zig not found at $zig" }
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { throw "python not found" }

$script:results = [ordered]@{}
$script:failures = @()

function Run-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host "===== $Name =====" -ForegroundColor Cyan
    try {
        & $Body
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "exit code $LASTEXITCODE" }
        $script:results[$Name] = 'PASS'
        Write-Host "PASS: $Name" -ForegroundColor Green
    } catch {
        $script:results[$Name] = "FAIL: $($_.Exception.Message)"
        $script:failures += $Name
        Write-Host "FAIL: $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

Run-Step "library tests (zig build test)" {
    & $zig build test
}

Run-Step "function coverage (100%)" {
    & python tools/coverage.py --min-functions 100
}

if (-not $SkipC) {
    Run-Step "C harness self-checks" { & pwsh -NoProfile -File scripts/check_bench_c.ps1 }
    Run-Step "C reference host benchmark" { & pwsh -NoProfile -File scripts/build_bench_c.ps1 }
}

Run-Step "Zig host benchmark (wg8 + wg1)" {
    & $zig build bench
    & (Join-Path $repo 'zig-out/bin/flashdb-bench.exe') --wg 8 --runs $Runs --out bench/results/zig_wg8_host.json
    & (Join-Path $repo 'zig-out/bin/flashdb-bench.exe') --wg 1 --runs $Runs --out bench/results/zig_wg1_host.json
}

foreach ($wg in 8, 1) {
    Run-Step "C<->Zig host comparison (wg$wg)" {
        & python tools/compare_bench.py "bench/results/c_wg${wg}_host.json" "bench/results/zig_wg${wg}_host.json" --metric min --normalize-ts --checksum-scope kv
    }
}

Run-Step "C<->Zig behavioural differential (KV + TS)" {
    & pwsh -NoProfile -File scripts/diff.ps1
}

if (-not $SkipFirmware) {
    if (-not $SkipC) {
        Run-Step "C Cortex-M3/QEMU firmware" { & pwsh -NoProfile -File scripts/build_fw_c.ps1 }
    }
    Run-Step "Zig Cortex-M3/QEMU firmware" { & pwsh -NoProfile -File firmware/zig/build.ps1 }
}

Write-Host ""
Write-Host "================ acceptance summary ================" -ForegroundColor Cyan
foreach ($k in $script:results.Keys) {
    $status = $script:results[$k]
    $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("{0,-42} {1}" -f $k, $status) -ForegroundColor $color
}

# ---- headline numbers -----------------------------------------------------
Write-Host ""
Write-Host "---- host benchmark: Zig / C weighted flash cost (lower is better) ----"
foreach ($wg in 8, 1) {
    $cPath = "bench/results/c_wg${wg}_host.json"
    $zPath = "bench/results/zig_wg${wg}_host.json"
    if ((Test-Path $cPath) -and (Test-Path $zPath)) {
        $c = Get-Content $cPath -Raw | ConvertFrom-Json
        $z = Get-Content $zPath -Raw | ConvertFrom-Json
        $cw = 0; $zw = 0
        foreach ($s in $c.scenarios) { $cw += $s.flash.read_bytes + 10 * $s.flash.write_bytes + 100 * $s.flash.erase_bytes }
        foreach ($s in $z.scenarios) { $zw += $s.flash.read_bytes + 10 * $s.flash.write_bytes + 100 * $s.flash.erase_bytes }
        Write-Host ("wg{0}: C={1,12:N0}  Zig={2,12:N0}  ratio={3:N3}" -f $wg, $cw, $zw, ($zw / [double]$cw))
    }
}

Write-Host ""
Write-Host "---- Cortex-M3/QEMU firmware (plain variant) ----"
$cf = 'bench/results/c_firmware.json'
$zf = 'bench/results/zig_firmware.json'
if ((Test-Path $cf) -and (Test-Path $zf)) {
    $c = Get-Content $cf -Raw | ConvertFrom-Json
    $z = Get-Content $zf -Raw | ConvertFrom-Json
    $cp = $c.variants.plain
    $zp = $z.variants.plain
    Write-Host ("ROM          C={0,6}  Zig={1,6}  ratio={2:N3}" -f $cp.rom, $zp.rom, ($zp.rom / [double]$cp.rom))
    Write-Host ("static RAM   C={0,6}  Zig={1,6}  ratio={2:N3}" -f $cp.static_ram, $zp.static_ram, ($zp.static_ram / [double]$cp.static_ram))
    Write-Host ("peak stack   C={0,6}  Zig={1,6}  ratio={2:N3}" -f $cp.stack, $zp.stack, ($zp.stack / [double]$cp.stack))
    $ci = $c.variants.instrumented
    $zi = $z.variants.instrumented
    if ($ci.cycles -and $zi.cycles) {
        Write-Host ("cycles total C={0,8}  Zig={1,8}  ratio={2:N3}" -f $ci.cycles.total, $zi.cycles.total, ($zi.cycles.total / [double]$ci.cycles.total))
    }
    if ($zp.results.kv_checksum -ne $cp.results.kv_checksum -or $zp.results.ts_checksum -ne $cp.results.ts_checksum) {
        Write-Host "FAIL: firmware workload checksums differ from C" -ForegroundColor Red
        $script:failures += 'firmware checksums'
    } else {
        Write-Host "firmware workload checksums: identical to C (kv, kv_iter, ts)" -ForegroundColor Green
    }
}

Write-Host ""
if ($script:failures.Count -gt 0) {
    Write-Host ("ACCEPTANCE FAILED: {0}" -f ($script:failures -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "ACCEPTANCE PASSED" -ForegroundColor Green
exit 0
