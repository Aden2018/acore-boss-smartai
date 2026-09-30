-- ============================================================================
--  2026_09_30 — 奖励体系 v2 第 1 步：建 boss_reward_pools 并把 6 个奖池迁进去
-- ----------------------------------------------------------------------------
--  模型：奖池不再是「ext 表里 6 组固定列」，而是一张表里的行 —— 池数量任意、
--        每池独立配置（含金币区间），删除走软删除且 pool_id 不复用（历史位图可解释）。
--
--    主键 (state_key, pool_id)；pool_id 即 boss_activity_contributors.reward_pools_mask
--    的位号：pool_id = k ↔ 1 << (k-1)，上限 32 池。
--
--  本脚本做四件事（**幂等，可重复执行**）：
--    1. 建 `boss_reward_pools`；
--    2. 给每个已存在的 state_key 补 6 行出厂默认池（INSERT IGNORE，不覆盖已有行）；
--    3. 把旧模型的金币通道（主表 `gold_min_copper` / `gold_max_copper`）迁到池 1（全员奖）——
--       这两列会被新版 boss.lua 加载时 DROP，必须在这里先读走；
--    4. 若库里还留着 v1 的 `reward_pool_N_*` 列（例如曾加载过 v1 版 boss.lua），
--       则**按区读那 36 列的值**迁移，奖品为空时用出厂默认填。
--    5. 回读校验：每个区应恰好 6 行。
--
--  用法（库名取自 DATABASE()，所以必须在命令行指定目标库；不写死具体库名）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 \
--        -u root -p --default-character-set=utf8mb4 <该区配置库> < 2026_09_30_reward_pools_v2.sql
--
--  第 2 步（删 ext 表的 36 个旧列）是**独立文件**：2026_09_30_reward_pools_ext_cleanup.sql
--  先跑本文件并核对行数，再跑那一个。两步之间新版 boss.lua 也能正常工作。
-- ============================================================================

SET @boss_db = DATABASE();
SET @boss_rows_before = 0;
SET @boss_has_legacy = 0;

