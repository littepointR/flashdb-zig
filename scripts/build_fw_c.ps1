<#
.SYNOPSIS
    Build, size and run the C FlashDB Cortex-M3 firmware measurement image.

.DESCRIPTION
    Builds the UNMODIFIED C FlashDB 2.2.99 (reference/FlashDB) plus the
    bare-metal measurement harness in firmware/ for the ARM MPS2-AN385 board
    (Cortex-M3) with the PINNED Zig nightly acting as the C compiler:

        zig cc -target thumb-freestanding-eabi -mcpu=cortex_m3 -Os ...

    then runs it under qemu-system-arm (-M mps2-an385 -cpu cortex-m3
    -semihosting -icount shift=0), parses the single semihosting RESULT line
    and writes bench/results/c_firmware.json with

      * .text/.rodata/.data/.bss (llvm-size -A, cross-checked against the
        linker-symbol numbers the firmware itself prints),
      * ROM = .text + .rodata + .data, static RAM = .data + .bss,
      * stack high-water (0xA5 stack paint) and stack limit,
      * per-phase stack peaks and cycle counts (instrumented variant),
      * the workload constants, checksums and workload result counts,
      * the compiler/linker/QEMU flags actually used.

    Two variants are built and measured by default:

      plain         - no cycle/phase instrumentation (pure library + harness
                      footprint; comparable to a plain Zig image),
      instrumented  - -DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1: cycle counts of
                      every phase (DWT on silicon, SysTick virtual-time proxy
                      under QEMU) plus per-phase stack peaks.

    Each variant is run TWICE and the two RESULT lines must be identical, so a
    non-deterministic build/run is caught immediately.

    Exit status is 0 only when both builds link, both QEMU runs print exactly
    one `RESULT ... rc=0` line, the RESULT/llvm-size numbers agree and the
    expected workload checksums are reproduced.  A timeout (hard fault, missing
    vector table), missing RESULT, rc != 0 or any inconsistency fails loudly.

.PARAMETER Zig
    Path to the pinned zig executable (default <repo>/.tools/zig/zig.exe).

.PARAMETER WriteGran
    FDB_WRITE_GRAN for the firmware (default 8, the baseline).

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
    JSON output path (default <repo>/bench/results/c_firmware.json).

.EXAMPLE
    pwsh -NoProfile -File scripts/build_fw_c.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/build_fw_c.ps1 -BuildOnly

.EXAMPLE
    pwsh -NoProfile -File scripts/build_fw_c.ps1 -WriteGran 1 -Cycles:`$false
#>
[CmdletBinding()]
param(
    [string]$Zig = '',
    [int]$WriteGran = 8,
    [int]$TimeoutSec = 60,
    [switch]$Cycles = $true,
    [switch]$Phases = $true,
    [switch]$BuildOnly,
    [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($Zig -eq '') { $Zig = Join-Path $repoRoot '.tools/zig/zig.exe' }
if ($OutJson -eq '') { $OutJson = Join-Path $repoRoot 'bench/results/c_firmware.json' }

$buildDir = Join-Path $repoRoot 'build/fw'
$resDir = Join-Path $repoRoot 'bench/results'
New-Item -ItemType Directory -Force -Path $buildDir, $resDir | Out-Null

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

$ref = Join-Path $repoRoot 'reference/FlashDB'
$fw = Join-Path $repoRoot 'firmware'

$commonCflags = @(
    '-target', 'thumb-freestanding-eabi',
    '-mcpu=cortex_m3',
    '-Os',
    '-std=gnu11',
    '-w',
    '-ffunction-sections', '-fdata-sections', '-fno-common',
    '-fno-builtin', '-fno-stack-protector', '-ffreestanding',
    '-fno-asynchronous-unwind-tables', '-fno-unwind-tables',
    "-DFDB_WRITE_GRAN=$WriteGran",
    '-I', (Join-Path $fw 'common'),
    '-I', (Join-Path $fw 'c/include'),
    '-I', (Join-Path $ref 'inc'),
    '-I', (Join-Path $ref 'port/fal/inc')
)

$sources = @(
    (Join-Path $fw 'common/startup_armv7m.S'),
    (Join-Path $fw 'common/semihost.c'),
    (Join-Path $fw 'common/stack.c'),
    (Join-Path $fw 'common/cycles.c'),
    (Join-Path $fw 'c/main.c'),
    (Join-Path $fw 'c/fal_ram_sim.c'),
    (Join-Path $fw 'c/libc_stubs.c'),
    (Join-Path $ref 'src/fdb.c'),
    (Join-Path $ref 'src/fdb_kvdb.c'),
    (Join-Path $ref 'src/fdb_tsdb.c'),
    (Join-Path $ref 'src/fdb_utils.c'),
    (Join-Path $ref 'port/fal/src/fal.c'),
    (Join-Path $ref 'port/fal/src/fal_flash.c'),
    (Join-Path $ref 'port/fal/src/fal_partition.c')
)

$ldScript = Join-Path $fw 'common/mps2_an385.ld'
$ldFlags = @(
    '-Wl,--gc-sections',
    "-Wl,-T,$ldScript",
    '-Wl,-e,Reset_Handler'
)

function Get-ExtraFlags([string]$variant) {
    $f = @()
    if ($variant -eq 'instrumented') {
        if ($Cycles) { $f += '-DFW_CYCLES=1' }
        if ($Phases) { $f += '-DHARNESS_STACK_PHASES=1' }
    }
    return $f
}

function Build-Firmware([string]$variant) {
    $elf = Join-Path $buildDir "fw_c_$variant.elf"
    $extra = Get-ExtraFlags $variant
    $ccArgs = @('cc') + $commonCflags + $extra + @('-nostdlib') + $ldFlags + @('-o', $elf) + $sources

    Write-Host "[$variant] zig cc -Os -> $([System.IO.Path]::GetFileName($elf))"
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
        if ($line -match '^\s*(\.[A-Za-z0-9_.]+)\s+(\d+)\s+(\d+)') {
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
    $log = Join-Path $buildDir "qemu_c_$variant.log"
    $so = "$log.stdout"
    $se = "$log.stderr"
    Remove-Item -LiteralPath $log, $so, $se -Force -ErrorAction SilentlyContinue
    $qargs = @(
        '-M', 'mps2-an385', '-cpu', 'cortex-m3', '-nographic', '-semihosting',
        '-icount', 'shift=0', '-kernel', $elf
    )
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
    $elf = Build-Firmware $variant
    $sections = Get-ElfSections $elf

    if ($BuildOnly) {
        return @{ variant = $variant; elf = $elf; sections = $sections; run = $null }
    }

    $run1 = Invoke-Qemu $variant $elf
    if ($run1.ExitCode -ne 0) { Fail "[$variant] QEMU exited with code $($run1.ExitCode)" }
    $line1 = Get-ResultLine $run1.Text $variant
    $run2 = Invoke-Qemu $variant $elf
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
    $expectedCounts = @{
        kv_writes   = 1596   # 64 set + 32 update + 1500 churn
        kv_gets     = 64
        kv_iterated = 64
        ts_appends  = 200
        ts_iterated = 200
    }
    foreach ($k in $expectedCounts.Keys) {
        if ([int]$f[$k] -ne $expectedCounts[$k]) {
            Fail "[$variant] $k=$($f[$k]), expected $($expectedCounts[$k]) (workload drifted?)"
        }
    }
    $expectedSums = @{
        kv_checksum      = [uint32]0x4b3486a4
        kv_iter_checksum = [uint32]0x0e250daa
        ts_checksum      = [uint32]0x10d90680
    }
    foreach ($k in $expectedSums.Keys) {
        $got = Get-HexU32 $f[$k]
        if ($got -ne $expectedSums[$k]) {
            Fail ("[$variant] {0}={1} (0x{2:x8}), expected 0x{3:x8} (reference checksum changed!)" -f `
                $k, $f[$k], $got, $expectedSums[$k])
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
            $cyc['phases'] = $cycPhases
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

