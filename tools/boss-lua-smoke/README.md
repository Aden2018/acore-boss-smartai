# boss.lua 离线冒烟测试

`smoke.lua` 用桩函数替换 Eluna/核心 API，把 `boss.lua` 加载进一个独立的 Lua 环境里跑一遍，不需要启动 worldserver。

> 多区部署请用 `tools/deploy-realm.ps1` 安装到各区（改写 §2 的 `BOSS_DB_NAME` / `BOSS_RUNTIME_KEY` / `BOSS_CONFIG_KEY` + 备份 + 语法检查），
> 它改写的就是本测试断言的那几行常量；断言里的 state_key 从**被测文件**里读，不写死 `current`。

## 为什么需要

`boss.lua` 有 7000+ 行，纯语法检查（`luac -p`）发现不了下面这类**运行时**缺陷：

- 名字在 `local` 声明之前被引用 → 被解析成全局变量 → 运行时是 `nil`；
- 调用了引擎里不存在的 API（例如 `GetCreatureByGUID`，mod-ale 从来没有这个函数）；
- `.boss` 子命令的返回没有 `[AGMP_OK]`/`[AGMP_ERROR]` 标记 → AGMP 面板的严格标记校验会误判成功/失败；
- 覆盖全局 `print`（会连带影响之后加载的所有 Eluna 脚本）。

启动一次 worldserver 校验要几分钟且需要干净的库；这个脚本秒级返回。

引擎使用的 Lua 版本是 **5.2**（`mod-ale/CMakeLists.txt`: `LUA_VERSION "lua52"`），请用同版本解释器运行以保证语义一致。

## 用法

```powershell
# 建议在一个没有 lua_scripts 子目录的工作目录下运行：
#   这样脚本打不开日志文件，日志会回到 stdout 并被本测试捕获（断言依赖这些日志行）
cd <acore-boss-smartai>\tools\boss-lua-smoke
& <lua.exe> smoke.lua "D:/AzerothCore/release/<realm>/lua_scripts/boss.lua"
# 退出码：0 = 全部通过，1 = 有断言失败，2 = 加载/运行期错误
```

`lua.exe` 取任意 Lua 5.1/5.2 解释器（本仓库用 Lua 5.2.4 验证）。

## 覆盖范围

575 条断言（输出里的 `[ ok ]` 行数，下表按主题归并执行）；`.boss config show` 报出的**配置**分组是 26 组。

