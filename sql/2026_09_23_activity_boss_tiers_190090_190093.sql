-- ============================================================================
--  活动 Boss 专用模板（AGMP「Boss 活动管理」→ 难度档位）
--  目标库：该区的 world 库（如 acore_world；多区时每个区一个）；
--          末尾另含一次配置切换：共用库 ac_eluna + 主区 key current。
--
--  ★ 多区：末尾 UPDATE 写死了 ac_eluna 与 state_key='current'。用在别的区时**必须**换成该区 key，
--    否则会改到主区配置。正确做法：tools/deploy-realm.ps1 -ApplyTierSql <该区 world 库> -RuntimeKey <该区 key>。
--
--  建立 4 个专用模板（无 AIName、无 smart_scripts、无掉落/金钱，等级 83 + exp=2），
--  强度只由 HealthModifier / DamageModifier 决定，避免复用 647 模板时与 Eluna 形成双 AI。
--
--  数值口径（改完 .reload creature_template 生效，无需重启）：
--    基准血量 H = creature_classlevelstats(level=83, class=1).basehp2(13945) × HealthModifier × _GetHealthMod(rank)
--    实际血量   = H × (boss_health_multiplier_scaled / 100)      ← 面板「血量倍率」是全局旋钮（各区可不同）
--    近战基伤   = creature_classlevelstats(level=83, class=1).damage_exp2(177.07) × DamageModifier
--    档位    entry    HealthModifier   基准H    DamageModifier  近战/击   rank  适用场景
--    入门    190090   0.21              2,928    1.0             ≈177      1     与现网同级，单人/小队可达
--    标准    190091   0.60              8,367    2.0             ≈354      1     5 人小队（80 级，约 10 分钟）
--    困难    190092   1.45             20,220    4.0             ≈708      3     10 人团
--    团本    190093   3.60             50,202    7.0             ≈1,239    3     25 人团 / 高压
--    改某一档：UPDATE 该 entry 的 HealthModifier / DamageModifier 后 .reload creature_template；
--    整体缩放改面板「血量倍率」。参考：WotLK 团本 Boss 的 HealthModifier 165–1250、DamageModifier 35–139。
--
--  用法："C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -h 127.0.0.1 -P 3306 -u root -p acore_world < 本文件
--        然后 .reload creature_template；面板「难度档位」选择并保存即写入 boss_activity_config.boss_entry。
-- ============================================================================

-- 结构骨架：以 entry 647 复制，避免手写 56 个列而漏字段
CREATE TEMPORARY TABLE IF NOT EXISTS `tmp_boss_tier` LIKE `creature_template`;

-- ---------------------------------------------------------------------------
DELETE FROM `tmp_boss_tier`;
INSERT INTO `tmp_boss_tier` SELECT * FROM `creature_template` WHERE `entry` = 647;
UPDATE `tmp_boss_tier` SET
    `entry`                  = 190090,
    `name`                   = '送财童子',
    `subname`                = '活动Boss·入门',
    `minlevel`               = 83,
    `maxlevel`               = 83,
    `exp`                    = 2,
    `rank`                   = 1,
    `HealthModifier`         = 0.21,
    `DamageModifier`         = 1.0,
    `ManaModifier`           = 1,
    `ArmorModifier`          = 1,
    `ExperienceModifier`     = 1,
    `AIName`                 = '',
    `ScriptName`             = '',
    `lootid`                 = 0,
    `pickpocketloot`         = 0,
    `skinloot`               = 0,
    `mingold`                = 0,
    `maxgold`                = 0,
    `KillCredit1`            = 0,
    `KillCredit2`            = 0,
    `flags_extra`            = 0,
    `RegenHealth`            = 1,
    `CreatureImmunitiesId`   = -229,
    `VerifiedBuild`          = 12340;
DELETE FROM `creature_template` WHERE `entry` = 190090;
INSERT INTO `creature_template` SELECT * FROM `tmp_boss_tier`;

-- ---------------------------------------------------------------------------
DELETE FROM `tmp_boss_tier`;
INSERT INTO `tmp_boss_tier` SELECT * FROM `creature_template` WHERE `entry` = 647;
UPDATE `tmp_boss_tier` SET
    `entry`                  = 190091,
    `name`                   = '送财童子',
    `subname`                = '活动Boss·标准',
    `minlevel`               = 83,
    `maxlevel`               = 83,
    `exp`                    = 2,
    `rank`                   = 1,
    `HealthModifier`         = 0.60,
    `DamageModifier`         = 2.0,
    `ManaModifier`           = 1,
    `ArmorModifier`          = 1,
    `ExperienceModifier`     = 1,
    `AIName`                 = '',
    `ScriptName`             = '',
    `lootid`                 = 0,
    `pickpocketloot`         = 0,
    `skinloot`               = 0,
    `mingold`                = 0,
    `maxgold`                = 0,
    `KillCredit1`            = 0,
    `KillCredit2`            = 0,
    `flags_extra`            = 0,
    `RegenHealth`            = 1,
    `CreatureImmunitiesId`   = -229,
    `VerifiedBuild`          = 12340;
DELETE FROM `creature_template` WHERE `entry` = 190091;
INSERT INTO `creature_template` SELECT * FROM `tmp_boss_tier`;

