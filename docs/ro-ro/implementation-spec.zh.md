# 道路运输分支 · 实现规格书（给实现 Agent 的唯一输入）

> 本文件是"道路载具互载（RoRo）"特性的**实现用规格**，由 4 份代码调研底稿（`D:\CNS\ottd\.road-transport-analysis\sa1..sa4`）与《道路运输分支-整体规划.md》（下称《规划》）蒸馏而成。**用法**：实现 agent 以此为准逐模块施工；凡要"再探索"的东西，本文件已尽量压缩成"改哪个文件、哪个函数、加什么字段"。论证与背景见《规划》，本文件不再重复论述，只给指令。
> 基线：`D:\CNS\ottd\OpenTTD-patches`（JGRPP 0.73.1，SAVEGAME_VERSION 钉在 292）。行号仅作锚点，**以函数名为准定位**（版本漂移）。

---

## 0. 使用纪律（先读，违反即返工）

1. **确定性**：一切新逻辑只用整数/固定顺序迭代；不引入未固定浮点、不依赖 hash 迭代序；所有状态变更发生在 DoCommand 或 tick 内。每条新路径必须能被 sync test 覆盖。
2. **存档单向兼容**：fork 新档不得承诺回读 0.73.1；0.73.1 旧档必须能读入并取新字段默认值。**任何存档改动先做"自读自档"回归**（R3R 367 自读失败教训）。
3. **侵入面隔离**：普通货物/普通列车/非本特性订单行为零改动。新逻辑全部走：新状态位 + 新旗标 + 专用判断入口 + 站订单 RV 参数块（OrderExtraInfo）。
4. **禁改清单（踩过/验证过的坑，禁止触碰）**：
   - 不改 `Order` 既有字段**位宽**（pulsexlb 把 type 8→16 且无 compat 双档 → 旧档有判 corrupt 风险）；新参数一律新字节/新字段/`OrderExtraInfo`。
   - 不把新状态塞进 `Vehicle::vehicle_flags` 的高位（其存档文件宽度 16bit，R3R 已踩 bit23-25 截断）。
   - 不注册伪 CargoType、不把 RV 塞进 `st->goods`/`VehicleCargoList`（无身份、统计污染）。
   - 不做自定义装卸动画、不建"虚拟车库 tile"、不销毁重建 RV。
   - 不把条件求值写成有副作用（只读）；`OT_SLOT` 领/放仍由订单原语在各自时点执行。
5. **人类评审 gate**：每个里程碑（M1..M8）收口 = "可编译 + 最小场景可玩 + 回归不炸"，随后交人类评审再进下一步。

---

## 1. 范围与决策基线（快照，详见《规划》§1.4 / §4）

| 项 | 定稿 |
|---|---|
| 装载门 | 载体某节当前 `cargo_type` 属 `CargoClass::Oversized`（`IsCargoInClass`，cargotype.h:245）。默认内容无 oversized 货 → 需运车类 NewGRF/开发测试 GRF |
| 容量/重量 | 节容量换算成吨（`cargo_cap × CargoSpec::weight / 16`），RV 按整备重占用；按节判定；初期节内不混装普通货 |
| 重量物理 | 仅火车/公路车；入口 `GroundVehicle::CargoChanged()` |
| 配对 | 载体主导 + 条件表达式筛选 + 不匹配跳过（复用条件订单体系） |
| slot | 不单列机制：`SlotOccupancy/VehicleInSlot` 等作表达式子句；`OT_SLOT` TryAcquire/Release 作执行原语 |
| 装卸点 | 站内同 Station 的对应类型公路停靠站；直通式为推荐装卸坡道 |
| 收起/放下 | RV 从公路站格消失/出现 + 默认装卸动画（无自定义动画） |
| 在途货物口径 | D12 默认完全冻结（age/travelled 不计） |
| 运价 | 免费（只统计"被运载公里数"）；收费为二期（P7 仅评估） |
| 电车 | 不支持 |

---

## 2. 术语/锚点速查（改代码前先认这些）

