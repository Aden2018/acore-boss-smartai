# Acore Boss SmartAI Lua（中文说明）

AzerothCore 3.3.5a 的 Eluna 活动 Boss 脚本：带运行时持久化、配置热加载、事件追踪与贡献快照。

## 功能

- 智能战斗 AI、多套技能池预设与技能节奏档位。
- **技能池随机**：开启后每次生成/重生从面板勾选的预设池里随机抽一套（面板「扩展配置 → 技能池随机」），见下。
- **6 个独立奖池**：开关 / 概率 / 获奖人数（全部有效参战或指定数量）/ 奖品物品列表各自独立配置，
  面板里奖品填物品ID、下方直接显示物品名；奖品按职业过滤，不会发出玩家用不了的装备（见「奖励：6 个独立奖池」）。
- **可切换的强度档位**，由专用 `creature_template` 承载（见下）。
- **定时启停**：按每天的时间段自动开始/结束活动 Boss（面板「扩展配置 → 定时启停」），见下。
- **配置全部落库**：脚本里只保留默认值，运行期以 `ac_eluna` 为准（见下「配置在哪里改」）。
- 运行时数据落在 `ac_eluna`：`boss_activity_runtime`、`boss_activity_config`、
  `boss_activity_config_ext`、`boss_activity_events`、`boss_activity_contributors`。
- 表结构由 Lua 自举与迁移（不需要 Web 端建表）。
- 活动 Boss 使用**专用模板**，不会与核心 `SmartAI` 形成双 AI。
- 命令：

| 命令 | 作用 |
|---|---|
| `.boss` / `.boss spawn` | 在配置刷新点生成 Boss（定时计划在时段外时会被拒绝） |
| `.boss spawn force` | 忽略定时计划强制生成一只（调试用） |
| `.boss schedule` | 查看定时启停计划、当前是否在时间段内、距下次切换多久 |
| `.boss kill` | 击杀当前活跃 Boss（走正常死亡与奖励流程） |
| `.boss clear`（别名 `.boss despawn`） | 直接移除活跃 Boss、不发奖励并复位运行时记录 |
| `.boss rebase` | 按模板重算基准血量再套用倍率（**仅脱战可用**） |
| `.boss config reload` | 从 `ac_eluna` 热加载配置（AGMP 保存后自动调用） |
| `.boss config show [分组]` | 查看当前生效的配置项（不带分组则列出 24 个分组） |
| `.boss preset list` / `.boss preset <key>` | 查看 / 切换技能池预设 |
| `.boss preset random on\|off` | 开关「每次刷新随机选一套技能预设」（与面板同一份 ext 配置） |
| `.boss preset pool <key,key>` / `pool all` | 设置随机池 / 清空随机池（清空 = 全部预设） |
| `.boss difficulty list` / `.boss difficulty <key>` | 查看 / 切换技能节奏档位 |
| `.boss help` | 帮助 |

## 配置在哪里改

`boss.lua` 只在文件顶部 §3「配置区」保留**出厂默认值**；数据库里已有该行时，
默认值不生效（引导写入用 `INSERT IGNORE`）。改配置按优先级：

1. **AGMP 面板** —— 「基础配置」Tab 改主表 `boss_activity_config` 的列（Boss 身份/属性/刷新点/技能池/选人权重）；
   「扩展配置」Tab 改 `boss_activity_config_ext`（喊话/嘲讽/AI 节奏/阶段阈值/巡逻/小怪/援军/职业/受管模板/技能池随机/**6 个奖池**/定时启停，
   内部再按二级 Tab 分组）。
2. **直接改数据库** —— `boss_activity_config`（面板共享列）与 `boss_activity_config_ext`（脚本私有列）都可以。
3. 改脚本 §3 的默认值 —— 只影响「数据库里还没有这一行」的全新部署。

改完执行 `.boss config reload`（面板保存会自动执行），或重启 worldserver。

### 两张配置表的分工

