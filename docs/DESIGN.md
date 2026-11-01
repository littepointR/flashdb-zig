# FlashDB-Zig 设计文档

用 Zig 从零重写的 FlashDB：面向裸 Flash 的超轻量键值库（KVDB）与时序库（TSDB）。
本实现**不是** FlashDB-C 的逐行翻译：盘面格式、状态编码、缓存结构、遍历与 GC 路径都按
Zig 的能力重新设计。目标是在**性能 / ROM / 静态 RAM / 栈占用**四项上全部不劣于 C 原版。

> 本文是模块契约与盘面格式的唯一权威来源。任何实现与本文不一致，以本文为准（先改文档再改代码）。

---

## 1. 目标与约束

1. `no_std`、**零堆分配**、**零全局状态**：数据库以值语义直接持有 Flash 驱动，不依赖 FAL 分区表或全局锁。
2. **编译期特化**：扇区大小/数量、写粒度、时间戳位宽、缓存规模、名称上限全部是 `comptime` 参数；
   所有布局/分支在编译期折叠，运行期零开销。
3. **错误联合**：`Error = Flash.Error || error{...}`，驱动自身的错误类型原样透传，没有 `FDB_ASSERT` 死循环。
4. **崩溃一致性**：任何一次 Flash 操作之间掉电，重新挂载后数据必须是"旧值或新值"，绝不损坏。
   每个状态迁移只做**一次单写粒度的"清位"写入**（NOR 的 1→0 语义），因此天然原子。
5. **新盘面格式**（用户已确认允许重新设计）。不追求与 FlashDB 2.2.99 字节兼容，但功能语义对齐。
6. 支持写粒度 1/8/32/64/128/256 bit（`gran_bytes = 1,1,4,8,16,32`），小端。

## 2. 分层

```
                用户代码
                   │
        ┌──────────┴──────────┐
     Kvdb(F, cfg)         Tsdb(F, cfg)
        │                     │
        └─────────┬───────────┘
             device.zig           几何校验、Flash 读写封装、单粒度写、扇区头编解码
                  │
              flash.zig           Flash 协议 + Partition 适配器
                  │
              format.zig          盘面偏移/状态编码/魔数/CRC（全部 comptime）
```

| 文件 | 内容 |
|---|---|
| `src/flash.zig` | Flash 协议（duck-typed：`read/write/erase` + `Error`），`Partition(F)` 子分区适配器 |
| `src/format.zig` | 魔数、版本、扇区头布局、记录头布局、状态粒度编码、对齐工具、`Config` 校验（comptime） |
| `src/crc.zig` | CRC32(IEEE，comptime 256 项表) 与 CRC16(CCITT，16 项半字节表)、FNV-1a 与雪崩混合 |
| `src/device.zig` | 带边界检查的 `Device`：读/写/擦、单粒度状态写、扇区头解析/格式化 |
| `src/kvdb.zig` | KVDB：挂载/恢复、get/set/delete、迭代、GC、auto-update |
| `src/tsdb.zig` | TSDB：挂载/恢复、append、正/反/按时间迭代、query_count、rollover、clean |
| `src/sim.zig` | 宿主/固件通用的 RAM NOR 模拟器（擦写计数、故障注入、位级写语义） |

## 3. 盘面格式 v1

所有多字节字段小端。写粒度 `gran_bytes = max(1, write_gran/8)`，下称 `g`。

### 3.1 扇区头（KV 与 TS 共用前缀）

扇区头写在每个扇区起始处，`sector_data_off` 之后才是记录区。

```
偏移        大小      字段
0           2         magic   = 0x4446 ('F','D' LE)
2           1         version = 1
3           1         gran_log2（g = 1<<gran_log2）
4           1         kind: 1=KVDB, 2=TSDB
5           1         flags（bit0 reserved）
6           2         seq（扇区序号，单调递增，u16 回绕比较）
8           2         crc16（CCITT over 前 8 字节）
= 10 字节，向上对齐到 g
```