- 装卸公共主链：`Vehicle::BeginLoading`（vehicle.cpp:3407）→ `PrepareUnload`（economy.cpp:1524，push 进 `Station::loading_vehicles`）→ 站每 tick `LoadUnloadStation`（economy.cpp:2438，FIFO 逐个）→ `LoadUnloadVehicle`（economy.cpp:1944）→ `HandleLoading`（vehicle.cpp:3797）/`LeaveStation`（vehicle.cpp:3574）。载体进站汇聚点：`TrainEnterStation`（train_cmd.cpp:5056）、`ShipController`（ship_cmd.cpp:851）、`AircraftEntersTerminal`（aircraft_cmd.cpp:1505）。
- RV 到站：`RoadVehController`（roadveh_cmd.cpp:2140）→`ProcessOrders`→`HandleLoading`；停靠帧逻辑与 `RoadVehArrivesAt`+`BeginLoading` 在 roadveh_cmd.cpp 到站分支；Bus/Truck 判定 `IsCargoInClass(cargo_type, Passengers)`（roadveh_cmd.cpp:91）。
- 公路停靠站记账：`RoadStop`（roadstop_base.h）：港湾=Bay0/Bay1+entrance busy（铰接拒入，roadstop.cpp:318）；直通=每方向 `Entry{length,occupied}` 按累计车长记账（roadstop.cpp:375-461，跨连续段共享）。
- 条件订单：`OrderConditionVariable`（order_type.h:217-243）、求值 switch 在 order_cmd.cpp（pulsexlb 追加变量求值先例 order_cmd.cpp:4768-4771）、编辑器在 order_gui.cpp、`OT_SLOT/OT_COUNTER/OT_LABEL/OT_SLOT_GROUP`（order_type.h:96-110）。
- 离图车辆先例：`GVSF_VIRTUAL`（vehicle_base.h:83）+ 全套豁免点（economy.cpp:159/248/541、vehiclelist.cpp:149/178、vehicle.cpp:423/851、disaster_vehicle.cpp:592、infrastructure.cpp、group_cmd.cpp:142、vehicle_cmd.cpp:270/606、sl/vehicle_sl.cpp:299）；tile 哈希 `UpdateVehicleTileHash`（vehicle.cpp:846）。
- 存档：`SAVEGAME_VERSION`=292（sl/saveload_common.h:465）；XSLF 特征（sl/extended_ver_sl.h/.cpp，`XSLFI_*` + `SlXvFeatureTest`/`SlXvIsFeatureMissing`）；VEHS 表 `_common_veh_desc`（sl/vehicle_sl.cpp:1021）与类型表 :1365、`AfterLoadVehiclesPhase1/2`（sl/vehicle_sl.cpp:285/476）；独立"每车侧表"chunk 先例 'VESR'（sl/vehicle_sl.cpp:1893）。
- 命令：`Commands` 枚举 command_type.h:492（只能插 `End` 哨兵前）；`DEF_CMD_TUPLE` 于对应 `*_cmd.h`；表自动生成（command_table.cpp:185）。
- 设置：`src/table/settings/*.ini`（settingsgen→table/settings.h，勿手改生成物）+ `settings_type.h` 结构 + `settings_compat.h` 老档映射。
- 窗口：详情窗 `VehicleDetailsWindow`（vehicle_gui.cpp:3058）、火车详情内部 tab `TrainDetailsWindowTabs`（vehicle_gui.h:26）、各型绘制 `DrawTrainDetails/RoadVehDetails/ShipDetails/AircraftDetails`、depot 窗 `DepotWindow`（depot_gui.cpp:273）、列表 `BuildDepotVehicleList`（vehiclelist.cpp:78）、`VL_DEPOT_LIST` 按订单枚举（vehiclelist.cpp:192）。

---

## 3. M1 数据模型与存档骨架（对应 P1；先做，其余模块都依赖）

### 3.1 新增字段（全部经 XSLF 特征 `XSLFI_ROAD_VEH_TRANSPORT`（v1）门控，**不 bump SAVEGAME_VERSION**）

> **2026-09-10 实现简化（M1 开工定稿）**：不再使用"载体 Front `transported_rvs` vector + 节缓存"双写模型。评审 #1 的实质诉求是"节级可追溯"，用 **RV 侧标量字段**即可完全满足：被运 RV 自己记住"宿主 Front + 装载到哪一节 + 占多少吨 + 入队时刻"，载体端的"载了什么/每节用了多少"**按需反查**（过滤车辆池 / 过滤宿主节上的 RV）。好处：**不动 Station chunk、不需要新侧表 chunk 'VRVS'、不涉及 vector 序列化**，M1 风险与工作量大幅下降；载体侧汇总只做 NOSAVE 缓存（后加）。

| 挂载点 | 字段 | 类型/语义 | 入档方式 |
|---|---|---|---|
| `Vehicle`（RV 侧） | `uint8_t rv_transport_flags` | 位0=`WaitingToBeTransported`（在站待运，仍在图上停车）、位1=`Transported`（挂起离图） | VEHS `_common_veh_desc` 加 `SLE_CONDVAR_X(Vehicle, rv_transport_flags, SLE_UINT8, SL_MIN_VERSION, SL_MAX_VERSION, SlXvFeatureTest(XSLFTO_AND, XSLFI_ROAD_VEH_TRANSPORT))`；**不用 vehicle_flags 高位** |
| `Vehicle`（RV 侧） | `VehicleID transported_by` | 宿主载体 **Front**（整列/整船/整机维度） | `SLE_CONDREF_X(Vehicle, transported_by, REF_VEHICLE, …, 同一测试)` + Ptrs 回填；`VehicleID::Invalid()`=未收运 |
| `Vehicle`（RV 侧） | `VehicleID transported_host_part` | 宿主**节**（车厢/船节/主机）→ 满足"节级可追溯"：落地/容量归还按此节；一节装哪些 RV = 过滤 `transported_host_part==该节` | 同上（REF_VEHICLE） |
| `Vehicle`（RV 侧） | `uint16_t transported_weight` | 该 RV 占用宿主节的吨数（1 吨单位；装载瞬间快照 = 整备重 [+可选含货]） | `SLE_CONDVAR_X(…, SLE_UINT16, …)` |
| `Vehicle`（RV 侧） | `uint32_t transport_wait_tick` | 进入"等待被运载"的时刻（FIFO 排序、"未卸/未装 N 天"告警） | `SLE_CONDVAR_X(…, SLE_UINT32, …)` |
| `Vehicle`（载体 Front/节，NOSAVE） | `transported_weight_cache`（Front 汇总）、每节用量缓存 | 反查得到的缓存，随 `GroundVehicle::CargoChanged`/MarkDirty 重算 | NOSAVE，载入后按需重建 |