| 断言组 | 内容 |
|---|---|
| 加载 | `EnsureBossSchema` / `LoadBossConfigFromDB` / `LoadBossRuntimeFromDB` / 事件注册全流程无运行期错误；加载期日志可被捕获 |
| 回归 | 全局 `print` 未被覆盖；`RegisterBossEventsFor*`、`activeBossInfo`、`IsManagedBossEntry` 不泄漏为全局（其它导出全局允许） |
| SQL | 主表与扩展表（`boss_activity_config_ext`）的引导写入；扩展表写入列数 = 描述表项数 + `state_key` + `updated_at`；配置表不再用 `REPLACE INTO`；启动时写入 runtime 引导行 |
| 表结构自举 | 老库缺列时按描述表逐列 `ALTER ... ADD COLUMN ... AFTER`（[phase] 12 + [schedule] 3 + [recovery]/[reward] 5 + 批 5 手感 28 + 运行态 3），补列必须发生在引导写入之前 |
| 列契约 | `information_schema` 的"存在的列名"逐行读法；运行态 / 奖池整行 SELECT 的**列顺序**与快照一致（错位会静默读成隔壁字段）；奖池 SELECT 的 state_key / `deleted_at = 0` / `ORDER BY sort_order, pool_id` |
| 配置 | 26 组分齐全、项数之和 = 描述表总数；喊话/嘲讽/AI 节奏/阶段阈值/巡逻/小怪/援军/职业/受管模板/技能池随机/**恢复**/**结算口径**/定时启停/**技能手感 / 目标选择 / 软狂暴 / 团灭判定 / 世界公告 / 点名预警**确实取自数据库（桩数据用与默认值不同的值）；数据库快照缺列会直接判失败 |
| 命令 | `help` / `pools` / `config reload` / `config show [分组]` / `preset list` / `preset <key>` / `preset random on\|off` / `preset pool <key,key>\|all` / `difficulty <key>` / `rebase` / `kill` / `clear` / `schedule` / `spawn` / `spawn force` / 未知子命令 的标记与语义 |
| 技能池随机 | 开启后连续 20 次生成**每次都落在池内**且会出现不同预设；关闭后固定用 GM 指定的那套；`preset random off` / `preset pool` 写回扩展表且 `.boss config show` 立即反映；非法 key 返回 `AGMP_ERROR` |
| 技能池 / 连招内容 | 按**变量名**从已注册回调的闭包链取 `SKILL_PRESET_LIBRARY` / `SKILL_DIFFICULTY_LIBRARY` / `ApplySkillPreset` / `ApplySkillDifficulty`（`debug.getupvalue`，没有命令能打印它们），对**全部**预设断言：连招里每个法术 ID 都在同一预设的池内、`phase` 非空且 ⊆`{1,2,3}` 并有法术落在其声明阶段的池里、1/2/3 三段都被覆盖、池与 `openingSkills` 条目自检、连招名跨预设全局唯一、每个预设至少 `MIN_COMBOS_PER_PRESET` 条；连招喊话对**文件内默认库**硬断言（另加载一份 `CharDBQuery→nil` 的副本）；4 档难度 × 全部预设走真实缩放函数后**现取**结果，断言冷却与概率落在设计区间且未被钳制 |
| 连招施放（离线驱动） | 假 Boss（`IsInCombat=true` / 90% 血 = 阶段 1）+ 假玩家驱动 `OnBossEnterCombat` → `SmartBossAI`：第 1 次只放开场技能；第 2 次的**施放序列与某条声明的连招完全一致**，并核对连招冷却/全局冷却/阶段声明/连招喊话；随机性用 `env.math` 固定，段末还原 |
| 定时启停 | 三个配置列进建表、引导写入与 runtime 写入；用**可控时钟**驱动每秒 tick：星期掩码不匹配不生成、进入时段补生成 + `schedule_open`、同一段内不重复生成（30 秒重试）、离开时段写 `schedule_close` 并把残留 `respawn_at` 收敛为 0、时段外 `.boss spawn` 被拒而 `spawn force` 放行 |
| 奖池（表驱动） | ext 表里**已无** 36 个 `reward_pool_N_*` 列（DDL + 引导写入都查）；旧奖励模型 13 列被 `DROP COLUMN` 且主表建表语句里不再出现；读不到 `boss_reward_pools` 时回退出厂默认（来源 `code` + 日志），读到行时来源 `db` |
| 奖池位号 → 位图 | `GetRewardPoolMask(pool_id) = 2^(pool_id-1)`：逐点核对 1/6/**7**/**31**/越界 → 0，最大位号的掩码 = `2^(BOSS_MAX_REWARD_POOLS-1)` |
| 奖池实发（离线驱动） | 桩结果集给出**乱序**的 7 个合法池（含 `pool_id` **7 / 31**）+ 3 个非法池（`0` / 越界 / 重复）：断言按 `sort_order` 排序、非法池被丢弃并点名告警、`.boss pools` 显示库里的行与位号；死亡结算里核对按职业过滤、关闭的池一件不发、空池跳过、`reward_pools_mask` 用 `2^(pool_id-1)`（含 bit 2^6 / 2^30）、`announce=0` 的池不进世界通告 |
| 金币 | `ModifyMoney` 无返回值，按 `GetCoinage()` 前后差判定：金币池（`gold_min/max`）真加到账（差值 = 5000 铜）；`0/0` 的池既不扣也不加（`ModifyMoney` 只被调用 1 次）也不报错；获奖提示带金额 |
| 离线补发（邮件） | 击杀时已下线的贡献者**不被丢弃**：按 GUID 走 `SendMail`（收件人/发件人 0/`MAIL_STATIONERY_DEFAULT(61)`/物品/金币逐项核对），在线者照常入包；`offline_reward_delivery = 0` 时既不寄也不报错，写"未开启离线补发"日志 |
| 结算韧性 | 中段（发奖）注入异常（`PickRewardPoolItemFor` 抛错）后：`reward_failed` + `reward_granted` + 贡献快照 + `respawn_scheduled` + 重生计时照常，状态清理干净到可以立刻再生成 |
| 口径回归 | 治疗不要求治疗者本人站位（只要求同 map + 同 `instance_id` 且被治疗者是参战者）；同 tick 内出勤/仇恨样本按玩家去重；巡逻脱缰中心用 `activeBossInfo.homeX/homeY`（不是会被 AI 每 tick 覆盖的 `x/y`）；打断预筛距离 = 打断池最远射程；`(min,max)` 写反时归一为 `[min,min]` 并告警 |
| 跨重启恢复 | 另加载一份 boss.lua，喂 `status='spawned'` / `health_pct=60` / `spawn_point_index=1` / `skill_preset=...` 的运行态行，跑**首个 tick**：重建成功（1 次 `PerformIngameSpawn`）、血量 = `floor(maxHealth × health_pct / 100)`、技能预设沿用停服前那套（不是配置默认）、写 `runtime_recovered` 并把 `health_pct` 落库、恢复喊话替换 `{HEALTH_PCT}`；负路径一：时段外 → 不重建 + `runtime_recovered_skipped` + 运行态复位 `idle`；负路径二：`boss_entry` 不在受管集合内 → `runtime_recovery_failed` + 复位 `idle` + 第二个 tick 不再写恢复事件 |
| 写库失败可见性 | `CharDBExecute` 抛错一次 → `BossSql.failures.count` +1、打印 `[配置]写库失败[...]`、`.boss config reload` 仍返回 `AGMP_OK` 且回执里带上失败次数；"语句执行成功但回读不到"同样计入失败；`.boss help` 报告失败状态 |
| 放行 / 副作用 / 事件 | 非 boss 命令返回 `true` 且不产生回复；`.boss clear` 写 `command_clear` 并复位 runtime；`PLAYER_EVENT_ON_HEAL(42/65)` 与受管 entry（含 ext 额外指定的档位）的 6 个 creature 事件全部注册 |
| 多区绑定 | 把 §2 的两个 key 改写后重新加载：事件写入、runtime 语句与**奖池查询**都必须带新的 key，启动日志报出新 key，共用库名不变，老库自动补 `state_key` 列与索引；任何一处写死 `'current'` 都会失败（默认 key 与被改写 key 两种跑法都必须 PASS） |
| 批 5 手感与机制 | 键值配置（`skill_condition_thresholds_text` / `target_score_weights_text` / `announce_texts_text`）逐键读取、没写到的键回退脚本默认；条件阈值与评分权重真的参与判定（阈值 5 时 4 个敌人不成立、5 个成立）；威胁因子开关前后评分变化；终选分差窗口（0 = 只取最高分、25% 窗口内两者都可能、分差 100 vs 50 时只取最高）；软狂暴按起算时间叠层、施放强化法术、移速 = 基准 × (1 + 每层% × 层数)、喊话取自库、层数不超上限；团灭判定（宽限期内不停手、到点后 `AttackStop` + `ClearThreatList` + 回血到库值 + 喊话、表里还有存活单位则计时清零）；点名预警（挂标记光环 + 喊话 + 暂不出手、延迟到点才施放原技能、出手后记账与清状态、非 victim 与关闭开关时不预警）；`skill_instant_cast` 决定 `CastSpell` 的触发式参数；条目启停把被禁用的 spellId 从技能池 / 开场技能 / 连招三处剔除且清空后恢复原样；主循环接入（软狂暴 / 团灭 / 预警结算 / 读条移动门控）与三处世界公告调用点做源码结构回归 |

