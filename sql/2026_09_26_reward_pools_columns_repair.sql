-- ============================================================================
--  补列脚本：boss_activity_config_ext 的 6 奖池 + 职业过滤映射列
--  ⚠ 已被 2026_09_30_reward_pools_v2.sql 取代：奖池现在是 `boss_reward_pools` 表（数量任意 +
--    金币区间 + 软删除 + 位号不复用），扩展表的 reward_pool_N_* 列属上一版模型。
--    只有在需要复现上一版行为时才执行本文件。
--  场景：ext 表是旧版本创建的，缺列时报 Unknown column 'reward_pool_1_enabled' in 'field list'
--  库  ：boss.lua 的配置库（默认 ac_eluna；多区共用同一个库，**只需执行一次**）
--  幂等：已存在的列自动跳过，可反复执行
--  用法：mysql -h <host> -P <port> -u <user> -p <库名> < 本文件
--        例：mysql -h <host> -P <port> -u root -p ac_eluna < 本文件
--  执行后：游戏内 `.boss config reload`（或在 AGMP 面板点一次保存）让脚本重新读取
-- ============================================================================

-- ① 先看缺哪些列（返回 0 行 = 已齐，无需继续）
SELECT e.col AS missing_column
FROM (
             SELECT 'class_types_text' AS col
   UNION ALL SELECT 'class_reward_items_text'
   UNION ALL SELECT 'reward_pool_1_enabled'
   UNION ALL SELECT 'reward_pool_1_chance'
   UNION ALL SELECT 'reward_pool_1_winner_mode'
   UNION ALL SELECT 'reward_pool_1_winner_count'
   UNION ALL SELECT 'reward_pool_1_class_filter'
   UNION ALL SELECT 'reward_pool_1_items_text'
   UNION ALL SELECT 'reward_pool_2_enabled'
   UNION ALL SELECT 'reward_pool_2_chance'
   UNION ALL SELECT 'reward_pool_2_winner_mode'
   UNION ALL SELECT 'reward_pool_2_winner_count'
   UNION ALL SELECT 'reward_pool_2_class_filter'
   UNION ALL SELECT 'reward_pool_2_items_text'
   UNION ALL SELECT 'reward_pool_3_enabled'
   UNION ALL SELECT 'reward_pool_3_chance'
   UNION ALL SELECT 'reward_pool_3_winner_mode'
   UNION ALL SELECT 'reward_pool_3_winner_count'
   UNION ALL SELECT 'reward_pool_3_class_filter'
   UNION ALL SELECT 'reward_pool_3_items_text'
   UNION ALL SELECT 'reward_pool_4_enabled'
   UNION ALL SELECT 'reward_pool_4_chance'
   UNION ALL SELECT 'reward_pool_4_winner_mode'
   UNION ALL SELECT 'reward_pool_4_winner_count'
   UNION ALL SELECT 'reward_pool_4_class_filter'
   UNION ALL SELECT 'reward_pool_4_items_text'
   UNION ALL SELECT 'reward_pool_5_enabled'
   UNION ALL SELECT 'reward_pool_5_chance'
   UNION ALL SELECT 'reward_pool_5_winner_mode'
   UNION ALL SELECT 'reward_pool_5_winner_count'
   UNION ALL SELECT 'reward_pool_5_class_filter'
   UNION ALL SELECT 'reward_pool_5_items_text'
   UNION ALL SELECT 'reward_pool_6_enabled'
   UNION ALL SELECT 'reward_pool_6_chance'
   UNION ALL SELECT 'reward_pool_6_winner_mode'
   UNION ALL SELECT 'reward_pool_6_winner_count'
   UNION ALL SELECT 'reward_pool_6_class_filter'
   UNION ALL SELECT 'reward_pool_6_items_text'
) e
LEFT JOIN information_schema.COLUMNS c
       ON c.TABLE_SCHEMA = DATABASE()
      AND c.TABLE_NAME   = 'boss_activity_config_ext'
      AND c.COLUMN_NAME  = e.col
WHERE c.COLUMN_NAME IS NULL;

-- ② 一键补列（幂等）：把所有缺失列拼成一条 ALTER 执行；都已存在时输出 nothing to add
SET SESSION group_concat_max_len = 1000000;

