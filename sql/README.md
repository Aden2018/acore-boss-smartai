# release/80 自定义 SQL

## 活动 Boss 脚本私有配置表（2026_09_24_activity_boss_config_ext.sql）

`boss.lua` 的喊话 / 战斗嘲讽 / 巡逻 / 小怪节奏 / 职业奖励 / 受管模板等配置都在
`ac_eluna.boss_activity_config_ext`（**不是** `boss_activity_config`：AGMP 保存主表时用
`REPLACE INTO` 重写整行，会把它不认识的列重置为默认值）。

- 正常情况下**不需要手工执行这个文件**：`boss.lua` 每次加载都会
  `CREATE TABLE IF NOT EXISTS`（列由脚本 §3 配置区的 `BOSS_CONFIG_SCHEMA_EXT` 生成），
  首次加载还会用 `INSERT IGNORE` 写入默认值。
- 该文件用于 DBA 预建表 / 账号无建表权限时代建 / 人工复核列定义；
  其 DDL 与脚本生成的建表语句逐列一致（列名、类型、默认值；物理列序以脚本运行时补列的结果为准）。
- 加配置项的正确做法：改 `boss.lua` §3 的描述表（并同步本文件与面板 `config/boss.php`，新列追加在末尾），不要只手改数据库。
- AGMP 面板的「扩展配置」Tab 可以直接编辑这张表（二级 Tab 按分组归集），
  写入用 `INSERT ... ON DUPLICATE KEY UPDATE`（只改提交的列，不会像主表那样被 `REPLACE INTO` 重置）。
- 查看当前生效值：`.boss config show` / `.boss config show <分组>`
  （26 个分组：identity basic ally yells taunts ai phase patrol minion skill skill_random
  respawn spawnpoints schedule helper reward recovery class_ai class_reward tier
  feel_skill feel_target enrage wipe announce marker）。
- 手感类参数（技能手感 / 目标选择 / 软狂暴 / 团灭判定 / 世界公告 / 点名预警）见
  `2026_10_01_play_feel_columns.sql`：键值型配置（`skill_condition_thresholds_text` /
  `target_score_weights_text` / `skill_disabled_spells_text` / `announce_texts_text`）
  每行一条 `键=值`，未写到的键回退脚本内的默认值。
- 奖池**不在这张表**：见下面的 `boss_reward_pools`。

## 活动 Boss 奖池表与跨重启恢复（2026_09_30）

| 脚本 | 用途 | 顺序要求 |
|---|---|---|
| `2026_09_30_reward_pools_v2.sql` | 建 `boss_reward_pools`（每区任意行数奖池）→ 按区补 6 个出厂池 → 把旧模型的金币区间迁到池 1 | **必须在**新版 `boss.lua` 加载前执行：旧金币列 `gold_min_copper` / `gold_max_copper` 会被脚本加载时 DROP |
| `2026_09_30_boss_recovery_columns.sql` | 运行态 3 列（`health_pct` / `spawn_point_index` / `last_health_sample_at`）+ 贡献表 2 列（`class_id`、`reward_pools_mask`）+ 扩展表 5 列（recovery 3 + reward 2） | 与上一步同批执行；两者都幂等 |
| `2026_09_30_reward_pools_ext_cleanup.sql` | 删掉扩展表里 36 个废弃的 `reward_pool_N_*` 列（只对跑过上一版奖池模型的库有意义） | **在上一步之后**执行；`boss_reward_pools` 为空时脚本会报错拒绝执行 |
| `2026_10_01_play_feel_columns.sql` | 扩展表新增 28 列（技能手感 6 / 目标选择 3 / 软狂暴 6 / 团灭 3 / 世界公告 4 / 点名预警 3 + taunts 三组喊话 3） | 与新版 `boss.lua` 同批；幂等，缺锚点列时退回追加到表尾 |

奖池位号契约：`pool_id = k` ↔ 贡献位图第 `k-1` 位（`reward_pools_mask` 有符号 INT，故上限 31）；
删除池走软删除（`deleted_at`），位号不复用。面板「奖池」页即这张表的 CRUD。

`tools/deploy-realm.ps1 -ApplyConfigSql <配置库>` 会按上表顺序导入前两个脚本并做命中数断言。

## 活动 Boss 难度档位（2026_09_23_activity_boss_tiers_190090_190093.sql）

新建 4 个**活动 Boss 专用模板**，供 AGMP 面板「Boss 活动管理 → 难度档位」切换。