| 表 | 内容 | 谁写 |
|---|---|---|
| `boss_activity_config` | Boss 身份、等级/体型/血量倍率、光环、友方援军、刷新点、技能池、**选人权重/有效参战范围**（奖励物品在扩展表的 6 个奖池里） | AGMP 面板（`REPLACE INTO` 整行重写）+ Lua |
| `boss_activity_config_ext` | 喊话、战斗嘲讽（12 组文本）、AI 节奏、战斗阶段阈值、巡逻、小怪 AI、援军模板、**职业类型（AI 选目标用）**、职业过滤映射（奖池用）、受管模板、**技能池随机**、**6 个独立奖池**、**定时启停** | Lua 建表/引导 + AGMP 面板（`INSERT ... ON DUPLICATE KEY UPDATE` 只改提交的列） |

必须拆两张表：AGMP 保存主表时用 `REPLACE INTO` 重写整行，凡不在它列清单里的列都会被重置为建表
默认值，脚本私有配置放主表会被面板保存清掉；面板对 ext 表只做 upsert，所以脚本后续新增的列不会被
面板保存重置。**ext 表的列序必须与面板镜像一致**：新列一律追加到末尾，因为
`tools/verify_boss_ext_page.php` 会逐列比对面板与脚本描述表。

### 加一个配置项

1. 在 §3 配置区加默认值（或复用已有字段）；
2. 在 `BOSS_CONFIG_SCHEMA_MAIN`（面板共享列，需同时改 AGMP 与建表语句）或
   `BOSS_CONFIG_SCHEMA_EXT`（脚本私有列）里加一行：`group / column / kind / target / key`，ext 列还要给 `ddl`；
3. ext 表的建表语句、读、写、`.boss config show` 展示都会自动跟着变；如果要能在面板里编辑，
   再到 AGMP 的 `config/boss.php` 末尾补 `ext_fields`（列名/类型/边界）+ 中英文语言的字段名，
   `php tools/verify_boss_ext_page.php` 会逐列比对脚本与面板是否一致。

配置项的取值类型（`kind`）：`int` / `bool` / `scaled`（小数 ×100 存 INT）/ `text` /
`text_keep` / `intlist` / `lines` / `keyedlines` / `keyedword` / `keyedintlist` / `spawnpoints`。
（面板侧多两个：`schedule_windows` 每天时间段，保存前由 `Domain\Support\ScheduleWindows` 校验并归一化；
`preset_multi` 预设多选，落库仍是逗号分隔的 key 串。）

### 仍然写在脚本里的东西（不是配置项）

- 技能池预设 / 强度档位系数 / 打断法术池（§5 内容库）：属于「技能内容」（法术 ID、冷却、触发条件），随版本发布；
  可调的部分（选哪套预设、哪个档位、随机池里放哪些预设）已经落库。
- **10 套技能预设**（2026-09 由 6 套扩到 10 套）：原有 `storm_siege` 风暴攻城 / `ember_storm` 余烬风暴 /
  `frost_whiteout` 冰封压境 / `venom_pursuit` 毒猎追击 / `grave_bombard` 墓火轰炸 / `spellbreak_bulwark` 破法壁垒，
  新增 `arcane_cataclysm` 奥术崩解 / `plague_swarm` 瘟疫蜂群 / `iron_vanguard` 钢铁先锋 / `blood_covenant` 鲜血誓约。
  每个预设 = 3 个阶段的技能池 + **6 条连招链**（`comboChains`，2026-09 由每套 3 条扩到 6 条，共 **60 条**）+ 3 个开场技能。
  连招是「每条 3 个法术、按序施放、不再做目标条件判定」的固定小连击（`SkillAI:TryComboChain` + 施放循环），
  硬性不变量：**连招里用到的法术必须出现在该预设自己的技能池里**（冒烟测试强制），连招名全局唯一。
  新增 4 套预设后，面板「技能池随机」的勾选框会从 6 个变成 10 个（面板侧要同步 `config/boss.php` 的
  `preset_values` 与 `resources/lang/{zh_CN,en}/boss.php` 的 labels/summary，否则面板不认这几个 key）。
