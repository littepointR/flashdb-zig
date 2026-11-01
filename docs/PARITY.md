# 与上游 FlashDB 的功能对照

本库不是 C 源码的逐行翻译，但**功能上覆盖了上游公开 API**。这份文档逐项对照
[FlashDB 2.2.99](https://github.com/armink/FlashDB)（commit `db0afd9`）的公开接口与本库的等价能力，
并明确列出"有意不同"和"尚未实现"的部分，供迁移时参考。

- 上游接口清单来自 `reference/FlashDB/inc/flashdb.h`、`fdb_def.h`。
- 行为等价的证据：`bench/diff` 的 C↔Zig 行为差分（KV 2,020 行 + TS 1,046 行逐操作一致，含逐 mutation
  掉电）、`tests/kv_model.zig` 的随机模型对拍、Cortex-M3 固件两侧校验和一致。

## 1. 初始化与生命周期

| 上游 FlashDB | 本库 | 说明 |
|---|---|---|
| `fdb_kvdb_init(db, name, path, default_kv, user_data)` | `Kvdb(...).mount(f)`，随后 `applyDefaults(defaults)` 或 `autoUpdate(version, defaults)` | 上游在**所有扇区头都无效**（全新分区或整体损坏，见 `_fdb_kv_load`）时用 `fdb_kv_set_default` 写入默认值；本库把默认值做成显式调用，`applyDefaults` 可重复调用且只补缺失键 |
| `fdb_tsdb_init(db, name, path, get_time, max_len, user_data)` | `Tsdb(...).mount(f)`；时间由调用方在 `append(time, data)` 传入 | 无内部时钟回调（no_std 更直接），`max_len` 是编译期配置 |
| `fdb_kvdb_deinit` / `fdb_tsdb_deinit` | 无对应函数 | 本库无堆、无锁、无全局状态，数据库生命周期结束即释放；无需收尾调用 |
| `fdb_kvdb_check` | `check()` | 遍历并校验每条记录的 CRC32 |
| `fdb_calc_crc32` | `flashdb.crc.crc32` | 同一多项式/初值/查表 |
| `fdb_blob_make` / `fdb_blob_read` | 直接用 `[]const u8` / `[]u8` | Zig 侧 value 一律是字节切片，不需要 blob 包装 |

## 2. 控制命令与配置项

上游用 `fdb_kvdb_control` / `fdb_tsdb_control` 在运行期改配置；本库把几何与行为做成**编译期**配置
（`KvdbConfig` / `TsdbConfig`），运行期只保留必要的开关：

| 上游控制命令 / 配置宏 | 本库 |
|---|---|
| `SET_SEC_SIZE` / `GET_SEC_SIZE` | `Config.sector_size`（编译期，参与布局与地址类型推导） |
| `SET_MAX_SECTOR` / `SET_MAX_SIZE` | `Config.sector_count`（编译期，KVDB 3..32、TSDB 2..32） |
| `SET_LOCK` / `SET_UNLOCK`（线程锁回调） | 未提供——库无全局状态，建议一个数据库实例由单一线程/任务独占 |
| `SET_NOT_FORMAT` | `Config.not_formattable = true` |
| `SET_FILE_MODE` / `SET_MAX_SIZE`（文件模式） | 未提供（见 §4） |
| `FDB_TSDB_CTRL_SET_ROLLOVER` / `GET_ROLLOVER` | `setRollover(on)` / `getRollover()` |
| `FDB_TSDB_CTRL_GET_LAST_TIME` | `lastTime()` |
| `FDB_KV_AUTO_UPDATE` | `autoUpdate(version, defaults)`；另有 `applyDefaults(defaults)` 只补缺失键 |
| `FDB_KV_USING_CACHE` / `FDB_KV_CACHE_TABLE_SIZE` | `Config.cache_entries`（0 或 4 的倍数，≤128） |
| `FDB_WRITE_GRAN` | 由驱动的 `write_gran_bits` 决定（1/8/32/64/128/256），可同进程混用不同粒度 |
| `FDB_KV_NAME_MAX` | `Config.max_name_len` |
| `FDB_TSDB_FIXED_BLOB_SIZE` | 不需要：本库每条 entry 记录长度，`max_len` 只约束上限 |
| `FDB_USING_TIMESTAMP_64BIT` | `Config.ts_bits = 32 \| 64` |

## 3. KVDB API

| 上游 | 本库 | 说明 |
|---|---|---|
| `fdb_kv_set`（字符串） | `set(key, value: []const u8)` | 不要求 NUL 结尾 |
| `fdb_kv_get`（内部静态缓冲的 NUL 结尾字符串，仅当值为字符串且 ≤ `FDB_STR_KV_VALUE_MAX_SIZE`，默认 32 字节，否则返回 NULL） | `getString(key, buf) ?[]const u8`，底层 `get(key, buf) ?u32` | `getString` 追加 NUL 并返回切片，缓冲不足返回 `error.BufferTooSmall`；`get` 返回长度并复制任意二进制（可重入） |
| `fdb_kv_set_blob` / `fdb_kv_get_blob` | 同上 | 本库 value 天然支持任意二进制 |
| `fdb_kv_del` | `delete(key) !bool` | 返回是否真的删除 |
| `fdb_kv_set_default` | `restoreDefaults(defaults) !u32` | 强制把每个默认键写回默认值（工厂复位），返回写入数量 |
| `FDB_KV_AUTO_UPDATE`（`kv_auto_update`） | `autoUpdate(version, defaults)` | 仅在 `__ver_num__` 变化时补缺失默认键并更新版本 |
| `fdb_kv_get_obj` + `fdb_kv_to_blob` + `fdb_blob_read` | `iterator()` → `Entry`（含 `addr/value_len/crc`）→ `readValue(buf, entry)`；单键读取直接用 `get` | 同样是"先定位再读值"，一次性校验 CRC32 |
| `fdb_kv_iterator_init` / `fdb_kv_iterate`（回调） | `iterator()` + `next()` + `readValue()`；迭代器带 `iterated_count` / `iterated_value_bytes` / `iterated_obj_bytes` | 可 `break` 提前结束，无回调；统计字段与上游 `iterated_*` 对应 |
| `fdb_kv_print` | 未提供 | no_std 无默认日志；遍历 iterator 即可打印 |
| 缓存失效/统计 | 无公开接口 | 缓存是内部优化，不暴露统计 |
| 单键值上限 | `max_value_len` / `maxValueLenFor(key_len)` | 键越短可存的值越大，逐键精确 |

## 4. TSDB API

| 上游 | 本库 | 说明 |
|---|---|---|
| `fdb_tsl_append(blob)`（用 `get_time` 回调取时间） | `append(time, data)` | 时间必须严格递增，与上游 `tsl_append` 的检查一致 |
| `fdb_tsl_append_with_ts` | 同上 | 本库的 `append` 就是显式时间版本 |
| `fdb_tsl_iter` | `iterator()` | 正序 |
| `fdb_tsl_iter_reverse` | `iteratorReverse()` | 逆序 |
| `fdb_tsl_iter_by_time(from, to)` | `iteratorByTime(from, to)` | 闭区间 |
| `fdb_tsl_query_count(from, to, status)` | `queryCount(from, to, status)` | 额外支持 `from > to`（反向区间），上游要求 `from <= to` |
| `fdb_tsl_max_blob_count` | `maxEntryCount()` | 按 `max_len` 估算的单库容量 |
| `fdb_tsl_set_status` | `setStatus(entry, status)` | **更严格**：只允许状态前进，回退返回 `error.StatusNotAdvancing`（NOR 单次写粒度也无法真正回退） |
| `fdb_tsl_clean` | `clean()` | 擦除整个分区并重建 |
| `fdb_tsl_to_blob` + `fdb_blob_read` | `Entry.log_addr`/`len` + `readPayload(buf, entry)` | 复制 `min(buf.len, len)` 字节；TS 条目在上游与这里都没有 CRC |
| `fdb_tsl_t` 的 `log_len`/`addr.index`/`addr.log` | `Entry.len`/`index_addr`/`log_addr` | 字段一一对应 |

## 5. 有意不同的地方

1. **新盘面格式**（经确认）：KV 记录固定开销 10 B（上游 18–22 B），TS 索引 12 B（上游 17 B）；
   字节镜像不兼容，但逻辑行为由 `bench/diff` 逐操作对拍保证。
2. **状态迁移显式报错**：见上表 `setStatus`。
3. **没有锁**：上游的 lock/unlock 回调在这里不需要；多任务共享时请由调用方串行化。
4. **配置编译期化**：没有运行期改扇区大小/文件模式的接口，换来更小的 RAM/ROM 与可推导的地址类型。
5. **错误模型**：用 Zig error set（`SavedFull`、`NotFormatted`、`Corrupted`、`InvalidName`、
   `InitFailed`、`TimeNotIncreasing`、`ValueTooLarge`、`StatusNotAdvancing`）替代 `fdb_err_t`。
6. **默认值/迁移是显式调用**：`applyDefaults` / `restoreDefaults` / `autoUpdate`，不在 mount 里隐式写 Flash。

## 6. 尚未实现（可按需补充）

| 项目 | 现状与建议 |
|---|---|
| 多线程/中断锁回调 | 未实现。若要共享实例，可加 `Config.lock` 并在公开入口加钩子（会改动所有 API 的调用约定，且需避免嵌套加锁） |
| 调试打印（`fdb_kv_print`、`FDB_INFO` 日志） | 未实现。可加可选的 `dump(sink)`（自定义 `write` 回调，不依赖 `std`）；示例已展示遍历打印 |
| FAL 设备/分区名字注册表 | 不需要：`flash.Partition(Dev)` 已覆盖多分区，且无运行期字符串表开销 |
| 同物理 Flash 混用不同写粒度 | 不支持（上游同样不支持）；每个驱动固定 `write_gran_bits` |
| 运行期 control 命令、`deinit`、大端 | 分别见 §5：编译期配置、无资源、不支持 |

文件模式（`FDB_USING_FILE_POSIX_MODE`）已作为**宿主辅助模块**实现，见 §8。

## 7. 本轮补齐的缺口

- `restoreDefaults(defaults)`：等价上游 `fdb_kv_set_default`（强制写回默认值）。
- `applyDefaults(defaults)`：等价 `FDB_KV_AUTO_UPDATE` 内部"只补缺失默认键"的步骤，可在每次 mount 后
  安全调用（已存在键不会被覆盖）。
- `autoUpdate(version, defaults)` 改为复用 `applyDefaults`，语义与上游 `kv_auto_update` 一致：
  仅当版本号变化时补缺失键并更新版本。
- `getString(key, buf)`：等价上游 `fdb_kv_get` 的 NUL 语义（缓冲不足返回 `error.BufferTooSmall`）。
- KV 迭代器统计字段 `iterated_count` / `iterated_value_bytes` / `iterated_obj_bytes`：等价上游
  `iterated_cnt` / `iterated_value_bytes` / `iterated_obj_bytes`。
- 宿主文件模式：`host/file_flash.zig` + `flashdb_host` 模块 + `examples/file_backed.zig`（见 §8）。

## 8. 宿主文件模式（新增）

上游的 `FDB_USING_FILE_POSIX_MODE` 用普通文件当 Flash；本库对应的是
[`host/file_flash.zig`](../host/file_flash.zig)，作为**独立模块** `flashdb_host` 提供：

```zig
const host = @import("flashdb_host");
const FileFlash = host.FileFlash(.{ .file_size = 64 * 1024, .block_size = 4096 });

var fl = try FileFlash.open(io, std.Io.Dir.cwd(), "db.bin", .open_or_create);
defer fl.close();
var db: flashdb.Kvdb(FileFlash, .{ .sector_size = 4096, .sector_count = 4 }) = undefined;
try db.mount(fl);
```

- 库本体仍是 `no_std`：只有这一个文件导入 `std`，`flashdb.zig` 不引用它。
- 语义：文件即原始 NOR 镜像；`erase` 把整块填回擦除字节（0xFF），读写是库已对齐的
  positional I/O。没有硬件位清除保护（与上游文件模式一致，库本身也不会做 0→1 的写）。
- 文件大小固定：`open` 校验长度，不匹配返回 `error.SizeMismatch`；`create` 会预填擦除字节。
- 测试：`host/file_flash_test.zig`（随 `zig build test` 运行）覆盖擦除语义、越界/未对齐、
  固定长度校验以及"文件跨驱动实例持久化"；示例 `examples/file_backed.zig` 连续运行两次
  `boot_count` 递增。
