-- ============================================================================
--  2026_09_26 — 活动 Boss 奖励改版：旧「保底/基础/公式/坐骑/职业 + 金币」→ 6 个独立奖池
-- ----------------------------------------------------------------------------
--  ⚠ 已被 2026_09_30_reward_pools_v2.sql 取代：奖池现在是 `boss_reward_pools` 表（数量任意 +
--    金币区间 + 软删除 + 位号不复用），扩展表的 reward_pool_N_* 列属上一版模型。
--    只有在需要复现上一版行为时才执行本文件。
--  模型：每个奖池 = 开启 / 触发概率(%) / 获奖人数模式(all=全部有效参战, count=指定数量) /
--        获奖人数 / 是否按职业过滤奖品 / 奖品物品ID列表（每人随机 1 件）。
--        Boss 死亡时每个已开启的奖池各掷一次概率；命中后按人数模式挑人，
--        每位获奖者只拿"自己能用"的奖品（class_reward_items_text 映射 + 核心 CanUseItem）。
--
--  这张脚本做三件事（**幂等，可以重复执行**）：
--    1. 给 `boss_activity_config_ext` 补 6 个奖池 × 6 列（boss.lua 加载时也会自动补列，本步是给
--       DBA 预建 / 不想等服务器重启的场景用）；
--    2. 给已存在的行补上奖池奖品列表（只在为空时写入出厂默认，不动 GM 已经调好的池子）；
--    3. 删掉旧奖励模型在主表 `boss_activity_config` 里留下的 13 个列（**连数据一起删**）。
--       boss.lua 加载时也会执行同样的删除；两者谁先跑都行。
--
--  用法（必须用 mysql 客户端，因为用到 DELIMITER / 存储过程）：
--    mysql -h <host> -P <port> -u root -p --default-character-set=utf8mb4 ac_eluna < 2026_09_26_reward_pools.sql
--  然后：游戏内 `.reload ale`（或重启 worldserver）→ `.boss config reload`
--
--  注意：旧模型里的「职业奖励池」映射（`class_reward_items_text`）**保留不删**：
--        奖池的「只发该玩家能用的奖品」用它作为"哪件装备归哪个职业"的权威判断。
-- ============================================================================

-- --------------------------------------------------------------------------- 0. 工具过程
DROP PROCEDURE IF EXISTS `boss_add_column_if_missing`;
DROP PROCEDURE IF EXISTS `boss_drop_column_if_exists`;

DELIMITER $$

CREATE PROCEDURE `boss_add_column_if_missing`(IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_definition TEXT)
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = 'ac_eluna' AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
    ) THEN
        SET @boss_ddl = CONCAT('ALTER TABLE `ac_eluna`.`', p_table, '` ADD COLUMN `', p_column, '` ', p_definition);
        PREPARE boss_stmt FROM @boss_ddl;
        EXECUTE boss_stmt;
        DEALLOCATE PREPARE boss_stmt;
    END IF;
END$$

CREATE PROCEDURE `boss_drop_column_if_exists`(IN p_table VARCHAR(64), IN p_column VARCHAR(64))
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = 'ac_eluna' AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
    ) THEN
        SET @boss_ddl = CONCAT('ALTER TABLE `ac_eluna`.`', p_table, '` DROP COLUMN `', p_column, '`');
        PREPARE boss_stmt FROM @boss_ddl;
        EXECUTE boss_stmt;
        DEALLOCATE PREPARE boss_stmt;
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------------------------- 1. 6 个奖池的列
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_enabled',     "TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_chance',      "INT NOT NULL DEFAULT 100");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'all'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_winner_count',"INT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_1_items_text',  "TEXT NULL");

CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_enabled',     "TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_chance',      "INT NOT NULL DEFAULT 100");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'count'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_winner_count',"INT NOT NULL DEFAULT 3");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_2_items_text',  "TEXT NULL");

CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_enabled',     "TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_chance',      "INT NOT NULL DEFAULT 10");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'count'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_winner_count',"INT NOT NULL DEFAULT 3");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_3_items_text',  "TEXT NULL");

CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_enabled',     "TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_chance',      "INT NOT NULL DEFAULT 15");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'count'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_winner_count',"INT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_4_items_text',  "TEXT NULL");

CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_enabled',     "TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_chance',      "INT NOT NULL DEFAULT 60");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'count'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_winner_count',"INT NOT NULL DEFAULT 3");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_5_items_text',  "TEXT NULL");

CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_enabled',     "TINYINT NOT NULL DEFAULT 0");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_chance',      "INT NOT NULL DEFAULT 0");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_winner_mode', "VARCHAR(8) NOT NULL DEFAULT 'count'");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_winner_count',"INT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_class_filter',"TINYINT NOT NULL DEFAULT 1");
CALL boss_add_column_if_missing('boss_activity_config_ext', 'reward_pool_6_items_text',  "TEXT NULL");

-- 贡献快照的中奖位图（第 N 位 = 中过奖池 N）
CALL boss_add_column_if_missing('boss_activity_contributors', 'reward_pools_mask', "INT NOT NULL DEFAULT 0");

-- --------------------------------------------------------------------------- 2. 给已有行补奖品列表
-- 只在奖品列表为空时写入出厂默认（= boss.lua §3 的 REWARD_POOLS），不覆盖 GM 已调好的池子。
UPDATE `ac_eluna`.`boss_activity_config_ext` SET
    `reward_pool_1_items_text` = COALESCE(NULLIF(`reward_pool_1_items_text`, ''), '40753'),
    `reward_pool_2_items_text` = COALESCE(NULLIF(`reward_pool_2_items_text`, ''), '38082,41600,51809,34067'),
    `reward_pool_3_items_text` = COALESCE(NULLIF(`reward_pool_3_items_text`, ''), '45059,44491'),
    `reward_pool_4_items_text` = COALESCE(NULLIF(`reward_pool_4_items_text`, ''),
        '32768,30480,13335,37719,49282,49290,19872,33977,33809,37828,43963,54068,33183,33189,35513,43964,19902,43963,46109,50250,49286,30609,54860,37012'),
    `reward_pool_5_items_text` = COALESCE(NULLIF(`reward_pool_5_items_text`, ''),
        '40611,40614,40617,40620,40623,40256,40371,39257,40431,40257,40372,40622,40619,40616,40613,40610,40258,40382,39299,40624,40621,40618,40615,40612,40255,40373,40432'),
    `reward_pool_6_items_text` = COALESCE(`reward_pool_6_items_text`, ''),
    `updated_at`               = UNIX_TIMESTAMP();

-- --------------------------------------------------------------------------- 3. 删除旧奖励模型的列
-- 旧模型：保底物品/基础池/公式池/坐骑池 + 三个概率 + 随机人数上限 + 金币上下限
CALL boss_drop_column_if_exists('boss_activity_config', 'guaranteed_reward_enabled');
CALL boss_drop_column_if_exists('boss_activity_config', 'guaranteed_reward_notify');
CALL boss_drop_column_if_exists('boss_activity_config', 'max_random_reward_players');
CALL boss_drop_column_if_exists('boss_activity_config', 'class_reward_chance');
CALL boss_drop_column_if_exists('boss_activity_config', 'formula_reward_chance');
CALL boss_drop_column_if_exists('boss_activity_config', 'mount_reward_chance');
CALL boss_drop_column_if_exists('boss_activity_config', 'guaranteed_item_id');
CALL boss_drop_column_if_exists('boss_activity_config', 'guaranteed_item_count');
CALL boss_drop_column_if_exists('boss_activity_config', 'gold_min_copper');
CALL boss_drop_column_if_exists('boss_activity_config', 'gold_max_copper');
CALL boss_drop_column_if_exists('boss_activity_config', 'reward_items_text');
CALL boss_drop_column_if_exists('boss_activity_config', 'reward_formulas_text');
CALL boss_drop_column_if_exists('boss_activity_config', 'reward_mounts_text');

-- --------------------------------------------------------------------------- 4. 收尾
DROP PROCEDURE IF EXISTS `boss_add_column_if_missing`;
DROP PROCEDURE IF EXISTS `boss_drop_column_if_exists`;

-- 回读校验：6 个奖池 + 主表剩下的奖励相关列
SELECT `state_key`,
       `reward_pool_1_enabled` AS p1_on, `reward_pool_1_chance` AS p1_pct, `reward_pool_1_winner_mode` AS p1_mode,
       `reward_pool_1_winner_count` AS p1_n, `reward_pool_1_class_filter` AS p1_class,
       CHAR_LENGTH(`reward_pool_1_items_text`) AS p1_items_len,
       `reward_pool_5_chance` AS p5_pct, CHAR_LENGTH(`reward_pool_5_items_text`) AS p5_items_len,
       `reward_pool_6_enabled` AS p6_on
FROM `ac_eluna`.`boss_activity_config_ext`;

SELECT `state_key`, `random_reward_mode`, `participation_range`, `damage_weight`, `healing_weight`,
       `threat_weight`, `presence_weight`, `kill_weight`
FROM `ac_eluna`.`boss_activity_config`;