**待运队列**：不加 Station 字段——"站内等待被运载的 RV" = 过滤车辆池中 `rv_transport_flags.WaitingToBeTransported == true && last_station_visited == st->index` 的 RV，按 `transport_wait_tick` 排序即 FIFO；站销毁/车辆离开队列时按状态位注销。

**RV 侧状态位实现选择**：给 `Vehicle` 增加**XSLF 门控的独立字节** `rv_transport_flags`，而不是占 `subtype` 的 bit7（0.73.1 基线 bit7 空闲，但 decouple/pulsexlb 各自占用了 GVSF bit 7 用于 front-wagon 类角色，为将来合并留余量）。

### 3.2 AfterLoad 迁移与验证

- `AfterLoadVehiclesPhase1`（sl/vehicle_sl.cpp:285 区）追加：若 `SlXvIsFeatureMissing(XSLFI_ROAD_VEH_TRANSPORT)` → 全池清 `rv_transport_flags/transported_by/transported_host_part/transported_weight/transport_wait_tick`（旧档无此数据）；若 Present → 校验：`Transported` 的 RV 必须（a）`transported_by` 与 `transported_host_part` 有效且同属一条链（宿主节能解析到宿主 Front）；（b）不在任何 tile 哈希；（c）不在任何 Station 的 `loading_vehicles`。不一致=按"落地失败→滞留宿主"修复并记 debug 日志（DEBUG(misc, 1)）。
- `WaitingToBeTransported` 但所在站已无效/无匹配路站 → 清位并恢复正常行驶（避免死锁）。
- 回归三连（每档变更都跑）：① 0.73.1 旧档读入（新字段取默认、无崩溃）；② fork 自存自读一致；③ "收运中存档→读→再落地"往返（覆盖 vehicle_sl.cpp:299 式链一致性检查路径）。

---

## 4. M2 订单与状态机（对应 P2；核心，最小可玩闭环在此收口）

### 4.1 载体侧："站订单开关 + 参数块（OrderExtraInfo）"（2026-09-10 评审处置 #4 定稿，取代原"参数行/元订单"方案）

- 给 `OT_GOTO_STATION` 订单加"装载/卸载道路载具"开关（新 `ModifyOrderFlags`，参照 MOF_RV_TRAVEL_DIR 的既有加旗标套路）。
- 打开开关后，**参数直接挂在该站订单本体上**：`OrderExtraInfo`（懒分配）里新增一个"RV 运载参数块"结构，字段：`筛选条件集`（见 4.3）、`数量上限`、`是否空等`（与 full-load 旗标组合）、`目的地不匹配是否放行`、`下车方向`（复用 `SetRoadVehTravelDirection`，order_cmd.cpp:2711）。**不新增 OrderType、不插入任何"参数行/元订单"**——因此没有 ProcessOrders/AdvanceOrderIndex/删除级联那套特判；所有副作用只在装货循环（LoadUnloadVehicle 扩展分支）与 GUI 编辑里发生。载体进站时读到的正是该站订单副本（含 OrderExtraInfo），天然可取参数块。
- GUI：order_gui.cpp 的站订单详情行加开关 + 参数块展开编辑（条件编辑器复用条件订单控件）；英文/简中字符串按 STR_ORDER_* 命名新增。
- 归档：该参数块随订单序列化（OrderExtraInfo 的既有存档通道，XSLF 门控）。

### 4.2 RV 侧：等待被运载状态机

```
普通行驶 →(到"等待被运载"订单的站，停定在匹配公路停靠站格)
  → WaitingToBeTransported：注册进 Station 待运队列（记 dest=下一被卸载站）；
     → 该状态下不进行普通装卸（ProcessOrders/BeginLoading 特判，参照 WAIT_COUPLE 防误装卸先例）
  →(载体装载扫描命中，原子收运：清出队列/释放 bay·Entry 记账)
  → Transported：置 transported_flags.Transported + transported_by=载体Front；
     退出 tile 哈希、Hidden+Stopped、不 tick/不绘制/不计成本/不进列表（M4 清单）
  →(载体到卸货站、格位就绪，原子放车)
  → 落地：清位、重挂 tile 哈希、恢复运行；从其排程"被卸载"订单之后继续
```
- RV 订单表示：新增订单行/旗标"等待被运载"，可携带"目的地声明"（默认=下一被卸载站，显式可选）。RV 侧不承载筛选表达式（表达式归载体，见 4.3）。
- 状态串新增（照 pulsexlb "Waiting for locomotive" 风格）：`Waiting to be transported` / `Being transported` / `Waiting to unload`。

### 4.3 条件表达式筛选（评审定稿：复用条件订单体系，"不匹配即跳过"）

