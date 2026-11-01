# 测试与验证

本项目的正确性主张分四层：
**单元 → 随机模型对拍 → C↔Zig 行为差分 → 真实测量（宿主基准 + Cortex-M3 固件）**。
掉电一致性在每一层都单独扫过。

当前状态：`zig build test` **55/55 全绿**（43 个库内单元测试 + 12 个集成/模型测试），
函数覆盖率 **100%**（161/161，公开 API 54/54，见 §6），
`scripts/diff.ps1` **KV + TS 双向对拍 PASS**，C 与 Zig 固件校验和逐字节一致。

## 1. 单元测试（`src/**` 内，`zig build test`）

| 模块 | 数量 | 覆盖内容 |
|---|---:|---|
| `format.zig` | 5 | 扇区头编解码往返、错误 kind/粒度/CRC 拒绝；KV/TS 布局在 1/4/8/16/32 字节粒度下全部对齐、三段写区间恰好铺满记录；序号回绕比较；CRC16 半字节表与按位定义逐值一致 |
| `crc.zig` | 2 | CRC32 标准校验值（`"123456789"` → `0xCBF43926`）、流式累加等价、FNV-1a 已知向量、雪崩混合稳定性 |
| `sim.zig` | 2 | NOR 语义（写只能清位、越界/未对齐拒绝、擦除填充 0xFF）、故障注入只让写/擦失败且不改变介质、读永远成功 |
| `device.zig` | 1 | 边界检查、写粒度对齐、`writePadded` 尾部 0xFF 填充、扇区头 round-trip、状态粒度读取 |
| `flashdb.zig` | 1 | 入口测试块：把各模块单元测试纳入同一次运行 |
| `kvdb.zig` | 10 | CRUD + 重挂载持久化、短缓冲返回总长、迭代与计数、`autoUpdate`、GC churn 下全部值可回读、`check()`；**逐次写/擦掉电注入**（set/delete 的每一次 mutation）；32 bit 写粒度完整 churn；`maxValueLenFor` 对每种键长精确（+1 字节即 `SavedFull` 且不触碰 Flash）；**记录头损坏后的扫描/读取/GC 重同步**（损坏中间记录后仍能读到其后的键，GC 搬移不丢数据）；**默认值迁移**（`applyDefaults` 只补缺失、`restoreDefaults` 强制写回、`autoUpdate` 仅在版本变化时迁移） |
| `tsdb.zig` | 22 | append/正反向/按时间迭代与暴力扫描一致、queryCount、满库与 `maxEntryCount`、rollover 窗口、64 位时间戳、多写粒度、重挂载、索引 commit/offset 损坏恢复、end-info 重建、多次 USING 判定为损坏、clean、逐次 append/换扇区/rollover 掉电、超范围查询零读返回 |

## 2. 随机模型对拍（`tests/kv_model.zig`）

`std.Random.DefaultPrng`（种子打印，失败可复现）驱动随机操作流，与内存参考模型逐操作比对：

* **10 个随机流配置**：写粒度 1/8/32/64/128/256 bit、扇区 1024/4096 B、3/4/8/20 个扇区、
  缓存 0/8/64、名称上限 16/64；共 **3,860 次操作**（每配置 250–1,400 次），
  set/覆盖/delete（存在与不存在）/get（精确、前缀、零缓冲）/contains/count/iterate/
  check/remount/formatAll/autoUpdate 全覆盖。
* **51 组掉电扫描 / 542 个断电点**：11 个配置 × 4–5 种操作（覆盖写、删除、新键、
  formatAll、触发 GC 搬移的写入），对每一次 mutation 断电；每次恢复后校验
  `check()`、每个键是旧值或新值、无关键不变、count/迭代一致、无重复键、
  `set_bit_attempts == 0` 且 `violations == 0`，并验证"干净重放"与后置模型完全一致。
* **>64 KiB 分区（u32 地址路径）**：81920 B 分区无 formatAll 写入 670 × 100 B 键直到
  `SavedFull`，断言出现 `addr > 0xFFFF`，全部键可读、重挂载一致，并覆盖"GC 把活记录搬到
  0xFFFF 以上"的路径。
