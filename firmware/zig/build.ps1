<#
.SYNOPSIS
    Build, size and run the Zig FlashDB Cortex-M3 firmware measurement image.

.DESCRIPTION
    Completes the C <-> Zig firmware comparison started by
    scripts/build_fw_c.ps1: builds a freestanding Zig firmware for the ARM
    MPS2-AN385 board (Cortex-M3) that runs the *identical* deterministic
    workload from firmware/common/workload_spec.h on the Zig FlashDB
    implementation (src/flashdb.zig), then runs it under
    qemu-system-arm (-M mps2-an385 -cpu cortex-m3 -semihosting -icount shift=0),
    parses the single semihosting RESULT line and writes
    bench/results/zig_firmware.json.

    Fairness: the harness is compiled from the UNMODIFIED C sources in
    firmware/common/ (startup vector table, semihosting console, cycle
    counter, stack painting, linker script); both the C and the Zig image carry
    exactly the same harness bytes. The Zig image links Zig compiler_rt for the
    EABI mem*/64-bit helper surface where the C image links firmware/c/
    libc_stubs.c (firmware/README.md portability note 3). Only the workload +
    database code is Zig.

    Build pipeline (two stages, the same split the C image uses):

      1. Zig workload + database  ->  one relocatable object
             zig build-obj -target thumb-freestanding-eabi -mcpu=cortex_m3
                 -O ReleaseSmall --dep flashdb
                 -Mroot=firmware/zig/main.zig -Mflashdb=src/flashdb.zig
                 -femit-bin=build/fw/zig_plain.o

      2. C harness + Zig object   ->  final ELF
             zig cc -target thumb-freestanding-eabi -mcpu=cortex_m3 -Os
                 -std=gnu11 -w ... -Wl,--gc-sections
                 -Wl,-T,firmware/common/mps2_an385.ld -Wl,-e,Reset_Handler
                 <firmware/common/*.S|c> build/fw/zig_plain.o
                 -o build/fw/fw_zig_plain.elf

    Two variants are built and measured by default, mirroring the C script:

      plain         - no cycle/phase instrumentation (pure library + harness
                      footprint; comparable to fw_c_plain.elf),
      instrumented  - the Zig root registers the same instrumentation the C
                      build gets from -DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1:
                      cycle counts of every phase (DWT on silicon, SysTick
                      virtual-time proxy under QEMU) plus per-phase stack
                      peaks.

    Each variant is run TWICE and the two RESULT lines must be identical, so a
    non-deterministic build/run is caught immediately.

    Exit status is 0 only when both builds link, both QEMU runs print exactly
    one `RESULT ... rc=0` line, the RESULT/llvm-size numbers agree and the
    expected workload checksums are reproduced.  A timeout (hard fault, missing
    vector table), missing RESULT, rc != 0 or any inconsistency fails loudly.

.PARAMETER Zig
    Path to the pinned zig executable (default <repo>/.tools/zig/zig.exe).

.PARAMETER TimeoutSec
    Per QEMU run timeout in seconds (default 60).

.PARAMETER Cycles
    Measure cycle counts in the instrumented variant (default: on).
    Disable with -Cycles:$false.

.PARAMETER Phases
    Add per-phase stack peaks (and per-phase cycles) to the instrumented
    variant (default: on).  Disable with -Phases:$false.

.PARAMETER BuildOnly
    Build and print section sizes; do not run QEMU and do not write JSON.

.PARAMETER OutJson
    JSON output path (default <repo>/bench/results/zig_firmware.json).

.EXAMPLE
    pwsh -NoProfile -File firmware/zig/build.ps1

.EXAMPLE
    pwsh -NoProfile -File firmware/zig/build.ps1 -BuildOnly

.EXAMPLE
    pwsh -NoProfile -File firmware/zig/build.ps1 -Cycles:`$false -Phases:`$false
#>
[CmdletBinding()]
param(
    [string]$Zig = '',
    [int]$TimeoutSec = 60,
    [switch]$Cycles = $true,
    [switch]$Phases = $true,
    [switch]$BuildOnly,
    [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Zig -eq '') { $Zig = Join-Path $repoRoot '.tools/zig/zig.exe' }
if ($OutJson -eq '') { $OutJson = Join-Path $repoRoot 'bench/results/zig_firmware.json' }

$buildDir = Join-Path $repoRoot 'build/fw'
$resDir = Join-Path $repoRoot 'bench/results'
New-Item -ItemType Directory -Force -Path $buildDir, $resDir | Out-Null

# --------------------------------------------------------------------------
# Workload scope: the TSDB workload (200 appends + full iteration) is wired in
# `firmware/zig/fw.zig` behind `@hasDecl(flashdb, "Tsdb")`, so it is active now
# that src/flashdb.zig exports `Tsdb`.  This switch is the single source of
# truth for the expected scope (RESULT validation + JSON fields); it was
# $false during phase 1 (KV-only) and is $true for the final KV+TS workload.
# --------------------------------------------------------------------------
$TsPhaseImplemented = $true

# Expected workload results -- MUST match firmware/c/main.c and
# bench/results/c_firmware.json (the C reference for the same workload).
$expectedCounts = [ordered]@{
    kv_writes   = 1596   # 64 set + 32 update + 1500 churn
    kv_gets     = 64
    kv_iterated = 64
    ts_appends  = if ($TsPhaseImplemented) { 200 } else { 0 }
    ts_iterated = if ($TsPhaseImplemented) { 200 } else { 0 }
}
$expectedChecksums = [ordered]@{
    kv_checksum      = [uint32]0x4b3486a4
    kv_iter_checksum = [uint32]0x0e250daa
    ts_checksum      = if ($TsPhaseImplemented) { [uint32]0x10d90680 } else { [uint32]0x00000000 }
}

function Fail([string]$msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    throw $msg
}

function Find-Tool([string]$name, [string[]]$fallbacks) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    foreach ($f in $fallbacks) {
        if (Test-Path -LiteralPath $f) { return $f }
    }
    return ''
}

$zigVersion = (& $Zig version).Trim()
if ($LASTEXITCODE -ne 0) { Fail "cannot execute '$Zig version'" }
$sizeTool = Find-Tool 'llvm-size' @('D:\Program Files\LLVM\bin\llvm-size.exe')
if ($sizeTool -eq '') { Fail 'llvm-size not found on PATH (or D:\Program Files\LLVM\bin)' }
$qemu = Find-Tool 'qemu-system-arm' @('D:\Program Files\qemu\qemu-system-arm.exe')
if ($qemu -eq '') { Fail 'qemu-system-arm not found on PATH (or D:\Program Files\qemu)' }

# Source provenance: the measured numbers depend on src/** (actively evolving),
# so record which revision produced this JSON.
$gitRevision = 'unknown'
$gitDirty = $false
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $gitCmd) {
    $gitRevision = (& $gitCmd.Source rev-parse --short HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitRevision -eq '') { $gitRevision = 'unknown' }
    $porcelain = @(& $gitCmd.Source status --porcelain 2>$null)
    $gitDirty = ($porcelain.Count -gt 0)
}

Push-Location $repoRoot
try {

# --------------------------------------------------------------------------
# Build commands (exactly as documented in firmware/zig/README.md)
# --------------------------------------------------------------------------

# C harness sources: unmodified, identical to the C firmware build.
# NOTE: firmware/c/libc_stubs.c is NOT listed here: the C image needs it to
# replace the EABI mem* helpers that -nostdlib would otherwise drop, while the
# Zig image gets the equivalent helpers from Zig's compiler_rt/freestanding
# libc surface (firmware/README.md, portability note 3).  Both images therefore
# carry a comparable runtime baseline and no other library code differs.
$harnessSources = @(
    'firmware/common/startup_armv7m.S',
    'firmware/common/semihost.c',
    'firmware/common/cycles.c',
    'firmware/common/stack.c'
)

# C compiler flags for the link step (copied from scripts/build_fw_c.ps1 so the
# harness C code is compiled with the same options as in the C image).
$ccCommonFlags = @(
    '-target', 'thumb-freestanding-eabi',
    '-mcpu=cortex_m3',
    '-Os',
    '-std=gnu11',
    '-w',
    '-ffunction-sections', '-fdata-sections', '-fno-common',
    '-fno-builtin', '-fno-stack-protector', '-ffreestanding',
    '-fno-asynchronous-unwind-tables', '-fno-unwind-tables'
)

$ldFlags = @(
    '-Wl,--gc-sections',
    '-Wl,-T,firmware/common/mps2_an385.ld',
    '-Wl,-e,Reset_Handler'
)

# Zig object compiler flags shared by every root file.
$zigObjCommonFlags = @(
    'build-obj',
    '-target', 'thumb-freestanding-eabi',
    '-mcpu=cortex_m3',
    '-O', 'ReleaseSmall',
    '--dep', 'flashdb'
)

$qemuBaseArgs = @(
    '-M', 'mps2-an385', '-cpu', 'cortex-m3', '-nographic', '-semihosting',
    '-icount', 'shift=0'
)

function Get-VariantConfig([string]$variant) {
    $root = 'main.zig'
    $defines = @()
    if ($variant -eq 'instrumented') {
        if ($Cycles) {
            $root = 'main_cycles.zig'
            $defines += '-DFW_CYCLES=1'
        }
        if ($Phases) {
            $root = 'main_phases.zig'
            $defines += '-DHARNESS_STACK_PHASES=1'
        }
        if ($Cycles -and $Phases) { $root = 'main_instrumented.zig' }
    }
    return [pscustomobject]@{
        Variant = $variant
        Root    = $root
        Defines = $defines
    }
}

function Build-Firmware([pscustomobject]$cfg) {
    $variant = $cfg.Variant
    $obj = Join-Path $buildDir "zig_$variant.o"
    $elf = Join-Path $buildDir "fw_zig_$variant.elf"

    $objArgs = $zigObjCommonFlags + @(
        "-Mroot=firmware/zig/$($cfg.Root)",
        '-Mflashdb=src/flashdb.zig',
        "-femit-bin=$obj"
    )
    Write-Host "[$variant] zig build-obj -O ReleaseSmall ($($cfg.Root)) -> zig_$variant.o"
    $out = & $Zig @objArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        Fail "[$variant] zig build-obj failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $obj)) { Fail "[$variant] object '$obj' was not produced" }

    $ccArgs = @('cc') + $ccCommonFlags + $cfg.Defines + $ldFlags +
              $harnessSources + @($obj, '-o', $elf)
    Write-Host "[$variant] zig cc -Os harness + zig_$variant.o -> fw_zig_$variant.elf"
    $out = & $Zig @ccArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        Fail "[$variant] zig cc failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $elf)) {
        Fail "[$variant] compiler reported success but '$elf' does not exist"
    }
    return $elf
}

function Get-ElfSections([string]$elf) {
    $out = & $sizeTool -A $elf 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "llvm-size -A failed for '$elf'" }
    $sizes = [ordered]@{ text = 0; rodata = 0; data = 0; bss = 0 }
    foreach ($line in $out) {
        if ($line -match '^\s*(\.?[A-Za-z0-9_.]+)\s+(\d+)\s+(\d+)') {
            $name = $Matches[1]
            $size = [int]$Matches[2]
            if ($name -eq '.text') { $sizes.text += $size }
            elseif ($name -eq '.rodata') { $sizes.rodata += $size }
            elseif ($name -eq '.data') { $sizes.data += $size }
            elseif ($name -eq '.bss') { $sizes.bss += $size }
        }
    }
    return $sizes
}

function Invoke-Qemu([string]$variant, [string]$elf) {
    $log = Join-Path $buildDir "qemu_zig_$variant.log"
    $so = "$log.stdout"
    $se = "$log.stderr"
    Remove-Item -LiteralPath $log, $so, $se -Force -ErrorAction SilentlyContinue
    $qargs = $qemuBaseArgs + @('-kernel', $elf)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $qemu -ArgumentList $qargs `
        -RedirectStandardOutput $so -RedirectStandardError $se `
        -PassThru -NoNewWindow
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill($true) } catch { }
        $partial = ''
        foreach ($f in @($so, $se)) {
            if (Test-Path -LiteralPath $f) { $partial += (Get-Content -LiteralPath $f -Raw) }
        }
        Write-Host $partial
        Fail "[$variant] QEMU timed out after ${TimeoutSec}s (hard fault or no vector table; see $log)"
    }
    $sw.Stop()
    $text = ''
    foreach ($f in @($so, $se)) {
        if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw) }
    }
    Set-Content -LiteralPath $log -Value $text -Encoding ascii
    Remove-Item -LiteralPath $so, $se -Force -ErrorAction SilentlyContinue
    return @{
        ExitCode = $proc.ExitCode
        Text     = $text
        WallMs   = [int]$sw.ElapsedMilliseconds
        Log      = $log
        Args     = $qargs
    }
}

function Get-ResultLine([string]$text, [string]$variant) {
    $lines = @($text -split "`r?`n" | Where-Object { $_ -match '^RESULT ' })
    if ($lines.Count -eq 0) {
        Fail "[$variant] firmware printed no RESULT line (see QEMU log above)"
    }
    if ($lines.Count -gt 1) {
        Fail "[$variant] firmware printed $($lines.Count) RESULT lines, expected exactly 1"
    }
    return $lines[0].Trim()
}

function Parse-Fields([string]$line) {
    $fields = @{}
    foreach ($tok in ($line -split '\s+')) {
        $i = $tok.IndexOf('=')
        if ($i -gt 0) { $fields[$tok.Substring(0, $i)] = $tok.Substring($i + 1) }
    }
    return $fields
}

function Get-HexU32([string]$v) {
    if ($v -match '^0x[0-9a-fA-F]+$') { return [Convert]::ToUInt32($v.Substring(2), 16) }
    return [uint32]$v
}

function Measure-Variant([string]$variant) {
    $cfg = Get-VariantConfig $variant
    $elf = Build-Firmware $cfg
    $sections = Get-ElfSections $elf

    if ($BuildOnly) {
        Write-Host ("  BUILD {0}: text={1} rodata={2} data={3} bss={4} rom={5} ram={6}" -f `
            $variant, $sections.text, $sections.rodata, $sections.data, $sections.bss, `
            ($sections.text + $sections.rodata + $sections.data), ($sections.data + $sections.bss)) -ForegroundColor Green
        return @{ variant = $variant; elf = $elf; sections = $sections; run = $null }
    }

    $run1 = Invoke-Qemu $variant $elf
    if ($run1.ExitCode -ne 0) { Fail "[$variant] QEMU exited with code $($run1.ExitCode)" }
    $line1 = Get-ResultLine $run1.Text $variant
    $run2 = Invoke-Qemu $variant $elf
    if ($run2.ExitCode -ne 0) { Fail "[$variant] QEMU (second run) exited with code $($run2.ExitCode)" }
    $line2 = Get-ResultLine $run2.Text $variant
    if ($line1 -ne $line2) {
        Write-Host "run1: $line1"
        Write-Host "run2: $line2"
        Fail "[$variant] RESULT line is not reproducible between two runs"
    }

    $f = Parse-Fields $line1
    if ($f['rc'] -ne '0') { Fail "[$variant] RESULT rc=$($f['rc']) (workload reported a failure)" }

    # --- section sizes: linker symbols (RESULT) vs llvm-size -A -----------
    $rSizes = @{
        text   = [int]$f['text']
        rodata = [int]$f['rodata']
        data   = [int]$f['data']
        bss    = [int]$f['bss']
    }
    foreach ($k in @('text', 'rodata', 'data', 'bss')) {
        if ($rSizes[$k] -ne $sections[$k]) {
            Fail "[$variant] $k size mismatch: RESULT=$($rSizes[$k]) llvm-size=$($sections[$k])"
        }
    }
    if ([int]$f['sim_flash'] -ne 32768) {
        Fail "[$variant] sim_flash=$($f['sim_flash']), expected 32768"
    }

    # --- workload invariants (mirror firmware/common/workload_spec.h) ------
    foreach ($k in $expectedCounts.Keys) {
        if ([int]$f[$k] -ne $expectedCounts[$k]) {
            Fail "[$variant] $k=$($f[$k]), expected $($expectedCounts[$k]) (workload drifted?)"
        }
    }
    foreach ($k in $expectedChecksums.Keys) {
        $got = Get-HexU32 $f[$k]
        if ($got -ne $expectedChecksums[$k]) {
            Fail ("[$variant] {0}={1} (0x{2:x8}), expected 0x{3:x8} (reference checksum changed!)" -f `
                $k, $f[$k], $got, $expectedChecksums[$k])
        }
    }

    # --- stack -------------------------------------------------------------
    $stackLimit = [int]$f['stack_limit']
    $stack = [int]$f['stack']
    $stackInit = [int]$f['stack_init']
    if ($stackLimit -ne 8192) { Fail "[$variant] stack_limit=$stackLimit, expected 8192" }
    if ($stack -gt $stackLimit) { Fail "[$variant] stack high-water $stack exceeds the $stackLimit-byte stack" }

    $result = [ordered]@{
        variant        = $variant
        elf            = $elf
        sections       = $sections
        rom            = $sections.text + $sections.rodata + $sections.data
        static_ram     = $sections.data + $sections.bss
        stack_limit    = $stackLimit
        stack          = $stack
        stack_init     = $stackInit
        results        = [ordered]@{
            kv_writes        = [int]$f['kv_writes']
            kv_gets          = [int]$f['kv_gets']
            kv_iterated      = [int]$f['kv_iterated']
            kv_checksum      = $f['kv_checksum']
            kv_iter_checksum = $f['kv_iter_checksum']
            ts_appends       = [int]$f['ts_appends']
            ts_iterated      = [int]$f['ts_iterated']
            ts_checksum      = $f['ts_checksum']
        }
        result_line    = $line1
        qemu           = [ordered]@{ exit_code = $run1.ExitCode; log = $run1.Log }
        repeatable     = $true
    }

    # --- per-phase stack peaks --------------------------------------------
    if ($variant -eq 'instrumented' -and $Phases) {
        $phaseKeys = @('st_set', 'st_get', 'st_iter', 'st_gc', 'st_ts_append', 'st_ts_iter')
        $peaks = [ordered]@{}
        foreach ($k in $phaseKeys) {
            if (-not $f.ContainsKey($k)) { Fail "[$variant] RESULT misses phase field '$k'" }
            $v = [int]$f[$k]
            if ($v -gt $stackLimit) { Fail "[$variant] phase $k peak $v exceeds the stack" }
            $peaks[$k.Substring(3)] = $v
        }
        # Phase 2: once the TSDB workload is enabled its diagnostics must be
        # measured too (C: st_ts_append=584, st_ts_iter=656).
        if ($TsPhaseImplemented) {
            foreach ($k in @('ts_append', 'ts_iter')) {
                if ($peaks[$k] -le 0) {
                    Fail "[$variant] phase st_$k peak is 0; expected > 0 once the TSDB workload is enabled"
                }
            }
        }
        $result['stack_phases'] = $peaks
    }

    # --- cycles ------------------------------------------------------------
    if ($variant -eq 'instrumented' -and $Cycles) {
        $src = $f['cycles_src']
        if ($src -eq 'none' -or $src -eq $null) {
            Fail "[$variant] cycle counter reported source '$src' (no DWT and no SysTick proxy)"
        }
        $cyc = [ordered]@{
            source = $src
            mount  = [int]$f['cycles_mount']
            kv     = [int]$f['cycles_kv']
            ts     = [int]$f['cycles_ts']
            total  = [int]$f['cycles_total']
        }
        if ($src -eq 'systick') {
            # -icount shift=0, 25 MHz SysTick -> 40 instructions per tick; the
            # calibration spin is exactly 20000 instructions.
            $cyc.tick_hz = [int]$f['cycles_tick_hz']
            $cyc.calib_insn = [int]$f['cycles_calib_insn']
            $cyc.calib_ticks = [int]$f['cycles_calib_ticks']
            if ($cyc.tick_hz -ne 25000000) { Fail "[$variant] cycles_tick_hz=$($cyc.tick_hz), expected 25000000" }
            if ($cyc.calib_insn -ne 20000) { Fail "[$variant] cycles_calib_insn=$($cyc.calib_insn), expected 20000" }
            if ($cyc.calib_ticks -ne 500) {
                Fail "[$variant] cycles_calib_ticks=$($cyc.calib_ticks), expected 500 (is -icount shift=0 active?)"
            }
        }
        if ($cyc.total -ne ($cyc.mount + $cyc.kv + $cyc.ts)) {
            Fail "[$variant] cycles_total != cycles_mount + cycles_kv + cycles_ts"
        }
        if ($Phases) {
            $cycPhases = [ordered]@{}
            foreach ($k in @('cyc_st_set', 'cyc_st_get', 'cyc_st_iter', 'cyc_st_gc', 'cyc_st_ts_append', 'cyc_st_ts_iter')) {
                if (-not $f.ContainsKey($k)) { Fail "[$variant] RESULT misses cycle phase field '$k'" }
                $cycPhases[$k.Substring(7)] = [int]$f[$k]
            }
            # Phase 2: the TS diagnostics must also have been measured
            # (C: cyc_st_ts_append=350, cyc_st_ts_iter=2719).
            if ($TsPhaseImplemented) {
                foreach ($k in @('ts_append', 'ts_iter')) {
                    if ($cycPhases[$k] -le 0) {
                        Fail "[$variant] cyc_st_$k=0; expected > 0 once the TSDB workload is enabled"
                    }
                }
            }
            $cyc['phases'] = $cycPhases
        }
        # Phase 2: the TS phase must have cost cycles (C: cycles_ts=5776).
        if ($TsPhaseImplemented -and $cyc.ts -le 0) {
            Fail "[$variant] cycles_ts=$($cyc.ts); expected > 0 once the TSDB workload is enabled"
        }
        $result['cycles'] = $cyc
    }

    Write-Host ("  PASS {0}: text={1} rodata={2} data={3} bss={4} rom={5} ram={6} stack={7}/{8}" -f `
        $variant, $sections.text, $sections.rodata, $sections.data, $sections.bss, `
        $result.rom, $result.static_ram, $stack, $stackLimit) -ForegroundColor Green
    if ($result.cycles) {
        $c = $result.cycles
        Write-Host ("       cycles src={0} mount={1} kv={2} ts={3} total={4}" -f `
            $c.source, $c.mount, $c.kv, $c.ts, $c.total)
    }
    Write-Host ("       checksums kv={0} kv_iter={1} ts={2}" -f `
        $result.results.kv_checksum, $result.results.kv_iter_checksum, $result.results.ts_checksum)
    Write-Host ("       qemu exit={0} wall={1} ms (log: {2})" -f `
        $run1.ExitCode, $run1.WallMs, (Split-Path -Leaf $run1.Log))
    return $result
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

Write-Host '== Zig FlashDB firmware measurement (Cortex-M3, MPS2-AN385) =='
Write-Host "  repo     : $repoRoot"
Write-Host "  source   : git $gitRevision$(if ($gitDirty) { ' (dirty working tree: numbers depend on the current src/**)' })"
Write-Host "  zig      : $Zig ($zigVersion)"
Write-Host "  target   : thumb-freestanding-eabi / cortex_m3 / -O ReleaseSmall (Zig) + -Os (C harness)"
Write-Host "  qemu     : $qemu"
Write-Host "  cycles   : $Cycles   phases: $Phases"
Write-Host "  scope    : $(if ($TsPhaseImplemented) { 'kvdb+tsdb (full C workload)' } else { 'kvdb ONLY -- TSDB workload pending, not the final apples-to-apples number' })"
Write-Host ''

$variants = [ordered]@{}
$variants['plain'] = Measure-Variant 'plain'
if ($Cycles -or $Phases) {
    $variants['instrumented'] = Measure-Variant 'instrumented'
}

if ($BuildOnly) {
    Write-Host ''
    Write-Host 'build only: skipping QEMU and JSON output'
    exit 0
}

# --------------------------------------------------------------------------
# JSON document (same shape as bench/results/c_firmware.json)
# --------------------------------------------------------------------------

$workload = [ordered]@{
    includes            = if ($TsPhaseImplemented) { @('kvdb', 'tsdb') } else { @('kvdb') }
    kv_keys             = 64
    kv_updates          = 32
    kv_churn            = 1500
    kv_churn_keys       = 16
    kv_value_len        = 24
    ts_appends          = 200
    ts_payload_len      = 16
    ts_base_time        = 1000
    tsdb_max_len        = 64
    sim_flash_len       = 32768
    sim_flash_blk       = 4096
    kv_partition_len    = 16384
    ts_partition_len    = 16384
    kv_partition_offset = 0
    ts_partition_offset = 16384
    source              = 'firmware/common/workload_spec.h'
    zig_source          = 'firmware/zig/fw.zig'
}

$doc = [ordered]@{
    impl        = 'zig'
    version     = 'flashdb-zig'
    # Phase 1 = KVDB only; the C reference (bench/results/c_firmware.json)
    # covers KVDB+TSDB, so a kv-only Zig row is NOT the final apples-to-apples
    # comparison.  Flipped to 'kv+ts' together with $TsPhaseImplemented.
    workload_scope = if ($TsPhaseImplemented) { 'kv+ts' } else { 'kv-only' }
    target      = 'thumb-freestanding-eabi'
    cpu         = 'cortex_m3'
    machine     = 'mps2-an385'
    opt         = 'ReleaseSmall'
    write_gran  = 8
    compiler    = "zig $zigVersion (Zig frontend for the workload/DB; zig cc for the C harness)"
    toolchain   = [ordered]@{
        zig            = $Zig
        zig_version    = $zigVersion
        size_tool      = $sizeTool
        qemu           = $qemu
        c_harness_compiler = "zig cc $zigVersion"
        git_revision   = $gitRevision
        git_dirty      = $gitDirty
    }
    flags       = [ordered]@{
        cycles          = [bool]$Cycles
        phases          = [bool]$Phases
        zig_obj_cflags  = @('build-obj', '-target', 'thumb-freestanding-eabi', '-mcpu=cortex_m3',
                             '-O', 'ReleaseSmall', '--dep', 'flashdb',
                             '-Mroot=firmware/zig/<variant root>.zig', '-Mflashdb=src/flashdb.zig')
        cflags          = @($ccCommonFlags) + @($ldFlags)
        zig_runtime     = 'Zig compiler_rt / freestanding libc (zig cc default, replaces libc_stubs.c: same EABI mem*/64-bit helpers the C image gets from firmware/c/libc_stubs.c)'
        harness_sources = @($harnessSources)
        zig_sources     = @('firmware/zig/main.zig', 'firmware/zig/main_instrumented.zig',
                             'firmware/zig/main_cycles.zig', 'firmware/zig/main_phases.zig',
                             'firmware/zig/fw.zig')
        cycles_define   = 'FW_CYCLES semantics selected by the Zig root file (main_cycles.zig / main_instrumented.zig); C harness gets -DFW_CYCLES=1'
        phases_define   = 'HARNESS_STACK_PHASES semantics selected by the Zig root file (main_phases.zig / main_instrumented.zig); C harness gets -DHARNESS_STACK_PHASES=1'
        qemu            = @($qemuBaseArgs)
        cycle_note      = 'QEMU 8.2 does not model the Cortex-M3 DWT (DEMCR/DWT_CTRL read 0); the C harness probes DWT first and falls back to the SysTick 24-bit down-counter, which under -icount shift=0 ticks every 40 instructions (25 MHz tick clock, 1 ns per instruction). cycles_src= in RESULT says which source was used. The Zig image calls the same unmodified firmware/common/cycles.c module.'
        fairness_note   = 'firmware/common/{startup_armv7m.S,semihost.c,cycles.c,stack.c} and firmware/common/mps2_an385.ld are compiled UNMODIFIED into both the C and the Zig image, so the harness overhead (vectors, semihosting, cycle counter, stack painting, linker script) is byte-identical on both sides. The only deliberately different runtime piece is the compiler support library: the C build links -nostdlib + firmware/c/libc_stubs.c, the Zig build links Zig compiler_rt, which supplies the same EABI mem*/64-bit helper surface (firmware/README.md portability note 3). Only the workload + database code is Zig (src/flashdb.zig, firmware/zig/fw.zig).'
    }
    workload    = $workload
    variants    = $variants
}

$json = $doc | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $OutJson -Value $json -Encoding utf8
Write-Host ''
Write-Host "wrote $OutJson"
Write-Host ''
Write-Host 'PASS: Zig firmware built, sized and run under QEMU with rc=0 (all checks passed)' -ForegroundColor Green

}
finally {
    Pop-Location
}