- **改造点 A（唯一必要的求值侧重构）**：把条件订单求值入口从"作用域=拥有订单的车辆"抽成显式入参形式，例如 `bool EvaluateVehicleCondition(const Order& cond, const Vehicle* subject, …)`；对既有条件订单调用传原车，行为不变（零影响）。位置：order_cmd.cpp 的条件求值 switch 一带。
- **改造点 B**：注册 RV 侧新变量到 `OrderConditionVariable`（追加枚举值，带 versioning 注释）：候选 RV 的卸车目标站、Bus/Truck、极速、长度、载货率、是否铰接、引擎 ID、组 ID。取值函数以 subject 为候选 RV 计算。
- **改造点 C**：载体站订单参数块（§4.1）存"条件集"（≥0 子句；子句=变量+比较器+值；多子句=AND；0 子句=不过滤）。默认新建时**自动插入一条预设子句**：`候选RV.卸车目标站 == 本载体订单本次到站之后的下一个停靠站`（作为普通可删子句，勿写死为引擎规则）。
- **装载扫描语义（挂在 LoadUnloadVehicle 扩展分支）**：载体 OT_LOADING 期间，若当前站订单参数块要求装 RV 且该节可装（4.4）：对站待运队列按 FIFO 逐台求值 → 命中则走收运事务（容量/重量校验见 4.4），不命中则跳过留队；0 命中且不允许空等 → 按普通满载语义离站。扫描与普通货装卸同 tick 节拍，FIFO 纪律不破坏。
- slot 相关：`SlotOccupancy/VehicleInSlot/VehicleInSlotGroup` 直接作为变量使用（读共享槽状态，不随作用域变）；`OT_SLOT` TryAcquire/Release 的领/放仍由**拥有订单的车**执行——"预约班次"组合用法（载体先 TryAcquire 槽、表达式用槽状态筛选）留到 P3 验证清单再实测，本期 GUI 只做基础筛选。

### 4.4 容量/重量校验（收运事务的前置判定，逐节）

- 装载门：该节当前 `IsCargoInClass(cargo_type, CargoClass::Oversized)`。
- 节运载吨容量 = `cargo_cap × CargoSpec::Get(cargo_type)->weight / 16`；RV 占用吨 = 整备重（`GetWeight()` 不含货）+（可选开关：+自身载货重）。
- 校验：`sum(transported_units_used) + 本RV占用 ≤ 节吨容量`；不满足→拒装（新闻串提示），RV 留队。
- 铰接 RV 整组按一个候选判定与收运（原子）；一节装不下整组就不装。
- 落地归还容量/重量；同节剩余吨容量**不得**再装普通货（节内不混装），其余节正常装普通货。

### 4.5 最小可玩闭环（本里程碑验收）

测试地图：一站同时含铁路站台+公路停靠站（直通式）A/B。场景：RV(带货) 从 A 站路站排队 → 火车到 A 有"装载 RV"参数块（默认目的站匹配）→ RV 消失并计入火车（运载面板可见）→ 火车到 B → RV 落地恢复行驶 → 后续订单继续。**联机 2 端 sync test 1 小时**。收/放画面仅默认装卸动画。

---

## 5. M3 站队列、匹配表达式接入与重量（对应 P3）

- 队列注册/注销点：RV 进入 WaitingToBeTransported（注册）与收运/玩家手动取消（注销）；落地不经过队列。
- 装载扫描与条件求值挂接：`LoadUnloadVehicle` 扩展分支内（见 4.3/4.4），调用 `EvaluateVehicleCondition(subject=候选RV)`。
- 重量：`GroundVehicle<T,Type>::CargoChanged()`（ground_vehicle.cpp:103-145）逐节循环内、`current_weight = u->GetCargoWeight()` 之后加 `current_weight += u->GetTransportedWeight()`（读节缓存 transported_weight，收/放时置脏 → `MarkDirty`（train_cmd.cpp:4993 / roadveh_cmd.cpp:438）触发重算）。坡度阻力/质心/PowerChanged 自动联动。船/机无重量模型，只做容量与显示。
- GUI 数据：运载面板/站窗显示用的聚合（数量/总重/目的站）由 Front `transported_rvs` + 节缓存现算。
- 验收：5 RV × 3 载体（含"带筛选/不带筛选"两类订单）反复装卸 30 分钟无错乱；筛选不匹配的确认留队等后续班次；重量反映到列车动力（上坡极速）；货+RV 混列正常。**补测**：slot 变量作为子句时求值上下文正常、OT_SLOT 领/放时点不破坏扫描（本期只验证读取语义）。

---

## 6. M4 TRANSPORTED 生命周期与豁免点（对应 P4；风险最高，先行自测）

### 6.1 离图/回图事务

- 收运 = 对 RV Front 整链（铰接）：记现场快照（NOSAVE：原 tile/方向/last_station_visited/orders 游标）→ `UpdateVehicleTileHash(remove)`（vehicle.cpp:846，参照 :851 VIRTUAL 分支写法）→ 置 `Hidden|Stopped` + transport_state.Transported + transported_by → 从 `loading_vehicles`/站队列/`VehiclesOnTile` 语义中消失 → 失败则回滚（备份恢复）。
- 落地 = 逆向：格位分配器（见 6.3）→ 重挂哈希 → 清位/清 Hidden/恢复 Stopped=false → 校验成功后返回运行；失败保持 Transported，绝不半落地。
- 宿主被售/被毁/公司破产清盘时的清场规则（新增处理点，见 6.4）：先把被运 RV 作"强制落地到最近匹配站"，无匹配站/无空间则"按残值赔偿移除"（先在设置开关下实现"移除+赔款+新闻"，默认开）。