* 运行时间约 0.5 s（提交在 60 s 预算内）。

```powershell
.tools\zig\zig.exe build test                 # 55/55
# 单独运行模型套件（模块 import 需要显式模块表）
.tools\zig\zig.exe test --dep flashdb -Mroot=tests\kv_model.zig -Mflashdb=src\flashdb.zig
```

## 3. C↔Zig 行为差分（`bench/diff/`，`scripts/diff.ps1`）

盘面格式不同（本库是新格式），因此镜像级兼容不适用，改为**行为级**对拍：同一份确定性操作脚本
同时驱动 C 原版与本库，输出规范化的逐操作记录与状态摘要，逐行比较。

当前结果（`pwsh -NoProfile -File scripts/diff.ps1`，exit 0）：

| 部分 | 结果 |
|---|---|
| KV 主脚本 | **2,020 行完全一致**（2,000 条 OP + 8 个 checkpoint + 最终 state/roll/summary） |
| KV 掉电 | set 阶段：C 9 个断电点 / Zig 6 个（格式相关，允许）；每次可见状态有效，最终 dump_fnv 两侧一致 `0xe3e5e6a1`。delete 阶段同理，`0xf6bd93f4` 一致 |
| TS 主脚本 | **1,046 行完全一致**（1,000 条 TS-OP + 4 checkpoint + TS-STATE + 8×TS-QUERY + TS-ROLL + TS-SUMMARY） |
| TS 掉电 | C 5 个 / Zig 4 个断电点；新条目"存在或不存在"集合一致，最终 dump_fnv 一致 `0xe1ac9481` |

脚本协议（种子、LCG、键/值生成、bucket 比例、崩溃枚举与允许差异）写在
[`bench/diff/README.md`](bench/diff/README.md)：KV 2,000 op（set/delete/get/miss/iterate/
remount/defaults，48 键池、值长 1..120）；TS 1,000 op（append/remount/by-time/query_count/
clean+repopulate，每个 epoch 最多 40 条以保证两侧逻辑内容相同）；崩溃探针在 append/set/delete
的每个 mutation 断电后校验可见状态。

## 4. 宿主基准（`bench/`）

协议见 [`bench/SCENARIOS.md`](bench/SCENARIOS.md)：32 KiB RAM NOR、4 KiB 块、16 KiB KV 分区 +
16 KiB TS 分区、写粒度 8/1 bit；每次测量前重置计数器，记录读/写/擦次数与字节、每操作用时
（7 次运行取样本最小值）、结果 checksum。数据生成、LCG 区间、checksum 序列化与 C 侧逐字节一致。

```powershell
.\scripts\build_bench_c.ps1
.tools\zig\zig.exe build bench
.\zig-out\bin\flashdb-bench.exe --wg 8 --runs 7 --out bench\results\zig_wg8_host.json
python tools\compare_bench.py bench\results\c_wg8_host.json bench\results\zig_wg8_host.json --metric min --normalize-ts --checksum-scope kv
```

结果表见 [`BENCHMARKS.md`](BENCHMARKS.md)。C 参考实现自身还有 `--mode check`
（约 100 条不变量，`scripts\check_bench_c.ps1`），Zig 基准也有 `--mode check`
（两个写粒度各 0 failure），保证对照侧与被测侧的模拟器与库行为可信。

## 5. Cortex-M3 / QEMU 固件对比（`firmware/`）

两侧运行**同一工作负载**（`firmware/common/workload_spec.h`：64 键写入、32 次更新、
1500 次 GC churn、64 次校验读取、全量遍历、200 条 TS 追加与遍历），链接**同一套测量脚手架**
（启动向量表、半主机输出、栈涂色、周期计数、链接脚本），因此数字可直接比较：

* ROM = `.text + .rodata + .data`；静态 RAM = `.data + .bss`；峰值栈 = 0xA5 涂色水位；
* CPU 周期：真实芯片走 DWT CYCCNT；QEMU 8.2 不建模 DWT，退化为 `-icount shift=0` 下的
  SysTick 指令代理（`cycles_src=` 标明来源，两侧同口径）；