不要改用副本 Boss（例如死亡矿井的「绿皮队长」entry 647）：647 自带 `AIName=SmartAI`
与 2 条 `smart_scripts`，会和 Eluna 脚本形成双 AI，面板的技能预设管不到它们。

| entry | 档位 | HealthModifier | DamageModifier | rank | 基准血量 H |
|---|---|---|---|---|---|
| 190090 | 入门 | 0.21 | 1.0 | 1 | 2,928 |
| 190091 | 标准 | 0.60 | 2.0 | 1 | 8,367 |
| 190092 | 困难 | 1.45 | 4.0 | 3 | 20,220 |
| 190093 | 团本 | 3.60 | 7.0 | 3 | 50,202 |

- 模板统一：等级 83 / `exp=2` / `AIName=''` / 无 `smart_scripts` / `lootid=0`（奖励由脚本发放）/ `CreatureImmunitiesId=-229`（Boss 级控制免疫）。
- 血量公式：`creature_classlevelstats(83, class=1).basehp2(=13945) × HealthModifier × _GetHealthMod(rank) × (boss_health_multiplier_scaled/100)`。
- **面板的「血量倍率」是全局旋钮**：改它会让 4 个档位等比缩放；实际血量因区而异，以面板「基础配置 → 血量倍率」为准（本文件的回读查询会按本区倍率算出来）。
- 想改某一档的强度：`UPDATE creature_template SET HealthModifier=..., DamageModifier=... WHERE entry=19009x;` 然后 `.reload creature_template`。
  参考量级：真实 WotLK 团本 Boss 的 HealthModifier 165–1250、DamageModifier 35–139。

### 部署步骤（新环境）

1. 导入本 SQL：
   ```powershell
   & "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 -u root -p `
       --default-character-set=utf8mb4 acore_world < .\2026_09_23_activity_boss_tiers_190090_190093.sql
   ```
   （SQL 末尾会把 `ac_eluna.boss_activity_config.boss_entry` 设为 190090；重复执行是幂等的。）
   **多区注意**：末尾那次配置切换写的是 80 区的库名 `ac_eluna`。把它用在别的区时，
   先把库名换成该区自己的库（例如 `<该区库>`），或者直接用
   `tools/deploy-realm.ps1 -ApplyTierSql <该区 world 库> -DbName <该区库>` —— 脚本会替你改写并导入。
2. 让核心重新读取模板（游戏内 GM 或 AGMP 面板控制台通道）：
   ```
   .reload creature_template
   ```
3. 让 Eluna 重新加载脚本：
   ```
   .reload ale
   ```
   然后 `.boss config reload` 让脚本按新 entry 重新注册事件与技能池。
4. 切换档位：AGMP →「Boss 活动管理」→ 难度档位下拉框 → 保存
   （面板写入 `boss_entry` 后会自动执行 `.boss config reload`）。
   **已在场的 Boss 会继续用旧模板**：重生或手动 `.boss clear` + `.boss spawn` 后生效。

GM 命令见项目根目录 `README.md` 的「命令」表。

## 技能内容扩充的配套喊话（2026_09_26）

技能池 / 连招链的**内容**在 `boss.lua`（随版本发布），但**喊话存在扩展表**，两者要配套上线：

| 脚本 | 用途 | 与什么配套 |
|---|---|---|
| `2026_09_26_skill_yells_rename.sql` | 把 22 个技能施放喊话的键名改成 Spell.dbc 官方名 | **必须**跟同名版本的 `boss.lua` 一起执行：`skillCastYells` 以技能名为键，只改脚本会让这 22 个技能静默不喊话（然后 `.reload ale`） |
| `2026_09_26_combo_yells_expansion.sql` | 给第一批扩充的 18 条连招补喊话 | 6 套预设的 `boss.lua` 版本；`.boss config reload` 即可 |
| `2026_09_26_combo_yells_new_presets.sql` | 给新增 4 套预设（奥术崩解/瘟疫蜂群/钢铁先锋/鲜血誓约）的 24 条连招补喊话 | 10 套预设的 `boss.lua` 版本；`.boss config reload` 即可 |

三个脚本都是**逐键幂等**（已存在就跳过，只追加缺失键，不动 GM 改过的文案），键名按**行首**锚定
（避免 `烈焰余烬=` 被 `余烬=` 子串误判）。多区部署时把脚本里的库名与 `state_key` 换成该区的
（`tools/deploy-realm.ps1` 只改写它自带的 tier SQL，不会自动改写这三个）。