**KV 扇区没有持久状态区**：`using`/`full`/`dirty`/GC 进度全部在挂载时由记录扫描推导，
因此 KV 的 `data_off` 就是 `align_up(10, g)`（g=1 时 10 字节，C 版为 18 字节），
每个扇区生命周期还少 3 次状态写。TSDB 需要 `using`/`full` 两个状态粒度
（前者定位当前写入扇区，避免挂载时扫描所有扇区；后者是扇区尾部时间信息的提交标记）：

| 扇区类型 | 状态粒度（顺序） | 含义 |
|---|---|---|
| KV | 无 | 全部推导 |
| TS | `using`, `full` | 依次置 0：当前写入扇区 / 已写满 |

TS 另有：

```
start_time      align_up(T, g)      扇区首条记录时间戳（变 USING 时写一次）
end_time        align_up(T, g)      扇区末条记录时间戳（变 FULL 时写一次）
end_offsets     align_up(4, g)      { end_idx_off: u16, end_data_off: u16 }，与 end_time 同批写入
```

`T` = 时间戳宽度（4 或 8）。这些字段各自只写一次；`FULL` 粒度最后写入，充当它们的提交标记。

**各粒度扇区头大小（g=1 / g=4）**：KV 10 / 12 字节；TS（T=4）24 / 32 字节。
C 原版分别为 18 / 36（KV）与 41 / 80（TS）。

### 3.2 KV 记录

记录起始地址必须 `g` 对齐。

```
偏移              大小                 字段
0                 g                    commit   （0x00…=已提交；0xFF…=未完成）
g                 g                    pending  （0x00…=待删除，掉电可恢复）
2g                g                    deleted  （0x00…=彻底删除，GC 时回收）
3g                1                    name_len
3g+1              2 | 4                value_len（max_size ≤ 64 KiB 时 u16，否则 u32）
3g+1+W            4                    crc32（覆盖 name_len、value_len、(name)、(value)）
3g+1+W+4          name_len             name
...               align_up(value_len)  value
末尾补齐到 g
```

* **提交协议**：先写 `[3g, 记录尾)` 一段连续数据（含 name_len/value_len/crc32/name/value），
  再单独写 `commit` 粒度（清零）。断电时 `commit` 非 0 → 整条记录忽略。
* **更新/删除协议**（顺序即崩溃语义）：
  1. 旧记录 `pending = 0`（立刻不可见，但可恢复）；
  2. 写入新记录并提交（若是更新）；
  3. 旧记录 `deleted = 0`。
  掉电在 1–3 之间：挂载时发现 `pending` 有效且**找不到同 key 的已提交记录**→ 把旧记录搬移（move）到当前扇区并重新提交（恢复旧值）；
  如果找到已提交的新值 → 直接补写 `deleted`。
* **写入次数**：新建 2 次（数据 + commit）；更新 4 次（pending + 数据 + commit + deleted）；删除 2 次。
  C 原版分别为 5 / 8–9 / 2。
* `name_len` 上限 comptime 配置（默认 64）；`value_len` 上限由扇区大小约束。

### 3.3 TS 记录（索引 + 载荷）

扇区内：索引自 `sector_data_off` 向上增长，载荷自扇区末尾向下增长；两者相撞即扇区满。

索引记录（固定大小，`g` 对齐）：

```
0                 g          commit     （0x00…=已提交）
g                 g          user1      （用户状态 1）
2g                g          deleted    （已删除）
3g                g          user2      （用户状态 2）
4g                align_up(T,g)  time
+                 align_up(2,g)  log_len
+                 align_up(2,g)  log_off（载荷相对扇区起点的偏移）
```

状态读法：`commit` 未置 → 槽位为空（等同 C 的 UNUSED/PRE_WRITE，遍历到此终止）；
否则取"最后一个被置位的槽"：`user2 > deleted > user1 > write`，与 C 的状态序一致。
每个槽在记录生命周期内至多写一次。

**append 协议**：写载荷 → 写索引数据（`[4g, 末尾)`）→ 写 `commit`。
断电时 `commit` 未置 → 索引槽视为空；恢复时按 `max_len` 预留载荷空间（与 C 相同）。

**扇区满协议**：写 `end_time`/`end_offsets` → 写扇区 `full` 粒度（提交）→ 切到下一扇区
（必要时擦除并重新格式化，实现 rollover，更新 `oldest`）→ 写 `using` 粒度与 `start_time`。

