-- ============================================================================
--  2026_09_30 — 跨重启恢复 + 结算口径：运行态/贡献表/扩展配置的新列
-- ----------------------------------------------------------------------------
--  背景：停服或崩溃重启后，运行态里 status ∈ {spawned, engaged} 的那只 Boss 要能按
--        「原刷新点 + 原技能预设 + 原难度 + 血量百分比折算」重建（不做 save=true 静态刷怪）。
--        这需要把「重启前血量百分比」等运行信息落库；离线补发还需要把玩家职业记下来。
--
--  本脚本只加列（幂等，可重复执行），业务逻辑在 boss.lua 里：
--    1. `boss_activity_runtime`：health_pct / spawn_point_index / last_health_sample_at
--    2. `boss_activity_contributors`：class_id（离线补发按职业过滤奖品用）+ reward_pools_mask（奖池中奖位图）
--    3. `boss_activity_config_ext`：recovery 组 3 列 + reward 组 2 列
--       （新列插在 schedule 三列之前，与 boss.lua 的描述表列序一致）
--
--  用法（库名取自 DATABASE()，必须指定目标库）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 \
--        -u root -p --default-character-set=utf8mb4 <该区配置库> < 2026_09_30_boss_recovery_columns.sql
--
--  注：boss.lua 每次加载也会自举这些列（缺哪列补哪列），本文件是给 DBA 预建 / 人工复核用。
-- ============================================================================

SET @boss_db = DATABASE();
SET @boss_rows_before = 0;

DROP PROCEDURE IF EXISTS `boss_add_column_if_missing`;

DELIMITER $$

CREATE PROCEDURE `boss_add_column_if_missing`(IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_definition TEXT, IN p_after VARCHAR(64))
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
    ) THEN
        -- 锚点列可能根本不存在（老库缺列是常态）：不存在就退回"加到表尾"，不让补列失败
        IF p_after IS NOT NULL AND p_after <> '' AND NOT EXISTS (
            SELECT 1 FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND COLUMN_NAME = p_after
        ) THEN
            SET p_after = NULL;
        END IF;

        SET @boss_ddl = CONCAT('ALTER TABLE `', DATABASE(), '`.`', p_table, '` ADD COLUMN `', p_column, '` ', p_definition,
            IF(p_after IS NULL OR p_after = '', '', CONCAT(' AFTER `', p_after, '`')));
        PREPARE boss_stmt FROM @boss_ddl;
        EXECUTE boss_stmt;
        DEALLOCATE PREPARE boss_stmt;
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------------------------- 1. 运行态：跨重启折算依据
CALL boss_add_column_if_missing('boss_activity_runtime', 'health_pct', 'INT NOT NULL DEFAULT 100', 'schedule_next_change_at');
CALL boss_add_column_if_missing('boss_activity_runtime', 'spawn_point_index', 'INT NOT NULL DEFAULT -1', 'health_pct');
CALL boss_add_column_if_missing('boss_activity_runtime', 'last_health_sample_at', 'INT NOT NULL DEFAULT 0', 'spawn_point_index');

-- --------------------------------------------------------------------------- 2. 贡献快照：职业 + 奖池中奖位图
CALL boss_add_column_if_missing('boss_activity_contributors', 'class_id', 'TINYINT NOT NULL DEFAULT 0', 'account_id');
-- 位图：第 k-1 位 = 该玩家中过 pool_id=k 的池（有符号 INT，故位号上限 31）。
-- 脚本加载时也会自举这一列；DBA 预建（不启动 worldserver 就上线面板）时必须一起给，否则脚本的列契约自检会点名。
CALL boss_add_column_if_missing('boss_activity_contributors', 'reward_pools_mask', 'INT NOT NULL DEFAULT 0', 'guaranteed_reward');

-- --------------------------------------------------------------------------- 3. 扩展配置：recovery 组 + reward 组
-- 锚点用老库里一定存在的列（managed_tier_entries_text），不依赖 skill_random 两列（老库可能没有）
-- 先补上技能池随机的两列：面板「扩展配置」页一次 SELECT 全部 54 列，缺列会让整页读取失败，
-- 所以不能等"脚本加载时自举"——先补齐，面板与脚本谁先上线都不会坏。
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_preset_random_enabled', 'TINYINT NOT NULL DEFAULT 0', 'managed_tier_entries_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_preset_pool_text', 'VARCHAR(255) NOT NULL DEFAULT ''''', 'skill_preset_random_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'health_sample_interval_sec', 'INT NOT NULL DEFAULT 15', 'skill_preset_pool_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'recovery_min_health_pct', 'INT NOT NULL DEFAULT 5', 'health_sample_interval_sec');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'boss_recovered_yell',
    'VARCHAR(255) NOT NULL DEFAULT ''{BOSS_NAME} 卷土重来！（血量 {HEALTH_PCT}%）''', 'recovery_min_health_pct');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'last_hit_only_qualifies', 'TINYINT NOT NULL DEFAULT 0', 'boss_recovered_yell');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'offline_reward_delivery', 'TINYINT NOT NULL DEFAULT 1', 'last_hit_only_qualifies');

DROP PROCEDURE IF EXISTS `boss_add_column_if_missing`;

-- --------------------------------------------------------------------------- 4. 回读校验
SELECT 'runtime 新列（应为 3）' AS check_item, COUNT(*) AS found
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_runtime'
  AND COLUMN_NAME IN ('health_pct', 'spawn_point_index', 'last_health_sample_at')
UNION ALL
SELECT 'contributors 新列（应为 2）', COUNT(*)
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_contributors'
  AND COLUMN_NAME IN ('class_id', 'reward_pools_mask')
UNION ALL
SELECT 'ext 新列（应为 5）', COUNT(*)
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config_ext'
  AND COLUMN_NAME IN ('health_sample_interval_sec', 'recovery_min_health_pct', 'boss_recovered_yell',
                      'last_hit_only_qualifies', 'offline_reward_delivery');

SELECT `state_key`, `status`, `health_pct`, `spawn_point_index`, `last_health_sample_at`, `skill_preset`, `updated_at`
FROM `boss_activity_runtime` ORDER BY `state_key`;

SELECT `state_key`, `health_sample_interval_sec`, `recovery_min_health_pct`, `boss_recovered_yell`,
       `last_hit_only_qualifies`, `offline_reward_delivery`
FROM `boss_activity_config_ext` ORDER BY `state_key`;