### 6.2 豁免点清单（对照 GVSF_VIRTUAL 排雷；逐点改并断言）

| 系统 | 文件（锚点函数） | 处理 |
|---|---|---|
| 经济/折旧/运行成本/利润 | economy.cpp（车辆遍历处 159/248/541 同款位置） | Transported 的 RV 跳过 |
| 公司统计/基建/网络报表 | infrastructure.cpp、network_server.cpp:1890 同款 | 跳过 |
| 车辆列表/车库/组/共享订单 | vehiclelist.cpp:149/178、vehiclelist.cpp:78（BuildDepotVehicleList 天然不中——无 tile）、group_cmd.cpp:142 | 跳过/天然排除 |
| 绘制/视口 | vehicle.cpp:423 IsDrawn（参照 VIRTUAL） | 不绘制 |
| 碰撞/灾难/新闻目标 | disaster_vehicle.cpp:592 同款 | 排除 |
| 自动替换/克隆/模板 | autoreplace_*、vehicle_cmd.cpp 克隆路径 | 排除 + "运载中不可操作"断言 |
| 卖出/拆除 | vehicle_cmd.cpp（SellVehicleFlags 同款加 VirtualOnly 式旗标） | 直接禁止：CmdSellVehicle 对 Transported 返回错误 |
| AI/脚本 | script/api（script_vehicle* 等） | 只读隐藏（查询返回"被运载中"，禁命令） |
| desync 校验 | cachecheck.cpp | 允许瞬时态（链头≠front 之类）或跳过 |
| 存档链完整性 | sl/vehicle_sl.cpp:299 同款 | Transported RV 不被当作普通链/图上车校验 |
| 基建共享计费/破产 | 同上经济遍历处 | 跳过 |

> 原则：与 GVSF_VIRTUAL 一致——"在池里但被所有常规系统豁免"，逐点改判定，不改既有行为。

### 6.3 落地格位分配器（卸载侧规则，优先级从高到低）

1. 目的站（RV dest）同 Station 的**直通式公路停靠站**：该方向 `Entry.length − Entry.occupied ≥ RV 整车长（铰接按 gcache.cached_total_length）` → 落格；
2. 港湾格（Bay0/Bay1 空闲 且 !entrance busy 且 RV 非铰接——铰接本身被 RoadStop::Enter 拒）→ 落格；
3. 都无 → RV 保持 Transported，随载体去下一兼容站重试；达到"未卸天数阈值"（设置）→ 新闻告警；
4. 目的站被拆/路线被改永不触达 → 见 4.2 兜底/6.1 清场。
落地瞬间需恢复的下车方向：取 RV 订单"下车方向"参数（默认随路站方向/其排程下一站方位）。

### 6.4 新增处理点（宿主生命周期联动）

- `~Vehicle`/`PreDestructor`（vehicle.cpp:1152/1241 区）：宿主（载体）销毁前，对被运 RV 执行 6.1 清场；
- 公司破产/清盘：遍历公司 Transported RV 走清场；
- 卖出命令、autoreplace 换代、克隆：均对"宿主含被运 RV"或"RV 处于 Transported"报错或先清场（按设置：auto 清场 on/off）。

### 6.5 验收

运载中 RV：崩溃/卖出/车库/替换/克隆/灾难均不可触碰；联机 2 端 1h sync test 无 desync；落地后统计、重量、顺序、货物完整恢复。

---

---

## 7. M5 GUI（对应 P5）

- **运载面板（跨车型统一）**：新增独立子窗口 `WindowClass::VehicleTransportedList`（window_type.h 追加值；window number=公司/VehicleID 语义自定），由 `VehicleViewWindow` 加按钮打开（vehicle_gui.cpp:3955 区；widget 定义 widgets/vehicle_widget.h）。内容：遍历 `Vehicle::IterateTypeFrontOnly` 过滤 `transport_state.Transported`，列"车型(引擎名×N)/总重/目的站/宿主载体/滞留天数/车内货物摘要"；点击单项开该车 `VehicleView`（只读）。不提供买/卖/改装/维护入口。
- **火车详情可选 tab**：`TrainDetailsWindowTabs`（vehicle_gui.h:26）追加 `TDW_TAB_TRANSPORTED`；改 `_nested_train_vehicle_details_widgets`（vehicle_gui.cpp:2985）、tab 切换（OnClick :3597 区）、`DrawTrainDetails`（train_gui.cpp:429）加分支。注意 static_assert（vehicle_gui.cpp:2954）把 tab widget 与枚举钉死，加值要同步。非火车不做 tab（其详情窗无 tab 条）。
- **站窗口**：待运队列显示（数量×目的站）放 station_gui.cpp（可加 tooltip/次要文本，避免大改布局）。
- **订单编辑器**：载体站订单行加"装载/卸载道路载具"开关（order_gui.cpp；MOF_* 追加，order_cmd.cpp）；条件编辑器复用条件订单控件组（变量下拉/比较器/值 + 预设按钮：目的站匹配/仅卡车/仅巴士/长度≤N…）；RV"等待被运载"行编辑（目的地声明可选）。
- **字符串**：`src/lang/english.txt` 新增（命名 STR_ORDER_/STR_VEHICLE_/STR_NEWS_ 前缀按窗口上下文；需要 4 车种×N 的用 `###length VEHICLE_TYPES` 组）；中文同步译（missing 回退英文）。新增状态串/新闻失败串：装载失败(超重/无空间/目的地不可达/表达式不匹配时无车可装)、未卸告警。
- 验收：运载面板数据与实体一致；订单开关+条件编辑闭环可用；人类评审 UI 走查。

