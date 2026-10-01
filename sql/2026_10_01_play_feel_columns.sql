-- ============================================================================
--  2026_10_01 — 批 5（趣味与智能增强）：扩展配置新增 28 列
-- ----------------------------------------------------------------------------
--  内容：技能手感 6 列、目标选择 3 列、软狂暴 6 列、团灭判定 3 列、世界公告 4 列、
--        点名预警 3 列，另加 taunts 分组的三组新喊话 3 列。全部追加在表尾，
--        与 boss.lua 的 BOSS_CONFIG_SCHEMA_EXT 列序、面板 config/boss.php 的 ext_fields 一致。
--
--  本脚本只加列（幂等，可重复执行），业务逻辑在 boss.lua 里；列不存在的库也能跑：
--  锚点列缺失时自动退回"加到表尾"。
--
--  用法（库名取自 DATABASE()，必须指定目标库）：
--    "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 \
--        -u root -p --default-character-set=utf8mb4 <该区配置库> < 2026_10_01_play_feel_columns.sql
--
--  注：boss.lua 每次加载也会自举这些列（缺哪列补哪列），本文件是给 DBA 预建 / 人工复核用。
-- ============================================================================

SET @boss_db = DATABASE();

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

-- --------------------------------------------------------------------------- 1. [feel_skill] 技能手感
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_instant_cast',
    'TINYINT NOT NULL DEFAULT 0', 'activity_schedule_clear_on_close');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'combo_trigger_chance_pct',
    'INT NOT NULL DEFAULT 100', 'skill_instant_cast');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'combo_global_cooldown_seconds',
    'INT NOT NULL DEFAULT 5', 'combo_trigger_chance_pct');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_pick_random_top',
    'INT NOT NULL DEFAULT 2', 'combo_global_cooldown_seconds');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_condition_thresholds_text',
    'TEXT NULL', 'skill_pick_random_top');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'skill_disabled_spells_text',
    'TEXT NULL', 'skill_condition_thresholds_text');

-- --------------------------------------------------------------------------- 2. [feel_target] 目标选择
CALL boss_add_column_if_missing('boss_activity_config_ext', 'target_random_spread_pct',
    'INT NOT NULL DEFAULT 25', 'skill_disabled_spells_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'threat_factor_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'target_random_spread_pct');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'target_score_weights_text',
    'TEXT NULL', 'threat_factor_enabled');

-- --------------------------------------------------------------------------- 3. [enrage] 软狂暴
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_enabled',
    'TINYINT NOT NULL DEFAULT 0', 'target_score_weights_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_seconds',
    'INT NOT NULL DEFAULT 300', 'soft_enrage_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_interval_seconds',
    'INT NOT NULL DEFAULT 30', 'soft_enrage_seconds');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_spell_id',
    'INT NOT NULL DEFAULT 8599', 'soft_enrage_interval_seconds');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_speed_pct_per_stack',
    'INT NOT NULL DEFAULT 5', 'soft_enrage_spell_id');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'soft_enrage_max_stacks',
    'INT NOT NULL DEFAULT 10', 'soft_enrage_speed_pct_per_stack');

-- --------------------------------------------------------------------------- 4. [wipe] 团灭判定
CALL boss_add_column_if_missing('boss_activity_config_ext', 'wipe_detect_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'soft_enrage_max_stacks');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'wipe_grace_seconds',
    'INT NOT NULL DEFAULT 12', 'wipe_detect_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'wipe_reset_health_pct',
    'INT NOT NULL DEFAULT 100', 'wipe_grace_seconds');

-- --------------------------------------------------------------------------- 5. [announce] 世界公告
CALL boss_add_column_if_missing('boss_activity_config_ext', 'announce_spawn_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'wipe_reset_health_pct');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'announce_phase_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'announce_spawn_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'announce_restore_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'announce_phase_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'announce_texts_text',
    'TEXT NULL', 'announce_restore_enabled');

-- --------------------------------------------------------------------------- 6. [marker] 点名预警
CALL boss_add_column_if_missing('boss_activity_config_ext', 'marker_warning_enabled',
    'TINYINT NOT NULL DEFAULT 1', 'announce_texts_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'marker_warning_delay_seconds',
    'INT NOT NULL DEFAULT 2', 'marker_warning_enabled');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'marker_warning_spell_id',
    'INT NOT NULL DEFAULT 0', 'marker_warning_delay_seconds');

-- --------------------------------------------------------------------------- 7. [taunts] 三组新喊话
CALL boss_add_column_if_missing('boss_activity_config_ext', 'taunt_soft_enrage_yells_text',
    'TEXT NULL', 'marker_warning_spell_id');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'taunt_wipe_yells_text',
    'TEXT NULL', 'taunt_soft_enrage_yells_text');
CALL boss_add_column_if_missing('boss_activity_config_ext', 'taunt_marker_warning_yells_text',
    'TEXT NULL', 'taunt_wipe_yells_text');

DROP PROCEDURE IF EXISTS `boss_add_column_if_missing`;

-- --------------------------------------------------------------------------- 8. 回读校验
SELECT 'ext 批 5 新列（应为 28）' AS check_item, COUNT(*) AS found
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @boss_db AND TABLE_NAME = 'boss_activity_config_ext'
  AND COLUMN_NAME IN (
    'skill_instant_cast', 'combo_trigger_chance_pct', 'combo_global_cooldown_seconds',
    'skill_pick_random_top', 'skill_condition_thresholds_text', 'skill_disabled_spells_text',
    'target_random_spread_pct', 'threat_factor_enabled', 'target_score_weights_text',
    'soft_enrage_enabled', 'soft_enrage_seconds', 'soft_enrage_interval_seconds',
    'soft_enrage_spell_id', 'soft_enrage_speed_pct_per_stack', 'soft_enrage_max_stacks',
    'wipe_detect_enabled', 'wipe_grace_seconds', 'wipe_reset_health_pct',
    'announce_spawn_enabled', 'announce_phase_enabled', 'announce_restore_enabled',
    'announce_texts_text',
    'marker_warning_enabled', 'marker_warning_delay_seconds', 'marker_warning_spell_id',
    'taunt_soft_enrage_yells_text', 'taunt_wipe_yells_text', 'taunt_marker_warning_yells_text');

SELECT `state_key`, `skill_instant_cast`, `combo_trigger_chance_pct`, `target_random_spread_pct`,
       `threat_factor_enabled`, `soft_enrage_enabled`, `soft_enrage_seconds`,
       `wipe_detect_enabled`, `wipe_grace_seconds`, `announce_phase_enabled`,
       `marker_warning_enabled`, `marker_warning_delay_seconds`
FROM `boss_activity_config_ext` ORDER BY `state_key`;