- 法术来源与校验：全部取自 WLK 团队副本。两轮扩充共补进 **53 条新法术**（法术 ID 37 → 66 → **99**，
  技能池条目 72 → 101 → **144**），每条的 `name` 都逐字取自客户端 `Spell.dbc` 的 enCN 名称槽位。
  校验工具：`tools/spell-check/spell-check.lua`（存在性 + 名称逐字比对）；团本来源证据取自
  AzerothCore 源码里各副本 Boss 脚本的 `SPELL_* = <id>` 枚举与真实 `CastSpell/DoCast` 调用点（最强证据），
  辅以 `spell_script_names`（有脚本者标"需注意"）。
  ⚠️ 两条容易踩坑的口径：**① `creature_template_spell` 里查不到 WLK 团本技能**（它们是核心硬编码），不能当依据；
  **② `spelldifficulty_dbc` 对 WLK 团本基本无效**（10/25 人变体是 C++ 里的 `_10N/_25N/_10H/_25H` 常量），
  而且 `SpellMgr::GetSpellIdForDifficulty` 在非副本/非战场地图会**直接返回原 spellId** ——
  所以野外 AI 直放时基础档 ID 就是最终效果，池里一律填基础档。
  历史遗留的 **22 个法术名已修正为 DBC 官方名**（例：`69055` 由「骨刃分劈」改为「军刀猛刺」、
  `72034` 由「白茫」改为「霜至」）。改名必须与 `sql/2026_09_26_skill_yells_rename.sql` **一起执行**：
  技能施放喊话 `skillCastYells` 与扩展表列 `taunt_skill_cast_yells_text` 都以**技能名为键**，
  只改脚本不改库会让这 22 个技能在线上静默不喊话；且改名后要 `.reload ale`（不是 `.boss config reload`）。
  该脚本按**行首**锚定键名（避免 `烈焰余烬=` 被 `余烬=` 子串误判），可重复执行。
  另：池子里有 3 条法术来自 **5 人本**（King Dred / 达克萨隆要塞、Slad'ran / 古达克、Krick&Ick / 萨隆矿坑），
  已在注释里如实标注；若要严格"只用团本技能"，需要替换成团本等价法术（属内容决策，非缺陷）。
- **施法方式（2026-09 改）**：`SkillAI:CastSkill` 现在走 `CastSpell(target, spellId, SKILL_CAST_TRIGGERED)`，
  该常量当前为 **`false` = 副本式读条**（按 Spell.dbc 的施法时间前摇，可被玩家打断）。配套两项：
  ① AI 每 tick 先查 `TargetSelector:IsCasting(creature)`，施法中不下发新指令（避免互相打断/丢技能）；
  ② 连招不再同一 tick 连发，而是排进 `state.pendingCasts`，由空闲 tick 逐发排空（否则核心会拒绝后两发）。
  池内约 1/3 的法术在 DBC 里 cast=0（瞬发），它们本来就没有前摇。想回到旧的瞬发手感：把该常量改成 `true`
  （打断法术池保持触发式瞬发，不受影响）。
- **半径上限约定**：技能池内所有法术的 `SpellRadius` 一律 ≤99yd —— 超过 99yd 在野外等价于"全地图 AoE"，
  而 **50000yd 是 SpellRadius.dbc 的"无限"占位**（副本内是团本范围，野外会打到整张地图）。
  2026-09 已把 11 条超限法术替换成同角色的团本替代品（含原有内容里的 `64386 惊骇尖啸`、`72034 霜至`
  这两条 50000yd）；新增法术时请用 `sp2.lua oneline <id>` 复核 `radius` 列。
  新增连招的喊话落库脚本：`sql/2026_09_26_combo_yells_expansion.sql`（第一批 18 条）与
  `sql/2026_09_26_combo_yells_new_presets.sql`（4 套新预设的 24 条）——喊话存在扩展表 `taunt_combo_yells_text`，
  **库里的值会整体覆盖脚本默认值**，所以只改脚本默认文案线上不会生效。
- 显示用文本（职业中文名等）、小怪召唤的散布半径、技能条件里的个别常量：属于逻辑常量，不是调参项。

## 奖励：6 个独立奖池

6 个结构相同、完全独立的奖池配置在 `boss_activity_config_ext`（AGMP 面板「扩展配置 → 奖池」），每池 6 个字段：