## 8. M6 船/机打通（对应 P6；无动画工作）

- 船：多节船每节独立 Ship Vehicle、独立 `cargo_cap`（XSLFI_MULTI_CARGO_SHIPS + GRF multi_part_ships 门控；articulated_vehicles.cpp AddArticulatedParts）→ 逐节判定与收运；无重量物理（跳过 CargoChanged 分量，仅容量/显示）。
- 机：只有整机容量概念（mail 部件=第 2 个 Aircraft 部件、AIR_SHADOW，aircraft_cmd.cpp:293-378）；`cargo_type` 属 Passengers 时天然不可装（门不过）；货机 refit oversized 后可用；无重量物理。
- 收/放画面：全部走默认装卸动画（无自定义）；运载面板文本罗列跨 4 类一致。
- 验收：船/机各跑一遍 4.5 闭环；refit 到 oversized 前后装载门行为正确。

## 9. M7 设置/经济/NewGRF/脚本（对应 P7）

- 设置项（table/settings/game_settings.ini + settings_type.h 结构 + settings_compat.h 老档名映射）：
  - `roadveh_transport.enabled`（总开关，GameSetting）；
  - `roadveh_transport.count_transported_weight_with_cargo`（RV 自重是否含其载货，默认 true）；
  - `roadveh_transport.freeze_in_transit_cargo`（D12 口径，默认 A=完全冻结；预留 B/C 枚举位）；
  - `roadveh_transport.unload_warning_days`（未卸告警阈值，默认 30 天）；
  - `roadveh_transport.liquidation`（宿主清场策略：force-land / compensate-remove，默认 compensate-remove）。
- 经济：本期免费；只加统计字段（被运载公里数：按宿主累计移动 × 车上 RV 数计，随宿主里程钩子，见下）。收费运价=二期（需自建价目表，勿混入 CargoPayment）。
- D12 口径 C（时间+里程联动）若启用：在宿主移动/到站钩子处，把行进增量按比例写入被运 RV 各 cargo packet 的 travelled 并调用 AgeCargo——**本期不做**，仅留钩子注释。
- NewGRF：验证点 = 带 refit 容量回调（`CBID_VEHICLE_REFIT_CAPACITY`/`Engine::DetermineCapacity` engine.cpp:236）的车在收运瞬间容量换算走 `refit_cap` 正确；铰接 RV 收/放瞬间的 NewGRF 变量（var0x42 等）一致性——如需可在收运/落地前后调用 `InvalidateNewGRFCacheOfChain`+`RefreshTrainUserDefData`（pulsexlb 假想列套路），失败即回滚。
- AI/脚本：script API 对"被运载 RV"只读（返回状态），禁任何命令；站订单 RV 参数块对脚本可见性按只读最小化。

## 10. M8 回归与收尾（对应 P8）

回归矩阵（每条 = 可运行场景 + 预期）：

| 场景 | 预期 |
|---|---|
| 0.73.1 旧档读入 | 无崩溃，新字段默认 |
| fork 自读自档（含收运中） | 一致（M1 三回归） |
| gradual_loading / improved_load / 真实制动 与收运组合 | 节拍不冲突、重量正确 |
| 模板替换/自动替换/克隆碰到被运 RV 或宿主 | 被拒或先清场（M4） |
| Cargodist：RV 货物在途 | 不产生中间 flow（D12/§4.4 末节） |
| 铰接 RV / 多节船 / 货机 | 逐节判定正确 |
| 港湾 vs 直通混用、铰接卸车只走直通 | 格位分配器行为符合 M4.6.3 |
| 站台被拆/RV 滞留 | 告警 + 兜底（M4） |
| 条件表达式各比较器/预设/RV 新变量 | 求值正确、跳过语义稳定 |
| slot 子句读取 + OT_SLOT 领放时点 | 无死锁/无 desync（P3 补测） |

- 联机：2–4 端 + AI 对手 ≥2h；sync test；desync 修复后补跑全矩阵。
- 卫生：删调试桩（R3R 教训：fopen 逐 tick 写盘/硬编码地图坐标/TEMPORARY DIAGNOSTIC）；`english.txt`+`simplified_chinese.txt` 增量最小化；确认无死代码/孤立字符串。
- 收口：CHANGELOG 条目 + 发布说明；更新《规划》附 B 开放项与本节估算。

---

## 附录 A：实现顺序与依赖