## 已知缺口（离线测不到的 / 需要 boss.lua 侧决定的）

本测试不断言下面三件事为"通过"，而是打印 `[info]` 供人工裁决（改 boss.lua 后这些 `[info]` 会跟着变）：

- **贡献快照不写 `class_id`**：列在 DDL / 列契约自检 / 内存记录里都有，但 `boss_activity_contributors` 的 INSERT 列清单里没有它 → 落库恒为 0（同场次的离线补发用内存里的 `classId`，不受影响；用 DB 行回补职业过滤会失真）。
- **预备阶段异常不受保护**：`BuildClassItemIndex()` 在 `xpcall` **之外**调用，它抛错会直接中断 `OnBossDied` → 没有 `reward_granted`、没有快照、不排重生。
- **奖池表的"0 行结果集"分支不可达**：`ReadRewardPoolsFromQuery` 对非 nil 的 query 总会先读一次首行，所以 `#pools > 0` 恒成立；`boss_reward_pools` 存在但本区没有行时既不会播种出厂默认、也不会回落到 `code`，而是得到 0 个池（发不出奖）。只有"查询返回 nil（表不存在）"才走得到回落分支。
- 引擎侧无法离线复现的部分：`SendMail` / `ModifyMoney` / `PerformIngameSpawn` 的真实副作用、ALE 结果集"首行即可读"的实际时序、以及 `GetMaxHealth` 等模板数值。