**按时间迭代**：先用扇区头 `start_time/end_time` 跳过不相交扇区，再在扇区内对固定大小的索引做二分，
找到首个 `time >= from` 的槽位后顺序扫描；`from > to` 时自动反向（与 C 行为一致）。

### 3.4 扇区序号与最老扇区

每次格式化扇区 `seq = ++db.seq`（u16，回绕用有符号差比较）。挂载时读取所有有效扇区头即可重建：
`oldest` = seq 最小者；`current` = seq 最大者（KV 的当前写入扇区即"最后一个有空间者"）。
不依赖物理环序，也不需要在 RAM 里缓存整张扇区表。

## 4. 崩溃一致性的原子性论证

NOR 写只能把位从 1 清到 0；一次"写一个粒度"的操作在断电时**要么完成、要么未完成**，
不会出现第三种可读值（部分编程的位仍读 1）。因此：

* 提交 = 把 commit 粒度从 `0xFF…` 写成 `0x00…`：只有完成才读得到全 0，未完成读回非 0。
* 不可见 = 把 pending/deleted 粒度写成 `0x00…`：完成即可见地标记，未完成则保持旧状态。
* 每个粒度的写入在扇区被擦除前都只发生一次（设计保证），满足 STM32L4/U5 等"擦除前每 quad-word 只能编程一次"的器件限制。
* 任何"旧值丢失"的中间态都通过 `pending` + 挂载恢复（move）兜底，与 C 的 `PRE_DELETE` 恢复等价。

## 5. KVDB 设计要点

### 5.1 内存布局（全部 comptime 定长）

| 项 | 大小（4 扇区、64 缓存项、max_size≤64K） |
|---|---|
| `Kvdb` 结构体（含 Flash 驱动） | 驱动 + 约 30 B 标量 + 缓存表 + 每扇区 2 B |
| 名称缓存 | `4 路组相联`，每项 `{tag: u16, addr: u16}` = 4 B × 128 = 512 B（可用 0/32/64/128 配置） |
| 每扇区状态 | `empty_off: u16` × 扇区数，`dirty_mask: u32` |

C 原版为 64×8 B + 8×40 B = 832 B 缓存 + 152 B 结构体；本实现 Cortex-M3 上实测 `sizeof(Kvdb)` = 584 B（含 16 B Partition 驱动值）。

### 5.2 查找

1. 名称哈希（FNV-1a + Murmur3 雪崩混合）→ 4 路组相联探测（round-robin 替换）；命中则读记录头（`[0, 3g+7)` 一次读）校验 name_len，再读 name 比对；
2. 未命中回落到全扇区扫描，只读记录头，`name_len` 相同才读 name；**从不为了遍历而读 value/CRC**；
3. 扫描顺序为 seq 降序（新→旧），首个可见版本即答案。

### 5.3 读取

`get` 一次路径：记录头 → （命中缓存时可跳过）name 校验 → value 分块读取、**边拷贝边算 CRC32**。
撕裂缓存命中时 CRC 校验用调用方 key 替代 name，一次读完成"键匹配 + 数据完整性"双重校验，
命中失败自动回退扫描。C 在同一操作里读 4 次以上。

### 5.4 迭代

`Iterator.next()` 返回 `Entry`（含指向迭代器内部缓冲的 name 切片，生命周期到下次 `next`）；
`Entry.readValue(buf)` 按需读 value。跳过定长头部与整条记录都靠 `value_len/name_len` 直接计算下一条地址，
不需要像 C 那样逐字节扫描魔术字。

### 5.5 分配 / GC

* 分配：当前扇区有空间就用；否则取一个未格式化的扇区（首次空白挂载只格式化第一个扇区，其余保持整块擦除状态，后续认领时只需写扇区头，不再多擦一次）。
* **保留一个空扇区**给 GC：若只剩 1 个空扇区且存在脏扇区，先 GC 再分配，避免"无处可搬"死锁。
* GC：收集 seq 最小的脏扇区 → 把其中可见记录 move 到当前扇区（保留原 seq 语义，不改变新旧关系）→ 擦除并重新格式化该扇区 → 更新 `oldest`。
  move 过程中的记录级协议与更新相同（pending → 新副本 → deleted），掉电可恢复。