M1 → M2 → M3 → M4 必须依序（各自收口即"最小可玩"增量）；M5 可与 M2-M3 并行起步（先订单开关 UI 后可单独交付）；M6 依赖 M2-M4 全绿；M7 依赖 M4/M5；M8 收尾。若做"试点校准"：取 M1(最小)+M2 的站订单参数块+4.5 闭环 = 一个可独立量测 token 的小试点。

## 附录 B：本文件来源与版本

- 依据：《规划》§1.3/§1.4/§4（决策与论证）、调研底稿 sa1–sa4（函数/行号锚点）、评审 v2 意见（默认动画/条件表达式/slot 维度/在途口径）。
- 定位铁律：所有"文件（函数）"引用在 0.73.1 实测；行号随版本漂移，实现时以函数名 grep 定位。
- 本规格不回答"为什么"，只回答"改什么/怎么验"；如实现 agent 发现与《规划》冲突，以《规划》决策表为准并回写本文件。

## 附录 C：外部评审处置记录（2026-09-10，优先级高于正文冲突处）

> 评审来源：`建议.txt`（16 问题 + 风险 A/B/C）。状态：✅定案（改设计）/ 🔧规格补丁 / ⭕约束消解 / ⛔不成立。

| # | 状态 | 处置 |
|---|---|---|
| 1 | ✅ | 落地记账改**节级**：每节持 `transported_slots{RV_front_id, 占用吨}`；Front `transported_rvs` 降为汇总缓存（顺序=装载序）；落地按节归还，删除"Front 表+节缓存"双写旧设计。 |
| 2 | ✅ | `StationRVItem` **只存 `rv_id`，不存 dest 快照**；dest/条件在扫描与显示时实时解析 RV 当前订单。 |
| 3 | 🔧 | SLXI 子块登记：`sl/extended_ver_sl.cpp` 表项（仿 `"VESR"` 行，extended_ver_sl.cpp:144 一带）+ `extended_ver_sl.h` 加 `XSLFI_ROAD_VEH_TRANSPORT` 枚举。 |
| 4 | ✅ | **弃用"元订单/参数行"（OT_LOAD_ROAD_VEHICLES=15）**：改为站订单 `OrderExtraInfo` 挂"装载 RV 参数块"（筛选条件集/数量上限/空等/下车方向）；无新 OrderType、无 ProcessOrders 特判；正文 §4.1 按此改。 |
| 5 | 🔧 | 不重构既有条件求值调用链；新增独立入口 `EvaluateConditionForRV(const Order&, const Vehicle* rv)`；"变量取值"抽成可按 subject 调用的最小函数；既有 switch 耦合低才顺手参数化。 |
| 6 | ✅ | **收运不消耗 slot**：slot 仅只读筛选（SlotOccupancy/VehicleInSlot 子句）；OT_SLOT 领/放属载体订单原语、与收运不相交；预约玩法二期。 |
| 7 | 🔧 | RV 占用吨 = `GetWeightWithoutCargo()`（roadveh.h:254-270，1/4t 换算）+ 可选开关加 `GetCargoWeight()`；修正正文"GetWeight() 不含货"笔误。 |
| 8 | ⭕ | D12 冻结口径 + "Transported 期间 cargo 加锁"→ 货物重量恒定，transported_weight 无需同步；口径 B/C 二期再议。 |
| 9 / 风险A | ✅ | **tick 内提交纪律（非命令事务）**：装卸本不经 DoCommand；收运同 tick"先全判定→按分配先行、纯赋值收尾提交→异常同 tick 逐个还原"，无跨 tick 可见中间态；运行时快照含站队列项/RV 哈希与状态/节占用表。 |
| 10 | 🔧 | 豁免点逐条给"一行伪代码 + 天然排除/显式跳过"：`BuildDepotVehicleList`（VehiclesOnTile）天然排除；公司全列表（vehiclelist.cpp:149 Iterate）须显式跳过（仿 GVSF_VIRTUAL）。 |
| 11 | 🔧 | 定案**无状态重试**：每到兼容站从头扫、判定天然防重复、失败零数据变更（不重算重量）；无"已尝试"标记。 |
| 12 | 🔧 | 运载面板 window number=CompanyID（每公司一扇）。 |
| 13 | 🔧 | 货机 refit oversized 后 mail 容量并入主舱 → 飞机按**整机单节判定**；与多节船逐节的差异=载体形态差异。 |
| 14 | ✅ | 清场默认 **force-land → 无处可落才 compensate-remove**（设置默认值修改）。 |
| 15 | 🔧 | 性能验收：500 台待运+20 节车单次装货扫描 ≤ 设定阈值；扫描仅在到站装卸节拍发生。 |
| 16 | 🔧 | 日志白名单：保留未卸告警/装载失败新闻/回滚警告（DEBUG misc 1 级）；删 fopen 写盘/逐 tick/硬编码坐标/TEMPORARY DIAGNOSTIC。 |
| 风险B | ✅ | 筛选求值**只读**，新变量清单禁副作用；OT_SLOT 领/放只由订单原语执行，扫描内绝不 TryAcquire。 |
| 风险C | ⛔ | XSLF 特征 XSCF_NULL 恒写 → 0.73.1 打开新档为优雅拒绝并提示（非崩溃）；只需发布说明 + 验证拒绝文案。 |