| 字段 | 说明 |
|---|---|
| `reward_pool_N_enabled` | 是否开启该奖池（关闭 = 完全不参与结算） |
| `reward_pool_N_chance` | 触发概率（%，每次击杀每个开启的奖池各掷一次） |
| `reward_pool_N_winner_mode` | `all` = 全部有效参战者都拿；`count` = 抽指定人数（按贡献加权或纯随机，见主表 `random_reward_mode`） |
| `reward_pool_N_winner_count` | `count` 模式的获奖人数（不会超过有效参战人数） |
| `reward_pool_N_class_filter` | 是否「只发该玩家能用的奖品」（默认开） |
| `reward_pool_N_items_text` | 奖品物品ID列表；每位获奖者从中随机抽 **1 件** |

结算流程（Boss 死亡时）：算出有效参战者 → 每个开启的奖池各掷一次概率 → 命中后按人数模式定获奖名单 →
每位获奖者从该池里随机抽 1 件**自己能用的**物品；同一轮里各池互不影响，中奖位图写进
`boss_activity_contributors.reward_pools_mask`（第 N 位 = 中过奖池 N），事件流水里也有 `reward_granted` 明细。

**按职业过滤（不会发不能用的装备）** —— `class_filter=1` 时，每件奖品的可用性判定：

1. 物品出现在「奖池 → 职业过滤映射」（`class_reward_items_text`，键=职业ID）里 → **以这份映射为准**：
   只有该职业的列表里有这件物品，才会发给他；
2. 不在映射里（坐骑 / 公式 / 通用物品）→ 问核心 `Player:CanUseItem`（职业/种族/等级限制）；
3. 核心没给结论（老版本/异常）→ 按"无限制"处理，避免整池发不出东西。

所以奖池里可以放心混放各职业的装备：战士只会拿到战士列表里的，法师只会拿到法师列表里的；
某位获奖者在该池里一件能用的都没有时，他这一池就跳过（日志会写明原因）。

出厂默认：池 1「保底」全员 100%（`40753`）、池 2「基础」3 人 100%、
池 3「公式」3 人 10%、池 4「坐骑」1 人 15%、池 5「职业」3 人 60%（27 件职业装备并集 + 按职业过滤）、池 6 关闭备用。

**升级已有部署**：跑一次 `sql/2026_09_26_reward_pools.sql`（幂等：补 6 个奖池的列 → 给已有行补上默认奖品 →
删掉旧奖励模型的 13 个列），再 `.reload ale` / 重启 worldserver；`boss.lua` 加载时也会自己做同样的补列/删列。

## 技能池随机

开启后**每次生成/重生都从随机池里抽一套预设**（同一只 Boss 打到死都用抽中的那套），而不是固定的 `skill_preset`。

配置在 `boss_activity_config_ext`（AGMP 面板「扩展配置 → 技能池随机」）：

| 列 | 默认 | 说明 |
|---|---|---|
| `skill_preset_random_enabled` | `0` | 是否每次刷新随机抽一套预设 |
| `skill_preset_pool_text` | `''` | 随机池：逗号分隔的预设 key（面板是勾选框）；**空 = 全部预设** |

行为约定：

- 抽签发生在**生成/重生前**（`.boss spawn`、定时启停补生成、GM 在当前位置生成、重生计时到点都算）；
  被拒绝的生成不会消耗抽签、也不会改掉当前预设。
- 池子里出现脚本不认识的 key 只记一行日志并忽略；池子为空/全非法 key = 用 `SKILL_PRESET_ORDER` 里的全部预设
  （不会因为"池子填错"变成不施放技能）。
- 关闭随机时固定使用主表 `boss_activity_config.skill_preset`；开启后它只是回退值。
- **面板保存不会换掉活跃 Boss 的技能池**：抽签只在下一次生成/重生时更新
  （`.boss preset <key>` 手动切换同样会被记住）。
- 用 `.boss preset list`（或面板「运行状态」卡片的技能预设）确认当前生效的是哪一套；
  运行态表 `boss_activity_runtime.skill_preset` 记录的就是活跃 Boss 实际使用的那套。

> **升级顺序**：这两列由 `boss.lua` 建表/补列。先更新 `boss.lua` 并让 worldserver 加载一次
> （`EnsureBossExtTableColumns` 会自动补列），再更新 AGMP 面板；反过来（面板先上）时扩展配置页会
> 一直提示读取/保存失败，直到 Lua 把列补上。

## 定时启停（每天的时间段）