* 两侧 RESULT 行必须在两次重复运行中逐字节一致，且业务校验和完全相等
  （`kv=0x4b3486a4`、`kv_iter=0x0e250daa`、`ts=0x10d90680`、`rc=0`）。

```powershell
.\scripts\build_fw_c.ps1        # C: bench\results\c_firmware.json
.\firmware\zig\build.ps1        # Zig: bench\results\zig_firmware.json
```

## 6. 覆盖率

Zig 0.18 的工具链没有暴露 LLVM 的源码级覆盖率插桩（CLI 无 `-fprofile-instr-generate` /
`-fcoverage-mapping`，`lib/compiler_rt` 也不带 profiling runtime），因此**行覆盖率无法用官方
工具链测量**。项目改为用 `tools/coverage.py` 测量可复现的**函数覆盖率**：把 `src/**` 复制到
`build/coverage/` 下，在每个函数体插入一次性计数器（`test` 块与测试辅助函数不计数），
用同一套 54 个测试（单元 + 集成 + 随机模型）跑一遍，统计命中的函数比例。

当前实测（`python tools/coverage.py`，JSON 报告写入 `build/coverage/report.json`）：
**函数覆盖率 100%（161/161：160 个运行期命中 + 1 个仅在编译期执行的函数），公开 API 54/54**。

| 文件 | 函数数 | 运行期命中 | 编译期命中 | 覆盖率 |
|---|---:|---:|---:|---:|
| `src/crc.zig` | 4 | 4 | 0 | 100% |
| `src/device.zig` | 10 | 10 | 0 | 100% |
| `src/flash.zig` | 5 | 5 | 0 | 100% |
| `src/format.zig` | 20 | 19 | 1 | 100% |
| `src/kvdb.zig` | 51 | 51 | 0 | 100% |
| `src/sim.zig` | 12 | 12 | 0 | 100% |
| `src/tsdb.zig` | 59 | 59 | 0 | 100% |
| **合计** | **161** | **160** | **1** | **100%** |
| 公开 API 函数 | 54 | 54 | 0 | **100%** |

关于"编译期命中"：`format.comptimePow2` 是纯编译期的对齐断言（`comptime comptimePow2(g)`），
运行期不可达，无法触发运行期探针；但它会在编译测试二进制时被 `KvLayout`/`TsLayout` 的
comptime 块实际执行。工具对"所有引用都处于 comptime 上下文"的函数做静态分类并单独计一列，
不把它们混进运行期数字。type 工厂（`Kvdb(...) type`、`Partition(...) type` 等纯 comptime
函数）与测试辅助函数不计入分母。CI 以 `--min-functions 100` 运行该脚本，覆盖率回退即红灯。

```powershell
python tools\coverage.py                     # 报告 + build/coverage/report.json
python tools\coverage.py --min-functions 100 # 低于阈值时非零退出（CI 使用）
```

## 7. 一键验收


```powershell
pwsh -NoProfile -File scripts\accept_all.ps1
```

依次执行：库测试 → C 基准自检 → C 宿主基准 → Zig 宿主基准 → C/Zig 逐项对比（KV 校验和严格）→
KV+TS 行为差分 → C 固件 → Zig 固件，并打印 ROM/RAM/栈/周期与加权流量汇总；任何一步失败即
非零退出。

## 已知测试边界

* 未移植文件模式（`FDB_USING_FILE_*`）与大端格式，因此不在测试范围内。
* 本会话没有连接调试器，实板测试未执行；C 与 Zig 两侧都在 QEMU `mps2-an385`（Cortex-M3）上
  以同一脚手架测量。`firmware/README.md` 记录了在 NUCLEO-U545RE-Q 上复现所需的命令。
* 宿主机耗时受负载影响；验收用每次运行的最小样本（`--metric min`），Flash 计数与 checksum
  是确定性的。`tsl_mount` 单轮只有约 2 µs，宿主计时噪声会放大比值（见 BENCHMARKS.md §4），
  该场景以 Cortex-M3 周期与加权 Flash 成本判定。
* TS 基准的原始校验和按容量而定（新格式同分区多存 19.5% 的条目），语义对等由
  `c_ref_*` 前缀/窗口校验和与 `bench/diff` 共同保证。