## 附录 D：实现进度与验证手册（截至 M2b，2026-09-10）

### D.1 工作副本与提交

| 项 | 值 |
|---|---|
| 开发副本 | `D:\CNS\ottd\OpenTTD-patches-rvtransport`（由 0.73.1 基线复制） |
| 分支 | `feature/road-veh-transport` |
| 提交 | `bf70a8b4da` M1 存档骨架 → `cdf4cef8e0` M2a 核心事务 → `780396da90` M2b 订单驱动装卸 |
| 纯基线副本（旧档生成器） | `D:\CNS\ottd\OpenTTD-patches-baseline`（未改动，已构建） |
| 构建方式 | MSYS2/MinGW64：`D:\msys64\mingw64\bin` 的 cmake+ninja+g++；`cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DOPTION_USE_ASSERTS=ON`，然后 `cmake --build build --target openttd` |

### D.2 ⚠ 命令行参数陷阱（曾导致验证假阳性）

**`-g <savegame>` = 加载存档；`-G <seed>` = 生成新地图。**（我们最初把两者搞反，使"旧档/自读自档"验证在对空地图做假阳性检查；现已修正并重验。）

### D.3 验证手册（全部自包含，不使用玩家存档）

| 脚本（`testrun\`） | 作用 | 期望输出 |
|---|---|---|
| `verify_oldsave.ps1` | 基线 exe 生成旧档 → fork 加载 | `step1: OK` / `step2: PASS (fork loads pristine 0.73.1 savegame)` |
| `m1_verify.ps1` | 自产地图生成→save→重新加载（自读自档）；Part A 若存在 `testrun\baseline.sav` 则顺带验证旧档 | `Part B: PASS (self save/load round-trip OK)` |
| `smoke_m2a.ps1` | 空地图加载 + 跑 `rvtransport` 命令 | `SMOKE: no crash detected` |
| `verify_intransit.ps1` | **收运中存档往返**：装载 → save → 重新加载 → 检查被运载状态是否保留 → 再落地 | `RESULT: PASS (carried state survives save/load, and unload still works)` |
| `verify_sim.ps1` | 在真实存档上跑"等待 → 站内扫描 → 装载"完整链路 | `sim: scan found=true attached=true carrying=1` |
| `verify_user_save.ps1` | 订单命令链验证（`rvtransport modify` load/unload/dest） | `modify: OK` |
| `run_selftest.ps1` | （**已停用**）批量用户存档跑 selftest——用户存档过大/带 NewGRF，不适用 | — |

### D.4 调试/验收命令 `rvtransport`

```
rvtransport                      # 帮助
rvtransport state <vehicle_id>   # 打印 RoRo 状态（flags/tile/hidden/宿主/重量）
rvtransport wait <vehicle_id> on|off
rvtransport orderflag <vehicle_id> load|unload   # 给当前订单与订单列表项打旗标
rvtransport attach <carrier_id> <rv_id> [force]
rvtransport detach <carrier_id> <station_id>
rvtransport selftest             # 自动收运→落地并判定 PASS/FAIL（需要地图上有车）
```

### D.5 进度与待办

- ✅ **M1**：XSLFI_ROAD_VEH_TRANSPORT + 5 个 Vehicle 字段 + XSLF 门控序列化；旧档兼容与自读自档已用真实档验证通过。
- ✅ **M2a**：`roadveh_transport.{h,cpp}` 收运/落地事务（Stopped+Hidden+哈希移除 / 路站格恢复）、容量-重量判定、调试命令。
- ✅ **M2b**：`LoadUnloadVehicle` 读订单参数块执行装/卸；RV 站订单带 `ORVTF_LOAD` 时进入等待态并跳过普通装卸。
- ✅ **M3a/M3b**：目的地匹配筛选（`ORVTF_MATCH_DEST`，"不匹配即跳过"）；订单类型白名单修复（"不能执行这个命令"根因）。
- ✅ **M4a**：被运载车辆从 tick 缓存/每日处理/经济/列表/组/基建统计/联机统计/灾难/绘制中豁免（仿 GVSF_VIRTUAL）。
- ✅ **M5a–d**：订单窗口入口（装货方式下拉三项）、按载具类型文案、订单行与按钮状态显示、状态串、启用装载时默认打开目的地匹配。
- ✅ **人工验收**：玩家实测确认"卡车自动等待 → 被装载 → 被卸下 → 继续执行调度"全流程正常。
- ✅ **M8（部分）**：**收运中存档往返 PASS**（状态/宿主/节号/重量完整保留，读档后仍可落地）；**旧档兼容重跑 PASS**；自读自档 PASS；链路仿真与订单命令链 PASS。
- 🔧 关键修复（都是实测暴露后定位）：`Order::AssignOrder()` 拷贝时丢弃 RoRo 旗标（车辆读到的是丢失后的当前订单）；装载时对非车头调用 `MarkDirty()` 触发 `CargoChanged()` 断言；订单类型白名单未允许新字段。
- ⏳ **待办**：载体"等待道路载具"语义（火车现在不为等车延迟发车）；铰接道路车辆上下车；载运清单 UI；船/机实机验证；联机 sync test；性能验收；调试命令在合并前剥离。