-- ---------------------------------------------------------------------------
DELETE FROM `tmp_boss_tier`;
INSERT INTO `tmp_boss_tier` SELECT * FROM `creature_template` WHERE `entry` = 647;
UPDATE `tmp_boss_tier` SET
    `entry`                  = 190092,
    `name`                   = '送财童子',
    `subname`                = '活动Boss·困难',
    `minlevel`               = 83,
    `maxlevel`               = 83,
    `exp`                    = 2,
    `rank`                   = 3,
    `HealthModifier`         = 1.45,
    `DamageModifier`         = 4.0,
    `ManaModifier`           = 1,
    `ArmorModifier`          = 1,
    `ExperienceModifier`     = 1,
    `AIName`                 = '',
    `ScriptName`             = '',
    `lootid`                 = 0,
    `pickpocketloot`         = 0,
    `skinloot`               = 0,
    `mingold`                = 0,
    `maxgold`                = 0,
    `KillCredit1`            = 0,
    `KillCredit2`            = 0,
    `flags_extra`            = 0,
    `RegenHealth`            = 1,
    `CreatureImmunitiesId`   = -229,
    `VerifiedBuild`          = 12340;
DELETE FROM `creature_template` WHERE `entry` = 190092;
INSERT INTO `creature_template` SELECT * FROM `tmp_boss_tier`;

-- ---------------------------------------------------------------------------
DELETE FROM `tmp_boss_tier`;
INSERT INTO `tmp_boss_tier` SELECT * FROM `creature_template` WHERE `entry` = 647;
UPDATE `tmp_boss_tier` SET
    `entry`                  = 190093,
    `name`                   = '送财童子',
    `subname`                = '活动Boss·团本',
    `minlevel`               = 83,
    `maxlevel`               = 83,
    `exp`                    = 2,
    `rank`                   = 3,
    `HealthModifier`         = 3.60,
    `DamageModifier`         = 7.0,
    `ManaModifier`           = 1,
    `ArmorModifier`          = 1,
    `ExperienceModifier`     = 1,
    `AIName`                 = '',
    `ScriptName`             = '',
    `lootid`                 = 0,
    `pickpocketloot`         = 0,
    `skinloot`               = 0,
    `mingold`                = 0,
    `maxgold`                = 0,
    `KillCredit1`            = 0,
    `KillCredit2`            = 0,
    `flags_extra`            = 0,
    `RegenHealth`            = 1,
    `CreatureImmunitiesId`   = -229,
    `VerifiedBuild`          = 12340;
DELETE FROM `creature_template` WHERE `entry` = 190093;
INSERT INTO `creature_template` SELECT * FROM `tmp_boss_tier`;

DROP TEMPORARY TABLE IF EXISTS `tmp_boss_tier`;

-- ---------------------------------------------------------------------------
DELETE FROM `creature_template_model` WHERE `CreatureID` IN (190090, 190091, 190092, 190093);
INSERT INTO `creature_template_model`
    (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`, `VerifiedBuild`)
SELECT t.`entry`, m.`Idx`, m.`CreatureDisplayID`, m.`DisplayScale`, m.`Probability`, m.`VerifiedBuild`
FROM `creature_template_model` m
JOIN (SELECT 190090 AS `entry` UNION ALL SELECT 190091 UNION ALL SELECT 190092 UNION ALL SELECT 190093) t
WHERE m.`CreatureID` = 647;

-- ---------------------------------------------------------------------------
-- addon（近战握持姿态等），与旧模板保持一致
-- ---------------------------------------------------------------------------
DELETE FROM `creature_template_addon` WHERE `entry` IN (190090, 190091, 190092, 190093);
INSERT INTO `creature_template_addon`
    (`entry`, `path_id`, `mount`, `bytes1`, `bytes2`, `emote`, `visibilityDistanceType`, `auras`)
SELECT t.`entry`, a.`path_id`, a.`mount`, a.`bytes1`, a.`bytes2`, a.`emote`, a.`visibilityDistanceType`, a.`auras`
FROM `creature_template_addon` a
JOIN (SELECT 190090 AS `entry` UNION ALL SELECT 190091 UNION ALL SELECT 190092 UNION ALL SELECT 190093) t
WHERE a.`entry` = 647;

-- 刻意不复制：creature_template_spell（旧模板的 Cleave/Harpoon，技能由 Eluna 技能池驱动）、
--             creature_template_locale（避免沿用"绿皮队长"的本地化名字）

-- ---------------------------------------------------------------------------
UPDATE `ac_eluna`.`boss_activity_config`
SET `boss_entry` = 190090,
    `boss_name`  = '送财童子',
    `updated_at` = UNIX_TIMESTAMP()
WHERE `state_key` = 'current';

-- ---------------------------------------------------------------------------
-- 预估血量 = 基准H × 该区面板倍率（这里直接读配置表的 boss_health_multiplier_scaled/100）
SELECT t.`entry`, t.`name`, t.`subname`, t.`minlevel`, t.`maxlevel`, t.`exp`, t.`rank`,
       t.`HealthModifier`, t.`DamageModifier`, t.`AIName`, t.`ScriptName`, t.`lootid`,
       ROUND(13945 * t.`HealthModifier` * (c.`boss_health_multiplier_scaled` / 100)) AS 预估血量_按本区倍率
FROM `creature_template` t
LEFT JOIN `ac_eluna`.`boss_activity_config` c ON c.`state_key` = 'current'
WHERE t.`entry` IN (190090, 190091, 190092, 190093)
ORDER BY t.`entry`;

SELECT `state_key`, `boss_entry`, `boss_name`, `boss_health_multiplier_scaled`
FROM `ac_eluna`.`boss_activity_config` WHERE `state_key` = 'current';
