# FlashDB-Zig

[![CI](https://github.com/littepointR/flashdb-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/littepointR/flashdb-zig/actions/workflows/ci.yml)
[![coverage](https://img.shields.io/badge/coverage-100%25%20functions-brightgreen)](docs/TESTING.md#6-覆盖率)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

用 **Zig 从零重写**的 [FlashDB](https://github.com/armink/FlashDB)：面向裸 Flash 的超轻量级
**键值数据库（KVDB）** 与 **时序数据库（TSDB）**。

这不是 C 源码的翻译，也不是对原版的封装：盘面格式、状态编码、缓存结构、遍历与 GC 路径
全部按 Zig 的能力重新设计，并按"性能 / ROM / 静态 RAM / 栈占用至少达到原版水平"的目标验收。
完整的格式与算法契约见 [`docs/DESIGN.md`](docs/DESIGN.md)，实测数据见
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)，验证矩阵见 [`docs/TESTING.md`](docs/TESTING.md)。

## 实测结论（对照 C 原版 2.2.99，同一工作负载/同一测量脚手架）

| 维度 | C 原版 | Zig 重写 | 结果 |
|---|---|---|---|
| Cortex-M3 ROM（`-Os` / `ReleaseSmall`） | 12,700 B | **12,036 B** | -5.2% |
| Cortex-M3 静态 RAM | 1,144 B | **760 B** | -33.6% |
| Cortex-M3 峰值栈 | 1,208 B | **840 B** | -30.5% |
| Cortex-M3 CPU 周期（KV+TS 全负载） | 532,601 | **170,780** | -67.9% |
| 宿主加权 Flash 流量（16 场景合计） | 56.88 M | **51.49 M** | -9.5%，逐场景均不高于 C |
| 宿主耗时（16 场景合计） | 5.23 ms | **0.78 ms** | -85.0% |
| KV 逻辑校验和 | — | — | 8/8 与 C 完全一致 |
| KV+TS 行为差分（逐操作） | — | — | 3,066 行全部一致；逐次掉电恢复一致 |
| TS 存储密度（16 KiB 分区） | 308 条 | **368 条** | +19.5% |

关键结构数据：KV 每条记录固定开销 **10 B**（C 18–22 B）、TS 索引 **12 B**（C 17 B）、
KVDB 结构体 584 B（C 1,064 B）、TSDB 56 B（C 160 B）。详细表格、口径与唯一一处宿主
`tsl_mount` 计时噪声的说明见 [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)。

```zig
const flashdb = @import("flashdb");

// 你的 Flash 驱动：read/write/erase + 两个编译期常量
const NorFlash = struct {
    pub const Error = error{ BusError, Timeout };
    pub const write_gran_bits: u16 = 8;      // 1 | 8 | 32 | 64 | 128 | 256
    pub const erase_block_size: u32 = 4096;
    pub fn read(self: *NorFlash, addr: u32, buf: []u8) Error!void { ... }
    pub fn write(self: *NorFlash, addr: u32, data: []const u8) Error!void { ... }
    pub fn erase(self: *NorFlash, addr: u32, len: u32) Error!void { ... }
};

const Kv = flashdb.Kvdb(NorFlash, .{ .sector_size = 4096, .sector_count = 4 });

var db: Kv = undefined;

try db.mount(nor_flash);
try db.set("boot_count", &[_]u8{ 42, 0, 0, 0 });

var buf: [16]u8 = undefined;
if (try db.get("boot_count", &buf)) |len| {
    // buf[0..len] 是值；get 在同一次读取中完成 CRC32 校验
}

var it = db.iterator();
while (try it.next()) |entry| {
    _ = try it.readValue(&buf, entry);          // 按需读取 + 校验，不复制用不到的值
}
```

## 为什么是重写而不是移植

| 方面 | FlashDB-C | FlashDB-Zig |
|---|---|---|
| 全局状态 | FAL 分区表 + 全局注册表 | 零全局状态；数据库值语义持有 Flash 驱动，多个分区/实例可直接共存 |
| 内存 | 664 B 结构体 + 832 B 缓存 + 调用栈 | 约 56 B 结构体 + 512 B 4 路缓存（可 0/32/64/128 配置） |
| 堆 | 不用堆 | 不用堆（`no_std`，无分配器依赖） |
| 配置 | `#define` / `fdb_cfg.h` | `comptime` 配置：扇区几何、写粒度、时间戳位宽、缓存规模、名称上限全部编译期折叠 |
| 状态编码 | 每状态一个写粒度的状态表（KV 每记录 5 份） | 3 个状态粒度/记录，单粒度"清位"原子提交；掉电语义由格式保证 |
| 查找 | 每条途经记录都读完整 value 算 CRC，64 项线性扫描缓存 | 只读记录头；4 路组相联缓存 + 混合哈希 O(1) 探测；命中时不读 value 即可校验 |
| 遍历 | 逐字节扫描魔术字定位下一条记录 | 由记录头中的长度直接算出下一条地址 |
| 迭代 | 回调 + `void *` 参数 | Zig 迭代器 + 按需 `readValue` |
| 错误 | `fdb_err_t` 错误码 | `error` 联合，驱动自身错误类型原样透传 |
| 掉电恢复 | PRE_WRITE / PRE_DELETE / DELETED / ERR_HDR 状态机 | pending → 新记录提交 → deleted；恢复时按"有无后继版本"决定补删除或搬移恢复 |

## 盘面格式

新格式（见 [`docs/DESIGN.md`](docs/DESIGN.md) §3）的核心是**每个状态标记独占一个写粒度**：

* 记录提交 = 把 commit 粒度从全 `1` 写成全 `0`。NOR 写只能清位，断电时该粒度要么完成、
  要么保持全 `1`，不存在可读的中间态 → **提交天然原子**。
* 更新：旧记录写 `pending`（立即不可见、可恢复）→ 写新记录并提交 → 旧记录写 `deleted`。
* 删除：单次 `deleted` 写入即原子生效。
* 扇区头 10 字节 + 每状态一个粒度；KV 记录固定开销 10 字节（C 版 18–22 字节），
  TS 索引 12 字节（C 版 17 字节）。
* 每个粒度在扇区擦除前只写一次，满足 STM32L4/U5 等"擦除前每个 quad-word 只能编程一次"的器件限制。

**与 C 版盘面不兼容**（用户已确认允许重新设计格式）：C 写的镜像不能直接被本库挂载，反之亦然；
迁移方式是重新初始化并在应用层导入数据。语义（get/set/delete、TS 追加/遍历/rollover/clean）
与原版对齐，并通过 C↔Zig 差分测试验证。

## Flash 驱动协议

```zig
pub const Error = <你的错误集>;        // error{...}，可为空 error{}
pub const write_gran_bits: u16;       // 1 | 8 | 32 | 64 | 128 | 256
pub const erase_block_size: u32;      // 最小擦除单位（字节）
pub fn read(self: *Self, addr: u32, buf: []u8) Error!void;
pub fn write(self: *Self, addr: u32, data: []const u8) Error!void;  // 库保证地址/长度按写粒度对齐
pub fn erase(self: *Self, addr: u32, len: u32) Error!void;          // 库保证按擦除块对齐
```

同一物理 Flash 上划多个分区用 `flashdb.flash.Partition(Driver)` 适配器（替代 FAL）：

```zig
const Part = flashdb.flash.Partition(NorFlash);
const kv_part: Part = .{ .dev = &nor_flash, .offset = 0, .len = 16 * 1024 };
const ts_part: Part = .{ .dev = &nor_flash, .offset = 16 * 1024, .len = 16 * 1024 };
```

## 获取工具链与上游参考

仓库本身不包含编译器与上游 C 源码（两者都可复现拉取，且不参与库的构建）：

```powershell
python tools\bootstrap.py        # 下载 toolchain.lock.json 指定的 Zig 每夜版到 .tools/zig/
python tools\fetch_reference.py  # 拉取 FlashDB 2.2.99（固定 commit）到 reference/FlashDB/
```

`tools/bootstrap.py` 会按平台选择官方压缩包、校验 SHA-256 并解压；`fetch_reference.py`
只在需要跑 **C 对照**（`bench/c`、`bench/diff`、`firmware/c`）时才需要。Zig 库、Zig 基准、
测试与示例只依赖 `.tools/zig/`。

## 构建、测试与基准

工具链固定为 `.tools/zig/zig.exe`（见 [`toolchain.lock.json`](toolchain.lock.json)，当前
`0.18.0-dev.753+1420479be`）。Linux/macOS 下同一路径为 `.tools/zig/zig`。

```powershell
.tools\zig\zig.exe build test          # 单元测试 + 集成测试 + 模型对拍（58/58）
python tools\coverage.py                 # 函数覆盖率（当前 100%，公开 API 100%）
.tools\zig\zig.exe build               # 库 + 示例 + 宿主基准程序
.tools\zig\zig.exe build bench         # 直接跑宿主基准 -> zig-out\bin\flashdb-bench.exe
./zig-out/bin/flashdb-bench --mode check --wg 8   # 基准自检（8 bit 写粒度）
./zig-out/bin/flashdb-bench --mode check --wg 1   # 基准自检（1 bit 写粒度）
```

对照 C 原版的完整验收流程面向 **Windows + PowerShell 7**（脚本还会用到 QEMU 与
LLVM/`llvm-size`，见 [`docs/TESTING.md`](docs/TESTING.md)）；库本身、测试、Zig 基准与示例
在 Linux/macOS 同样可用（CI 在 Ubuntu 与 Windows 上构建并测试）：

```powershell
pwsh -NoProfile -File scripts\accept_all.ps1   # 一键：测试 + 宿主基准对比 + 行为差分 + 两侧固件
```

分步执行：

```powershell
.\scripts\build_bench_c.ps1            # C 参考基准 JSON -> bench/results/c_wg*.json
.\zig-out\bin\flashdb-bench.exe --wg 8 --runs 7 --out bench\results\zig_wg8_host.json
python tools\compare_bench.py bench\results\c_wg8_host.json bench\results\zig_wg8_host.json `
    --metric min --normalize-ts --checksum-scope kv
.\scripts\diff.ps1                     # C<->Zig 逐操作行为对拍（KV + TS，含掉电）
.\scripts\build_fw_c.ps1               # C 固件：ROM/RAM/栈/周期（Cortex-M3/QEMU）
.\firmware\zig\build.ps1               # Zig 固件：同一工作负载、同一测量口径
```

## 目录结构

| 路径 | 说明 |
|---|---|
| `src/` | 库本体：`format.zig`（盘面布局）、`crc.zig`、`flash.zig`、`device.zig`、`kvdb.zig`、`tsdb.zig` |
| `src/sim.zig` | RAM NOR 模拟器：位级写语义、读写擦计数、故障注入（宿主测试/基准/固件共用） |
| `bench/` | 宿主基准：`bench/c/`（C 参考）、`bench/zig/`（Zig 实现）、`bench/SCENARIOS.md`（协议） |
| `firmware/` | Cortex-M3/QEMU 固件对比：`firmware/c/`、`firmware/zig/`、`firmware/common/`（共用启动/半主机/栈测量） |
| `tests/` | 集成测试、随机模型对拍 |
| `docs/` | 设计、基准、测试、优化记录；[`PARITY.md`](docs/PARITY.md) 是上游 FlashDB 功能对照表 |
| `host/` | 宿主辅助模块：`file_flash.zig` 文件后备 Flash 驱动（等价上游文件模式；独立 `flashdb_host` 模块，库本体不依赖 `std`） |
| `reference/` | 上游 FlashDB 2.2.99 源码（只读，仅用于差分测试，不参与构建） |
| `scripts/`, `tools/` | 基准/固件/差分测试脚本与报告工具 |

## 与 C 原版的行为差异

1. **盘面格式不同**（见上），迁移需重新初始化。
2. `Kvdb.get` 返回值的**总长度**（复制长度 = `min(buf.len, len)`）；C 的 blob API 返回实际复制长度。
3. `delete` 返回 `bool`（键是否存在），不再用 `FDB_KV_NAME_ERR` 表达"不存在"。
4. `Tsdb.setStatus` 只允许向前迁移（写新槽位）；向后迁移返回 `error.StatusNotAdvancing`（C 会重复编程同一粒度，在写一次器件上既无效也不安全）。
5. 未移植文件模式（`FDB_USING_FILE_*`）；宿主测试用 `flashdb.sim.RamFlash`。
6. 不支持大端。
7. `FDB_KV_AUTO_UPDATE` 等价为显式 `Kvdb.autoUpdate(version, defaults)`；仅补缺失键。`fdb_kv_set_default` 等价为 `Kvdb.restoreDefaults(defaults)`，只补缺失键的版本是 `Kvdb.applyDefaults(defaults)`。
8. 扇区几何在编译期确定（替代 `FDB_KVDB_CTRL_SET_SEC_SIZE` 等运行期 control 命令）。
9. 不提供 lock/unlock 回调：数据库是独占的可变借用（Zig 借用检查保证同一时刻只有一个操作），多任务场景由调用方用互斥量包住整个数据库对象即可。

## 许可

本库以 Apache-2.0 发布。`reference/FlashDB` 为上游 [armink/FlashDB](https://github.com/armink/FlashDB)
2.2.99（Apache-2.0）的只读副本，仅用于差分测试；`bench/` 与 `firmware/` 中的 C 代码同样是
测量对照实现。详见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
