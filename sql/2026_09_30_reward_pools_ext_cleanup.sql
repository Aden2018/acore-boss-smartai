-- ============================================================================
--  2026_09_30 — 奖励体系 v2 第 2 步：删掉 ext 表的 36 个旧奖池列
-- ----------------------------------------------------------------------------
--  只删「v1 的 6 组固定奖池列」（reward_pool_1..6 的 开关/概率/人数模式/人数/职业过滤/奖品）。
--  `skill_preset_random_enabled` / `skill_preset_pool_text` **保留**（属技能池随机，不是奖池）。
--
--  ⚠ 前置条件：必须先跑 `2026_09_30_reward_pools_v2.sql`，且 `boss_reward_pools`
--    已有行。本脚本自带守卫：不满足就直接报错退出，不会把配置删成一片空白。
--
--  用法（库名取自 DATABASE()，必须指定目标库）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 \
--        -u root -p --default-character-set=utf8mb4 <该区配置库> < 2026_09_30_reward_pools_ext_cleanup.sql
--
--  回滚：执行前对 `boss_activity_config_ext` 做整表备份（CREATE TABLE ..._bak LIKE + INSERT SELECT）。
--        本脚本只删列，无法自行还原；旧版 boss.lua 需要的列在脚本执行前必须已备份。
-- ============================================================================

SET @boss_db = DATABASE();
SET @boss_pool_rows = 0;

-- --------------------------------------------------------------------------- 0. 守卫
SET @boss_pool_rows = (
  SELECT COUNT(*) FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_reward_pools'
);

SET @boss_check_sql = IF(@boss_pool_rows = 0,
  'SELECT ''ERROR: boss_reward_pools 不存在，请先执行 2026_09_30_reward_pools_v2.sql'' AS stop',
  CONCAT('SELECT COUNT(*) INTO @boss_pool_rows FROM `', @boss_db, '`.`boss_reward_pools`'));
PREPARE boss_stmt FROM @boss_check_sql;
EXECUTE boss_stmt;
DEALLOCATE PREPARE boss_stmt;

-- MySQL 里没有「条件中止脚本」，用一条会产生错误的语句把脚本钉死在这里：
-- 池行数为 0 时 SELECT 一个不存在的列，执行者会看到明确的报错而不是"悄悄删完"。
SET @boss_guard_sql = IF(@boss_pool_rows > 0, 'DO 0',
  'SELECT `boss_reward_pools_is_empty_run_reward_pools_v2_first` FROM `boss_reward_pools_v2_required`');
PREPARE boss_stmt FROM @boss_guard_sql;
EXECUTE boss_stmt;
DEALLOCATE PREPARE boss_stmt;

-- --------------------------------------------------------------------------- 1. 工具过程
DROP PROCEDURE IF EXISTS `boss_drop_column_if_exists`;

DELIMITER $$

CREATE PROCEDURE `boss_drop_column_if_exists`(IN p_table VARCHAR(64), IN p_column VARCHAR(64))
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
    ) THEN
        SET @boss_ddl = CONCAT('ALTER TABLE `', DATABASE(), '`.`', p_table, '` DROP COLUMN `', p_column, '`');
        PREPARE boss_stmt FROM @boss_ddl;
        EXECUTE boss_stmt;
        DEALLOCATE PREPARE boss_stmt;
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------------------------- 2. 删列（36 个）
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_1_items_text');

CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_2_items_text');

CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_3_items_text');

CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_4_items_text');

CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_5_items_text');

CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_enabled');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_chance');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_winner_mode');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_winner_count');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_class_filter');
CALL boss_drop_column_if_exists('boss_activity_config_ext', 'reward_pool_6_items_text');

-- --------------------------------------------------------------------------- 3. 收尾与回读
DROP PROCEDURE IF EXISTS `boss_drop_column_if_exists`;

SELECT 'ext 表剩下的奖池列（应为 0）' AS check_item,
       COUNT(*) AS remaining
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config_ext'
  AND COLUMN_NAME LIKE 'reward_pool_%';

SELECT '技能池随机两列必须保留（应为 2）' AS check_item,
       COUNT(*) AS kept
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config_ext'
  AND COLUMN_NAME IN ('skill_preset_random_enabled', 'skill_preset_pool_text');

SELECT `state_key`, COUNT(*) AS pools FROM `boss_reward_pools` GROUP BY `state_key` ORDER BY `state_key`;