* 无需"GC 进行中"标记：被搬移记录先写 `pending`，副本提交后才写 `deleted`；挂载时对仍为 `pending` 的记录检查"是否存在可见后继版本"，有则补 `deleted`，无则搬移恢复。GC 中断后的扇区必然含 pending/deleted，扫描时会被重新标记为脏扇区。

## 6. TSDB 设计要点

* `Tsdb` 结构体在 Cortex-M3 上实测 56 B（C 为 160 B）；TS 扇区头 24 B（C 41 B），索引 12 B（C 17 B）。
* `append(time, data)`：显式时间戳；另提供 `appendNow(getTime)`。时间必须严格递增，长度 ≤ `max_len`。
* 迭代器：`iter()` / `iterReverse()` / `iterByTime(from, to)`，`TslEntry.readPayload(buf)`。
* `rollover` 运行期可切换（`setRollover/getRollover`），与 C 的 control 语义一致。
* `last_time` 恢复：优先取 USING 扇区最后已提交记录，否则取前一扇区头 `end_time`。

## 7. Zig 特性使用清单

| 特性 | 用途 |
|---|---|
| `comptime` 结构体参数 | 几何、粒度、时间戳位宽、缓存规模、CRC 表规模全部编译期常量 |
| `comptime` 块 + `@compileError` | 配置校验（2 的幂、扇区数下限、g 合法性、u16 偏移是否溢出） |
| `comptime` 生成 CRC 表 | 零运行期初始化，1 KiB `.rodata`（可选 64 B 半字节表） |
| `@intCast/@truncate/@bitCast` | 精确位宽，编译器可证明无溢出；ReleaseSmall/Fast 无安全检查开销 |
| `error` 联合 | 驱动错误透传、无错误码映射表 |
| `*Self` 挂载 + 值语义驱动 | 静态分配数据库零栈拷贝（等价 C 的 `fdb_kvdb_init` 指针式 API） |
| `[]const u8` / `[]u8` 切片 | key/value API 无长度参数、无 `strlen` |
| `inline fn` + comptime 分支 | 写粒度、状态槽位在此编译期完全折叠 |
| `std.mem` 之外的零依赖 | 库不引用 `std.fmt`/`std.io`/分配器，ROM 可控 |
| `@export` / freestanding | Cortex-M3 固件无需 libc |

## 8. 与 C 原版的行为差异（有意为之）

1. **盘面格式不同**（用户确认允许）：本库不能读取 C 版镜像，反之亦然；迁移需重新初始化。
2. `Kvdb.get` 返回**值的总长度**（拷贝长度 = min(buf.len, len)），C 返回实际拷贝长度。
3. `delete` 返回 `bool`（键是否存在），不区分 `FDB_KV_NAME_ERR`。
4. `tsl_set_status` 只允许"向前"迁移（写新槽位）；向后迁移为 no-op（C 会重复编程同一粒度，在部分器件上不安全）。
5. 未移植文件模式（`FDB_USING_FILE_*`）；宿主测试用 `sim.RamFlash`。
6. 不支持大端。
7. `FDB_KV_AUTO_UPDATE` 等价为显式 `autoUpdate(version, defaults)`。
8. 扇区大小/数量在编译期确定（C 为运行期 control 命令）。
9. 没有 lock/unlock 回调：*Kvdb/*Tsdb 是可变的独占借用，多任务访问由调用方加锁；库内不保存函数指针，结构体更小。

## 9. 验收口径

1. 宿主基准：`bench/SCENARIOS.md` 全部场景，Zig vs C，Flash 流量（读/写/擦次数与字节）+ 耗时。
2. Cortex-M3/QEMU 固件（`-Os`/ReleaseSmall）：`.text/.rodata/.data/.bss`、峰值栈、DWT 周期、工作负载校验和。
3. 正确性：单元测试、C 原版行为测试移植、随机状态机模型对拍、逐 Flash 操作掉电注入、长时间浸泡。