-- --------------------------------------------------------------------------- 1. 奖池表
CREATE TABLE IF NOT EXISTS `boss_reward_pools` (
  `state_key` VARCHAR(32) NOT NULL,
  `pool_id` SMALLINT UNSIGNED NOT NULL COMMENT '1-32；位号 = pool_id-1；创建后不复用',
  `sort_order` INT NOT NULL DEFAULT 0 COMMENT '发放与展示顺序（与 pool_id 解耦）',
  `name` VARCHAR(120) NOT NULL DEFAULT '' COMMENT '池展示名（日志/公告/面板）',
  `enabled` TINYINT NOT NULL DEFAULT 1,
  `chance` INT NOT NULL DEFAULT 100 COMMENT '整池掷一次的概率 0-100',
  `winner_mode` VARCHAR(8) NOT NULL DEFAULT 'count' COMMENT 'all=全部有效参战 / count=指定人数',
  `winner_count` INT NOT NULL DEFAULT 1,
  `class_filter` TINYINT NOT NULL DEFAULT 1 COMMENT '只发该玩家能用的奖品',
  `items_text` TEXT NULL COMMENT '奖品物品ID列表（逗号/空白分隔），每人随机 1 件',
  `gold_min_copper` INT NOT NULL DEFAULT 0 COMMENT '金币下限（铜）；与上限同为 0 = 不发金币',
  `gold_max_copper` INT NOT NULL DEFAULT 0,
  `announce` TINYINT NOT NULL DEFAULT 1 COMMENT '是否进世界通告',
  `deleted_at` INT NOT NULL DEFAULT 0 COMMENT '>0 视为已删除（软删除，位号保留）',
  `updated_at` INT NOT NULL DEFAULT 0,
  PRIMARY KEY (`state_key`, `pool_id`),
  KEY `idx_state_key_sort` (`state_key`, `sort_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------------------------- 2. 出厂默认池
-- 出厂默认 = boss.lua §3 的 REWARD_POOL_DEFAULTS（池 1-6 的语义与 v1 逐位一致：
-- 1 全员 / 2 基础 / 3 公式 / 4 坐骑 / 5 职业 / 6 备用）。
INSERT IGNORE INTO `boss_reward_pools`
  (`state_key`, `pool_id`, `sort_order`, `name`, `enabled`, `chance`, `winner_mode`, `winner_count`,
   `class_filter`, `items_text`, `gold_min_copper`, `gold_max_copper`, `announce`, `deleted_at`, `updated_at`)
SELECT `state_key`, 1, 10, '全员奖', 1, 100, 'all',   1, 1, '40753', 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`
UNION ALL SELECT `state_key`, 2, 20, '基础奖池', 1, 100, 'count', 3, 1, '38082,41600,51809,34067', 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`
UNION ALL SELECT `state_key`, 3, 30, '公式奖池', 1, 10,  'count', 3, 1, '45059,44491', 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`
UNION ALL SELECT `state_key`, 4, 40, '坐骑奖池', 1, 15,  'count', 1, 1,
  '32768,30480,13335,37719,49282,49290,19872,33977,33809,37828,43963,54068,33183,33189,35513,43964,19902,43963,46109,50250,49286,30609,54860,37012',
  0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`
UNION ALL SELECT `state_key`, 5, 50, '职业奖池', 1, 60,  'count', 3, 1,
  '40611,40614,40617,40620,40623,40256,40371,39257,40431,40257,40372,40622,40619,40616,40613,40610,40258,40382,39299,40624,40621,40618,40615,40612,40255,40373,40432',
  0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`
UNION ALL SELECT `state_key`, 6, 60, '备用奖池', 0, 0,   'count', 1, 1, '', 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config`;

-- --------------------------------------------------------------------------- 3. 旧模型的金币通道 → 池 1
-- 旧模型的金币在主表 `boss_activity_config`（gold_min_copper / gold_max_copper），属"保底"语义 →
-- 迁到池 1（全员奖，winner_mode=all）。这两个列在新版 boss.lua 加载时会被 DROP，所以**必须在这里
-- 先读走**；列已不存在（新版脚本先加载过）时跳过，池 1 保持默认 0/0（不发金币）。
SET @boss_has_legacy_gold = (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config'
    AND COLUMN_NAME = 'gold_min_copper'
);

SET @boss_gold_sql = IF(@boss_has_legacy_gold > 0,
  CONCAT('UPDATE `boss_reward_pools` p JOIN `boss_activity_config` c ON c.`state_key` = p.`state_key` ',
         'SET p.`gold_min_copper` = GREATEST(0, c.`gold_min_copper`), ',
         '    p.`gold_max_copper` = GREATEST(0, c.`gold_max_copper`), ',
         '    p.`updated_at` = UNIX_TIMESTAMP() WHERE p.`pool_id` = 1'),
  'DO 0');
PREPARE boss_stmt FROM @boss_gold_sql;
EXECUTE boss_stmt;
DEALLOCATE PREPARE boss_stmt;

-- --------------------------------------------------------------------------- 4. 从 v1 的 36 列迁移（仅在那些列还存在时执行）
SET @boss_has_legacy = (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config_ext'
    AND COLUMN_NAME = 'reward_pool_1_enabled'
);

SET @boss_legacy_sql = CONCAT(
  'INSERT IGNORE INTO `boss_reward_pools` ',
  '(`state_key`, `pool_id`, `sort_order`, `name`, `enabled`, `chance`, `winner_mode`, `winner_count`, ',
  ' `class_filter`, `items_text`, `gold_min_copper`, `gold_max_copper`, `announce`, `deleted_at`, `updated_at`) ',
  'SELECT `state_key`, 1, 10, ''全员奖'', `reward_pool_1_enabled`, `reward_pool_1_chance`, `reward_pool_1_winner_mode`, `reward_pool_1_winner_count`, ',
  '       `reward_pool_1_class_filter`, COALESCE(NULLIF(`reward_pool_1_items_text`, ''''), ''40753''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext` ',
  'UNION ALL SELECT `state_key`, 2, 20, ''基础奖池'', `reward_pool_2_enabled`, `reward_pool_2_chance`, `reward_pool_2_winner_mode`, `reward_pool_2_winner_count`, ',
  '       `reward_pool_2_class_filter`, COALESCE(NULLIF(`reward_pool_2_items_text`, ''''), ''38082,41600,51809,34067''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext` ',
  'UNION ALL SELECT `state_key`, 3, 30, ''公式奖池'', `reward_pool_3_enabled`, `reward_pool_3_chance`, `reward_pool_3_winner_mode`, `reward_pool_3_winner_count`, ',
  '       `reward_pool_3_class_filter`, COALESCE(NULLIF(`reward_pool_3_items_text`, ''''), ''45059,44491''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext` ',
  'UNION ALL SELECT `state_key`, 4, 40, ''坐骑奖池'', `reward_pool_4_enabled`, `reward_pool_4_chance`, `reward_pool_4_winner_mode`, `reward_pool_4_winner_count`, ',
  '       `reward_pool_4_class_filter`, COALESCE(NULLIF(`reward_pool_4_items_text`, ''''), ',
  '         ''32768,30480,13335,37719,49282,49290,19872,33977,33809,37828,43963,54068,33183,33189,35513,43964,19902,43963,46109,50250,49286,30609,54860,37012''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext` ',
  'UNION ALL SELECT `state_key`, 5, 50, ''职业奖池'', `reward_pool_5_enabled`, `reward_pool_5_chance`, `reward_pool_5_winner_mode`, `reward_pool_5_winner_count`, ',
  '       `reward_pool_5_class_filter`, COALESCE(NULLIF(`reward_pool_5_items_text`, ''''), ',
  '         ''40611,40614,40617,40620,40623,40256,40371,39257,40431,40257,40372,40622,40619,40616,40613,40610,40258,40382,39299,40624,40621,40618,40615,40612,40255,40373,40432''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext` ',
  'UNION ALL SELECT `state_key`, 6, 60, ''备用奖池'', `reward_pool_6_enabled`, `reward_pool_6_chance`, `reward_pool_6_winner_mode`, `reward_pool_6_winner_count`, ',
  '       `reward_pool_6_class_filter`, COALESCE(`reward_pool_6_items_text`, ''''), 0, 0, 1, 0, UNIX_TIMESTAMP() FROM `boss_activity_config_ext`;'
);

SET @boss_legacy_sql = IF(@boss_has_legacy > 0, @boss_legacy_sql, 'DO 0');
PREPARE boss_stmt FROM @boss_legacy_sql;
EXECUTE boss_stmt;
DEALLOCATE PREPARE boss_stmt;

-- --------------------------------------------------------------------------- 5. 回读校验
-- 期望：每个 state_key 恰好 6 行（v1 迁移过来的区可能更多，属正常，人工核对即可）。
SELECT 'boss_activity_config 里的区' AS source, COUNT(DISTINCT `state_key`) AS realms FROM `boss_activity_config`
UNION ALL SELECT 'boss_reward_pools 里的池行数', COUNT(*) FROM `boss_reward_pools`
UNION ALL SELECT 'v1 的 36 列是否还在（0=已是 v2）', @boss_has_legacy
UNION ALL SELECT '旧主表金币列是否还在（1=已迁到池 1）', @boss_has_legacy_gold;

SELECT `state_key`, COUNT(*) AS pools, SUM(`enabled`) AS enabled_pools, MAX(`pool_id`) AS max_pool_id,
       SUM(`gold_max_copper` > 0) AS gold_pools
FROM `boss_reward_pools` GROUP BY `state_key` ORDER BY `state_key`;

SELECT `state_key`, `pool_id`, `sort_order`, `name`, `enabled`, `chance`, `winner_mode`, `winner_count`,
       `class_filter`, CHAR_LENGTH(`items_text`) AS items_len, `gold_min_copper`, `gold_max_copper`, `announce`, `deleted_at`
FROM `boss_reward_pools` ORDER BY `state_key`, `sort_order`, `pool_id`;