## 配置一致性（重构时用的一次性工具，不在本目录）

判断配置落库重构是否改变行为用的是 `tmp` 里的一次性脚本：`snapshot.lua <boss.lua> <out.txt> [nodb|live] [row.txt]`
捕获 `bootstrap.*` 引导写入语句与 `after-preset.*` 回写，重构前后各跑一次再 diff（主表列必须逐字段一致）。

## ⚠ 安全警告：DDL 导出不要放进事务里重放

**不要把 `--dump-sql` 导出的 SQL 丢进「真实库 + `START TRANSACTION` / `ROLLBACK`」里校验。**

导出文件含 `CREATE DATABASE` / `CREATE TABLE` 这类 DDL，而 MySQL 的 **DDL 会隐式提交**，事务被提前结束，
后面的 `REPLACE INTO` / `INSERT` 就真的落库了（一次误操作覆盖过线上 `boss_activity_config` 的配置列）。

正确做法（二选一）：

1. 只用导出文件做**人工复核**（默认已过滤 DDL，只剩 INSERT/REPLACE/UPDATE/DELETE）；
2. 需要真跑语法校验时，建一个 **scratch 库**（`CREATE DATABASE boss_verify` + `CREATE TABLE ... LIKE`），
   把导出 SQL 里的库名替换成 `boss_verify` 再执行，最后 `DROP DATABASE boss_verify`。

## 说明

- 两张配置表的 SELECT 都返回一份**按列名给出**的快照：`boss_activity_config`（Boss 身份/属性/选人权重）
  与 `boss_activity_config_ext`（喊话/嘲讽/节奏/巡逻/小怪/职业/受管模板/技能池随机/[recovery]/[reward] 结算口径/定时启停）。
  ext 快照故意用与文件内默认值不同的值，用来断言「运行时确实以数据库为准」；快照缺少描述表里的任何一列都会直接判失败。
- 奖池**不是配置列**：`boss_reward_pools` 的桩结果集按 `pool_id/sort_order/.../deleted_at` 给出（`nil` = 查询返回 nil）。
  奖池实发/离线补发/结算韧性几段会临时改动这份结果集与职业映射（再 `.boss config reload`），段末还原桩函数。
- 假对象是用「表 + 改写 `type()`」冒充 userdata 的，`AddItem` 的记录就是断言用的"玩家背包"，
  `GetCoinage`/`ModifyMoney` 的记录就是断言用的"钱包"，`SendMail` 的记录就是断言用的"邮箱"。
- 抓日志的方式：boss.lua 把 `print` 重绑成了文件级 `BossLog`，而 `BossLog` 回落到它自己的上值 `basePrint`
  （= 加载那一刻的全局 `print`）。所以本测试在跑 chunk 之前把全局 `print` 换成录制器，撤掉之后再断言 `print == originalPrint`。
  因此**必须**在打不开 `lua_scripts/lua_logs/boss.log` 的目录下运行，否则日志进文件、断言拿不到。
- 技能池 / 连招的内容与施放两组断言用 `debug.getupvalue` **按变量名**从已注册回调的闭包链上取文件内 local
  （写死上值下标会在 boss.lua 改动后失效，所以一律按名字查）。
- runtime / events / contributors 的 SELECT 默认返回「无行」（走内存默认分支）；只取 `status` 的回读校验返回一行，
  用来模拟"写入已落地"。需要驱动恢复分支时，用另加载一份 boss.lua 的方式喂运行态整行。
- 桩环境里没有 `GetCreatureByGUID`：一旦脚本再引用它，会立刻以运行期错误暴露出来。
- 本脚本不写任何文件（会刻意避开 `lua_scripts/lua_logs/`），也不连数据库。