让活动 Boss 只在设定的时间段里进行：**进入时间段自动生成一只，离开时间段停掉待重生计时**（默认还会清理当时活跃的 Boss）。

配置在 `boss_activity_config_ext`（AGMP 面板「扩展配置 → 定时启停」）：

| 列 | 默认 | 说明 |
|---|---|---|
| `activity_schedule_enabled` | `0` | 是否按时间段自动开关 |
| `activity_schedule_windows` | `''` | 时间段文本，语法见下 |
| `activity_schedule_clear_on_close` | `1` | 离开时间段时是否清理当前活跃 Boss（`0` = 只停新刷新，已生成的打到死为止） |

时间段写法（与 AGMP 的 `app/Domain/Support/ScheduleWindows.php` 完全一致，改一边必须改另一边）：

```
08:00-09:00                  每天 08:00-09:00
08:00-09:00; 20:00-22:00     多段用分号（段里没有 @ 时逗号也能分段）
1-5@20:00-23:00              周一至周五（1=周一 … 7=周日，也认 mon-fri 与 一/日）
6,7@10:00-12:00              周六、周日
22:00-02:00                  跨夜（到次日凌晨 2 点）
```

行为约定：

- **计划优先于手动开关**：计划启用且在时段外时，`.boss spawn` 会被拒绝并提示（`.boss spawn force` 可临时绕过，供调试）；
  时段内没有活跃 Boss 且没有待触发的重生计时，tick 会补生成一只（生成失败 30 秒后重试）。
- 启用但时间段为空/写错 = **永不自动开关**（不会因为"填错一次"就把线上 Boss 清空），非法片段只写一行日志并跳过。
- 被杀死的 Boss 仍按 `respawn_time_minutes` 重生；若重生时刻已落在时段外，本次不再排程，等下一个时间段。
- 用 `.boss schedule` 看计划与当前状态；运行态（`off/empty/open/closed`、命中段、下次切换时刻）会写进
  `boss_activity_runtime` 的 `schedule_state` / `schedule_window` / `schedule_next_change_at`，
  AGMP 的「运行状态」卡片直接显示脚本上报的状态。
- 计时用服务器本地时间（`os.date`），全天时间段与跨夜段都按**段开始那天**判断星期。

面板侧的时间段解析类 `Acme\Panel\Domain\Support\ScheduleWindows` 由聊天答题与活动 Boss 共用：
面板负责"保存前校验并归一化 + 给出人话的报错"，到点开关全部由 Lua 的 tick 执行。

## 难度档位

活动 Boss 使用 4 个等级 83 的专用模板（无 `AIName`、无 `smart_scripts`、无掉落）：

| entry | 档位 | HealthModifier | DamageModifier | rank | 血量（倍率 1500 时） |
|---|---|---|---|---|---|
| 190090 | 入门（与旧档同级） | 0.21 | 1.0 | 1 | 4,392,675 |
| 190091 | 标准（5 人） | 0.60 | 2.0 | 1 | 12,550,500 |
| 190092 | 困难（10 人） | 1.45 | 4.0 | 3 | 30,330,376 |
| 190093 | 团本（25 人） | 3.60 | 7.0 | 3 | 75,302,998 |

- 血量公式：`creature_classlevelstats(level=83, class=1).basehp2(=13945) × HealthModifier × (boss_health_multiplier_scaled / 100)`。
- 档位存在 `boss_activity_config.boss_entry`；AGMP 以「难度档位」下拉框呈现，并显示当前倍率下的预估血量。
- 面板的「血量倍率」是全局旋钮，改它会让所有档位等比缩放。
- 建档 SQL：`sql/2026_09_23_activity_boss_tiers_190090_190093.sql`（部署步骤见 `sql/README.md`）。

## 回归约束（冒烟测试守住的不变量）