SET @boss_missing_ddl = (
  SELECT CONCAT('ALTER TABLE `', DATABASE(), '`.`boss_activity_config_ext` ',
                GROUP_CONCAT(CONCAT('ADD COLUMN `', e.col, '` ', e.ddl) SEPARATOR ', '))
  FROM (
               SELECT 'class_types_text'         AS col, 'text NULL'                        AS ddl
     UNION ALL SELECT 'class_reward_items_text',       'text NULL'
     UNION ALL SELECT 'reward_pool_1_enabled',         'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_1_chance',          'int NOT NULL DEFAULT 100'
     UNION ALL SELECT 'reward_pool_1_winner_mode',     'varchar(8) NOT NULL DEFAULT ''all'''
     UNION ALL SELECT 'reward_pool_1_winner_count',    'int NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_1_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_1_items_text',      'text NULL'
     UNION ALL SELECT 'reward_pool_2_enabled',         'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_2_chance',          'int NOT NULL DEFAULT 100'
     UNION ALL SELECT 'reward_pool_2_winner_mode',     'varchar(8) NOT NULL DEFAULT ''count'''
     UNION ALL SELECT 'reward_pool_2_winner_count',    'int NOT NULL DEFAULT 3'
     UNION ALL SELECT 'reward_pool_2_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_2_items_text',      'text NULL'
     UNION ALL SELECT 'reward_pool_3_enabled',         'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_3_chance',          'int NOT NULL DEFAULT 10'
     UNION ALL SELECT 'reward_pool_3_winner_mode',     'varchar(8) NOT NULL DEFAULT ''count'''
     UNION ALL SELECT 'reward_pool_3_winner_count',    'int NOT NULL DEFAULT 3'
     UNION ALL SELECT 'reward_pool_3_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_3_items_text',      'text NULL'
     UNION ALL SELECT 'reward_pool_4_enabled',         'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_4_chance',          'int NOT NULL DEFAULT 15'
     UNION ALL SELECT 'reward_pool_4_winner_mode',     'varchar(8) NOT NULL DEFAULT ''count'''
     UNION ALL SELECT 'reward_pool_4_winner_count',    'int NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_4_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_4_items_text',      'text NULL'
     UNION ALL SELECT 'reward_pool_5_enabled',         'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_5_chance',          'int NOT NULL DEFAULT 60'
     UNION ALL SELECT 'reward_pool_5_winner_mode',     'varchar(8) NOT NULL DEFAULT ''count'''
     UNION ALL SELECT 'reward_pool_5_winner_count',    'int NOT NULL DEFAULT 3'
     UNION ALL SELECT 'reward_pool_5_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_5_items_text',      'text NULL'
     UNION ALL SELECT 'reward_pool_6_enabled',         'tinyint NOT NULL DEFAULT 0'
     UNION ALL SELECT 'reward_pool_6_chance',          'int NOT NULL DEFAULT 0'
     UNION ALL SELECT 'reward_pool_6_winner_mode',     'varchar(8) NOT NULL DEFAULT ''count'''
     UNION ALL SELECT 'reward_pool_6_winner_count',    'int NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_6_class_filter',    'tinyint NOT NULL DEFAULT 1'
     UNION ALL SELECT 'reward_pool_6_items_text',      'text NULL'
  ) e
  LEFT JOIN information_schema.COLUMNS c
         ON c.TABLE_SCHEMA = DATABASE()
        AND c.TABLE_NAME   = 'boss_activity_config_ext'
        AND c.COLUMN_NAME  = e.col
  WHERE c.COLUMN_NAME IS NULL
);

SET @boss_missing_ddl = IFNULL(@boss_missing_ddl, 'SELECT ''nothing to add''');

SELECT @boss_missing_ddl AS will_execute;

PREPARE boss_stmt FROM @boss_missing_ddl;
EXECUTE boss_stmt;
DEALLOCATE PREPARE boss_stmt;

-- ③ 校验：应返回 38
SELECT COUNT(*) AS reward_pool_and_class_columns
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME = 'boss_activity_config_ext'
  AND (COLUMN_NAME LIKE 'reward_pool%' OR COLUMN_NAME LIKE 'class_%');

-- ④ 手工兜底（② 无法执行时用；一条语句补齐 36 列，已存在的列请自行删掉对应行）
-- ALTER TABLE `boss_activity_config_ext`
--   ADD COLUMN `reward_pool_1_enabled` tinyint NOT NULL DEFAULT 1,
--   ADD COLUMN `reward_pool_1_chance` int NOT NULL DEFAULT 100,
--   ADD COLUMN `reward_pool_1_winner_mode` varchar(8) NOT NULL DEFAULT 'all',
--   ADD COLUMN `reward_pool_1_winner_count` int NOT NULL DEFAULT 1,
--   ADD COLUMN `reward_pool_1_class_filter` tinyint NOT NULL DEFAULT 1,
--   ADD COLUMN `reward_pool_1_items_text` text NULL,
--   ...（第 2–6 池同构，默认值见 ② 里的定义）
--   ADD COLUMN `class_reward_items_text` text NULL;