Write-Host '== C FlashDB firmware measurement (Cortex-M3, MPS2-AN385) =='
Write-Host "  repo     : $repoRoot"
Write-Host "  zig cc   : $Zig ($zigVersion)"
Write-Host "  target   : thumb-freestanding-eabi / cortex_m3 / -Os"
Write-Host "  qemu     : $qemu"
Write-Host "  writegran: $WriteGran"
Write-Host "  cycles   : $Cycles   phases: $Phases"
Write-Host ''

$variants = [ordered]@{}
$variants['plain'] = Measure-Variant 'plain'
if (($Cycles -or $Phases) -and -not $BuildOnly) {
    $variants['instrumented'] = Measure-Variant 'instrumented'
} elseif (($Cycles -or $Phases) -and $BuildOnly) {
    $variants['instrumented'] = Measure-Variant 'instrumented'
}

if ($BuildOnly) {
    Write-Host ''
    Write-Host 'build only: skipping QEMU and JSON output'
    exit 0
}

# --------------------------------------------------------------------------
# JSON document
# --------------------------------------------------------------------------

$workload = [ordered]@{
    kv_keys          = 64
    kv_updates       = 32
    kv_churn         = 1500
    kv_churn_keys    = 16
    kv_value_len     = 24
    ts_appends       = 200
    ts_payload_len   = 16
    ts_base_time     = 1000
    tsdb_max_len     = 64
    sim_flash_len    = 32768
    sim_flash_blk    = 4096
    kv_partition_len = 16384
    ts_partition_len = 16384
    kv_partition_offset = 0
    ts_partition_offset = 16384
    source           = 'firmware/common/workload_spec.h'
}

$doc = [ordered]@{
    impl        = 'c'
    version     = 'fdb-2.2.99'
    target      = 'thumb-freestanding-eabi'
    cpu         = 'cortex_m3'
    machine     = 'mps2-an385'
    opt         = 'Os'
    write_gran  = $WriteGran
    compiler    = "zig cc $zigVersion"
    toolchain   = [ordered]@{
        zig         = $Zig
        zig_version = $zigVersion
        size_tool   = $sizeTool
        qemu        = $qemu
    }
    flags       = [ordered]@{
        cycles         = [bool]$Cycles
        phases         = [bool]$Phases
        cflags         = @($commonCflags) + @('-nostdlib') + @($ldFlags)
        cycles_define  = '-DFW_CYCLES=1 (instrumented variant)'
        phases_define  = '-DHARNESS_STACK_PHASES=1 (instrumented variant)'
        qemu           = @('-M', 'mps2-an385', '-cpu', 'cortex-m3', '-nographic',
                           '-semihosting', '-icount', 'shift=0')
        cycle_note     = 'QEMU 8.2 does not model the Cortex-M3 DWT (DEMCR/DWT_CTRL read 0); the firmware probes DWT first and falls back to the SysTick 24-bit down-counter, which under -icount shift=0 ticks every 40 instructions (25 MHz tick clock, 1 ns per instruction). cycles_src= in RESULT says which source was used.'
    }
    workload    = $workload
    variants    = $variants
}

$json = $doc | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $OutJson -Value $json -Encoding utf8
Write-Host ''
Write-Host "wrote $OutJson"
Write-Host ''
Write-Host 'PASS: C firmware built, sized and run under QEMU with rc=0 (all checks passed)' -ForegroundColor Green