- mod-ale/Eluna **没有** `GetCreatureByGUID()` —— 找回活跃 Boss 要用 `GetMapById()` + `GetUnitGUID(low, entry)` + `Map:GetWorldObject()`。
- `IsManagedBossEntry`、`DEFAULT_SPAWN_POINTS`、`activeBossInfo` 必须在文件顶部前置声明：在 `local` 声明之前引用会被解析成全局 `nil`。
- `rebase` / `config reload` 必须按模板重算基准血量（`Creature:UpdateEntry()`，**仅脱战**，它会清威胁表）；战斗中按倍率反推，绝不叠加。
- `Unit:SetLevel()` 只写等级字段、不重算生物属性，必须用等级 83 模板 + `exp=2` 才真正吃 WotLK 数值行。
- 贡献统计按 Boss guid 累积，只在击杀结算或 `.boss clear` 时释放。
- 配置光环按 guid 记录，热加载时做差量 `RemoveAura`。
- `print` 必须文件级 `local print = BossLog`：覆盖全局 `print` 会让之后加载的所有 Eluna 脚本都写进 `boss.log`。
- 日志 5MB 轮转到 `boss.log.<时间戳>.bak`；事件/贡献文本按列宽做 UTF-8 安全截断；刷新点为空要显式保护（`math.random(0)` 会报错）。
- 纯信息子命令（`.boss help`、`preset list`、`difficulty list`）首行必须走 `BossReply`，否则严格调用方看不到 `[AGMP_OK]` / `[AGMP_ERROR]` 标记。
- `bossRewardedGUIDs` 在死亡时清理。

## 不启动服务器也能测

`tools/boss-lua-smoke/smoke.lua` 把 `boss.lua` 加载进桩化的 Eluna 环境（不需要 `worldserver`），断言 219 项不变量：
加载流程、两张配置表的 SQL 构造、扩展表建表/写入列一致性、命令标记、`.boss config show` 输出、
「数据库值确实覆盖脚本默认值」、`.boss clear` 副作用、事件注册、定时启停、技能池随机、
**技能池 / 连招内容**（连招法术必须在本预设池内、连招名全局唯一、每个预设至少 6 条连招、
四档难度缩放后冷却与概率不撞 `ClampNumber(10,80)` 钳制、文件内默认库的连招喊话全覆盖）、
**连招施放（离线驱动）**（假 Boss + 假玩家驱动真实的 `TryComboChain` 与施放循环：触发 tick 只发第一发、其余进入
`state.pendingCasts` 队列，之后的空闲 tick 逐发排空，累计施放序列 == 某条连招；连招冷却按**触发时刻快照**核对）、
自身冷却与全局冷却写入、喊话内容 == 配置值）、
6 个独立奖池（含跑通整条 `OnBossDied` 实发流程）、多区绑定，以及上面那些回归。用法见 `tools/boss-lua-smoke/README.md`。

```
lua smoke.lua /path/to/boss.lua          # 退出码 0 = 全部通过
```

## 依赖

- AzerothCore 3.3.5a + Eluna（在 AzerothCore 使用的 Eluna 分支 `mod-ale` 上验证）。
- MySQL/MariaDB，且能访问 `characters` 库。
- 脚本放在 `lua_scripts` 加载路径下。
- 脚本通过 `CharDBQuery`/`CharDBExecute` 访问 `ac_eluna` 库；库名是 `boss.lua` 顶部的 `BOSS_DB_NAME` 常量，多区部署时每个区改成自己的库名（见下面「多区部署」），改完面板 `config/boss.php` 的 `server_overrides` 也要同步。

## 安装

1. 把 `boss.lua` 放进 Eluna 脚本目录。
2. （可选）用 `sql/2026_09_23_activity_boss_tiers_190090_190093.sql` 建专用模板，然后 `.reload creature_template`。
3. 重启 `worldserver`（或 `.reload ale`）。
4. 检查服务器日志中的建表/自举输出。
5. 检查本区绑定：`lua_scripts/lua_logs/boss.log` 里应有一行
   `[BOSS] 本区绑定: db=... configKey=... runtimeKey=...`。

## 多区部署（多个 realm 共用一套 auth）

一台机器上跑多个区时，**每个区各跑一份 worldserver + 一份 `boss.lua`**，但**共用同一个数据库**
（默认 `ac_eluna`），靠 `state_key` 把各区数据分租 —— **不需要为每个区建库**。四张表都按这个 key 区分：

| 表 | 分租方式 |
|---|---|
| `boss_activity_config` / `boss_activity_config_ext` / `boss_activity_runtime` | `state_key` 就是主键 |
| `boss_activity_events` / `boss_activity_contributors` | 有 `state_key` 列（老库由 `boss.lua` 自动补列 + 建索引） |

所以各区之间 `boss.lua` 的唯一差别是 §2 里的那**一个 key**（两行必须相同）：

```lua
local BOSS_DB_NAME = "ac_eluna"       -- 共用库，一般不动
local BOSS_RUNTIME_KEY = "current"    -- 本区 key：运行态/事件/贡献
local BOSS_CONFIG_KEY = "current"     -- 本区 key：配置表（必须与上一行相同）
```

| 区 | worldserver 目录 | key（两行相同） | 面板 `server_overrides[<索引>].runtime_key` |
|---|---|---|---|
| 主区（从单区升级上来的） | `D:\AzerothCore\release\<realm-a>` | `current`（保持不动 → 已有行仍归它，**零迁移**） | `current` |
| 第二个区 | `D:\AzerothCore\release\<realm-b>` | `<realm-b>` | `<realm-b>` |
| 第三个区 | … | `<realm-c>` | `<realm-c>` |

**两个区用同一个 key 就等于共用同一份配置/运行态/事件**，部署时务必给每个区一个不同的 key。

用 `tools/deploy-realm.ps1` 部署（自动改写 key + 备份原文件 + 语法检查 + 打印面板片段）：

```powershell
# 先干跑看改动
pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> -DryRun
# 真部署（顺带导入难度档位模板到该区的 world 库）
pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> `
    -LuaExe <lua.exe> -ApplyTierSql <该区 world 库> -DbPassword <pw>
```

新区的配置第一次加载时由 `boss.lua` 用该 key 写入一份默认值（`INSERT IGNORE`）；想让新区沿用
老区的活动配置，可导出老区那一行（`WHERE state_key = '<老区 key>'`）、把 key 改成新区的再导入。

## 独立运行（不接 Web）

脚本可独立运行：加载时 Lua 自举数据库与表、写入缺失的配置默认值，并且是运行时/事件/贡献记录的唯一写入方。
核心功能不依赖 AGMP/Web。

## 配合 AGMP 面板

### 职责划分

- Lua 负责建表/迁移与运行时持久化。
- AGMP 只读写数据并发送 SOAP 命令（含难度档位选择、击杀/重置按钮）。
- 表缺失时 AGMP 只提示，不建表。
- 控制台/SOAP 回复带 `[AGMP_OK]` / `[AGMP_ERROR]` 标记；AGMP 把「没有标记」判为失败，避免"命令根本没到游戏"被当成成功。

### 推荐流程

1. 先让 `boss.lua` 至少加载一次（完成建表）。
2. 打开 AGMP 的 Boss 页面。
3. 在网页里改配置（刷新点、难度档位等）。
4. 保存。
5. AGMP 自动执行 `.boss config reload`。

### 关键约定

- AGMP 的 Boss 模块指向 `ac_eluna`。
- 面板对两张表用的写法不同：`boss_activity_config` 用 `REPLACE INTO` 整行重写（列清单写死在
  `BossRepository`），`boss_activity_config_ext` 用 `INSERT ... ON DUPLICATE KEY UPDATE` 只改提交的列。
  因此：给主表加列必须同步改面板，否则会被面板保存重置；给 ext 表加列不会被面板影响，
  但必须追加在脚本描述表与面板 `ext_fields` 的末尾，列序要保持一致。
- `boss_activity_config` 必须含 `spawn_points_text` 列。
- SOAP 账号需要有执行 Boss 命令的权限。
- 面板「扩展配置」Tab 的字段与脚本描述表由 `php tools/verify_boss_ext_page.php` 逐列比对（含中英文文案）。

## 安全与运维

- 只给可信 GM/管理员开放这些命令。
- 大改数值前备份 `ac_eluna`。
- 脚本与 AGMP 模块版本保持同步。
- **不要**把含 `CREATE`/`ALTER` 的 SQL 导出放进「真实库 + `START TRANSACTION`/`ROLLBACK`」重放：MySQL 的 DDL 会隐式提交。请改用临时 scratch 库（见 `tools/boss-lua-smoke/README.md`）。

## 许可

MIT，见 `LICENSE`。
