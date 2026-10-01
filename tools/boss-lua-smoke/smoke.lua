-- ============================================================================
--  boss.lua 离线冒烟测试（不需要启动 worldserver）
--  ---------------------------------------------------------------------------
--  为什么需要它：boss.lua 只靠语法检查发现不了「前向引用被当成全局变量(nil)」
--  这类运行时缺陷；而启动 worldserver 校验一次要几分钟。本脚本用桩函数替换
--  Eluna/核心 API，再用自定义 _ENV 加载 boss.lua，捕获 RegisterPlayerEvent /
--  RegisterCreatureEvent 的回调，逐条驱动 .boss 命令并断言返回标记。
--
--  用法（在任意目录，建议在无 lua_scripts 子目录的工作目录下运行，
--  这样脚本打不开日志文件、所有输出都回到 stdout）：
--      lua.exe smoke.lua "D:\AzerothCore\release\<realm>\lua_scripts\boss.lua"
--
--  覆盖：配置加载(SQL 构造/两张配置表)、扩展表建表 + 写入列 + 缺列自动 ALTER、
--        列契约自检(information_schema 逐行返回存在的列名)、「数据库值覆盖脚本默认值」、
--        运行时持久化与跨重启恢复(spawned/engaged 首个 tick 重建 + 两条失败路径)、
--        奖池(boss_reward_pools 表驱动 + 出厂默认回落 + 位图映射 + 金币/离线邮件发放)、
--        写库失败可见性、结算三段式的收尾韧性、
--        help/pools/config/config show/preset/difficulty/rebase/kill/clear/schedule/spawn/未知子命令、
--        非 boss 命令放行，以及「全局 print 未被覆盖」「不再泄漏全局函数」两项回归断言。
-- ============================================================================

local bossPath = arg and arg[1] or "lua_scripts/boss.lua"

-- 技能池 / 连招内容回归的阈值：每个预设至少要有的连招条数。
-- 内容扩充（18 → 36 条、每套 6 条）时**只改这一处**，断言里不写死数字。
local MIN_COMBOS_PER_PRESET = 6

-- ---------------------------------------------------------------- 记录与断言
local originalPrint = print
local recorded = {
    sql = {}, events = {}, replies = {}, failures = {}, alters = {},
    spawnAttempts = 0, logLines = {}, mails = {}, printFailureFlags = {},
}
local scheduledEvents = {}

-- 冒烟环境里 boss.lua 把 print 重绑成了文件级 BossLog（§1），BossLog 打不开日志文件时
-- 会走它自己的上值 basePrint —— 而 basePrint 是**加载那一刻**的全局 print。所以要在跑 chunk
-- 之前把全局 print 换成录制器，脚本的每一行日志才会落进 recorded.logLines。
-- （assertTrue(print == originalPrint) 在录制器撤掉之后再断言，仍然成立。）
local function captureGlobalPrint(run)
    local wrapped = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(index, ...)))
        end
        recorded.logLines[#recorded.logLines + 1] = table.concat(parts, "\t")
        originalPrint(...)
    end

    _G.print = wrapped
    local ran, err = pcall(run)
    _G.print = originalPrint
    if not ran then
        error(err, 0)
    end
end

local function findLogLine(pattern, fromIndex)
    for index = fromIndex or 1, #recorded.logLines do
        local line = recorded.logLines[index]
        if line:find(pattern, 1, true) then return line end
    end
    return nil
end

-- 可控时钟：定时启停要看"此刻是否在时间段内"，必须能设定现在几点。
-- boss.lua 的 BossNow() 优先用 GetGameTime()，所以改写它即可（os.date 仍按真实时区解析）。
local fakeNow = os.time{year = 2026, month = 9, day = 1, hour = 3, min = 0, sec = 0}
local function setNow(value) fakeNow = value end
local function fail(msg)
    table.insert(recorded.failures, msg)
    io.write("  [FAIL] " .. msg .. "\n")
end
local function ok(msg)
    io.write("  [ ok ] " .. msg .. "\n")
end
local function assertTrue(cond, msg)
    if cond then ok(msg) else fail(msg) end
end

-- ---------------------------------------------------------------- 核心桩函数
local engineCallbacks = { creature = {}, player = {} }

local function mockQuery(values)
    return {
        GetUInt32 = function(_, i) return values[i + 1] end,
        GetInt32 = function(_, i) return values[i + 1] end,
        GetFloat = function(_, i) return values[i + 1] end,
        GetString = function(_, i) return tostring(values[i + 1] or "") end,
    }
end

-- 多行结果集（ALEQuery = 核心 QueryResult：首行即可读，:NextRow() 前进一行并返回是否还有行）。
-- 三处用到：information_schema 的"存在的列名"、boss_reward_pools、运行态整行。
-- 首行语义按核心自己的 `do { Fetch() } while (NextRow())` 写法：不调 NextRow 就能读第一行。
local function mockResultSet(rows)
    local cursor = 1

    local function cell(index)
        local row = rows[cursor]
        if row == nil then return nil end
        return row[index + 1]
    end

    return {
        GetUInt32 = function(_, index) return tonumber(cell(index)) end,
        GetInt32 = function(_, index) return tonumber(cell(index)) end,
        GetFloat = function(_, index) return tonumber(cell(index)) end,
        GetString = function(_, index) return tostring(cell(index) or "") end,
        NextRow = function()
            cursor = cursor + 1
            return rows[cursor] ~= nil
        end,
        __rows = rows,
    }
end

-- 按 SELECT 里的列名把一份"按列名给出的快照"铺成结果集行；缺列直接判失败
-- （描述表加了列而快照没跟上时立刻暴露，而不是悄悄回落到文件内默认值）。
local function rowsFromSelect(sql, values, label)
    local columnsText = sql:match("SELECT%s+(.-)%s+FROM")
    if not columnsText then
        return nil
    end

    local row, missing = {}, {}
    for column in columnsText:gmatch("`([%w_]+)`") do
        local value = values[column]
        if value == nil then
            missing[#missing + 1] = column
        end
        row[#row + 1] = value
    end

    if #missing > 0 then
        fail((label or "数据库") .. "快照缺少列: " .. table.concat(missing, ", "))
    end

    return mockResultSet({row})
end

-- 数据库快照（按列名给出，不依赖描述表顺序）：
--   main = ac_eluna.boss_activity_config（与 AGMP 面板共享）
--   ext  = ac_eluna.boss_activity_config_ext（脚本私有配置）
-- ext 故意用与文件内默认值不同的值：用来断言「运行时确实以数据库为准」。
local CONFIG_VALUES = {
    boss_entry = 190090, boss_name = "送财童子", boss_level = 83,
    boss_scale_scaled = 999, boss_health_multiplier_scaled = 150000, boss_auras_text = "467",
    ally_level = 50, ally_health_multiplier_scaled = 999, respawn_time_minutes = 10,
    minion_count_min = 1, minion_count_max = 2,
    skill_preset = "spellbreak_bulwark", skill_difficulty = "hard",
    random_reward_mode = "weighted", participation_range = 80,
    damage_weight = 100, healing_weight = 80, threat_weight = 35, presence_weight = 10, kill_weight = 3,
    spawn_points_text = "571,4353.573,-4411.8877,151.3909",
    -- 写入后的回读校验只取这一列（SELECT `updated_at` FROM ... LIMIT 1）
    updated_at = 1756700000,
}

local EXT_VALUES = {
    boss_spawn_yell = "DB喊话-{BOSS_NAME}", boss_enter_combat_yell = "DB进战喊话",
    ally_spawn_yell = "DB友方喊话", boss_respawn_yell = "DB重生喊话", boss_gm_spawn_yell = "DB GM喊话",
    taunt_cooldown_seconds = 11, random_taunt_chance = 22,
    taunt_phase2_yells_text = "DB阶段2嘲讽",
    taunt_phase3_yells_text = "", taunt_critical_hp_yells_text = "",
    taunt_skill_cast_yells_text = "DB技能名=DB技能喊话",
    taunt_target_switch_yells_text = "DB换目标嘲讽", taunt_interrupt_yells_text = "DB打断嘲讽",
    taunt_kill_yells_text = "DB击杀嘲讽", taunt_low_hp_yells_text = "DB低血嘲讽",
    taunt_healer_kill_yells_text = "DB治疗击杀嘲讽", taunt_summon_minion_yells_text = "DB召唤嘲讽",
    taunt_combo_yells_text = "DB连招名=DB连招喊话", taunt_long_combat_yells_text = "DB久战嘲讽",
    ai_update_interval_ms = 2500,
    phase2_hp_threshold = 71, phase3_hp_threshold = 21, critical_hp_threshold = 9,
    low_hp_taunt_threshold = 31, low_hp_taunt_cooldown_ms = 21000,
    long_combat_taunt_interval_ms = 61000, target_reeval_loops = 4,
    phase2_summon_count_min = 3, phase2_summon_count_max = 4, phase3_summon_count = 5,
    phase2_spell_id = 1045, phase3_spell_id = 8600,
    patrol_enabled = 0, patrol_radius = 66, patrol_leash_radius = 77, patrol_interval_ms = 8000,
    minion_ai_enabled = 0, minion_ai_interval_ms = 2600, minion_target_range = 55,
    helper_entries_text = "11111,22222", ally_helper_entry = 20000,
    class_types_text = "1=melee\n2=healer", class_reward_items_text = "1=40611\n2=40622",
    managed_tier_entries_text = "190090,190091,190092,190093,190094",
    -- [skill_random] 技能池随机：故意用与文件内默认值不同的值（脚本默认是关闭 + 空池 = 全部预设）
    skill_preset_random_enabled = 1,
    skill_preset_pool_text = "ember_storm, frost_whiteout",
    -- [recovery] 跨重启恢复：故意用与文件内默认值不同的值（脚本默认 15 秒 / 5%）
    health_sample_interval_sec = 25, recovery_min_health_pct = 12,
    boss_recovered_yell = "DB恢复喊话-{HEALTH_PCT}%",
    -- [reward] 结算口径（奖池本体已不在 ext 表里：见 boss_reward_pools）
    last_hit_only_qualifies = 0, offline_reward_delivery = 1,
    -- [schedule] 定时启停：故意用与文件内默认值不同的值（脚本默认是关闭 + 空时间段）
    activity_schedule_enabled = 1,
    activity_schedule_windows = "20:00-22:00; 1-5@08:00-09:00",
    activity_schedule_clear_on_close = 1,
    -- [feel_skill] 技能手感：读条/瞬发、连招概率与全局冷却保持默认值（由专门的用例改写后重载验证）；
    -- 条件阈值给与默认等价的子集（keyedlines 只覆盖写到的键，其余键回退脚本默认）
    skill_instant_cast = 0,
    combo_trigger_chance_pct = 100,
    combo_global_cooldown_seconds = 5,
    skill_pick_random_top = 1,
    skill_condition_thresholds_text = "multi_target=1\nmulti_melee=1\nmany_attackers=5",
    skill_disabled_spells_text = "",
    -- [feel_target] 目标选择：关掉威胁因子与随机窗口 → 目标选择确定化（既有断言不受随机影响）
    target_random_spread_pct = 0,
    threat_factor_enabled = 0,
    target_score_weights_text = "base=50\nthreat=60\ninterrupt=100\ncasting=45",
    -- [enrage] 软狂暴：保持关闭（这是文件默认值），数值给非默认值以证明 DB 值进配置
    soft_enrage_enabled = 0,
    soft_enrage_seconds = 120,
    soft_enrage_interval_seconds = 15,
    soft_enrage_spell_id = 8600,
    soft_enrage_speed_pct_per_stack = 7,
    soft_enrage_max_stacks = 4,
    -- [wipe] 团灭判定：关掉（文件默认是开），避免影响既有的战斗模拟断言
    wipe_detect_enabled = 0,
    wipe_grace_seconds = 20,
    wipe_reset_health_pct = 80,
    -- [announce] 世界公告：三个开关都关掉（文件默认是开），避免给既有用例多发世界消息
    announce_spawn_enabled = 0,
    announce_phase_enabled = 0,
    announce_restore_enabled = 0,
    announce_texts_text = "spawn=DB 生成公告\nphase=DB 阶段公告 {PHASE}\nrestore=DB 恢复公告",
    -- [marker] 点名预警：关掉（文件默认是开），避免给技能施放路径插入延迟
    marker_warning_enabled = 0,
    marker_warning_delay_seconds = 3,
    marker_warning_spell_id = 467,
    -- [taunts] 手感三组新喊话（未启用对应机制时也不会被取用，仅用于验证"取自数据库"）
    taunt_soft_enrage_yells_text = "DB软狂暴喊话1\nDB软狂暴喊话2",
    taunt_wipe_yells_text = "DB团灭喊话",
    taunt_marker_warning_yells_text = "DB预警喊话 {PLAYER_NAME}",
    -- 写入后的回读校验只取这一列（SELECT `updated_at` FROM ... LIMIT 1）
    updated_at = 1756700000,
}

-- 模拟「扩展表已存在、但脚本升级后描述表多了列」的线上状态：
-- 加载时必须先 ALTER 补列，否则引导写入会因 Unknown column 整条失败。
local PHASE_COLUMNS = {
    "phase2_hp_threshold", "phase3_hp_threshold", "critical_hp_threshold",
    "low_hp_taunt_threshold", "low_hp_taunt_cooldown_ms", "long_combat_taunt_interval_ms",
    "target_reeval_loops", "phase2_summon_count_min", "phase2_summon_count_max",
    "phase3_summon_count", "phase2_spell_id", "phase3_spell_id",
}

-- 再模拟一次"脚本升级后描述表又多了定时启停三列"：加载时必须自动补列。
local SCHEDULE_COLUMNS = {
    "activity_schedule_enabled", "activity_schedule_windows", "activity_schedule_clear_on_close",
}

-- 再模拟一次"脚本升级后描述表又多了 [recovery] / [reward] 结算口径五列"：同样必须自动补列。
local RECOVERY_COLUMNS = {
    "health_sample_interval_sec", "recovery_min_health_pct", "boss_recovered_yell",
}
local REWARD_SETTLEMENT_COLUMNS = { "last_hit_only_qualifies", "offline_reward_delivery" }

-- 再模拟一次"脚本升级后描述表又多了批 5 的 28 列（手感/目标/软狂暴/团灭/公告/点名 + taunts 三列）"：
-- 同样必须逐列自动补上，否则引导写入整条失败。
local PLAY_FEEL_COLUMNS = {
    "skill_instant_cast", "combo_trigger_chance_pct", "combo_global_cooldown_seconds",
    "skill_pick_random_top", "skill_condition_thresholds_text", "skill_disabled_spells_text",
    "target_random_spread_pct", "threat_factor_enabled", "target_score_weights_text",
    "soft_enrage_enabled", "soft_enrage_seconds", "soft_enrage_interval_seconds",
    "soft_enrage_spell_id", "soft_enrage_speed_pct_per_stack", "soft_enrage_max_stacks",
    "wipe_detect_enabled", "wipe_grace_seconds", "wipe_reset_health_pct",
    "announce_spawn_enabled", "announce_phase_enabled", "announce_restore_enabled",
    "announce_texts_text",
    "marker_warning_enabled", "marker_warning_delay_seconds", "marker_warning_spell_id",
    "taunt_soft_enrage_yells_text", "taunt_wipe_yells_text", "taunt_marker_warning_yells_text",
}
local NEW_EXT_COLUMNS = {}
for _, group in ipairs({ RECOVERY_COLUMNS, REWARD_SETTLEMENT_COLUMNS, PLAY_FEEL_COLUMNS }) do
    for _, column in ipairs(group) do NEW_EXT_COLUMNS[#NEW_EXT_COLUMNS + 1] = column end
end

-- 列存在性状态：按表登记"老库还没有的列"，其余列（含主表里那些待 DROP 的历史列）一律当作存在。
-- 三类 information_schema 查询都要能答：逐列 COLUMN_NAME = / 集合 COLUMN_NAME IN (...)
-- （FetchExistingColumns 读的是**逐行返回的列名**，返回一个计数会让每个列都算缺）/ STATISTICS。
local TABLE_NAMES = {
    main = "boss_activity_config",
    ext = "boss_activity_config_ext",
    runtime = "boss_activity_runtime",
    pools = "boss_reward_pools",
}

local mockMissingColumns = {
    [TABLE_NAMES.main] = {},
    [TABLE_NAMES.ext] = {},
    -- 运行态表的定时启停三列也按"老库还没有"处理（面板读不到时会降级显示，脚本自己要补）
    [TABLE_NAMES.runtime] = {
        schedule_state = true, schedule_window = true, schedule_next_change_at = true,
    },
    [TABLE_NAMES.pools] = {},
}

local function markMissing(tableName, columns)
    for _, column in ipairs(columns) do
        mockMissingColumns[tableName][column] = true
    end
end

markMissing(TABLE_NAMES.ext, PHASE_COLUMNS)
markMissing(TABLE_NAMES.ext, SCHEDULE_COLUMNS)
markMissing(TABLE_NAMES.ext, NEW_EXT_COLUMNS)

local function mockInformationSchema(sql)
    -- 索引存在性：一律按"已存在"处理（本脚本不校验索引 DDL 的列）
    if sql:find("information_schema.STATISTICS", 1, true) then
        return mockQuery({1})
    end

    local tableName = sql:match("TABLE_NAME = '([%w_]+)'")
    local missing = mockMissingColumns[tableName] or {}

    local inList = sql:match("COLUMN_NAME IN %((.-)%)")
    if inList then
        local present = {}
        for name in inList:gmatch("'([%w_]+)'") do
            if not missing[name] then present[#present + 1] = name end
        end

        if sql:find("COUNT(*)", 1, true) then
            return mockQuery({#present})
        end

        -- FetchExistingColumns 的形态：逐行返回"存在的列名"（一行一列）
        local rows = {}
        for _, name in ipairs(present) do rows[#rows + 1] = {name} end
        return mockResultSet(rows)
    end

    local single = sql:match("COLUMN_NAME = '([%w_]+)'")
    if single then
        return mockQuery({missing[single] and 0 or 1})
    end

    return mockQuery({1})
end

-- ---------------------------------------------------------------- 运行态 / 奖池结果集
-- 运行态整行的列顺序就是 LoadBossRuntimeFromDB 的 SELECT 顺序；快照按列名给出，缺列直接判失败。
local RUNTIME_SELECT_COLUMNS = {
    "boss_guid", "boss_entry", "boss_name", "map_id", "instance_id",
    "home_x", "home_y", "home_z", "phase", "status", "respawn_at",
    "last_spawn_at", "last_engage_at", "last_death_at", "last_reset_at",
    "schedule_state", "schedule_window", "schedule_next_change_at",
    "health_pct", "spawn_point_index", "last_health_sample_at",
    "skill_preset", "skill_difficulty",
}

-- boss_reward_pools 的 SELECT 列顺序（同 LoadRewardPoolsFromDB）。
local REWARD_POOL_SELECT_COLUMNS = {
    "pool_id", "sort_order", "name", "enabled", "chance", "winner_mode",
    "winner_count", "class_filter", "items_text", "gold_min_copper",
    "gold_max_copper", "announce",
}

local function buildRow(columns, values, label)
    local row, missing = {}, {}
    for index, column in ipairs(columns) do
        if values[column] == nil then missing[#missing + 1] = column end
        row[index] = values[column]
    end
    if #missing > 0 then
        fail(label .. "快照缺少列: " .. table.concat(missing, ", "))
    end
    return row
end

-- 运行态快照：nil = 表里没有本区行（走"内存态/首次引导"分支）
local function runtimeRow(values)
    return buildRow(RUNTIME_SELECT_COLUMNS, values, "运行态")
end

-- 奖池快照：nil = 读不到（缺表）；{} = 空结果集（本脚本按"没有本区数据"处理）
local function rewardPoolRows(list)
    local rows = {}
    for _, values in ipairs(list) do
        rows[#rows + 1] = buildRow(REWARD_POOL_SELECT_COLUMNS, values, "奖池")
    end
    return rows
end

local env = setmetatable({}, { __index = _G })

env.CharDBQuery = function(sql)
    table.insert(recorded.sql, { kind = "query", sql = sql })

    if sql:find("information_schema", 1, true) then
        return mockInformationSchema(sql)
    end
    if sql:find("boss_reward_pools", 1, true) and sql:find("SELECT", 1, true) then
        return recorded.rewardPoolRows and mockResultSet(recorded.rewardPoolRows) or nil
    end
    if sql:find("boss_activity_config_ext", 1, true) and sql:find("SELECT", 1, true) then
        return rowsFromSelect(sql, EXT_VALUES, "扩展表")
    end
    if sql:find("boss_activity_config", 1, true) and sql:find("SELECT", 1, true) then
        return rowsFromSelect(sql, CONFIG_VALUES, "主表")
    end
    if sql:find("boss_activity_runtime", 1, true) and sql:find("SELECT", 1, true) then
        -- 整行读取（SELECT 里带 boss_guid）默认"没有行"；只取 status 的是写入后的回读校验
        if sql:find("`boss_guid`", 1, true) then
            return recorded.runtimeRow and mockResultSet({recorded.runtimeRow}) or nil
        end
        -- 模拟"语句执行成功但数据没落地"：回读校验拿不到行
        if recorded.runtimeVerifyFails then return nil end
        return mockQuery({"idle"})
    end
    return nil -- 其它：模拟"没有行"
end

env.CharDBExecute = function(sql)
    table.insert(recorded.sql, { kind = "execute", sql = sql })

    -- 写库失败可见性（§写库统一入口）用：让下一次写抛错，模拟"Lua 侧语句拼接异常"
    if recorded.failNextExecute then
        recorded.failNextExecute = false
        error("injected CharDBExecute failure")
    end

    -- 补列必须真的改变「表结构」，否则后面的查询/写入还是按缺列状态走
    local addedColumn = sql:match("ADD COLUMN `([%w_]+)`")
    if addedColumn then
        local tableName = sql:match("ALTER TABLE `[^`]+`%.`([%w_]+)`")
        local missing = mockMissingColumns[tableName]
        if missing == nil then
            fail("补列语句指向未知表: " .. tostring(tableName) .. "（" .. sql:sub(1, 120) .. "）")
        else
            if missing[addedColumn] ~= true then
                fail("重复补列(" .. tostring(tableName) .. "): " .. addedColumn)
            end
            missing[addedColumn] = nil
        end
        recorded.alters[#recorded.alters + 1] = addedColumn
        recorded.altersSql = recorded.altersSql or {}
        recorded.altersSql[#recorded.altersSql + 1] = sql
    end
end

env.WorldDBQuery = env.CharDBQuery
env.WorldDBExecute = env.CharDBExecute

env.GetGameTime = function() return fakeNow end
env.SendWorldMessage = function(msg) table.insert(recorded.replies, "[WORLD] " .. tostring(msg)) end
env.GetPlayersInWorld = function() return {} end
env.GetPlayerByGUID = function() return nil end
env.CreateLuaEvent = function(fn, delay, repeats)
    scheduledEvents[#scheduledEvents + 1] = {fn = fn, delay = delay, repeats = repeats}
    return #scheduledEvents
end
env.RemoveEventById = function() end
env.PerformIngameSpawn = function()
    recorded.spawnAttempts = (recorded.spawnAttempts or 0) + 1
    return nil
end
env.GetMapById = function() return nil end
env.GetUnitGUID = function(low, entry) return tostring(low) .. ":" .. tostring(entry) end
env.RegisterCreatureEvent = function(entry, ev, fn)
    engineCallbacks.creature[tostring(entry) .. "/" .. tostring(ev)] = fn
end
env.RegisterPlayerEvent = function(ev, fn)
    engineCallbacks.player[tostring(ev)] = fn
end
env.GetConfigValue = function() return 1 end
-- 离线补发走全局 SendMail（按 GUID 投递，玩家不在线也进邮箱）：只记录调用参数供断言
env.SendMail = function(subject, text, receiverGUIDLow, senderGUIDLow, stationery, delay, money, cod, itemId, itemCount)
    recorded.mails[#recorded.mails + 1] = {
        subject = subject, text = text,
        receiverGUIDLow = receiverGUIDLow, senderGUIDLow = senderGUIDLow,
        stationery = stationery, delay = delay,
        money = money, cod = cod, itemId = itemId, itemCount = itemCount,
    }
    return true
end

local function runConsoleCommand(command)
    local handler = {
        messages = {},
        SendSysMessage = function(self, msg) table.insert(self.messages, tostring(msg)) end,
    }
    local fn = engineCallbacks.player["42"]
    if not fn then
        fail("PLAYER_EVENT_ON_COMMAND(42) 未注册")
        return {}
    end
    local returned = fn(42, nil, command, handler)
    recorded.lastReturn = returned
    return handler.messages
end

local function markersOf(messages)
    local text = table.concat(messages, " | ")
    local markers = {}
    for m in text:gmatch("%[AGMP_[A-Z]+%]") do table.insert(markers, m) end
    return table.concat(markers, ","), text
end

-- ------------------------------------------- 从 INSERT 里按列名取一个值（断言贡献快照用）
-- 不能靠"第几个数字"猜：列会增删，而 VALUES 里的字符串还可能含逗号。
local function splitSqlValues(valuesText)
    local values, current, inQuote, index = {}, {}, false, 1
    while index <= #valuesText do
        local character = valuesText:sub(index, index)
        if inQuote then
            if character == "'" then
                if valuesText:sub(index + 1, index + 1) == "'" then
                    current[#current + 1] = "'"
                    index = index + 1
                else
                    inQuote = false
                    current[#current + 1] = character
                end
            else
                current[#current + 1] = character
            end
        elseif character == "'" then
            inQuote = true
            current[#current + 1] = character
        elseif character == "," then
            values[#values + 1] = table.concat(current)
            current = {}
        else
            current[#current + 1] = character
        end
        index = index + 1
    end
    values[#values + 1] = table.concat(current)
    return values
end

local function insertColumnValue(sql, column)
    local columnsText = sql:match("%((.-)%) VALUES")
    if columnsText == nil then return nil end

    local position, wanted = 0, nil
    for name in columnsText:gmatch("`([%w_]+)`") do
        position = position + 1
        if name == column then wanted = position end
    end
    if wanted == nil then return nil end

    local valuesText = sql:match("VALUES%s*%((.*)%)%s*;?%s*$")
    if valuesText == nil then return nil end

    return splitSqlValues(valuesText)[wanted]
end

-- ------------------------------------------------------------------- 加载脚本
io.write("== 加载 " .. bossPath .. " ==\n")
local chunk, loadErr = loadfile(bossPath, "t", env)
if not chunk then
    io.write("LOAD ERROR: " .. tostring(loadErr) .. "\n")
    os.exit(2)
end

-- 全局 print 在跑 chunk 期间换成录制器：boss.lua 的 basePrint 就是这一刻的 print，
-- 之后它所有日志（含加载期的奖池来源 / 列契约自检 / 跨重启恢复检测）都会落进 recorded.logLines。
local runOk, runErr
captureGlobalPrint(function()
    runOk, runErr = pcall(chunk)
end)
if not runOk then
    io.write("RUNTIME ERROR during load: " .. tostring(runErr) .. "\n")
    os.exit(2)
end
ok("脚本加载执行完成（EnsureBossSchema / LoadBossConfigFromDB / LoadBossRuntimeFromDB / 事件注册）")

-- --------------------------------------------------------------- 回归断言 1/2
assertTrue(print == originalPrint and rawget(env, "print") == nil,
    "全局 print 未被 boss.lua 覆盖（其它 Eluna 脚本不受影响）")
assertTrue(#recorded.logLines > 0,
    "能捕获 boss.lua 的日志输出（" .. #recorded.logLines
        .. " 行；打不开 lua_scripts/lua_logs/boss.log 时才会回落到 stdout，请在无该目录的工作目录下运行）")
assertTrue(rawget(env, "RegisterBossEventsForEntry") == nil and rawget(env, "RegisterBossEventsForCandidates") == nil,
    "RegisterBossEventsFor* 不再泄漏为全局变量")
assertTrue(rawget(env, "activeBossInfo") == nil and rawget(env, "IsManagedBossEntry") == nil,
    "activeBossInfo / IsManagedBossEntry 仍为文件内 local")

-- ------------------------------------------- 文件内 local 的取样通道（技能池 / 连招回归用）
-- SKILL_PRESET_LIBRARY / SKILL_DIFFICULTY_LIBRARY / ApplySkillPreset / ApplySkillDifficulty /
-- BOSS_CONFIG / bossAIStates / 缩放后的 COMBO_CHAINS 与 SKILL_POOLS 全都是文件内 local，
-- **没有任何 .boss 命令会把它们打印出来**；唯一通道是 debug.getupvalue 走已注册回调的闭包链。
-- 必须按变量名查：boss.lua 一改，写死的上值下标就漂了。
local UPVALUE_WALK_LIMIT = 20000
local UPVALUE_MAX_DEPTH = 12

local function findUpvalueInCallbacks(callbacks, name)
    local seenFunctions, seenTables = {}, {}
    local budget = UPVALUE_WALK_LIMIT

    local function walk(value, depth)
        if budget <= 0 or depth > UPVALUE_MAX_DEPTH then return nil end
        budget = budget - 1

        local valueType = type(value)
        if valueType == "function" then
            if seenFunctions[value] then return nil end
            seenFunctions[value] = true

            local index = 1
            while true do
                local upName, upValue = debug.getupvalue(value, index)
                if upName == nil then break end
                if upName == name then return upValue end
                -- _ENV 会把整个桩环境（含 recorded.sql 上千条语句）拖进来，而且文件内 local
                -- 不可能只挂在 _ENV 上，所以整条 _ENV 分支直接跳过。
                if upName ~= "_ENV" then
                    local found = walk(upValue, depth + 1)
                    if found ~= nil then return found end
                end
                index = index + 1
            end
            return nil
        end

        if valueType ~= "table" or seenTables[value] then return nil end
        seenTables[value] = true

        -- 技能方法挂在 SkillAI / TargetSelector / TauntSystem 这类表里，表必须一起走
        for key, innerValue in pairs(value) do
            if key ~= "_ENV" and key ~= "_G" and innerValue ~= nil and innerValue ~= _G then
                local found = walk(innerValue, depth + 1)
                if found ~= nil then return found end
            end
        end
        return nil
    end

    -- 先查两个最有代表性的回调：命令处理器能直达 ApplySkillPreset / ApplySkillConfig 的上值链
    local preferred = { callbacks.player["42"], callbacks.creature["190090/1"] }
    for _, root in ipairs(preferred) do
        local found = walk(root, 0)
        if found ~= nil then return found end
    end
    -- 兜底：其余已注册回调（内容扩充后命令处理器被改名也还能取到）
    for _, bucket in ipairs({ callbacks.creature, callbacks.player }) do
        local keys = {}
        for key in pairs(bucket) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local found = walk(bucket[key], 0)
            if found ~= nil then return found end
        end
    end
    return nil
end

-- 按名字取文件内 local；返回 nil 表示这个名字已经不在闭包链里（改名 / 被删除）
local function bossLocal(name, callbacks)
    return findUpvalueInCallbacks(callbacks or engineCallbacks, name)
end

-- 沿上值链（含表内的函数）递归找「含指定字段的表」：按名字查不到时的兜底通道
local function reachableTable(root, field, maxDepth, validator)
    local seenFunctions, seenTables = {}, {}
    local depthLimit = maxDepth or UPVALUE_MAX_DEPTH

    local function walk(value, depth)
        local valueType = type(value)
        if valueType == "function" then
            if seenFunctions[value] or depth > depthLimit then return nil end
            seenFunctions[value] = true

            local index = 1
            while true do
                local upName, upValue = debug.getupvalue(value, index)
                if upName == nil then break end
                if upName ~= "_ENV" then
                    local found = walk(upValue, depth + 1)
                    if found ~= nil then return found end
                end
                index = index + 1
            end
            return nil
        end

        if valueType ~= "table" or seenTables[value] then return nil end
        seenTables[value] = true

        if rawget(value, field) ~= nil and (validator == nil or validator(value)) then
            return value
        end
        if depth > depthLimit then return nil end

        for key, innerValue in pairs(value) do
            if key ~= "_ENV" and key ~= "_G" and innerValue ~= nil and innerValue ~= _G then
                local found = walk(innerValue, depth + 1)
                if found ~= nil then return found end
            end
        end
        return nil
    end

    return walk(root, 0)
end

-- 缩放后的技能池 / 连招必须**每次现取**：ApplySkillConfig 会整体重绑这两个 local
-- （boss.lua:1873-1875），缓存下来就会断言到上一套预设。
local function scaledComboChains()
    local chains = bossLocal("COMBO_CHAINS")
    if chains ~= nil then return chains end
    return reachableTable(engineCallbacks.player["42"], 1, UPVALUE_MAX_DEPTH, function(candidate)
        local first = rawget(candidate, 1)
        return type(first) == "table" and type(rawget(first, "skills")) == "table"
    end)
end

local function scaledSkillPools()
    local pools = bossLocal("SKILL_POOLS")
    if pools ~= nil then return pools end
    return reachableTable(engineCallbacks.player["42"], 1, UPVALUE_MAX_DEPTH, function(candidate)
        local firstPool = rawget(candidate, 1)
        local firstSkill = type(firstPool) == "table" and rawget(firstPool, 1) or nil
        return type(firstSkill) == "table" and rawget(firstSkill, "spellId") ~= nil
    end)
end

local function assertEq(got, want, msg)
    assertTrue(got == want,
        msg .. "（实际 " .. tostring(got) .. "，期望 " .. tostring(want) .. "）")
end

-- 加载一份「CharDBQuery 全部返回 nil」的副本，用来读**文件内默认值**：
-- 运行时的 comboYells 会被扩展表列 taunt_combo_yells_text **整体替换**
-- （boss.lua:674-675 声明为 keyedlines、839-841 的 setter 是整体赋值），
-- 而冒烟快照里只给了 1 条假 key，所以默认库只有另加载一份副本才拿得到。
-- 段内临时换掉 engineCallbacks 的两张表，退出时**整表还原**
-- （多区绑定段的子环境会覆盖它们，只能整表放回，不能只删自己加的 key）。
local function withDefaultConfig(fn)
    local childEnv = setmetatable({
        -- DB 读一律返回 nil（走文件内默认分支），写一律丢弃（不污染 recorded.sql）
        CharDBQuery = function() return nil end,
        CharDBExecute = function() end,
        WorldDBQuery = function() return nil end,
        WorldDBExecute = function() end,
        CreateLuaEvent = function() return 0 end,
        RemoveEventById = function() end,
        print = function() end,
    }, { __index = env })

    local savedCreature, savedPlayer = engineCallbacks.creature, engineCallbacks.player
    engineCallbacks.creature, engineCallbacks.player = {}, {}

    local callResult = nil
    local chunk, loadErr = loadfile(bossPath, "t", childEnv)
    if not chunk then
        fail("默认配置副本加载失败: " .. tostring(loadErr))
    else
        local runOk, runErr = pcall(chunk)
        if not runOk then
            fail("默认配置副本运行期错误: " .. tostring(runErr))
        else
            local callOk, callErr = pcall(function() callResult = fn(engineCallbacks) end)
            if not callOk then
                fail("默认配置副本断言出错: " .. tostring(callErr))
            end
        end
    end

    engineCallbacks.creature, engineCallbacks.player = savedCreature, savedPlayer
    return callResult
end

-- ------------------------------------------------------ 配置读写 SQL 是否成形
local mainConfigWrites, extConfigWrites = 0, 0
local extCreateSql, extInsertSql, mainInsertSql = nil, nil, nil

-- 精确区分两张表：扩展表名包含主表名，必须用「带反引号的完整表名」判断
local function isExtConfigSql(sql) return sql:find("`boss_activity_config_ext`", 1, true) ~= nil end
local function isMainConfigSql(sql)
    return sql:find("`boss_activity_config`", 1, true) ~= nil and not isExtConfigSql(sql)
end
local function isInsertSql(sql) return sql:find("INSERT", 1, true) ~= nil end

for _, item in ipairs(recorded.sql) do
    if item.kind == "query" and item.sql:find("CREATE TABLE IF NOT EXISTS", 1, true)
        and isExtConfigSql(item.sql) then
        extCreateSql = item.sql
    end
    if item.kind == "execute" and isExtConfigSql(item.sql) then
        extConfigWrites = extConfigWrites + 1
        if isInsertSql(item.sql) and extInsertSql == nil then
            extInsertSql = item.sql
        end
    end
    if item.kind == "execute" and isMainConfigSql(item.sql) then
        mainConfigWrites = mainConfigWrites + 1
        if isInsertSql(item.sql) and mainInsertSql == nil then
            mainInsertSql = item.sql
        end
    end
end

assertTrue(mainConfigWrites >= 1, "启动时会引导式写入 boss_activity_config")
assertTrue(extConfigWrites >= 1, "启动时会引导式写入 boss_activity_config_ext（脚本私有配置）")

if mainInsertSql then
    assertTrue(mainInsertSql:find("190090", 1, true) ~= nil, "主表配置写入包含新模板 entry 190090")
    assertTrue(mainInsertSql:find("`spawn_points_text`", 1, true) ~= nil, "主表配置写入包含 spawn_points_text 列")
    assertTrue(mainInsertSql:find("INSERT IGNORE INTO", 1, true) ~= nil, "引导写入用 INSERT IGNORE（不覆盖已有配置）")
end

-- REPLACE INTO 会删行重插：面板写在同表、但脚本不认识的列会被重置，所以脚本对
-- 两张配置表一律不用它（运行时表 boss_activity_runtime 用 REPLACE 是既有行为，不在检查范围）
local replaceConfigWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.kind == "execute" and item.sql:find("REPLACE INTO", 1, true)
        and item.sql:find("boss_activity_config", 1, true) then
        replaceConfigWrites = replaceConfigWrites + 1
    end
end
assertTrue(replaceConfigWrites == 0, "配置表写入不再使用 REPLACE INTO（避免清掉面板列）")

-- 扩展表：建表语句与写入语句的列都必须和描述表一致（防止「描述表加了、DDL 忘了加」）
local extSchema = bossLocal("BOSS_CONFIG_SCHEMA_EXT")
local mainSchema = bossLocal("BOSS_CONFIG_SCHEMA_MAIN")
assertTrue(type(extSchema) == "table" and type(mainSchema) == "table",
    "按名字取到文件内 local BOSS_CONFIG_SCHEMA_MAIN / BOSS_CONFIG_SCHEMA_EXT（列数断言的数据源）")

if extCreateSql and extInsertSql then
    local createColumns = {}
    local createBody = extCreateSql:match("%((.*)%) ENGINE") or ""
    for column in createBody:gmatch("`([%w_]+)`") do
        createColumns[column] = true
    end

    local insertColumnsText = extInsertSql:match("%((.-)%) VALUES") or ""
    local insertColumnCount, missingInCreate = 0, {}
    for column in insertColumnsText:gmatch("`([%w_]+)`") do
        insertColumnCount = insertColumnCount + 1
        if not createColumns[column] then
            missingInCreate[#missingInCreate + 1] = column
        end
    end

    -- 引导写入 = state_key + 描述表全部列 + updated_at
    assertEq(insertColumnCount, (type(extSchema) == "table" and #extSchema or 0) + 2,
        "扩展表写入覆盖描述表全部列（" .. tostring(type(extSchema) == "table" and #extSchema or 0)
            .. " 个描述项 + state_key + updated_at）")
    assertTrue(#missingInCreate == 0,
        "扩展表写入的每一列都在建表语句里" .. (#missingInCreate > 0 and ("（缺: " .. table.concat(missingInCreate, ",") .. "）") or ""))

    for _, column in ipairs({
        "boss_spawn_yell", "taunt_kill_yells_text", "taunt_combo_yells_text",
        "patrol_enabled", "minion_ai_interval_ms", "helper_entries_text",
        "class_reward_items_text", "managed_tier_entries_text",
    }) do
        assertTrue(createColumns[column] == true, "扩展表建表语句含列 " .. column)
    end

    -- 五个新列（[recovery] 三列 + [reward] 结算口径两列）必须同时进建表与引导写入
    for _, column in ipairs(NEW_EXT_COLUMNS) do
        assertTrue(createColumns[column] == true, "扩展表建表语句含新列 " .. column)
        assertTrue(extInsertSql:find("`" .. column .. "`", 1, true) ~= nil,
            "扩展表引导写入含新列 " .. column)
    end

    -- 奖池已经搬进 boss_reward_pools 表：ext 表里不允许再出现 reward_pool_N_* 列
    local stalePoolColumns = {}
    for column in pairs(createColumns) do
        if column:match("^reward_pool_%d+_") then stalePoolColumns[#stalePoolColumns + 1] = column end
    end
    for column in insertColumnsText:gmatch("`([%w_]+)`") do
        if column:match("^reward_pool_%d+_") then stalePoolColumns[#stalePoolColumns + 1] = column end
    end
    assertTrue(#stalePoolColumns == 0,
        "扩展表已无 reward_pool_N_* 列（旧奖池的 36 个配置列彻底移出配置表）"
        .. (#stalePoolColumns > 0 and ("（仍有: " .. table.concat(stalePoolColumns, ",") .. "）") or ""))
end

local runtimeWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_runtime") and item.kind == "execute" then
        runtimeWrites = runtimeWrites + 1
    end
end
assertTrue(runtimeWrites >= 1, "启动时写入了 boss_activity_runtime 引导行")

-- 扩展表迁移：桩状态里故意缺 [phase] 12 列 + [schedule] 3 列 + [recovery]/[reward] 5 列，
-- 运行态表缺 [schedule] 3 列；加载时必须先补列再写配置，
-- 否则线上遇到「脚本升级后描述表多了列」会整条写入失败（配置改了却不生效）
io.write("\n== 扩展表缺列迁移 ==\n")
do
-- 本区 key 从**被测文件**里读：多区部署由 deploy-realm.ps1 改写这两行常量，
-- 断言里写死 'current' 会让"key 不是 current 的区"永远失败（而每个区都必须是不同的 key）。
local expectedConfigKey, expectedRuntimeKey = "current", "current"
do
    local handle = io.open(bossPath, "r")
    if handle then
        local text = handle:read("*a")
        handle:close()
        expectedConfigKey = text:match('local BOSS_CONFIG_KEY%s*=%s*"([^"]*)"') or expectedConfigKey
        expectedRuntimeKey = text:match('local BOSS_RUNTIME_KEY%s*=%s*"([^"]*)"') or expectedRuntimeKey
    end
end
assertTrue(expectedConfigKey ~= "" and expectedRuntimeKey ~= "",
    "从被测文件里读到 BOSS_CONFIG_KEY / BOSS_RUNTIME_KEY（多区部署会改写它们）")

local expectedAlters = #PHASE_COLUMNS + #SCHEDULE_COLUMNS + #NEW_EXT_COLUMNS + 3
assertEq(#recorded.alters, expectedAlters,
    string.format("自动补列 %d 个（缺 [phase] %d + [schedule] %d + 新列 %d + 运行态 %d）",
        expectedAlters, #PHASE_COLUMNS, #SCHEDULE_COLUMNS, #NEW_EXT_COLUMNS, 3))

for tableName, label in pairs({ [TABLE_NAMES.ext] = "扩展表", [TABLE_NAMES.runtime] = "运行态表" }) do
    local stillMissing = {}
    for column in pairs(mockMissingColumns[tableName]) do
        stillMissing[#stillMissing + 1] = column
    end
    assertTrue(#stillMissing == 0,
        "补列后" .. label .. "列齐全" .. (#stillMissing > 0 and ("（缺: " .. table.concat(stillMissing, ",") .. "）") or ""))
end

-- 新列必须真的被 ALTER 过，而且带 AFTER（物理列序与描述表一致，DBA 复核 / 面板镜像都按这个顺序）
for _, column in ipairs(NEW_EXT_COLUMNS) do
    local alterSql = nil
    for _, sql in ipairs(recorded.altersSql or {}) do
        if sql:find("ADD COLUMN `" .. column .. "`", 1, true) then alterSql = sql end
    end
    assertTrue(alterSql ~= nil, "老库缺列时自动 ALTER 补列 " .. column)
    if alterSql ~= nil then
        assertTrue(alterSql:find("AFTER `", 1, true) ~= nil,
            "补列 " .. column .. " 带 AFTER（插到描述表里的位置，物理列序与面板镜像一致）")
    end
end

local healthAlter = nil
for _, sql in ipairs(recorded.altersSql or {}) do
    if sql:find("ADD COLUMN `health_sample_interval_sec`", 1, true) then healthAlter = sql end
end
assertTrue(healthAlter ~= nil and healthAlter:find("AFTER `skill_preset_pool_text`", 1, true) ~= nil,
    "health_sample_interval_sec 补在 skill_preset_pool_text 之后（[recovery] 组插在 [schedule] 之前）")

local firstAlterIndex, firstExtInsertIndex = nil, nil
for index, item in ipairs(recorded.sql) do
    if item.kind == "execute" and item.sql:find("ADD COLUMN", 1, true) and firstAlterIndex == nil then
        firstAlterIndex = index
    end
    if item.kind == "execute" and isExtConfigSql(item.sql) and isInsertSql(item.sql)
        and firstExtInsertIndex == nil then
        firstExtInsertIndex = index
    end
end
assertTrue(firstAlterIndex ~= nil and firstExtInsertIndex ~= nil and firstAlterIndex < firstExtInsertIndex,
    "补列发生在扩展表写入之前（顺序：ALTER → INSERT）")

-- ------------------------------------------------- 整行读取的列契约（运行态 / 奖池）
-- 这两张表的快照是"按列名"给出的，靠列顺序对齐；boss.lua 一改 SELECT 列就必须在这里暴露，
-- 否则 GetQuery*(query, index) 会静默错位（读成隔壁字段的值）。
local function selectColumnsOf(sql)
    local text = sql:match("SELECT%s+(.-)%s+FROM") or ""
    local columns = {}
    for column in text:gmatch("`([%w_]+)`") do columns[#columns + 1] = column end
    return columns
end

local runtimeSelectSql, rewardPoolSelectSql = nil, nil
for _, item in ipairs(recorded.sql) do
    -- 只认整行 SELECT：同一批里还有 CREATE TABLE / information_schema 的列契约查询
    if item.kind == "query" and item.sql:find("SELECT", 1, true)
        and item.sql:find("CREATE", 1, true) == nil
        and item.sql:find("COLUMN_NAME", 1, true) == nil then
        if item.sql:find("`boss_activity_runtime`", 1, true) and item.sql:find("`health_pct`", 1, true)
            and runtimeSelectSql == nil then
            runtimeSelectSql = item.sql
        end
        if item.sql:find("`boss_reward_pools`", 1, true) and item.sql:find("`items_text`", 1, true)
            and rewardPoolSelectSql == nil then
            rewardPoolSelectSql = item.sql
        end
    end
end

assertTrue(runtimeSelectSql ~= nil, "启动时按整行读取 boss_activity_runtime（跨重启恢复依赖它）")
if runtimeSelectSql ~= nil then
    assertEq(table.concat(selectColumnsOf(runtimeSelectSql), ","), table.concat(RUNTIME_SELECT_COLUMNS, ","),
        "运行态 SELECT 的列与冒烟快照顺序一致（" .. #RUNTIME_SELECT_COLUMNS .. " 列，含 health_pct/spawn_point_index/技能预设）")
    assertTrue(runtimeSelectSql:find(expectedRuntimeKey, 1, true) ~= nil,
        "运行态查询用本区 key（" .. expectedRuntimeKey .. "）过滤")
end

assertTrue(rewardPoolSelectSql ~= nil, "启动时会从 boss_reward_pools 读奖池（不是 ext 配置列）")
if rewardPoolSelectSql ~= nil then
    assertEq(table.concat(selectColumnsOf(rewardPoolSelectSql), ","), table.concat(REWARD_POOL_SELECT_COLUMNS, ","),
        "奖池 SELECT 的列与冒烟快照顺序一致（" .. #REWARD_POOL_SELECT_COLUMNS .. " 列）")
    -- key 取自被测文件（deploy-realm 会改写），不写死 'current'
    assertTrue(rewardPoolSelectSql:find("`state_key` = '" .. expectedConfigKey .. "'", 1, true) ~= nil,
        "奖池查询按本区 state_key 过滤（" .. expectedConfigKey .. "，多区共用库）")
    assertTrue(rewardPoolSelectSql:find("`deleted_at` = 0", 1, true) ~= nil,
        "奖池查询排除软删除行（deleted_at = 0；pool_id 不复用）")
    assertTrue(rewardPoolSelectSql:find("ORDER BY `sort_order`, `pool_id`", 1, true) ~= nil,
        "奖池查询按 sort_order / pool_id 排序（面板拖拽顺序即生效顺序）")
end
end

-- ------------------------------------------------------------ 命令驱动与断言
do
local cases = {
    { cmd = "boss help",              expect = "AGMP_OK",    name = ".boss help" },
    { cmd = "boss config reload",     expect = "AGMP_OK",    name = ".boss config reload" },
    { cmd = "boss preset list",       expect = "AGMP_OK",    name = ".boss preset list" },
    { cmd = "boss preset ember_storm",expect = "AGMP_OK",    name = ".boss preset <key>" },
    { cmd = "boss difficulty raid",   expect = "AGMP_OK",    name = ".boss difficulty <key>" },
    { cmd = "boss rebase",            expect = "AGMP_ERROR", name = ".boss rebase（无活跃 Boss）" },
    { cmd = "boss kill",              expect = "AGMP_ERROR", name = ".boss kill（无活跃 Boss）" },
    { cmd = "boss clear",             expect = "AGMP_OK",    name = ".boss clear（无活跃 Boss）" },
    { cmd = "boss schedule",          expect = "AGMP_OK",    name = ".boss schedule" },
    { cmd = "boss pools",             expect = "AGMP_OK",    name = ".boss pools" },
    { cmd = "boss spawn",             expect = "AGMP_ERROR", name = ".boss spawn（定时计划在时段外 → 拒绝）" },
    { cmd = "boss spawn force",       expect = "AGMP_ERROR", name = ".boss spawn force（桩生成失败）" },
    { cmd = "boss nonsense",          expect = "AGMP_ERROR", name = ".boss 未知子命令" },
}

io.write("\n== 命令驱动 ==\n")
for _, case in ipairs(cases) do
    local messages = runConsoleCommand(case.cmd)
    local markers, text = markersOf(messages)
    io.write(string.format("  %-34s markers=%-12s %s\n", case.name, markers ~= "" and markers or "-",
        text:sub(1, 90)))
    assertTrue(markers:find(case.expect, 1, true) ~= nil,
        case.name .. " 返回 " .. case.expect .. "（面板可据此判定成功/失败）")
end
end

local function showGroup(group)
    return table.concat(runConsoleCommand("boss config show " .. group), " | ")
end

-- 配置展示 + 「运行时以数据库为准」：ext 表里的值必须真的生效，而不是被默认值盖掉
io.write("\n== .boss config show ==\n")
do
local groupMessages = runConsoleCommand("boss config show")
local groupText = table.concat(groupMessages, " | ")
assertTrue(#groupMessages > 0, ".boss config show 有输出")
local groupKeys = {
    "identity", "basic", "ally", "yells", "taunts", "ai", "phase", "patrol",
    "minion", "skill", "skill_random", "respawn", "spawnpoints", "schedule",
    "helper", "reward", "recovery", "class_ai", "class_reward", "tier",
    "feel_skill", "feel_target", "enrage", "wipe", "announce", "marker",
}
local missingGroups = {}
for _, group in ipairs(groupKeys) do
    if not groupText:find(group, 1, true) then missingGroups[#missingGroups + 1] = group end
end
assertTrue(#missingGroups == 0, "配置分组齐全（26 组：含批 5 新增的手感/软狂暴/团灭/公告/点名五组）" ..
    (#missingGroups > 0 and ("（缺: " .. table.concat(missingGroups, ",") .. "）") or ""))

-- 奖池不再是配置列：不能再出现 reward_pool_N 分组
local staleGroups = {}
for _, group in ipairs({ "reward_pool_1", "reward_pool_2", "reward_pool_3", "reward_pool_4", "reward_pool_5", "reward_pool_6" }) do
    if groupText:find(group, 1, true) then staleGroups[#staleGroups + 1] = group end
end
assertTrue(#staleGroups == 0, "配置分组里已无 6 个奖池组（奖池改由 boss_reward_pools 表维护）" ..
    (#staleGroups > 0 and ("（仍有: " .. table.concat(staleGroups, ",") .. "）") or ""))

assertEq(#groupKeys, 26, "分组清单常量与 boss.lua 的 BOSS_CONFIG_GROUP_ORDER 一致（26 组）")

-- 各组声明的项数之和必须等于两张描述表的项数之和（漏登记/漏分组会立刻暴露）
local listedTotal, listedGroupCount = 0, 0
for count in groupText:gmatch("（(%d+) 项）") do
    listedTotal = listedTotal + tonumber(count)
    listedGroupCount = listedGroupCount + 1
end
assertEq(listedGroupCount, #groupKeys, "展示出的有项分组数与预期一致")
if type(extSchema) == "table" and type(mainSchema) == "table" then
    assertEq(listedTotal, #mainSchema + #extSchema,
        string.format("分组项数之和 = 描述表总数（主表 %d + 扩展表 %d）", #mainSchema, #extSchema))
end

local yellsText = showGroup("yells")
assertTrue(yellsText:find("DB喊话-{BOSS_NAME}", 1, true) ~= nil,
    "喊话取自 boss_activity_config_ext（DB 值生效）")
assertTrue(yellsText:find("打爆这个垃圾服务器", 1, true) == nil,
    "喊话未回落到文件内默认值（说明 ext 表确实覆盖了默认配置）")

local tauntText = showGroup("taunts")
assertTrue(tauntText:find("DB击杀嘲讽", 1, true) ~= nil, "嘲讽列表取自 ext 表（多行文本解析正确）")
assertTrue(tauntText:find("DB技能名=DB技能喊话", 1, true) ~= nil, "键值型嘲讽（技能名=喊话）解析正确")
assertTrue(tauntText:find("11", 1, true) ~= nil and tauntText:find("22", 1, true) ~= nil,
    "嘲讽冷却/概率取自 ext 表")

local patrolText = showGroup("patrol")
assertTrue(patrolText:find("false", 1, true) ~= nil, "patrol_enabled=0 解析为 false")
assertTrue(patrolText:find("66", 1, true) ~= nil, "patrol_radius 取自 ext 表")

local helperText = showGroup("helper")
assertTrue(helperText:find("11111,22222", 1, true) ~= nil, "援军 entry 列表取自 ext 表")
assertTrue(helperText:find("20000", 1, true) ~= nil, "友方援军 entry 取自 ext 表")

local tierText = showGroup("tier")
assertTrue(tierText:find("190090,190091,190092,190093,190094", 1, true) ~= nil,
    "受管档位模板取自 ext 表")

-- 职业相关的两个字段被拆到两个组：class_ai（AI 选目标）与 class_reward（奖池过滤）
local classAiText = showGroup("class_ai")
assertTrue(classAiText:find("class_types_text", 1, true) ~= nil,
    "职业类型映射（AI 选目标用）在 class_ai 组里")
assertTrue(classAiText:find("1=melee", 1, true) ~= nil,
    "职业类型映射（键值文本 1=melee）解析正确")

local classRewardText = showGroup("class_reward")
assertTrue(classRewardText:find("class_reward_items_text", 1, true) ~= nil,
    "职业过滤映射在 class_reward 组里")
assertTrue(classRewardText:find("1=40611", 1, true) ~= nil,
    "职业过滤映射（键=物品列表）解析正确")
assertTrue(showGroup("class"):find("职业配置", 1, true) == nil,
    "旧的 class 组已经不再存在（两个职业字段各归其位）")

-- 战斗阶段阈值/阶段法术/召唤数量原先写死在 AI 里，现在必须来自配置
local phaseText = showGroup("phase")
assertTrue(phaseText:find("phase2_hp_threshold (phase2HpThreshold) = 71", 1, true) ~= nil,
    "阶段阈值 phase2HpThreshold 取自 ext 表")
assertTrue(phaseText:find("phase3_hp_threshold (phase3HpThreshold) = 21", 1, true) ~= nil,
    "阶段阈值 phase3HpThreshold 取自 ext 表")
assertTrue(phaseText:find("phase2_spell_id (phase2SpellId) = 1045", 1, true) ~= nil,
    "阶段法术 phase2SpellId 取自 ext 表")
assertTrue(phaseText:find("phase3_summon_count (phase3SummonCount) = 5", 1, true) ~= nil,
    "阶段召唤数量 phase3SummonCount 取自 ext 表")
assertTrue(phaseText:find("target_reeval_loops (targetReevalLoops) = 4", 1, true) ~= nil,
    "目标重评估间隔 targetReevalLoops 取自 ext 表")

-- [recovery] 跨重启恢复（新组）：三列都必须来自 ext 表
local recoveryText = showGroup("recovery")
assertTrue(recoveryText:find("health_sample_interval_sec (healthSampleIntervalSec) = 25", 1, true) ~= nil,
    "[recovery] 血量采样间隔取自 ext 表")
assertTrue(recoveryText:find("recovery_min_health_pct (recoveryMinHealthPct) = 12", 1, true) ~= nil,
    "[recovery] 恢复血量下限取自 ext 表")
assertTrue(recoveryText:find("boss_recovered_yell (bossRecoveredYell) = DB恢复喊话-{HEALTH_PCT}%", 1, true) ~= nil,
    "[recovery] 恢复喊话取自 ext 表（{HEALTH_PCT} 占位符原样保留）")

-- [reward] 结算口径两列（奖池本体已移出 ext 表）
local rewardSettlementText = showGroup("reward")
assertTrue(rewardSettlementText:find("last_hit_only_qualifies (lastHitOnlyQualifies) = false", 1, true) ~= nil,
    "[reward] last_hit_only_qualifies=0 解析为 false（只有最后一击不算有效参战）")
assertTrue(rewardSettlementText:find("offline_reward_delivery (offlineRewardDelivery) = true", 1, true) ~= nil,
    "[reward] offline_reward_delivery=1 解析为 true（下线玩家走邮件补发）")

local badGroupMessages = runConsoleCommand("boss config show nonsense")
local badMarkers = markersOf(badGroupMessages)
assertTrue(badMarkers:find("AGMP_ERROR", 1, true) ~= nil, "未知配置分组返回 AGMP_ERROR")

local badUsage = markersOf(runConsoleCommand("boss config oops"))
assertTrue(badUsage:find("AGMP_ERROR", 1, true) ~= nil, ".boss config <未知子命令> 返回 AGMP_ERROR")
end

-- 非 boss 命令必须放行（返回 true 表示交给核心继续处理）
io.write("\n== 非 boss 命令放行 ==\n")
do
local handler = { messages = {}, SendSysMessage = function(self, m) table.insert(self.messages, m) end }
local passthrough = engineCallbacks.player["42"](42, nil, "reload ale", handler)
assertTrue(passthrough == true, "非 boss 命令返回 true（不拦截其他 GM 指令）")
assertTrue(#handler.messages == 0, "非 boss 命令不产生 boss 回复")

-- clear 必须写 command_clear 事件并把运行时复位
io.write("\n== .boss clear 的副作用 ==\n")
runConsoleCommand("boss clear")
local hasClearEvent, hasRuntimeReset = false, false
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_events") and item.sql:find("command_clear", 1, true) then
        hasClearEvent = true
    end
    if item.sql:find("boss_activity_runtime") and item.sql:find("'idle'", 1, true) then
        hasRuntimeReset = true
    end
end
assertTrue(hasClearEvent, ".boss clear 写入 event_type='command_clear'")
assertTrue(hasRuntimeReset, ".boss clear 把 runtime 复位为 idle")

-- PLAYER_EVENT_ON_HEAL(65) 与 6 个 creature 事件是否注册齐全
io.write("\n== 事件注册 ==\n")
assertTrue(engineCallbacks.player["65"] ~= nil, "PLAYER_EVENT_ON_HEAL(65) 已注册")
for _, entry in ipairs({ "190090", "190091", "190092", "190093" }) do
    local complete = true
    for _, ev in ipairs({ "1", "2", "3", "4", "5", "9" }) do
        if not engineCallbacks.creature[entry .. "/" .. ev] then complete = false end
    end
    assertTrue(complete, "entry " .. entry .. " 的 creature 事件齐全(1/2/3/4/5/9)")
end
-- ext 表里的 managed_tier_entries_text 多带了一个 190094（文件内默认没有）：
-- 它也被注册事件，说明「受管模板」确实以数据库为准
assertTrue(engineCallbacks.creature["190094/1"] ~= nil,
    "受管模板 entry 由 ext 表驱动（190094 也注册了事件）")
end

-- ------------------------------------------------- 定时启停（每天时间段自动开关）
-- 三件事必须成立：
--   1) 三个新配置列真的进了建表 / 引导写入 / 运行时写入（面板读同一份描述表）；
--   2) 时间段解析与命中判定按「星期掩码 + 跨夜」正确（用可控时钟驱动 tick 断言）；
--   3) 门控真的生效：时段外不生成、进入时段自动补生成、离开时段写结束事件。
io.write("\n== 定时启停（时间段） ==\n")
do
local scheduleColumns = {
    "activity_schedule_enabled", "activity_schedule_windows", "activity_schedule_clear_on_close",
}
for _, column in ipairs(scheduleColumns) do
    if extCreateSql then
        assertTrue(extCreateSql:find("`" .. column .. "`", 1, true) ~= nil,
            "扩展表建表语句含定时启停列 " .. column)
    end
    if extInsertSql then
        assertTrue(extInsertSql:find("`" .. column .. "`", 1, true) ~= nil,
            "扩展表引导写入含定时启停列 " .. column)
    end
end

local runtimeScheduleColumns = false
for _, item in ipairs(recorded.sql) do
    if item.kind == "execute" and item.sql:find("boss_activity_runtime", 1, true)
        and item.sql:find("`schedule_state`", 1, true)
        and item.sql:find("`schedule_window`", 1, true)
        and item.sql:find("`schedule_next_change_at`", 1, true) then
        runtimeScheduleColumns = true
    end
end
assertTrue(runtimeScheduleColumns, "runtime 写入语句含定时启停三列（面板读同一行显示）")

-- 自动补列：线上老库（扩展表 + 运行态表）都没有这三列，加载时必须先 ALTER 再读写
-- （断言依据是"补列时桩状态里的缺列真的被清掉了"，见上面 == 扩展表缺列迁移 == 一节）
for _, column in ipairs(scheduleColumns) do
    assertTrue(mockMissingColumns[TABLE_NAMES.ext][column] == nil,
        "加载时自动补扩展表列 " .. column)
end
for _, column in ipairs({ "schedule_state", "schedule_window", "schedule_next_change_at" }) do
    assertTrue(mockMissingColumns[TABLE_NAMES.runtime][column] == nil,
        "加载时自动补运行态列 " .. column)
end

-- 组内取值必须来自 ext 表（面板保存的就是这三列）
local scheduleShowText = showGroup("schedule")
assertTrue(scheduleShowText:find("activity_schedule_enabled (scheduleEnabled) = true", 1, true) ~= nil,
    "定时启停开关取自 ext 表")
assertTrue(scheduleShowText:find("activity_schedule_windows (scheduleWindows) = 20:00-22:00; 1-5@08:00-09:00", 1, true) ~= nil,
    "时间段文本取自 ext 表（分号 / @ / 逗号原样保留）")
assertTrue(scheduleShowText:find("activity_schedule_clear_on_close (scheduleClearOnClose) = true", 1, true) ~= nil,
    "离开时段清理开关取自 ext 表")

-- tick 注册：每秒、无限重复（repeats=0）
local scheduleTick = nil
for _, item in ipairs(scheduledEvents) do
    if item.delay == 1000 and item.repeats == 0 and scheduleTick == nil then
        scheduleTick = item.fn
    end
end
assertTrue(scheduleTick ~= nil, "定时启停 tick 已注册（1000ms / repeats=0）")

if scheduleTick then
    local function clockAt(hour, minute, allowedWdays)
        local base = os.time{year = 2026, month = 9, day = 1, hour = hour, min = minute, sec = 0}
        for offset = 0, 13 do
            local candidate = base + offset * 86400
            if allowedWdays[tonumber(os.date("%w", candidate))] then
                return candidate
            end
        end
        return base
    end

    local weekdays = {[1] = true, [2] = true, [3] = true, [4] = true, [5] = true}
    local weekend = {[0] = true, [6] = true}
    local everyday = {[0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true}

    local insideWeekday = clockAt(8, 30, weekdays)   -- 命中 1-5@08:00-09:00
    local outsideWeekend = clockAt(8, 30, weekend)   -- 星期掩码不匹配
    local outsideNight = clockAt(23, 0, everyday)    -- 22:00 之后，两段都不在

    -- 1) 星期掩码：周六 08:30 不在「工作日」段内 → 不生成
    recorded.spawnAttempts = 0
    setNow(outsideWeekend)
    scheduleTick(0, 1000, 0)
    assertTrue(recorded.spawnAttempts == 0, "星期掩码生效：周六 08:30 不在 1-5@08:00-09:00 内（不生成）")
    local weekendText = table.concat(runConsoleCommand("boss schedule"), " | ")
    assertTrue(weekendText:find("未到时间", 1, true) ~= nil, ".boss schedule 报告当前不在时间段内")

    local closedPersisted = false
    for _, item in ipairs(recorded.sql) do
        if item.sql:find("boss_activity_runtime", 1, true) and item.sql:find("'closed'", 1, true) then
            closedPersisted = true
        end
    end
    assertTrue(closedPersisted, "不在时间段内时把运行态写成 closed（面板据此显示）")

    -- 2) 进入时间段：写 schedule_open + 尝试生成一只
    recorded.spawnAttempts = 0
    local beforeOpen = #recorded.sql
    setNow(insideWeekday)
    scheduleTick(0, 1000, 0)
    assertTrue(recorded.spawnAttempts == 1, "进入时间段 tick 补生成一只 Boss（桩生成失败也算尝试）")

    local openEvent, openPersisted = false, false
    for index = beforeOpen + 1, #recorded.sql do
        local sql = recorded.sql[index].sql
        if sql:find("schedule_open", 1, true) then openEvent = true end
        if sql:find("boss_activity_runtime", 1, true) and sql:find("'open'", 1, true) then openPersisted = true end
    end
    assertTrue(openEvent, "进入时间段写入 schedule_open 事件")
    assertTrue(openPersisted, "进入时间段把运行态写成 open")

    local openText = table.concat(runConsoleCommand("boss schedule"), " | ")
    assertTrue(openText:find("活动中", 1, true) ~= nil, ".boss schedule 报告当前在时间段内")

    -- 3) 同一段内重复 tick：不重复生成（30 秒重试）、不重复写事件
    recorded.spawnAttempts = 0
    local beforeSecondTick = #recorded.sql
    scheduleTick(0, 1000, 0)
    assertTrue(recorded.spawnAttempts == 0, "同一时间段内不会每秒重复生成（30 秒重试窗口）")
    local repeatedEvent = false
    for index = beforeSecondTick + 1, #recorded.sql do
        if recorded.sql[index].sql:find("schedule_open", 1, true) then repeatedEvent = true end
    end
    assertTrue(not repeatedEvent, "状态没翻转时不重复写 schedule_open 事件")

    -- 4) 离开时间段：写 schedule_close，运行态回到 closed，且残留的重生倒计时必须被收敛为 0
    recorded.spawnAttempts = 0
    local beforeClose = #recorded.sql
    setNow(outsideNight)
    -- 制造一个"上一次排重生留下的倒计时"：关窗分支必须把它清零（否则面板上停着一个永不到点的倒计时）
    local liveRuntimeState = bossLocal("bossRuntimeState")
    assertTrue(type(liveRuntimeState) == "table", "取到文件内 local bossRuntimeState（制造残留 respawn_at 用）")
    if type(liveRuntimeState) == "table" then liveRuntimeState.respawnAt = 4242 end
    scheduleTick(0, 1000, 0)
    assertTrue(recorded.spawnAttempts == 0, "离开时间段不会生成 Boss")
    if type(liveRuntimeState) == "table" then
        assertEq(liveRuntimeState.respawnAt, 0, "关窗分支把残留 respawn_at 收敛为 0（面板不会显示永不到点的倒计时）")
    end

    local closeEvent, closedAgain = false, false
    for index = beforeClose + 1, #recorded.sql do
        local sql = recorded.sql[index].sql
        if sql:find("schedule_close", 1, true) then closeEvent = true end
        if sql:find("boss_activity_runtime", 1, true) and sql:find("'closed'", 1, true) then closedAgain = true end
    end
    assertTrue(closeEvent, "离开时间段写入 schedule_close 事件")
    assertTrue(closedAgain, "离开时间段把运行态写回 closed")

    -- 5) 生成门控：时段外 .boss spawn 被拒；spawn force 放行
    setNow(outsideNight)
    recorded.spawnAttempts = 0
    local blockedMarkers, blockedText = markersOf(runConsoleCommand("boss spawn"))
    assertTrue(blockedMarkers:find("AGMP_ERROR", 1, true) ~= nil, "时段外 .boss spawn 返回 AGMP_ERROR")
    assertTrue(blockedText:find("定时启停", 1, true) ~= nil, "时段外 .boss spawn 的回复里说明是定时计划拦下的")
    assertTrue(recorded.spawnAttempts == 0, "时段外 .boss spawn 不会真的生成")

    recorded.spawnAttempts = 0
    runConsoleCommand("boss spawn force")
    assertTrue(recorded.spawnAttempts == 1, ".boss spawn force 绕过定时计划（调试用）")
end
end

-- ------------------------------------------------- 技能池随机（每次刷新抽一套预设）
-- 三件事必须成立：
--   1) 两个新配置列真的进了扩展表建表 / 引导写入（面板读同一份描述表）；
--   2) 开启后每次生成都从池子里抽（每次都在池内，且多次生成会抽到不同的预设）；
--   3) 关闭后生成不再抽签（固定用当前预设），命令行开关会写回扩展表。
io.write("\n== 技能池随机（每次刷新抽一套预设） ==\n")
do
local skillRandomColumns = { "skill_preset_random_enabled", "skill_preset_pool_text" }
for _, column in ipairs(skillRandomColumns) do
    if extCreateSql then
        assertTrue(extCreateSql:find("`" .. column .. "`", 1, true) ~= nil,
            "扩展表建表语句含技能池随机列 " .. column)
    end
    if extInsertSql then
        assertTrue(extInsertSql:find("`" .. column .. "`", 1, true) ~= nil,
            "扩展表引导写入含技能池随机列 " .. column)
    end
end

local skillRandomText = showGroup("skill_random")
assertTrue(skillRandomText:find("skill_preset_random_enabled (skillPresetRandomEnabled) = true", 1, true) ~= nil,
    "技能池随机开关取自 ext 表")
assertTrue(skillRandomText:find("ember_storm, frost_whiteout", 1, true) ~= nil,
    "随机池文本取自 ext 表（逗号 + 空格写法原样保留，解析由脚本负责）")

local function currentPresetKey()
    local text = table.concat(runConsoleCommand("boss preset list"), " | ")
    return text:match("当前技能池预设: ([%w_]+)%(")
end
assertTrue(currentPresetKey() ~= nil, ".boss preset list 能读出当前预设 key（随机断言依赖它）")

-- 抽 20 次：每次都必须落在池里（池外的默认预设 spellbreak_bulwark 绝不能出现），
-- 且两套预设都要出现过（否则说明"随机"退化成了固定第一套）
setNow(os.time{year = 2026, month = 9, day = 1, hour = 23, min = 0, sec = 0})
local poolHits, poolMisses = {}, {}
for _ = 1, 20 do
    runConsoleCommand("boss spawn force")
    local key = currentPresetKey()
    if key == "ember_storm" or key == "frost_whiteout" then
        poolHits[key] = true
    else
        poolMisses[#poolMisses + 1] = tostring(key)
    end
end
assertTrue(#poolMisses == 0, "开启随机后每次生成都从池里抽预设" ..
    (#poolMisses > 0 and ("（出现池外值: " .. table.concat(poolMisses, ",") .. "）") or ""))
assertTrue(poolHits.ember_storm == true and poolHits.frost_whiteout == true,
    "20 次生成抽到池内两套不同预设（不是固定第一套）")

-- 关闭随机：写回扩展表，之后的生成不再抽签（固定用 GM 指定的那套）
local randomOffMarkers = markersOf(runConsoleCommand("boss preset random off"))
assertTrue(randomOffMarkers:find("AGMP_OK", 1, true) ~= nil, ".boss preset random off 返回 AGMP_OK")
local skillRandomOffText = showGroup("skill_random")
assertTrue(skillRandomOffText:find("skill_preset_random_enabled (skillPresetRandomEnabled) = false", 1, true) ~= nil,
    "关闭随机后写回扩展表（.boss config show 立即反映，无需重启）")

local lockedPresetKey = "storm_siege"
runConsoleCommand("boss preset " .. lockedPresetKey)
local fixedViolations = {}
for _ = 1, 5 do
    runConsoleCommand("boss spawn force")
    local key = currentPresetKey()
    if key ~= lockedPresetKey then fixedViolations[#fixedViolations + 1] = tostring(key) end
end
assertTrue(#fixedViolations == 0, "关闭随机后生成不再抽签（固定 " .. lockedPresetKey .. "）" ..
    (#fixedViolations > 0 and ("（出现: " .. table.concat(fixedViolations, ",") .. "）") or ""))

-- 关闭随机后必须回到「配置的默认预设」，不能沿用上一次抽签结果
-- （命令关掉随机时不会触发 config reload，所以这条只能由生成前的那次检查保证）
local configuredPreset = lockedPresetKey
runConsoleCommand("boss preset random on")
runConsoleCommand("boss preset pool ember_storm,frost_whiteout")   -- 池里故意不含 storm_siege
local drewSomethingElse = false
for _ = 1, 10 do
    runConsoleCommand("boss spawn force")
    if currentPresetKey() ~= configuredPreset then drewSomethingElse = true break end
end
assertTrue(drewSomethingElse, "池里不含默认预设时，抽签会抽到别的预设（构造回归场景）")
runConsoleCommand("boss preset random off")
runConsoleCommand("boss spawn force")
assertTrue(currentPresetKey() == configuredPreset,
    "关闭随机后生成回到配置的默认预设（" .. configuredPreset .. "），而不是沿用抽签结果")

-- 池子：all/clear = 清空（= 全部预设）；非法 key 直接拒绝，不静默改池
local poolAllText = table.concat(runConsoleCommand("boss preset pool all"), " | ")
assertTrue(poolAllText:find("storm_siege", 1, true) ~= nil
    and poolAllText:find("spellbreak_bulwark", 1, true) ~= nil,
    ".boss preset pool all 清空池子 = 使用全部预设")
local badPoolMarkers = markersOf(runConsoleCommand("boss preset pool nonsense_preset"))
assertTrue(badPoolMarkers:find("AGMP_ERROR", 1, true) ~= nil, ".boss preset pool <非法 key> 返回 AGMP_ERROR")

-- 恢复成 ext 快照里的状态（后面的多区绑定段会 boss config reload，快照值会盖回来，这里只是保持一致）
runConsoleCommand("boss preset random on")
runConsoleCommand("boss preset pool ember_storm,frost_whiteout")

-- ------------------------------------------------- 技能池 / 连招内容（静态不变量 + 真实加载缩放）
-- 「技能池随机」段只保证抽出来的预设合法；这里回归的是**池与连招的内容本身**：
--   1) 连招里声明的每个法术都必须出现在同一预设的 skillPools 里（否则实发时会打出"池外法术"）；
--   2) 连招 phase 非空且 ⊆{1,2,3}，且至少有一个法术落在它声明阶段的池里；
--   3) 条目自检（spellId>0 / target∈{victim,self} / name 非空）；池恰好覆盖 1/2/3 且每池非空；
--   4) 连招名跨预设全局唯一；每个预设至少 MIN_COMBOS_PER_PRESET 条；每条连招都有连招喊话；
--   5) 真的走 ApplySkillPreset / ApplySkillDifficulty（4 档 × 全部预设）后**现取**缩放结果，
--      确认冷却/概率落在设计区间，且难度偏移没有被 ClampNumber(...,10,80) 静默钳掉。
-- 这些内容全是文件内 local，只能按名字从闭包链上取（见上方"文件内 local 的取样通道"）。
io.write("\n== 技能池 / 连招内容（静态不变量 + 真实加载缩放） ==\n")

local skillPresetLibrary = bossLocal("SKILL_PRESET_LIBRARY")
local skillDifficultyLibrary = bossLocal("SKILL_DIFFICULTY_LIBRARY")
local applySkillPreset = bossLocal("ApplySkillPreset")
local applySkillDifficulty = bossLocal("ApplySkillDifficulty")
local bossConfigTree = bossLocal("BOSS_CONFIG")

assertTrue(type(skillPresetLibrary) == "table" and next(skillPresetLibrary) ~= nil,
    "按名字取到文件内 local SKILL_PRESET_LIBRARY（debug.getupvalue 走已注册回调的闭包链）")
assertTrue(type(skillDifficultyLibrary) == "table" and next(skillDifficultyLibrary) ~= nil,
    "按名字取到 SKILL_DIFFICULTY_LIBRARY")
assertTrue(type(applySkillPreset) == "function" and type(applySkillDifficulty) == "function",
    "按名字取到 ApplySkillPreset / ApplySkillDifficulty（缩放断言走真实函数）")
assertTrue(type(bossConfigTree) == "table" and type(bossConfigTree.combatTaunts) == "table",
    "按名字取到 BOSS_CONFIG（连招喊话断言用运行时配置树）")

local function faultText(list)
    if #list == 0 then return "" end
    return "（" .. table.concat(list, "；", 1, math.min(#list, 6)) .. (#list > 6 and " …" or "") .. "）"
end

-- 预设 key 排序后逐个检查：不写死 6 套，内容扩充后自动覆盖新预设
local presetKeys = {}
if type(skillPresetLibrary) == "table" then
    for presetKey in pairs(skillPresetLibrary) do presetKeys[#presetKeys + 1] = presetKey end
end
table.sort(presetKeys, function(left, right) return tostring(left) < tostring(right) end)
assertTrue(#presetKeys > 0, "技能池预设表非空（当前 " .. #presetKeys .. " 套）")

local comboNameOwner = {}
local poolFaults, entryFaults, poolSpellFaults, phaseFaults = {}, {}, {}, {}
local phaseCoverFaults, openingFaults, comboNameFaults, thinPresets = {}, {}, {}, {}
local comboTotal = 0

for _, presetKey in ipairs(presetKeys) do
    local preset = skillPresetLibrary[presetKey]
    local pools = type(preset) == "table" and preset.skillPools or nil
    local combos = type(preset) == "table" and preset.comboChains or nil
    local openings = type(preset) == "table" and preset.openingSkills or nil

    -- 池：恰好覆盖 1/2/3 三个阶段，且每池非空
    local poolPhases = {}
    if type(pools) == "table" then
        for phase in pairs(pools) do poolPhases[#poolPhases + 1] = tostring(phase) end
    end
    table.sort(poolPhases)
    local poolShapeOk = type(pools) == "table" and #poolPhases == 3
        and poolPhases[1] == "1" and poolPhases[2] == "2" and poolPhases[3] == "3"
    if not poolShapeOk then
        poolFaults[#poolFaults + 1] = string.format("%s(阶段=%s)", tostring(presetKey), table.concat(poolPhases, "/"))
    end

    local poolSpellIds, spellPoolPhases, poolSpellCount, openingCount = {}, {}, 0, 0
    for phase = 1, 3 do
        local phasePool = type(pools) == "table" and pools[phase] or nil
        if type(phasePool) == "table" then
            if #phasePool == 0 then
                poolFaults[#poolFaults + 1] = string.format("%s(阶段%d空)", tostring(presetKey), phase)
            end
            for _, skill in ipairs(phasePool) do
                poolSpellCount = poolSpellCount + 1
                if type(skill) ~= "table" then
                    entryFaults[#entryFaults + 1] = tostring(presetKey) .. "/池" .. phase .. " 非表条目"
                else
                    local spellId = tonumber(skill.spellId) or 0
                    if spellId <= 0 then
                        entryFaults[#entryFaults + 1] = string.format("%s/池%d spellId=%s", tostring(presetKey), phase, tostring(skill.spellId))
                    end
                    if skill.target ~= "victim" and skill.target ~= "self" then
                        entryFaults[#entryFaults + 1] = string.format("%s/池%d(spellId %d) target=%s", tostring(presetKey), phase, spellId, tostring(skill.target))
                    end
                    if type(skill.name) ~= "string" or skill.name == "" then
                        entryFaults[#entryFaults + 1] = string.format("%s/池%d(spellId %d) 缺 name", tostring(presetKey), phase, spellId)
                    end
                    if spellId > 0 then
                        poolSpellIds[spellId] = true
                        spellPoolPhases[spellId] = spellPoolPhases[spellId] or {}
                        spellPoolPhases[spellId][phase] = true
                    end
                end
            end
        elseif poolShapeOk then
            poolFaults[#poolFaults + 1] = string.format("%s(阶段%d非表)", tostring(presetKey), phase)
        end
    end

    -- 连招：每个法术都要在同预设的池里；阶段声明 / 阶段覆盖 / 命名 / 条数
    local presetComboCount, coveredPhases = 0, {}
    for _, combo in ipairs(combos or {}) do
        presetComboCount = presetComboCount + 1
        local comboLabel = string.format("%s/%s", tostring(presetKey),
            tostring(type(combo) == "table" and combo.name or "?"))
        if type(combo) ~= "table" then
            phaseFaults[#phaseFaults + 1] = comboLabel .. " 非表条目"
        else
            if type(combo.name) ~= "string" or combo.name == "" then
                comboNameFaults[#comboNameFaults + 1] = tostring(presetKey) .. " 第 " .. presetComboCount .. " 条缺 name"
            else
                local owner = comboNameOwner[combo.name]
                if owner ~= nil then
                    comboNameFaults[#comboNameFaults + 1] = string.format("%s（%s 与 %s 重复）", combo.name, owner, tostring(presetKey))
                else
                    comboNameOwner[combo.name] = presetKey
                end
            end

            local declaredPhases, phaseOk = {}, false
            if type(combo.phase) == "table" and #combo.phase > 0 then
                phaseOk = true
                for _, phase in ipairs(combo.phase) do
                    local numericPhase = tonumber(phase)
                    if numericPhase == 1 or numericPhase == 2 or numericPhase == 3 then
                        declaredPhases[numericPhase] = true
                    else
                        phaseOk = false
                    end
                end
            end
            if not phaseOk then
                phaseFaults[#phaseFaults + 1] = comboLabel .. " phase 非空且 ⊆{1,2,3} 不成立"
            end

            local skills = combo.skills
            if type(skills) ~= "table" or #skills == 0 then
                poolSpellFaults[#poolSpellFaults + 1] = comboLabel .. " 没有 skills"
            else
                local spellInDeclaredPhase = false
                for skillIndex, skillInfo in ipairs(skills) do
                    local spellId = type(skillInfo) == "table" and tonumber(skillInfo[1]) or nil
                    local targetType = type(skillInfo) == "table" and skillInfo[2] or nil
                    if spellId == nil or not poolSpellIds[spellId] then
                        poolSpellFaults[#poolSpellFaults + 1] = string.format("%s 第%d个法术 %s 不在 %s 的池里",
                            comboLabel, skillIndex, tostring(spellId), tostring(presetKey))
                    else
                        for phase in pairs(declaredPhases) do
                            if (spellPoolPhases[spellId] or {})[phase] then spellInDeclaredPhase = true end
                        end
                    end
                    if targetType ~= "victim" and targetType ~= "self" then
                        phaseFaults[#phaseFaults + 1] = string.format("%s 第%d个法术 target=%s",
                            comboLabel, skillIndex, tostring(targetType))
                    end
                end
                if phaseOk and not spellInDeclaredPhase then
                    phaseFaults[#phaseFaults + 1] = comboLabel .. " 没有法术出现在它声明阶段的池里"
                end
            end

            for phase in pairs(declaredPhases) do coveredPhases[phase] = true end
        end
    end

    if presetComboCount < MIN_COMBOS_PER_PRESET then
        thinPresets[#thinPresets + 1] = string.format("%s(%d)", tostring(presetKey), presetComboCount)
    end
    for phase = 1, 3 do
        if not coveredPhases[phase] then
            phaseCoverFaults[#phaseCoverFaults + 1] = string.format("%s(阶段%d)", tostring(presetKey), phase)
        end
    end

    -- 开场技能：spellId>0 / target 合法 / 法术在池里
    if type(openings) ~= "table" or #openings == 0 then
        openingFaults[#openingFaults + 1] = tostring(presetKey) .. " 没有 openingSkills"
    else
        for _, opening in ipairs(openings) do
            openingCount = openingCount + 1
            local openingSpellId = type(opening) == "table" and tonumber(opening.spellId) or nil
            if openingSpellId == nil or openingSpellId <= 0 or not poolSpellIds[openingSpellId] then
                openingFaults[#openingFaults + 1] = string.format("%s 开场法术 %s 不在池里",
                    tostring(presetKey), tostring(openingSpellId))
            end
            if type(opening) ~= "table" or (opening.target ~= "victim" and opening.target ~= "self") then
                openingFaults[#openingFaults + 1] = string.format("%s 开场 target=%s", tostring(presetKey),
                    tostring(type(opening) == "table" and opening.target or nil))
            end
        end
    end

    comboTotal = comboTotal + presetComboCount
    io.write(string.format("  [info] 预设 %-19s 池法术 %2d / 连招 %d 条 / 开场技能 %d 个\n",
        tostring(presetKey), poolSpellCount, presetComboCount, openingCount))
end

assertTrue(#poolFaults == 0, "每个预设的 1/2/3 技能池都存在、结构齐全且非空" .. faultText(poolFaults))
assertTrue(#entryFaults == 0, "池条目标自检（spellId>0 / target∈{victim,self} / name 非空）" .. faultText(entryFaults))
assertTrue(#poolSpellFaults == 0,
    string.format("连招里的每个法术 ID 都在同一预设的池内（%d 条连招，核心不变量）", comboTotal) .. faultText(poolSpellFaults))
assertTrue(#phaseFaults == 0, "连招 phase 非空且 ⊆{1,2,3}，且至少有一个法术落在它声明阶段的池里" .. faultText(phaseFaults))
assertTrue(#phaseCoverFaults == 0, "每个预设的 1/2/3 阶段都被至少一条连招覆盖" .. faultText(phaseCoverFaults))
assertTrue(#openingFaults == 0, "开场技能 spellId / target 合法且都取自同预设的池" .. faultText(openingFaults))
assertTrue(#comboNameFaults == 0, "连招名全局唯一（跨预设也不重复）" .. faultText(comboNameFaults))
assertTrue(#thinPresets == 0,
    string.format("每个预设至少 %d 条连招（顶部常量 MIN_COMBOS_PER_PRESET，内容扩充后改这一处）", MIN_COMBOS_PER_PRESET)
    .. faultText(thinPresets))

-- 连招喊话：**文件内默认库**必须覆盖每一条连招名（硬断言）。
-- 运行时那一份会被扩展表列 taunt_combo_yells_text 整体替换，而快照里只给了 1 条假 key
-- （smoke.lua 的 EXT_VALUES），硬断言会一片假失败，所以运行时那份只输出 [info]。
local defaultComboYells = withDefaultConfig(function(childCallbacks)
    local childConfig = bossLocal("BOSS_CONFIG", childCallbacks)
    if type(childConfig) == "table" and type(childConfig.combatTaunts) == "table" then
        return childConfig.combatTaunts.comboYells
    end
    return nil
end)

assertTrue(type(defaultComboYells) == "table", "默认配置副本里取到文件内默认的 comboYells")
local defaultYellCount, missingDefaultYells = 0, {}
if type(defaultComboYells) == "table" then
    for _ in pairs(defaultComboYells) do defaultYellCount = defaultYellCount + 1 end
    for name in pairs(comboNameOwner) do
        local yell = defaultComboYells[name]
        if type(yell) ~= "string" or yell == "" then
            missingDefaultYells[#missingDefaultYells + 1] = tostring(name)
        end
    end
end
assertTrue(#missingDefaultYells == 0,
    string.format("文件内默认库的连招喊话覆盖全部 %d 条连招名（默认库共 %d 条喊话）", comboTotal, defaultYellCount)
    .. faultText(missingDefaultYells))

local runtimeComboYells = type(bossConfigTree) == "table" and type(bossConfigTree.combatTaunts) == "table"
    and bossConfigTree.combatTaunts.comboYells or nil
local runtimeYellCovered = 0
if type(runtimeComboYells) == "table" then
    for name in pairs(comboNameOwner) do
        if type(runtimeComboYells[name]) == "string" and runtimeComboYells[name] ~= "" then
            runtimeYellCovered = runtimeYellCovered + 1
        end
    end
end
io.write(string.format("  [info] 运行时 comboYells 覆盖 %d/%d 条连招（DB 快照只有 1 条假 key，属预期；硬断言走默认库）\n",
    runtimeYellCovered, comboTotal))

-- 真实加载缩放：4 档难度 × 全部预设，走 ApplySkillPreset / ApplySkillDifficulty 后现取缩放结果
if type(applySkillPreset) == "function" and type(applySkillDifficulty) == "function" and #presetKeys > 0 then
    local restorePresetKey = bossLocal("ACTIVE_SKILL_PRESET_KEY")
    local restoreDifficultyKey = bossLocal("ACTIVE_SKILL_DIFFICULTY_KEY")
    assertTrue(restorePresetKey ~= nil and restoreDifficultyKey ~= nil,
        "取到当前生效的预设 key / 难度 key（缩放断言结束后要复原现场）")

    local difficultyKeys = {}
    if type(skillDifficultyLibrary) == "table" then
        for key in pairs(skillDifficultyLibrary) do difficultyKeys[#difficultyKeys + 1] = key end
    end
    table.sort(difficultyKeys, function(left, right) return tostring(left) < tostring(right) end)

    local scaleFaults, chanceFaults, clampFaults, formulaFaults, poolCdFaults = {}, {}, {}, {}, {}
    local pairCount, chainCount, clampCount = 0, 0, 0
    local ranges = {}

    for _, difficultyKey in ipairs(difficultyKeys) do
        for _, presetKey in ipairs(presetKeys) do
            pairCount = pairCount + 1
            applySkillPreset(presetKey)
            applySkillDifficulty(difficultyKey)

            local difficulty = skillDifficultyLibrary[difficultyKey]
            local offset = tonumber(difficulty and difficulty.comboChanceOffset) or 0
            local rawCombos = type(skillPresetLibrary[presetKey]) == "table"
                and skillPresetLibrary[presetKey].comboChains or nil
            local scaledChains = scaledComboChains()
            local scaledPools = scaledSkillPools()
            local range = ranges[difficultyKey]
                or { minCD = nil, maxCD = nil, minChance = nil, maxChance = nil, clamped = 0 }
            ranges[difficultyKey] = range

            for index, combo in ipairs(scaledChains or {}) do
                chainCount = chainCount + 1
                local label = string.format("%s/%s/%s", tostring(difficultyKey), tostring(presetKey), tostring(combo.name))

                local cooldown = tonumber(combo.cooldown) or 0
                if cooldown < 4 then
                    scaleFaults[#scaleFaults + 1] = string.format("%s cooldown=%s <4（ScaleCooldown 下限）",
                        label, tostring(combo.cooldown))
                end
                if cooldown < 10 or cooldown > 45 then
                    scaleFaults[#scaleFaults + 1] = string.format("%s cooldown=%s ∉10..45", label, tostring(combo.cooldown))
                end
                if range.minCD == nil or cooldown < range.minCD then range.minCD = cooldown end
                if range.maxCD == nil or cooldown > range.maxCD then range.maxCD = cooldown end

                local chance = tonumber(combo.triggerChance)
                if chance == nil or chance < 10 or chance > 80 then
                    chanceFaults[#chanceFaults + 1] = string.format("%s triggerChance=%s ∉10..80",
                        label, tostring(combo.triggerChance))
                end
                if chance ~= nil then
                    if range.minChance == nil or chance < range.minChance then range.minChance = chance end
                    if range.maxChance == nil or chance > range.maxChance then range.maxChance = chance end
                end

                local rawCombo = type(rawCombos) == "table" and rawCombos[index] or nil
                local rawChance = type(rawCombo) == "table" and (tonumber(rawCombo.triggerChance) or 30) or 30
                local rawShifted = rawChance + offset
                if rawShifted < 10 or rawShifted > 80 then
                    clampCount = clampCount + 1
                    range.clamped = range.clamped + 1
                    clampFaults[#clampFaults + 1] = string.format(
                        "%s raw %d + comboChanceOffset %d = %d ∉10..80（会被 ClampNumber 静默钳制）",
                        label, rawChance, offset, rawShifted)
                elseif chance ~= rawShifted then
                    formulaFaults[#formulaFaults + 1] = string.format("%s 缩放后 %s ≠ raw %d + offset %d",
                        label, tostring(combo.triggerChance), rawChance, offset)
                end
            end

            for phase = 1, 3 do
                local phasePool = type(scaledPools) == "table" and scaledPools[phase] or nil
                for _, skill in ipairs(phasePool or {}) do
                    local minCD, maxCD = tonumber(skill.minCD), tonumber(skill.maxCD)
                    if minCD == nil or minCD < 4 or maxCD == nil or maxCD < minCD then
                        poolCdFaults[#poolCdFaults + 1] = string.format("%s/%s/阶段%d spellId %s CD %s..%s",
                            tostring(difficultyKey), tostring(presetKey), phase, tostring(skill.spellId),
                            tostring(skill.minCD), tostring(skill.maxCD))
                    end
                end
            end
        end
    end

    assertTrue(pairCount == #difficultyKeys * #presetKeys,
        string.format("缩放断言覆盖 %d 档难度 × %d 套预设 = %d 组（%d 条连招）",
            #difficultyKeys, #presetKeys, pairCount, chainCount))
    assertTrue(#scaleFaults == 0, "缩放后连招冷却 ≥4 且落在 10..45" .. faultText(scaleFaults))
    assertTrue(#chanceFaults == 0, "缩放后连招触发概率落在 10..80" .. faultText(chanceFaults))
    assertTrue(#clampFaults == 0,
        string.format("raw triggerChance + comboChanceOffset 本身就在 10..80 内（没被 ClampNumber 钳制：钳制 %d 条）", clampCount)
        .. faultText(clampFaults))
    assertTrue(#formulaFaults == 0, "难度偏移真的生效（缩放后 triggerChance == raw + offset）" .. faultText(formulaFaults))
    assertTrue(#poolCdFaults == 0, "缩放后技能池冷却 ≥4 且 minCD ≤ maxCD" .. faultText(poolCdFaults))

    for _, difficultyKey in ipairs(difficultyKeys) do
        local range = ranges[difficultyKey]
        if range and range.minCD ~= nil then
            io.write(string.format("  [info] %-9s 缩放区间: 冷却 %s..%s / 概率 %s..%s（钳制 %d 条）\n",
                tostring(difficultyKey), tostring(range.minCD), tostring(range.maxCD),
                tostring(range.minChance), tostring(range.maxChance), range.clamped))
        end
    end

    -- 复原现场：后面的奖池实发段 / 连招施放段仍在同一个父副本里跑，不能被缩放断言改掉预设
    if restorePresetKey ~= nil and restoreDifficultyKey ~= nil then
        applySkillPreset(restorePresetKey)
        applySkillDifficulty(restoreDifficultyKey)
    end
    assertEq(bossLocal("ACTIVE_SKILL_PRESET_KEY"), restorePresetKey, "缩放断言结束后预设复原")
    assertEq(bossLocal("ACTIVE_SKILL_DIFFICULTY_KEY"), restoreDifficultyKey, "缩放断言结束后难度复原")
    local restoredChains = scaledComboChains()
    assertTrue(type(restoredChains) == "table" and #restoredChains > 0, "复原后缩放连招表仍非空")
end
end

-- ------------------------------------------------- 奖池（boss_reward_pools 表驱动）
-- 三件事必须成立：
--   1) 36 个 reward_pool_N_* 描述列彻底消失（ext 建表 / 引导写入都不再有它们，见上面 == 扩展表 == 一节）；
--   2) 旧奖励模型的 13 个列从主表 DROP 掉，建表语句里也不再有它们；
--   3) 没有本区奖池数据时回退出厂默认（来源 code），有数据时一律以表为准（.boss pools 与结算都读同一份）。
io.write("\n== 奖池（表驱动） ==\n")

-- 旧奖励模型的列必须被 DROP（连数据一起删）
local legacyColumns = {
    "guaranteed_reward_enabled", "guaranteed_reward_notify", "max_random_reward_players",
    "class_reward_chance", "formula_reward_chance", "mount_reward_chance",
    "guaranteed_item_id", "guaranteed_item_count", "gold_min_copper", "gold_max_copper",
    "reward_items_text", "reward_formulas_text", "reward_mounts_text",
}
local droppedColumns, notDropped = {}, {}
for _, item in ipairs(recorded.sql) do
    for _, column in ipairs(legacyColumns) do
        if item.sql:find("DROP COLUMN `" .. column .. "`", 1, true) then
            droppedColumns[column] = true
        end
    end
end
for _, column in ipairs(legacyColumns) do
    if not droppedColumns[column] then notDropped[#notDropped + 1] = column end
end
assertTrue(#notDropped == 0, "旧奖励模型的 " .. #legacyColumns .. " 个列全部被 DROP" ..
    (#notDropped > 0 and ("（未删: " .. table.concat(notDropped, ",") .. "）") or ""))

-- 主表建表语句里不能再出现旧奖励列
local mainCreateSql = nil
for _, item in ipairs(recorded.sql) do
    if item.kind == "query" and item.sql:find("CREATE TABLE IF NOT EXISTS", 1, true) and isMainConfigSql(item.sql) then
        mainCreateSql = item.sql
    end
end
assertTrue(mainCreateSql ~= nil, "拿到主表建表语句")
if mainCreateSql then
    local stillThere = {}
    for _, column in ipairs(legacyColumns) do
        if mainCreateSql:find("`" .. column .. "`", 1, true) then stillThere[#stillThere + 1] = column end
    end
    assertTrue(#stillThere == 0, "主表建表语句里已无旧奖励列" ..
        (#stillThere > 0 and ("（仍有: " .. table.concat(stillThere, ",") .. "）") or ""))
    assertTrue(mainCreateSql:find("`random_reward_mode`", 1, true) ~= nil
        and mainCreateSql:find("`damage_weight`", 1, true) ~= nil
        and mainCreateSql:find("`participation_range`", 1, true) ~= nil,
        "主表仍保留选人相关列（random_reward_mode / participation_range / *_weight）")
end

-- reward 组只剩"谁算有效参战 / 怎么抽人" + 两个结算口径开关
local rewardText = showGroup("reward")
assertTrue(rewardText:find("participation_range (participationRange) = 80", 1, true) ~= nil,
    "reward 组仍显示有效参与范围")
assertTrue(rewardText:find("guaranteed_reward_enabled", 1, true) == nil
    and rewardText:find("reward_items_text", 1, true) == nil
    and rewardText:find("gold_min_copper", 1, true) == nil
    and rewardText:find("reward_pool_1", 1, true) == nil,
    "reward 组不再包含旧奖励字段与 6 个奖池字段（保底 / 基础池 / 金币 / reward_pool_N）")

-- 职业奖励池映射保留（奖池的 classFilter 依赖它）
assertTrue(showGroup("class_reward"):find("class_reward_items_text", 1, true) ~= nil,
    "职业过滤映射（class_reward_items_text）仍在配置里（奖池的 classFilter 依赖它）")
assertTrue(extInsertSql ~= nil and extInsertSql:find("`class_reward_items_text`", 1, true) ~= nil,
    "职业奖励池映射仍参与引导写入")

-- ------------------------------------------------ 奖池运行期来源（没有表数据 → 回退出厂默认）
-- REWARD_POOLS_SOURCE 在 boss.lua 里可能是文件内 local（按上值名取样），也可能是全局（落在 env 表里）
local function rewardPoolsSource()
    local localValue = bossLocal("REWARD_POOLS_SOURCE")
    if localValue ~= nil then return localValue end
    return rawget(env, "REWARD_POOLS_SOURCE")
end

local rewardPools = bossLocal("REWARD_POOLS")
assertTrue(type(rewardPools) == "table", "取到文件内 local REWARD_POOLS（运行期奖池表）")
assertEq(rewardPoolsSource(), "code",
    "读不到 boss_reward_pools 数据时来源标记为 code（回退出厂默认，活动不会因配置表异常停摆）")

local poolSourceLog = findLogLine("[奖池]")
assertTrue(poolSourceLog ~= nil, "奖池来源会写进日志（" .. tostring(poolSourceLog) .. "）")
assertTrue(poolSourceLog ~= nil and poolSourceLog:find("回退出厂默认", 1, true) ~= nil,
    "回退路径的日志说明了原因（表里没有本区数据）")

if type(rewardPools) == "table" then
    assertEq(#rewardPools, 6, "出厂默认奖池 6 个（REWARD_POOL_DEFAULTS）")
    local defaultPoolNames = {}
    for _, pool in ipairs(rewardPools) do defaultPoolNames[#defaultPoolNames + 1] = tostring(pool.name) end
    assertTrue(table.concat(defaultPoolNames, ","):find("全员奖", 1, true) ~= nil
        and table.concat(defaultPoolNames, ","):find("坐骑奖池", 1, true) ~= nil,
        "出厂默认池名齐全（" .. table.concat(defaultPoolNames, ",") .. "）")
end

-- `.boss pools`：来源 + 位号契约 + 每池一行
local poolsText = table.concat(runConsoleCommand("boss pools"), " | ")
assertTrue(poolsText:find("来源: code", 1, true) ~= nil, ".boss pools 报告来源 code（面板可据此提示迁移）")
assertTrue(poolsText:find("全员奖", 1, true) ~= nil, ".boss pools 列出生效池（含池名）")
assertTrue(poolsText:find("位号 = 贡献位图第 (位号-1) 位", 1, true) ~= nil,
    ".boss pools 说明位号 → 位图的契约（pool_id = k ↔ 第 k-1 位）")

-- 位号 → 位图掩码：2^(pool_id-1)，不是写死的 1..6 位
local getRewardPoolMask = rawget(env, "GetRewardPoolMask")
assertTrue(type(getRewardPoolMask) == "function", "取到 GetRewardPoolMask（位号 → 位图掩码）")
if type(getRewardPoolMask) == "function" then
    assertEq(getRewardPoolMask(1), 1, "pool_id=1 → 2^0 = 1")
    assertEq(getRewardPoolMask(6), 32, "pool_id=6 → 2^5 = 32（旧设计的最后一个池）")
    assertEq(getRewardPoolMask(7), 64, "pool_id=7 → 2^6 = 64（证明位映射不是写死的 1..6）")
    assertEq(getRewardPoolMask(31), 2 ^ 30, "pool_id=31 → 2^30（高位仍按 pool_id-1 映射）")
    assertEq(getRewardPoolMask(0), 0, "pool_id=0 非法 → 掩码 0（不置位）")
    assertEq(getRewardPoolMask(999), 0, "pool_id 超上限 → 掩码 0（不置位）")

    local maxPools = bossLocal("BOSS_MAX_REWARD_POOLS")
    assertTrue(tonumber(maxPools) ~= nil, "取到文件内 local BOSS_MAX_REWARD_POOLS（位图上限）")
    if tonumber(maxPools) ~= nil then
        assertEq(getRewardPoolMask(maxPools), 2 ^ (maxPools - 1),
            "最大位号的掩码 = 2^(BOSS_MAX_REWARD_POOLS-1)")
        io.write(string.format(
            "  [info] BOSS_MAX_REWARD_POOLS = %s；pool_id=32 的掩码 = %s（位图列是有符号 INT，第 32 位会溢出成负数）\n",
            tostring(maxPools), tostring(getRewardPoolMask(32))))
    end
end

-- 诊断（不改结论）：表在、但本区一行都没有（0 行结果集）时的行为。
-- 读出的是"空结果集"，而 ReadRewardPoolsFromQuery 对非 nil 的 query 总会先读一次首行 → 会产出一个
-- pool_id=0 的条目，于是 #pools > 0 成立、播种分支（要求 #pools == 0）永远进不去。
recorded.rewardPoolRows = {}
runConsoleCommand("boss config reload")
local zeroRowPools = bossLocal("REWARD_POOLS")
io.write(string.format(
    "  [info] boss_reward_pools 返回 0 行时：来源=%s，运行期池数=%s（播种/回落分支都要求 pools 为空，见报告）\n",
    tostring(rewardPoolsSource()), tostring(type(zeroRowPools) == "table" and #zeroRowPools or -1)))
recorded.rewardPoolRows = nil
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "code", "清空奖池结果集后来源又回到 code（回落分支可重复进入）")

-- ------------------------------------------------- 奖池实发（离线驱动：假 Boss + 假玩家）
-- 线上没有玩家时没法验证「真发奖 + 按职业过滤 + 金币 + 离线邮件」，这里用假对象把 OnBossDied 整条链路跑一遍：
--   · boss_reward_pools 的桩结果集故意乱序给出 7 个合法池（含 pool_id 7 / 31，就是**不落在 1..6** 的位号）
--     + 3 个非法池（pool_id 0 / 33 / 与 7 重复）→ 校验排序、丢弃告警与 2^(pool_id-1) 位图
--   · 职业奖励池映射改成 1=1001（战士专属）/ 8=1002（法师专属）
--   · 两名在线假玩家（战士 / 法师）各记一笔伤害进贡献池，然后触发死亡结算
-- 关键点：boss.lua 的 IsUnitValid 要求 type(unit)=="userdata"，所以本段临时改写 env.type()，
-- 并让 PerformIngameSpawn 返回假 Boss；段末恢复原样，避免影响后面的多区绑定断言。
io.write("\n== 奖池实发（离线驱动）==\n")

-- pool_id = 位号；sort_order 故意与 pool_id 顺序不同，用来证明展示/发奖顺序按 sort_order
local REWARD_POOL_IDS_IN_ORDER = { 2, 3, 1, 7, 4, 5, 31, 8 }
recorded.rewardPoolRows = rewardPoolRows({
    { pool_id = 31, sort_order = 70, name = "高位池", enabled = 1, chance = 100, winner_mode = "count",
      winner_count = 1, class_filter = 0, items_text = "6001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 1, sort_order = 30, name = "全体池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 9, class_filter = 1, items_text = "1001,1002", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 33, sort_order = 5, name = "越界池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "7001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 2, sort_order = 10, name = "单人池", enabled = 1, chance = 100, winner_mode = "count",
      winner_count = 1, class_filter = 1, items_text = "2001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 3, sort_order = 20, name = "战士池", enabled = 1, chance = 100, winner_mode = "count",
      winner_count = 2, class_filter = 1, items_text = "1001,9999", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 4, sort_order = 50, name = "关闭池A", enabled = 0, chance = 100, winner_mode = "all",
      winner_count = 5, class_filter = 1, items_text = "4001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 5, sort_order = 60, name = "关闭池B", enabled = 0, chance = 100, winner_mode = "count",
      winner_count = 5, class_filter = 1, items_text = "5001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    -- 金币池：没有物品、只有金币区间（离线补发与在线发放都要走金币通道）
    { pool_id = 7, sort_order = 40, name = "金币池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "", gold_min_copper = 5000, gold_max_copper = 5000, announce = 0 },
    -- 空池（无物品 + 金币 0/0）：必须"跳过"而不是报错，也不置位
    { pool_id = 8, sort_order = 80, name = "空池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 0, sort_order = 1, name = "零号池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "8001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
    { pool_id = 7, sort_order = 41, name = "重复位号池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "9001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
})
EXT_VALUES.class_reward_items_text = "1=1001\n8=1002"
local poolsLogBoundary = #recorded.logLines
local poolsReloadMarkers = markersOf(runConsoleCommand("boss config reload"))
assertTrue(poolsReloadMarkers:find("AGMP_OK", 1, true) ~= nil,
    "写入 boss_reward_pools 结果集后 boss config reload 返回 AGMP_OK")

-- 来源与顺序：以表为准（db），按 sort_order 排（pool_id 只做同序时的次级键）
assertEq(rewardPoolsSource(), "db", "读到 boss_reward_pools 行后来源标记为 db（不再回退出厂默认）")
local livePools = bossLocal("REWARD_POOLS")
assertTrue(type(livePools) == "table", "取到运行期 REWARD_POOLS（表驱动后的那份）")
if type(livePools) == "table" then
    local orderedIds = {}
    for _, pool in ipairs(livePools) do orderedIds[#orderedIds + 1] = tostring(pool.poolId) end
    assertEq(table.concat(orderedIds, ","), table.concat(REWARD_POOL_IDS_IN_ORDER, ","),
        "奖池按 sort_order 排序（与 pool_id 顺序不同：2→3→1→7→4→5→31→8）")
    assertEq(#livePools, #REWARD_POOL_IDS_IN_ORDER,
        "非法奖池全部被丢弃（pool_id 0 / 33 / 与 7 重复，共 3 个）")
    assertEq(livePools[4] and livePools[4].poolId, 7, "sort_order=40 的池就是 pool_id=7（排序生效）")
    local pool7 = livePools[4]
    assertTrue(pool7 ~= nil and pool7.poolId == 7 and pool7.name == "金币池" and pool7.announce == false,
        "pool_id=7 的池字段来自表（名/公告位解析正确）")
end

local droppedLog = findLogLine("[奖池]丢弃", poolsLogBoundary)
assertTrue(droppedLog ~= nil, "非法奖池会打告警日志（" .. tostring(droppedLog) .. "）")
assertTrue(droppedLog ~= nil and droppedLog:find("0", 1, true) ~= nil
    and droppedLog:find("33", 1, true) ~= nil and droppedLog:find("7", 1, true) ~= nil,
    "丢弃告警点名了 pool_id 0 / 33 / 重复的 7")

-- `.boss pools` 展示的是表里的行（来源 db + 池名 + 位号）
local dbPoolsText = table.concat(runConsoleCommand("boss pools"), " | ")
assertTrue(dbPoolsText:find("来源: db", 1, true) ~= nil, ".boss pools 报告来源 db")
assertTrue(dbPoolsText:find("金币池", 1, true) ~= nil and dbPoolsText:find("高位池", 1, true) ~= nil,
    ".boss pools 显示数据库里的池名（含 pool_id 7 / 31 这两个非 1..6 的池）")
assertTrue(dbPoolsText:find("#31", 1, true) ~= nil and dbPoolsText:find("#7", 1, true) ~= nil,
    ".boss pools 逐池打印位号（#7 / #31）")
assertTrue(dbPoolsText:find("越界池", 1, true) == nil, ".boss pools 不再展示被丢弃的越界池")


local fakePlayers = {}
local function newFakePlayer(guidLow, playerName, classId, usableItems, startCoinage)
    local player = {
        __fake = true,
        guidLow = guidLow,
        name = playerName,
        classId = classId,
        given = {},
        messages = {},
        -- 金币：ModifyMoney 在 mod-ale 里不返回成功标志，脚本按 GetCoinage 前后差判定
        coinage = tonumber(startCoinage) or 100000,
        goldOps = {},
    }
    player.IsInWorld = function() return true end
    player.IsPlayer = function() return true end
    player.GetName = function() return playerName end
    player.GetGUIDLow = function() return guidLow end
    -- 注意：GetPlayerByGUID 的桩按十进制查表，这里必须回十进制串（真实环境是 64 位 hex，桩里保持一致即可）
    player.GetGUID = function() return tostring(guidLow) end
    player.GetClass = function() return classId end
    player.GetAccountId = function() return 9000 + guidLow end
    player.GetMapId = function() return 571 end
    player.GetX = function() return 4108.16 end
    player.GetY = function() return 5316.85 end
    player.GetZ = function() return 28.76 end
    player.GetDistance = function() return 5 end
    player.CanUseItem = function(_, entry) return usableItems[entry] == true end
    player.AddItem = function(_, entry, count)
        table.insert(player.given, {entry = entry, count = count or 1})
        return {entry = entry}
    end
    player.GetCoinage = function() return player.coinage end
    player.ModifyMoney = function(_, amount)
        player.goldOps[#player.goldOps + 1] = amount
        player.coinage = player.coinage + amount
    end
    player.SendBroadcastMessage = function(_, message) table.insert(player.messages, message) end
    player.GetPlayersInRange = function() return {} end
    fakePlayers[guidLow] = player
    return player
end

-- 战士能用 1001/2001/6001；法师能用 1002/2001/6001；9999 谁都不能用
local warrior = newFakePlayer(501, "测试战士", 1, {[1001] = true, [2001] = true, [6001] = true})
local mage = newFakePlayer(502, "测试法师", 8, {[1002] = true, [2001] = true, [6001] = true})

local bossGuid = 777001
local fakeBoss = {
    __fake = true,
    IsInWorld = function() return true end,
    IsInCombat = function() return false end,
    IsAlive = function() return true end,
    GetGUIDLow = function() return bossGuid end,
    GetEntry = function() return 190090 end,
    GetName = function() return "送财童子" end,
    GetMapId = function() return 571 end,
    GetInstanceId = function() return 0 end,
    GetX = function() return 4108.16 end,
    GetY = function() return 5316.85 end,
    GetZ = function() return 28.76 end,
    GetO = function() return 0 end,
    GetMaxHealth = function() return 4392675 end,
    GetHealth = function() return 4392675 end,
    SetMaxHealth = function() end,
    SetHealth = function() end,
    SetLevel = function() end,
    SetScale = function() end,
    SetHomePosition = function() end,
    UpdateEntry = function() end,
    AddAura = function() end,
    RemoveAura = function() end,
    SendUnitYell = function() end,
    RemoveEvents = function() end,
    RegisterEvent = function() end,
    GetPlayersInRange = function() return {warrior, mage} end,
    GetDistance = function() return 5 end,
}

local originalType = env.type
local originalPerformIngameSpawn = env.PerformIngameSpawn
local originalGetPlayerByGUID = env.GetPlayerByGUID
env.type = function(value)
    if type(value) == "table" and rawget(value, "__fake") then return "userdata" end
    return originalType(value)
end
env.PerformIngameSpawn = function() return fakeBoss end
env.GetPlayerByGUID = function(guid)
    local numeric = tonumber(guid)
    if numeric and fakePlayers[numeric] then return fakePlayers[numeric] end
    return fakePlayers[guid]
end

local function containsId(player, wanted)
    for _, entry in ipairs(player.given) do
        if entry.entry == wanted then return true end
    end
    return false
end

-- 生成假 Boss → 记入两名玩家的伤害 → 触发死亡结算
-- 时钟调到时间段内（20:00-22:00），否则收尾阶段的重生排程会走"推迟到下一个时间段"分支
setNow(os.time{year = 2026, month = 9, day = 1, hour = 21, min = 0, sec = 0})
runConsoleCommand("boss spawn force")
local killBoundary = #recorded.sql
local damageHandler = engineCallbacks.creature["190090/9"]
if damageHandler then
    damageHandler(0, fakeBoss, warrior, 5000)
    damageHandler(0, fakeBoss, mage, 1000)
else
    fail("未注册 190090 的受伤事件（无法构造贡献池）")
end

local deathHandler = engineCallbacks.creature["190090/4"]
if deathHandler then
    deathHandler(0, fakeBoss, warrior)
else
    fail("未注册 190090 的死亡事件")
end

local function givenIds(player)
    local ids = {}
    for _, entry in ipairs(player.given) do ids[#ids + 1] = entry.entry end
    return ids
end

local warriorIds, mageIds = givenIds(warrior), givenIds(mage)
print("  [测试] 战士获奖: " .. table.concat(warriorIds, ",") .. " | 法师获奖: " .. table.concat(mageIds, ","))

assertTrue(#warriorIds > 0 and #mageIds > 0, "两名有效参战玩家都拿到了奖池奖励")
assertTrue(containsId(warrior, 1001) and not containsId(warrior, 1002),
    "战士拿到本职业专属 1001，且拿不到法师专属 1002")
assertTrue(containsId(mage, 1002) and not containsId(mage, 1001),
    "法师拿到本职业专属 1002，且拿不到战士专属 1001")
assertTrue(not containsId(warrior, 9999) and not containsId(mage, 9999),
    "核心判定为不可用的物品 9999 没有发给任何人")
assertTrue(not containsId(warrior, 4001) and not containsId(mage, 4001)
    and not containsId(warrior, 5001) and not containsId(mage, 5001),
    "已关闭的奖池（pool_id 4/5）一件都没发")
assertTrue(not containsId(warrior, 7001) and not containsId(mage, 7001),
    "越界（pool_id=33）的池被丢弃，一件都没发")
assertTrue(containsId(warrior, 6001) or containsId(mage, 6001),
    "pool_id=31 的池独立生效（指定 1 人拿到 6001）")
assertTrue(containsId(warrior, 2001) or containsId(mage, 2001),
    "pool_id=2 的指定 1 人抽奖发给了其中一位玩家")
assertTrue(#warriorIds >= 2 and #mageIds >= 1,
    "pool_id=1（全部有效参战）+ pool_id=3（战士专属）按人数模式发放")

-- 金币：pool_id=7 只有金币区间（5000/5000），其余池是 0/0 —— 只有前者该动钱
assertEq(warrior.coinage - 100000, 5000, "金币池给战士加了 5000 铜（按 GetCoinage 前后差证明真到账）")
assertEq(mage.coinage - 100000, 5000, "金币池给法师加了 5000 铜")
assertEq(#warrior.goldOps, 1, "其余奖池是 0/0：既不扣也不加钱（ModifyMoney 只被调用 1 次）")
assertEq(warrior.goldOps[1], 5000, "ModifyMoney 收到的是池内金额（5000 铜）")
assertTrue(table.concat(warrior.messages, " "):find("1 银 0 铜", 1, true) ~= nil
    or table.concat(warrior.messages, " "):find("0 金 0 银 0 铜", 1, true) ~= nil
    or table.concat(warrior.messages, " "):find("你参与了", 1, true) ~= nil,
    "获奖者收到含金币金额的中奖提示")

local emptyPoolLog = findLogLine("既没有奖品也没有金币")
assertTrue(emptyPoolLog ~= nil,
    "空池（无物品 + 金币 0/0）被跳过并写日志，不影响其它池（" .. tostring(emptyPoolLog) .. "）")

-- 贡献快照的奖池位图：必须用 2^(pool_id-1)，含 pool_id 7 / 31 这两个**不在 1..6** 的位号
local function snapshotValue(playerName, column)
    for index = killBoundary + 1, #recorded.sql do
        local sql = recorded.sql[index].sql
        if sql:find("INSERT INTO", 1, true) and sql:find("`boss_activity_contributors`", 1, true)
            and sql:find("'" .. playerName .. "'", 1, true) then
            local value = insertColumnValue(sql, column)
            if value ~= nil then return tonumber(value) end
        end
    end
    return nil
end

local warriorMask = snapshotValue("测试战士", "reward_pools_mask")
local mageMask = snapshotValue("测试法师", "reward_pools_mask")
print(string.format("  [测试] 位图: 战士=%s 法师=%s", tostring(warriorMask), tostring(mageMask)))

assertTrue(warriorMask ~= nil and mageMask ~= nil, "贡献快照写入了 reward_pools_mask（两位玩家都抓到）")

if warriorMask ~= nil and mageMask ~= nil and type(getRewardPoolMask) == "function" then
    local function maskHasBit(mask, poolId)
        local bitValue = getRewardPoolMask(poolId)
        if bitValue <= 0 then return false end
        return math.floor((mask or 0) / bitValue) % 2 == 1
    end

    assertTrue(maskHasBit(warriorMask, 1) and maskHasBit(mageMask, 1),
        "位图：两位都中过 pool_id=1（bit 2^0）")
    assertTrue(maskHasBit(warriorMask, 3) and not maskHasBit(mageMask, 3),
        "位图：只有战士中过 pool_id=3（池内只有战士专属 + 核心判定不可用物品）")
    assertTrue(maskHasBit(warriorMask, 7) and maskHasBit(mageMask, 7),
        "位图：pool_id=7 → bit 2^6（金币池对全体发放，证明位映射不是写死的 1..6）")
    assertTrue(maskHasBit(warriorMask, 31) ~= maskHasBit(mageMask, 31),
        "位图：pool_id=31 → bit 2^30 只落在 1 个人身上（高位位号同样按 pool_id-1 映射）")
    assertTrue(not maskHasBit(warriorMask, 4) and not maskHasBit(mageMask, 4),
        "位图：pool_id=4 已关闭 → bit 2^3 未置位")
    assertTrue(not maskHasBit(warriorMask, 5) and not maskHasBit(mageMask, 5),
        "位图：pool_id=5 已关闭 → bit 2^4 未置位")
    assertTrue(not maskHasBit(warriorMask, 8) and not maskHasBit(mageMask, 8),
        "位图：pool_id=8 是空池 → bit 2^7 未置位")
end

assertTrue(#warrior.messages > 0 and #mage.messages > 0, "获奖者收到了中奖提示")
assertTrue(#recorded.replies > 0 and table.concat(recorded.replies, " "):find("获奖名单", 1, true) ~= nil,
    "击杀后广播了按奖池分组的获奖名单")
assertTrue(table.concat(recorded.replies, " "):find("金币池", 1, true) == nil,
    "announce=0 的池不进世界通告（金币池公告位解析正确）")

-- --------------------------------------------- 结算后的收尾（快照 / reward_granted / 重生排程）
local sawRewardGranted, sawSnapshot, sawRespawnScheduled, respawnDelay = false, false, false, nil
for index = killBoundary + 1, #recorded.sql do
    local sql = recorded.sql[index].sql
    if sql:find("'reward_granted'", 1, true) then sawRewardGranted = true end
    if sql:find("'respawn_scheduled'", 1, true) then sawRespawnScheduled = true end
    if sql:find("`boss_activity_contributors`", 1, true) and sql:find("INSERT", 1, true) then sawSnapshot = true end
end
-- 重生排程走 CreateLuaEvent（respawn_time_minutes=10 → 600000ms）
for index = #scheduledEvents, 1, -1 do
    local scheduled = scheduledEvents[index]
    if scheduled.delay and scheduled.delay == 600000 then respawnDelay = scheduled.delay end
end
assertTrue(sawRewardGranted, "结算写入 event_type='reward_granted'")
assertTrue(sawSnapshot, "结算写入贡献快照（boss_activity_contributors）")
assertTrue(sawRespawnScheduled, "结算写入 event_type='respawn_scheduled'")
assertEq(respawnDelay, 600000, "结算后按 respawn_time_minutes 排出重生计时（CreateLuaEvent 600000ms）")

-- 职业与奖池位图都必须落库：离线补发与面板按 DB 行回补时依赖它们
local snapshotClassId = snapshotValue("测试战士", "class_id")
assertTrue(snapshotClassId ~= nil and tonumber(snapshotClassId) > 0,
    "贡献快照把 class_id 落库（离线补发与面板回补按职业过滤要用，实际 " .. tostring(snapshotClassId) .. "）")
local snapshotMask = snapshotValue("测试战士", "reward_pools_mask")
assertTrue(snapshotMask ~= nil, "贡献快照把 reward_pools_mask 落库（面板位图徽章要用）")


-- ------------------------------------------------- 离线补发（邮件通道）
-- 击杀时已下线的贡献者**不再被丢掉**：改走 SendMail 按 GUID 投递，物品与金币都能寄。
-- 职业过滤用贡献记录里落下的 classId（采样时玩家还在线）。
io.write("\n== 离线补发（邮件）==\n")

recorded.rewardPoolRows = rewardPoolRows({
    { pool_id = 9, sort_order = 10, name = "离线池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "3001", gold_min_copper = 700, gold_max_copper = 700, announce = 1 },
})
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "db", "离线补发段：奖池同样来自 boss_reward_pools 表")
assertEq(EXT_VALUES.offline_reward_delivery, 1, "离线补发段：offline_reward_delivery = 1")

local goblin = newFakePlayer(503, "测试盗贼", 4, {[3001] = true})
runConsoleCommand("boss spawn force")
damageHandler(0, fakeBoss, warrior, 100)
damageHandler(0, fakeBoss, mage, 100)
damageHandler(0, fakeBoss, goblin, 100)
-- 打完就下线：GetPlayerByGUID 查不到 → 结算时 entry.player = nil → 走邮件
fakePlayers[503] = nil

local mailBoundary, mailsBefore = #recorded.sql, #recorded.mails
deathHandler(0, fakeBoss, warrior)

local mailed = recorded.mails[#recorded.mails]
assertEq(#recorded.mails, mailsBefore + 1, "离线贡献者收到 1 封补发邮件（不再被静默丢弃）")
if mailed ~= nil and #recorded.mails > mailsBefore then
    assertEq(mailed.receiverGUIDLow, 503, "邮件收件人是离线玩家的 GUID low（player_guid）")
    assertEq(mailed.senderGUIDLow, 0, "邮件发件人是系统（senderGUIDLow = 0）")
    assertEq(mailed.stationery, 61, "邮件用 MAIL_STATIONERY_DEFAULT(61)")
    assertEq(tonumber(mailed.itemId), 3001, "邮件寄出池内物品 3001")
    assertEq(tonumber(mailed.money), 700, "邮件附上池内金币 700 铜")
    assertTrue(tostring(mailed.subject):find("战利品", 1, true) ~= nil,
        "邮件主题带战利品字样（" .. tostring(mailed.subject) .. "）")
end
assertTrue(findLogLine("已按离线补发寄出") ~= nil, "离线补发会写日志（便于 GM 核对）")

-- 在线的两位照旧进背包 + 金币，说明离线路径没有影响在线路径
assertEq(warrior.coinage - 100000, 5000 + 700, "在线战士的金币 = 金币池 5000 + 离线段的离线池 700")
assertTrue(containsId(warrior, 3001) and containsId(mage, 3001),
    "在线玩家照常从离线池拿到物品（离线路径不影响在线路径）")

-- offline_reward_delivery = 0：离线者不发（也不寄邮件），在线者照常
EXT_VALUES.offline_reward_delivery = 0
runConsoleCommand("boss config reload")
local suppressed = newFakePlayer(504, "测试术士", 9, {[3001] = true})
-- 时钟挪到时间段外：顺带断言"结算后的重生排程在时段外会推迟"
setNow(os.time{year = 2026, month = 9, day = 1, hour = 23, min = 0, sec = 0})
runConsoleCommand("boss spawn force")
damageHandler(0, fakeBoss, warrior, 100)
damageHandler(0, fakeBoss, mage, 100)
damageHandler(0, fakeBoss, suppressed, 100)
fakePlayers[504] = nil

local suppressBoundary, mailsBeforeSuppress = #recorded.sql, #recorded.mails
deathHandler(0, fakeBoss, warrior)

assertEq(#recorded.mails, mailsBeforeSuppress, "offline_reward_delivery=0 时不发补发邮件")
assertTrue(findLogLine("未开启离线补发") ~= nil, "跳过时写明原因是未开启离线补发")

local sawDeferred = false
for index = suppressBoundary + 1, #recorded.sql do
    if recorded.sql[index].sql:find("'respawn_deferred'", 1, true) then sawDeferred = true end
end
assertTrue(sawDeferred, "时段外结算不排重生计时，改写 respawn_deferred（进入下一个时间段后自动生成）")

-- 恢复 ext 快照里的离线补发开关，避免影响后面的段落
EXT_VALUES.offline_reward_delivery = 1
runConsoleCommand("boss config reload")
assertTrue(mailBoundary > 0, "离线补发段的 SQL 边界有效（扫描范围不为空）")

-- 恢复场地：桩函数与假对象都要撤掉，后面的多区绑定断言仍用原来的桩
env.type = originalType
env.PerformIngameSpawn = originalPerformIngameSpawn
env.GetPlayerByGUID = originalGetPlayerByGUID
recorded.rewardPoolRows = nil
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "code", "清空奖池结果集后来源又回到 code（回落分支可重复进入）")

-- ------------------------------------------------- 连招施放（离线驱动：假 Boss + 假玩家）
-- 奖池实发段只证明「死亡结算」这条链路；这里补的是**连招真的会被执行**：
--   假 Boss（IsInCombat=true / 90% 血 = 阶段 1）+ 假玩家（战士，没在读条 / 满血）
--   走一遍 OnBossEnterCombat → SmartBossAI 两次（第 1 次只放开场技能并置 openingDone，
--   第 2 次走连招），断言施放序列与某条声明的连招完全一致、连招冷却写对、连招喊话念对。
-- 这一段的状态是干净的：上一段的 OnBossDied（boss.lua:5490-5503）已经清了
-- scriptSpawnedBossGUIDs / bossAIStates 并 ClearActiveBoss()，所以可以再来一次
-- `boss spawn force`（否则 HasActiveBoss() 会挡住生成）。
-- 随机性通过 env.math 固定成「概率判定必过 + 取第一项」，不污染真实 math。
io.write("\n== 连招施放（离线驱动） ==\n")

-- 本段专用的假对象：不复用奖池实发段的 fakeBoss / newFakePlayer，避免互相串味
local comboGuid = 777002

local comboWarrior = { __fake = true }
comboWarrior.IsInWorld = function() return true end
comboWarrior.IsPlayer = function() return true end
comboWarrior.GetName = function() return "连招测试战士" end
comboWarrior.GetGUIDLow = function() return 502 end
comboWarrior.GetGUID = function() return "502" end
comboWarrior.GetClass = function() return 1 end
comboWarrior.GetAccountId = function() return 9502 end
comboWarrior.GetMapId = function() return 571 end
comboWarrior.GetX = function() return 4108.16 end
comboWarrior.GetY = function() return 5316.85 end
comboWarrior.GetZ = function() return 28.76 end
comboWarrior.GetHealthPct = function() return 100 end     -- 满血：不触发低血嘲讽
comboWarrior.IsCasting = function() return false end      -- 没在读条：不触发打断优先
comboWarrior.GetDistance = function() return 5 end
comboWarrior.SendBroadcastMessage = function() end
comboWarrior.CanUseItem = function() return false end

-- 假 Boss：IsInCombat 必须为 true，否则 SmartBossAI 在 boss.lua:4305 直接 return
local comboBoss = { __fake = true, casts = {}, yells = {}, events = {} }
comboBoss.IsInWorld = function() return true end
comboBoss.IsAlive = function() return true end
comboBoss.IsInCombat = function() return true end
comboBoss.GetGUIDLow = function() return comboGuid end
comboBoss.GetEntry = function() return 190090 end
comboBoss.GetName = function() return "送财童子" end
comboBoss.GetMapId = function() return 571 end
comboBoss.GetInstanceId = function() return 0 end
comboBoss.GetX = function() return 4108.16 end
comboBoss.GetY = function() return 5316.85 end
comboBoss.GetZ = function() return 28.76 end
comboBoss.GetO = function() return 0 end
comboBoss.GetMaxHealth = function() return 4392675 end
comboBoss.GetHealth = function() return 4392675 end
comboBoss.GetHealthPct = function() return 90 end       -- 90% 血 → 阶段 1（> phase2HpThreshold）
comboBoss.SetMaxHealth = function() end
comboBoss.SetHealth = function() end
comboBoss.SetLevel = function() end
comboBoss.SetScale = function() end
comboBoss.SetHomePosition = function() end
comboBoss.UpdateEntry = function() end
comboBoss.GetFaction = function() return 14 end
comboBoss.SetFaction = function() end
comboBoss.AddAura = function() end
comboBoss.RemoveAura = function() end
comboBoss.RemoveEvents = function(self) self.events = {} end
comboBoss.RegisterEvent = function(self, fn, delay, repeats)
    table.insert(self.events, {fn = fn, delay = delay, repeats = repeats})
end
comboBoss.SendUnitYell = function(self, message) table.insert(self.yells, tostring(message)) end
comboBoss.CastSpell = function(self, target, spellId)
    table.insert(self.casts, {spellId = tonumber(spellId), target = (target == self) and "self" or "victim"})
    return true
end
comboBoss.AttackStart = function() end
comboBoss.MoveChase = function() end
comboBoss.SpawnCreature = function() return nil end      -- 援军/小怪：本段只验连招施放，不需要它们真的出现
comboBoss.GetVictim = function() return comboWarrior end
comboBoss.GetThreatList = function() return {comboWarrior} end
comboBoss.GetPlayersInRange = function() return {comboWarrior} end
comboBoss.GetDistance = function() return 5 end

-- 连招喊话：运行时那份被扩展表列**整体替换**，而冒烟快照里只有 1 条假 key，
-- 直接硬断言会一片假失败。组内先把全部连招名写进快照再 boss config reload，
-- 这样「连招喊话内容」这条断言才是在验代码路径（默认库的覆盖性已在上一组硬断言过）。
local comboYellLibrary = bossLocal("SKILL_PRESET_LIBRARY")
if type(comboYellLibrary) == "table" then
    local yellLines = {}
    for _, preset in pairs(comboYellLibrary) do
        for _, combo in ipairs((type(preset) == "table" and preset.comboChains) or {}) do
            if type(combo.name) == "string" and combo.name ~= "" then
                yellLines[#yellLines + 1] = combo.name .. "=【连招喊话】" .. combo.name
            end
        end
    end
    table.sort(yellLines)
    EXT_VALUES.taunt_combo_yells_text = table.concat(yellLines, "\n")
    local reloadMarkers = markersOf(runConsoleCommand("boss config reload"))
    assertTrue(reloadMarkers:find("AGMP_OK", 1, true) ~= nil,
        "连招段：写入连招喊话后 boss config reload 返回 AGMP_OK")
else
    fail("连招段：取不到 SKILL_PRESET_LIBRARY，无法准备连招喊话")
end

local comboConfig = bossLocal("BOSS_CONFIG")
local comboYellMap = type(comboConfig) == "table" and type(comboConfig.combatTaunts) == "table"
    and comboConfig.combatTaunts.comboYells or nil
assertTrue(type(comboYellMap) == "table" and next(comboYellMap) ~= nil,
    "连招段：运行时 comboYells 已从扩展表列装载（组内写入，供喊话硬断言用）")

local savedComboMath = env.math
local savedComboType = env.type
local savedComboSpawn = env.PerformIngameSpawn
local savedComboGetPlayer = env.GetPlayerByGUID

-- 确定性随机：只换 boss.lua 的 _ENV.math，不动真实 math
env.math = setmetatable({
    random = function(a, b)
        if a == nil then return 0.5 end        -- 无参形态（boss.lua:5107 / 4266 的随机角度）
        if b ~= nil then return a end          -- math.random(min,max) → 取 min
        if a <= 0 then error("interval is empty") end
        return 1                               -- math.random(n) → 第一项；概率判定必过
    end,
}, { __index = math })

-- IsUnitValid 要求 type(unit)=="userdata"（boss.lua:2823-2827），照奖池实发段的 __fake 写法冒充
env.type = function(value)
    if type(value) == "table" and rawget(value, "__fake") then return "userdata" end
    return savedComboType(value)
end
env.PerformIngameSpawn = function() return comboBoss end
env.GetPlayerByGUID = function(guid)
    if tostring(guid) == "502" then return comboWarrior end
    return nil
end

local spawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
assertTrue(spawnMarkers:find("AGMP_OK", 1, true) ~= nil,
    "连招段：boss spawn force 生成假 Boss 返回 [AGMP_OK]")

local onEnterCombat = engineCallbacks.creature["190090/1"]
assertTrue(type(onEnterCombat) == "function", "连招段：拿到 190090 的 ON_ENTER_COMBAT 回调")
if type(onEnterCombat) == "function" then
    local entered, enterErr = pcall(onEnterCombat, 0, comboBoss, comboWarrior)
    assertTrue(entered, "连招段：OnBossEnterCombat 驱动成功"
        .. (entered and "" or ("（" .. tostring(enterErr) .. "）")))
end

local comboStates = bossLocal("bossAIStates")
local comboState = type(comboStates) == "table" and comboStates[comboGuid] or nil
assertTrue(type(comboState) == "table", "连招段：OnBossEnterCombat 建出 bossAIStates[" .. comboGuid .. "]")
if type(comboState) == "table" then
    assertTrue(comboState.phase == 1 and comboState.openingDone == false,
        string.format("连招段：AI 状态初值 phase=%s / openingDone=%s（90%% 血 = 阶段 1）",
            tostring(comboState.phase), tostring(comboState.openingDone)))
end
assertTrue(#comboBoss.events >= 1 and type(comboBoss.events[1].fn) == "function",
    "连招段：OnBossEnterCombat 注册了智能 AI 回调（creature:RegisterEvent(SmartBossAI, ...)）")

local aiCallback = comboBoss.events[1] and comboBoss.events[1].fn
if type(aiCallback) == "function" and type(comboState) == "table" then
    -- 第 1 次 AI 循环：只放开场技能并置 openingDone
    comboBoss.casts, comboBoss.yells = {}, {}
    local firstOk, firstErr = pcall(aiCallback, 0, 2500, 0, comboBoss)
    assertTrue(firstOk, "连招段：第 1 次 AI 循环执行成功"
        .. (firstOk and "" or ("（" .. tostring(firstErr) .. "）")))
    assertTrue(comboState.openingDone == true, "连招段：第 1 次 AI 循环置 openingDone=true")
    assertTrue(#comboBoss.casts == 1,
        "连招段：第 1 次 AI 循环只施放开场技能（实际施放 " .. #comboBoss.casts .. " 个法术）")

    local activePresetKey = bossLocal("ACTIVE_SKILL_PRESET_KEY")
    local expectedOpening = nil
    if type(comboYellLibrary) == "table" and type(activePresetKey) == "string" then
        local activePreset = comboYellLibrary[activePresetKey]
        local firstOpening = type(activePreset) == "table" and type(activePreset.openingSkills) == "table"
            and activePreset.openingSkills[1] or nil
        expectedOpening = type(firstOpening) == "table" and tonumber(firstOpening.spellId) or nil
    end
    assertTrue(expectedOpening ~= nil,
        "连招段：取到当前生效预设（" .. tostring(activePresetKey) .. "）的首个开场技能 ID")
    if #comboBoss.casts == 1 and expectedOpening ~= nil then
        assertEq(comboBoss.casts[1].spellId, expectedOpening,
            "连招段：开场技能 = 当前预设 openingSkills[1]（确定性随机取第一项）")
    end

    -- 第 2 次 AI 循环：走连招。读条模式下连招第一发立即施放，其余进入 state.pendingCasts 队列
    comboBoss.casts, comboBoss.yells = {}, {}
    local secondOk, secondErr = pcall(aiCallback, 0, 2500, 0, comboBoss)
    assertTrue(secondOk, "连招段：第 2 次 AI 循环执行成功"
        .. (secondOk and "" or ("（" .. tostring(secondErr) .. "）")))

    local queuedAfterTrigger = type(comboState.pendingCasts) == "table" and #comboState.pendingCasts or -1
    assertTrue(#comboBoss.casts == 1 and queuedAfterTrigger == 2,
        string.format("连招段：读条模式下触发 tick 只发第一发、其余 2 发入队（实际发 %d 发、队列 %d）",
            #comboBoss.casts, queuedAfterTrigger))

    -- 触发时刻的冷却快照：后面的排空 tick 会按 dt 递减 comboCooldowns，不能事后比对
    local cooldownsAtTrigger = {}
    if type(comboState.comboCooldowns) == "table" then
        for name, cd in pairs(comboState.comboCooldowns) do cooldownsAtTrigger[name] = cd end
    end
    local globalComboCooldownAtTrigger = comboState.comboCooldown

    -- 继续驱动 AI 直到队列排空（每个空闲 tick 发一发），累计序列才是完整连招
    local drainTicks = 0
    while drainTicks < 6 do
        local queued = type(comboState.pendingCasts) == "table" and #comboState.pendingCasts or 0
        if queued == 0 then break end
        local drainOk, drainErr = pcall(aiCallback, 0, 2500, 0, comboBoss)
        assertTrue(drainOk, "连招段：排空 pendingCasts 的 AI 循环执行成功"
            .. (drainOk and "" or ("（" .. tostring(drainErr) .. "）")))
        drainTicks = drainTicks + 1
    end
    assertTrue((type(comboState.pendingCasts) == "table" and #comboState.pendingCasts or 0) == 0,
        "连招段：连招队列已排空（每个空闲 tick 发一发）")

    local chains = scaledComboChains()
    assertTrue(type(chains) == "table" and #chains > 0,
        "连招段：现取到缩放后的 COMBO_CHAINS（" .. tostring(type(chains) == "table" and #chains or 0) .. " 条）")

    local casts = comboBoss.casts
    local castText = {}
    for _, cast in ipairs(casts) do
        castText[#castText + 1] = string.format("%s→%s", tostring(cast.spellId), tostring(cast.target))
    end

    local function sameSequence(combo)
        if type(combo) ~= "table" or type(combo.skills) ~= "table" or #combo.skills ~= #casts then
            return false
        end
        for index, skillInfo in ipairs(combo.skills) do
            if type(skillInfo) ~= "table" or tonumber(skillInfo[1]) ~= casts[index].spellId
                or skillInfo[2] ~= casts[index].target then
                return false
            end
        end
        return true
    end

    local matchedCombos = {}
    for _, combo in ipairs(chains or {}) do
        if sameSequence(combo) then matchedCombos[#matchedCombos + 1] = combo end
    end
    assertTrue(#casts > 0 and #matchedCombos >= 1,
        string.format("连招段：第 2 次 AI 循环的施放序列与某条声明的连招完全一致（实际 [%s]）",
            table.concat(castText, ", ")))

    local executedCombo = matchedCombos[1]
    if executedCombo ~= nil then
        local declaredPhase = false
        for _, phase in ipairs(type(executedCombo.phase) == "table" and executedCombo.phase or {}) do
            if tonumber(phase) == comboState.phase then declaredPhase = true end
        end
        assertTrue(declaredPhase,
            string.format("连招段：被选中的连招 %s 声明包含当前阶段 %s（phase=%s）",
                tostring(executedCombo.name), tostring(comboState.phase),
                type(executedCombo.phase) == "table" and table.concat(executedCombo.phase, ",") or "nil"))

        assertEq(cooldownsAtTrigger[executedCombo.name], executedCombo.cooldown,
            "连招段：触发时 state.comboCooldowns[" .. tostring(executedCombo.name)
                .. "] = 该连招的 cooldown（触发 tick 快照）")
        assertEq(globalComboCooldownAtTrigger, 5,
            "连招段：触发连招后全局连招冷却 state.comboCooldown=5（触发 tick 快照）")

        assertTrue(#comboBoss.yells == 1, "连招段：连招触发时喊话一次（实际 " .. #comboBoss.yells .. " 次）")
        local expectedYell = type(comboYellMap) == "table" and comboYellMap[executedCombo.name] or nil
        assertTrue(type(expectedYell) == "string" and expectedYell ~= "",
            "连招段：运行时 comboYells 覆盖被执行的连招名 " .. tostring(executedCombo.name))
        if #comboBoss.yells == 1 then
            assertEq(comboBoss.yells[1], expectedYell,
                "连招段：连招喊话内容 = BOSS_CONFIG.combatTaunts.comboYells[连招名]")
        end
    end
else
    fail("连招段：AI 回调或 bossAIStates 未建立，连招施放路径没能被驱动")
end

-- 还原场地：桩函数与假对象都要撤掉，后面的多区绑定断言仍用原来的桩
env.math = savedComboMath
env.type = savedComboType
env.PerformIngameSpawn = savedComboSpawn
env.GetPlayerByGUID = savedComboGetPlayer
assertTrue(env.math == savedComboMath and env.type == savedComboType
    and env.PerformIngameSpawn == savedComboSpawn and env.GetPlayerByGUID == savedComboGetPlayer,
    "连招段结束：env.math / env.type / PerformIngameSpawn / GetPlayerByGUID 全部还原")

-- ------------------------------------------------- 结算韧性 / 出厂默认实发 / 口径回归（离线驱动）
-- 三件事：
--   1) 结算三段式的卖点：中段（发奖）抛错也必须写快照、写 reward_granted、排重生；
--   2) 读不到 boss_reward_pools 时出厂默认池照样发奖（活动不因配置表异常停摆）；
--   3) 一批"改过就该断言"的口径：治疗不要求治疗者本人站位、同 tick 去重、
--      巡逻脱缰中心用 home_*、打断预筛距离取自打断池、(min,max) 写反要归一。
io.write("\n== 结算韧性（注入中段异常） ==\n")
do
local savedType, savedSpawn, savedGetPlayer = env.type, env.PerformIngameSpawn, env.GetPlayerByGUID

local fakePlayers = {}
local function newPlayer(guidLow, playerName, classId, instanceId)
    local player = {
        __fake = true, guidLow = guidLow, name = playerName, classId = classId,
        instanceId = tonumber(instanceId) or 0,
        given = {}, messages = {}, coinage = 100000, goldOps = {},
    }
    player.IsInWorld = function() return true end
    player.IsPlayer = function() return true end
    player.GetName = function() return playerName end
    player.GetGUIDLow = function() return guidLow end
    player.GetGUID = function() return tostring(guidLow) end
    player.GetClass = function() return classId end
    player.GetAccountId = function() return 9000 + guidLow end
    player.GetMapId = function() return 571 end
    player.GetInstanceId = function() return player.instanceId end
    player.GetX = function() return 4108.16 end
    player.GetY = function() return 5316.85 end
    player.GetZ = function() return 28.76 end
    player.GetDistance = function() return 5 end
    player.CanUseItem = function() return true end
    player.AddItem = function(_, entry, count)
        table.insert(player.given, {entry = entry, count = count or 1})
        return {entry = entry}
    end
    player.GetCoinage = function() return player.coinage end
    player.ModifyMoney = function(_, amount)
        player.goldOps[#player.goldOps + 1] = amount
        player.coinage = player.coinage + amount
    end
    player.SendBroadcastMessage = function(_, message) table.insert(player.messages, message) end
    player.GetPlayersInRange = function() return {} end
    fakePlayers[guidLow] = player
    return player
end

local function newBoss(guid, instanceId)
    local boss = {
        __fake = true, guid = guid, instanceId = tonumber(instanceId) or 0,
        events = {}, yells = {}, maxHealth = 1000, health = 1000,
        movedHome = false, movedRandom = 0,
    }
    boss.IsInWorld = function() return true end
    boss.IsAlive = function() return true end
    boss.IsInCombat = function() return false end
    boss.GetGUIDLow = function() return guid end
    boss.GetEntry = function() return 190090 end
    boss.GetName = function() return "送财童子" end
    boss.GetMapId = function() return 571 end
    boss.GetInstanceId = function() return boss.instanceId end
    boss.GetX = function() return 4108.16 end
    boss.GetY = function() return 5316.85 end
    boss.GetZ = function() return 28.76 end
    boss.GetO = function() return 0 end
    boss.GetMaxHealth = function() return boss.maxHealth end
    boss.GetHealth = function() return boss.health end
    boss.SetMaxHealth = function(_, value) boss.maxHealth = value end
    boss.SetHealth = function(_, value) boss.health = value end
    boss.SetLevel = function() end
    boss.SetScale = function() end
    boss.SetHomePosition = function() end
    boss.UpdateEntry = function() end
    boss.AddAura = function() end
    boss.RemoveAura = function() end
    boss.SendUnitYell = function(_, message) table.insert(boss.yells, tostring(message)) end
    boss.RemoveEvents = function() boss.events = {} end
    boss.RegisterEvent = function(_, fn, delay, repeats)
        table.insert(boss.events, {fn = fn, delay = delay, repeats = repeats})
    end
    boss.MoveHome = function() boss.movedHome = true end
    boss.MoveRandom = function(_, radius) boss.movedRandom = boss.movedRandom + 1; boss.movedRadius = radius end
    boss.GetPlayersInRange = function() return {} end
    boss.GetThreatList = function() return {} end
    boss.GetVictim = function() return nil end
    boss.GetDistance = function() return 5 end
    return boss
end

local function hasId(player, wanted)
    for _, entry in ipairs(player.given) do
        if entry.entry == wanted then return true end
    end
    return false
end

env.type = function(value)
    if type(value) == "table" and rawget(value, "__fake") then return "userdata" end
    return savedType(value)
end

local activeBoss = nil
env.PerformIngameSpawn = function()
    recorded.spawnAttempts = (recorded.spawnAttempts or 0) + 1
    return activeBoss
end
env.GetPlayerByGUID = function(guid)
    local numeric = tonumber(guid)
    if numeric and fakePlayers[numeric] then return fakePlayers[numeric] end
    return fakePlayers[guid]
end

local damageHandler = engineCallbacks.creature["190090/9"]
local deathHandler = engineCallbacks.creature["190090/4"]

-- ① 出厂默认池实发（读不到表 → 来源 code）
recorded.rewardPoolRows = nil
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "code", "读不到 boss_reward_pools 时来源 = code")
local fallbackPools = bossLocal("REWARD_POOLS")
assertEq(type(fallbackPools) == "table" and #fallbackPools or 0, 6, "回落后运行期仍持有 6 个出厂默认池")

local defaultWarrior = newPlayer(701, "默认战士", 1, 0)
local defaultMage = newPlayer(702, "默认法师", 8, 0)
activeBoss = newBoss(777301, 0)
setNow(os.time{year = 2026, month = 9, day = 1, hour = 21, min = 0, sec = 0})
-- 上一段（连招施放）留下的活跃 Boss 还在，先清干净，否则 HasActiveBoss() 会挡住生成
runConsoleCommand("boss clear")
local fallbackSpawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
assertTrue(fallbackSpawnMarkers:find("AGMP_OK", 1, true) ~= nil, "出厂默认段：生成假 Boss 成功")
damageHandler(0, activeBoss, defaultWarrior, 900)
damageHandler(0, activeBoss, defaultMage, 100)
deathHandler(0, activeBoss, defaultWarrior)
local defaultIds = {}
for _, entry in ipairs(defaultWarrior.given) do defaultIds[#defaultIds + 1] = entry.entry end
print("  [测试] 出厂默认奖池发给战士: " .. table.concat(defaultIds, ","))
assertTrue(hasId(defaultWarrior, 40753),
    "没有奖池表时出厂默认池照常发奖（池 1「全员奖」100% 的 40753 必须到手）")
assertTrue(type(findLogLine("回退出厂默认")) == "string", "回落路径写日志（[奖池]...回退出厂默认）")

-- ② 结算韧性：中段（xpcall 内）抛错，收尾必须照做
recorded.rewardPoolRows = rewardPoolRows({
    { pool_id = 3, sort_order = 10, name = "韧性池", enabled = 1, chance = 100, winner_mode = "all",
      winner_count = 1, class_filter = 0, items_text = "1001", gold_min_copper = 0, gold_max_copper = 0, announce = 1 },
})
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "db", "韧性段：奖池来自表")

local warrior = newPlayer(703, "韧性战士", 1, 0)
local mage = newPlayer(704, "韧性法师", 8, 0)
activeBoss = newBoss(777302, 0)
runConsoleCommand("boss clear")
local resilienceSpawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
assertTrue(resilienceSpawnMarkers:find("AGMP_OK", 1, true) ~= nil, "韧性段：生成假 Boss 成功")
damageHandler(0, activeBoss, warrior, 500)
damageHandler(0, activeBoss, mage, 500)

local boundary = #recorded.sql
local scheduledBefore = #scheduledEvents
local originalPick = env.PickRewardPoolItemFor
assertTrue(type(originalPick) == "function", "取到全局 PickRewardPoolItemFor（注入点）")
env.PickRewardPoolItemFor = function() error("injected mid-phase failure") end
local deathOk, deathErr = pcall(deathHandler, 0, activeBoss, warrior)
env.PickRewardPoolItemFor = originalPick

assertTrue(deathOk, "发奖中段抛错时 OnBossDied 自身不向外抛（xpcall 收口）：" .. tostring(deathErr))
local sawFailed, sawGranted, sawSnapshot, sawRespawn, sawErrorLog = false, false, false, false, false
for index = boundary + 1, #recorded.sql do
    local sql = recorded.sql[index].sql
    if sql:find("'reward_failed'", 1, true) then sawFailed = true end
    if sql:find("'reward_granted'", 1, true) then sawGranted = true end
    if sql:find("'respawn_scheduled'", 1, true) then sawRespawn = true end
    if sql:find("`boss_activity_contributors`", 1, true) and sql:find("INSERT", 1, true) then sawSnapshot = true end
end
sawErrorLog = findLogLine("结算过程出错") ~= nil
assertTrue(sawFailed, "中段异常写 event_type='reward_failed'（失败可见）")
assertTrue(sawGranted, "中段异常仍写 event_type='reward_granted'（已奖励标记在 Finalize 里）")
assertTrue(sawSnapshot, "中段异常仍写贡献快照（不再出现「无快照」）")
assertTrue(sawRespawn, "中段异常仍排重生（不再出现「不重生、该 GUID 永久跳过」）")
assertTrue(sawErrorLog, "中段异常打印错误日志")
assertTrue(#scheduledEvents > scheduledBefore, "中段异常后 CreateLuaEvent 仍被调用（重生计时）")
assertTrue(#warrior.given == 0, "注入点在发物品之前，所以这次没有物品入包（符合注入位置）")

-- 收尾跑完 → 状态清理干净，可以立刻再生成一只
local respawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
assertTrue(respawnMarkers:find("AGMP_OK", 1, true) ~= nil,
    "中段异常后状态已清理，可以立刻再生成（没有卡在「已有活跃 Boss」）")

-- 诊断（不改结论）：预备阶段（xpcall 之外）抛错的后果
boundary = #recorded.sql
damageHandler(0, activeBoss, warrior, 500)
local originalIndex = env.BuildClassItemIndex
env.BuildClassItemIndex = function() error("injected prep-phase failure") end
local prepOk = pcall(deathHandler, 0, activeBoss, warrior)
env.BuildClassItemIndex = originalIndex
local prepGranted, prepSnapshot, prepRespawn = false, false, false
for index = boundary + 1, #recorded.sql do
    local sql = recorded.sql[index].sql
    if sql:find("'reward_granted'", 1, true) then prepGranted = true end
    if sql:find("'respawn_scheduled'", 1, true) then prepRespawn = true end
    if sql:find("`boss_activity_contributors`", 1, true) and sql:find("INSERT", 1, true) then prepSnapshot = true end
end
io.write(string.format(
    "  [info] 预备阶段异常（BuildClassItemIndex 在 xpcall 之外）：OnBossDied 是否向外抛=%s / reward_granted=%s / 快照=%s / 重生排程=%s\n",
    tostring(not prepOk), tostring(prepGranted), tostring(prepSnapshot), tostring(prepRespawn)))
runConsoleCommand("boss clear")

-- ③ 口径回归：治疗 / 去重 / 巡逻 / 打断预筛 / 区间归一
io.write("\n== 口径回归（治疗 · 去重 · 巡逻 · 打断 · 区间归一） ==\n")

activeBoss = newBoss(777303, 5)
runConsoleCommand("boss clear")
local healSpawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
assertTrue(healSpawnMarkers:find("AGMP_OK", 1, true) ~= nil, "口径回归段：生成假 Boss 成功")
local healerSameInstance = newPlayer(705, "同副本奶", 5, 5)
local healerOtherInstance = newPlayer(706, "别副本奶", 5, 6)
local farTarget = newPlayer(707, "远处目标", 1, 5)
farTarget.GetX = function() return 9999 end
farTarget.GetY = function() return 9999 end
local offMapPlayer = newPlayer(708, "别的地图", 1, 5)
offMapPlayer.GetMapId = function() return 530 end

assertTrue(env.IsInActiveEncounterInstance(healerSameInstance) == true,
    "遭遇范围判定：同 map + 同 instance_id 的玩家算在场")
assertTrue(env.IsInActiveEncounterInstance(healerOtherInstance) == false,
    "遭遇范围判定：同 map 但 instance_id 不同（别的副本实例）不算在场")
assertTrue(env.IsInActiveEncounterInstance(offMapPlayer) == false,
    "遭遇范围判定：不同 map 不算在场")

local healHandler = engineCallbacks.player["65"]
damageHandler(0, activeBoss, healerSameInstance, 100)   -- 让它成为参战者
local contributionStats = bossLocal("bossContributionStats")
healHandler(0, healerSameInstance, healerSameInstance, 500)
healHandler(0, healerOtherInstance, healerSameInstance, 700)
healHandler(0, healerSameInstance, farTarget, 900)
local healState = contributionStats and contributionStats[777303]
local sameRecord = healState and healState.players["705"]
local otherRecord = healState and healState.players["706"]
assertTrue(sameRecord ~= nil and sameRecord.healingDone == 500,
    "治疗计入：治疗者本人不在参与半径内也算（只要同副本实例、被治疗者是参战者）")
assertTrue(otherRecord == nil or otherRecord.healingDone == 0,
    "治疗不计入：治疗者在别的副本实例")
assertEq(sameRecord and sameRecord.healingDone, 500,
    "治疗不计入：被治疗者既不在遭遇范围内也不是参战者（累计仍是 500）")

-- 同 tick 去重：附近玩家列表与威胁列表里重复出现同一个人，只记一份
local trackPresence = bossLocal("TrackEncounterPresence")
assertTrue(type(trackPresence) == "function", "按名字取到文件内 local TrackEncounterPresence")
if type(trackPresence) == "function" then
    local duplicate = newPlayer(709, "重复玩家", 1, 5)
    activeBoss.GetPlayersInRange = function() return {duplicate, duplicate} end
    trackPresence(activeBoss, {duplicate, duplicate})
    local duplicateRecord = healState and healState.players["709"]
    assertTrue(duplicateRecord ~= nil, "去重段的玩家进了贡献池")
    if duplicateRecord ~= nil then
        assertEq(duplicateRecord.presenceSamples, 1, "同一 tick 内重复出现只记 1 次出勤（列表 + 威胁表不重复累加）")
        assertEq(duplicateRecord.threatSamples, 1, "同一 tick 内重复出现只记 1 份仇恨样本（宠物与主人算一份）")
    end
end

-- 巡逻脱缰中心：必须用 activeBossInfo.homeX/homeY（x/y 会被 AI 每 tick 覆盖成实时坐标）
local bossConfigTable = bossLocal("BOSS_CONFIG")
local registerPatrol = bossLocal("RegisterBossPatrol")
assertTrue(type(bossConfigTable) == "table" and type(registerPatrol) == "function",
    "取到 BOSS_CONFIG 与 RegisterBossPatrol（巡逻断言用）")
if type(bossConfigTable) == "table" and type(registerPatrol) == "function" then
    local previousPatrolEnabled = bossConfigTable.patrolEnabled
    bossConfigTable.patrolEnabled = true

    -- 上一只还活着，先清干净（HasActiveBoss() 否则会挡住新的生成）
    runConsoleCommand("boss clear")
    local patrolBoss = newBoss(777304, 0)
    activeBoss = patrolBoss
    local patrolSpawnMarkers = markersOf(runConsoleCommand("boss spawn force"))
    assertTrue(patrolSpawnMarkers:find("AGMP_OK", 1, true) ~= nil, "巡逻段：生成巡逻用假 Boss 成功")
    activeBoss.movedHome, activeBoss.movedRandom = false, 0

    local liveInfo = bossLocal("activeBossInfo")
    assertTrue(type(liveInfo) == "table", "取到 activeBossInfo（巡逻中心断言用）")
    if type(liveInfo) == "table" then
        -- 实时坐标（x/y）= 生物当前位置；刷新点（home_*）离它 892 码 > 脱缰半径 77
        liveInfo.x, liveInfo.y = 4108.16, 5316.85
        liveInfo.homeX, liveInfo.homeY = 5000.0, 5316.85
        registerPatrol(activeBoss)
        local patrolEvent = activeBoss.events[#activeBoss.events]
        assertTrue(patrolEvent ~= nil and type(patrolEvent.fn) == "function", "巡逻循环已注册")
        if patrolEvent ~= nil then patrolEvent.fn(0, 1000, 0, activeBoss) end
        assertTrue(activeBoss.movedHome == true and activeBoss.movedRandom == 0,
            "脱缰判定用 activeBossInfo.homeX/homeY（若用被覆盖的实时 x/y 会误判成未脱缰并随机巡逻）")
    end

    bossConfigTable.patrolEnabled = previousPatrolEnabled
end

-- 打断预筛距离 = 打断池里最远射程（写死 10 会让 25/30 码的打断法术永远选不中）
local prescreenRange = bossLocal("GetInterruptPrescreenRange")
local interruptPool = bossLocal("INTERRUPT_SPELL_LIBRARY")
assertTrue(type(prescreenRange) == "function" and type(interruptPool) == "table",
    "按名字取到 GetInterruptPrescreenRange / INTERRUPT_SPELL_LIBRARY")
if type(prescreenRange) == "function" and type(interruptPool) == "table" then
    local poolMaxRange = 0
    for _, interruptSpell in ipairs(interruptPool) do
        local range = tonumber(interruptSpell.maxRange) or 0
        if range > poolMaxRange then poolMaxRange = range end
    end
    assertTrue(poolMaxRange > 10,
        "打断池里存在 >10 码的法术（预筛写死 10 就会把它们全筛掉）：最远 " .. poolMaxRange .. " 码")
    assertEq(prescreenRange(), poolMaxRange, "打断预筛距离取自打断池最远射程（不是写死的 10）")
end

-- (min,max) 写反必须归一：否则 math.random(min,max) 直接抛错，整段玩法消失
CONFIG_VALUES.minion_count_min, CONFIG_VALUES.minion_count_max = 5, 2
EXT_VALUES.phase2_summon_count_min, EXT_VALUES.phase2_summon_count_max = 6, 1
local rangeReloadMarkers, rangeReloadText = markersOf(runConsoleCommand("boss config reload"))
assertTrue(rangeReloadMarkers:find("AGMP_OK", 1, true) ~= nil,
    "区间写反时 .boss config reload 仍返回 AGMP_OK（不崩、不丢配置）")
assertTrue(rangeReloadText:find("写库失败", 1, true) ~= nil, "reload 回执带上写库状态")
assertTrue(findLogLine("数量区间写反了") ~= nil,
    "区间写反会打告警日志（" .. tostring(findLogLine("数量区间写反了")) .. "）")
local minionText = table.concat(runConsoleCommand("boss config show minion"), " | ")
assertTrue(minionText:find("minion_count_min (minionCountMin) = 5", 1, true) ~= nil
    and minionText:find("minion_count_max (minionCountMax) = 5", 1, true) ~= nil,
    "小怪数量区间被归一为 [5,5]（min 不变、max 抬到 min）")
local phaseRangeText = table.concat(runConsoleCommand("boss config show phase"), " | ")
assertTrue(phaseRangeText:find("phase2_summon_count_min (phase2SummonCountMin) = 6", 1, true) ~= nil
    and phaseRangeText:find("phase2_summon_count_max (phase2SummonCountMax) = 6", 1, true) ~= nil,
    "阶段2援军数量区间被归一为 [6,6]")

-- 复原：区间、桩函数、奖池结果集与活跃 Boss
CONFIG_VALUES.minion_count_min, CONFIG_VALUES.minion_count_max = 1, 2
EXT_VALUES.phase2_summon_count_min, EXT_VALUES.phase2_summon_count_max = 3, 4
env.type, env.PerformIngameSpawn, env.GetPlayerByGUID = savedType, savedSpawn, savedGetPlayer
recorded.rewardPoolRows = nil
runConsoleCommand("boss clear")
runConsoleCommand("boss config reload")
assertEq(rewardPoolsSource(), "code", "口径回归段结束后奖池来源回到 code（桩结果集已清空）")
end

-- ------------------------------------------------- 跨重启恢复（运行态说"停服前有一只"）
-- 三段都必须成立：
--   1) status ∈ {spawned, engaged} 时加载只置标志，首个 tick 才重建（加载期地图/世界未必就绪）；
--      重建后血量按 health_pct 折算、技能预设沿用停服前那套、写 runtime_recovered 事件；
--   2) 时段外 → 不重建，写 runtime_recovered_skipped 并把运行态复位为 idle；
--   3) 运行态里的 entry 非法 → 写 runtime_recovery_failed + 复位 idle，且**不重试**。
-- 用"另加载一份 boss.lua"驱动：只有从加载那一刻就带上运行态行，才走得到真正的恢复分支。
io.write("\n== 跨重启恢复（首个 tick 重建） ==\n")
do
-- SQL VALUES 里的单元格带引号与空格：取值统一去引号 + 去首尾空白
local function scalarValue(text)
    return (tostring(text or ""):gsub("'", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 只从**写入语句**里取值：同一段里还有 CREATE TABLE 与写入后的回读 SELECT（都提及 runtime 表，
-- 但都没有 VALUES 列清单，直接取会拿到 nil）。
local function runtimeWriteValue(fromIndex, column, requiredMarker)
    local found = nil
    for index = fromIndex, #recorded.sql do
        local item = recorded.sql[index]
        if item.kind == "execute" and item.sql:find("boss_activity_runtime", 1, true)
            and item.sql:find("VALUES", 1, true)
            and (requiredMarker == nil or item.sql:find(requiredMarker, 1, true) ~= nil) then
            local value = insertColumnValue(item.sql, column)
            if value ~= nil then found = value end
        end
    end
    return found
end

local function withFreshBoss(runtimeValues, envOverrides, run)
    local savedCreature, savedPlayer = engineCallbacks.creature, engineCallbacks.player
    local savedRuntimeRow, savedPoolRows = recorded.runtimeRow, recorded.rewardPoolRows
    local savedScheduledCount = #scheduledEvents

    engineCallbacks.creature, engineCallbacks.player = {}, {}
    recorded.runtimeRow = runtimeValues
    recorded.rewardPoolRows = nil

    local childEnv = setmetatable(envOverrides or {}, {__index = env})
    local childChunk, childLoadErr = loadfile(bossPath, "t", childEnv)
    local result, runErr = nil, nil
    if not childChunk then
        fail("恢复段：副本加载失败: " .. tostring(childLoadErr))
    else
        captureGlobalPrint(function()
            local loadedOk, loadError = pcall(childChunk)
            if not loadedOk then runErr = loadError end
        end)
        if runErr == nil then
            local ranOk, callError = pcall(function()
                result = run({
                    creature = engineCallbacks.creature,
                    player = engineCallbacks.player,
                    scheduled = scheduledEvents,
                    scheduledFrom = savedScheduledCount + 1,
                    env = childEnv,
                })
            end)
            if not ranOk then runErr = callError end
        end
    end

    engineCallbacks.creature, engineCallbacks.player = savedCreature, savedPlayer
    recorded.runtimeRow, recorded.rewardPoolRows = savedRuntimeRow, savedPoolRows

    if runErr ~= nil then
        fail("恢复段：副本执行出错: " .. tostring(runErr))
    end
    return result
end

-- 恢复段专用的假 Boss：血量由 SetMaxHealth/SetHealth 真实记录，才能核对 60% 折算
local function recoveryBoss(guid)
    local boss = {__fake = true, guid = guid, maxHealth = 1000, health = 1000, yells = {}}
    boss.IsInWorld = function() return true end
    boss.IsAlive = function() return true end
    boss.IsInCombat = function() return false end
    boss.GetGUIDLow = function() return guid end
    boss.GetEntry = function() return 190090 end
    boss.GetName = function() return "送财童子" end
    boss.GetMapId = function() return 571 end
    boss.GetInstanceId = function() return 0 end
    boss.GetX = function() return 4353.573 end
    boss.GetY = function() return -4411.8877 end
    boss.GetZ = function() return 151.3909 end
    boss.GetO = function() return 0 end
    boss.GetMaxHealth = function() return boss.maxHealth end
    boss.GetHealth = function() return boss.health end
    boss.SetMaxHealth = function(_, value) boss.maxHealth = value end
    boss.SetHealth = function(_, value) boss.health = value end
    boss.SetLevel = function() end
    boss.SetScale = function() end
    boss.SetHomePosition = function() end
    -- 按模板重算基准血量：UpdateEntry 后模板上限必须可读（1000）
    boss.UpdateEntry = function() boss.maxHealth = 1000; boss.health = 1000 end
    boss.AddAura = function() end
    boss.RemoveAura = function() end
    boss.SendUnitYell = function(_, message) table.insert(boss.yells, tostring(message)) end
    boss.RemoveEvents = function() boss.events = {} end
    boss.RegisterEvent = function() end
    boss.GetPlayersInRange = function() return {} end
    boss.GetDistance = function() return 5 end
    return boss
end

local function runtimeValues(overrides)
    local values = {
        boss_guid = 424242, boss_entry = 190090, boss_name = "送财童子", map_id = 571, instance_id = 0,
        home_x = 4353.573, home_y = -4411.8877, home_z = 151.3909, phase = 2, status = "spawned",
        respawn_at = 0, last_spawn_at = 1, last_engage_at = 2, last_death_at = 0, last_reset_at = 0,
        schedule_state = "open", schedule_window = "20:00-22:00", schedule_next_change_at = 0,
        health_pct = 60, spawn_point_index = 1, last_health_sample_at = 3,
        skill_preset = "iron_vanguard", skill_difficulty = "raid",
    }
    for key, value in pairs(overrides or {}) do values[key] = value end
    return runtimeRow(values)
end

-- 时间段内（20:00-22:00）才能重建
setNow(os.time{year = 2026, month = 9, day = 1, hour = 21, min = 0, sec = 0})

-- 1) 成功路径：status='spawned' / health_pct=60 / spawn_point_index=1 / skill_preset=iron_vanguard
local spawnedBoss = recoveryBoss(777201)
local recoveryRun = withFreshBoss(runtimeValues({}), {
    PerformIngameSpawn = function() recorded.spawnAttempts = (recorded.spawnAttempts or 0) + 1; return spawnedBoss end,
}, function(context)
    local tick = nil
    for index = context.scheduledFrom, #context.scheduled do
        if context.scheduled[index].delay == 1000 and context.scheduled[index].repeats == 0 then
            tick = context.scheduled[index].fn
        end
    end

    local loadedLog = findLogLine("[恢复]检测到停服前的活跃 Boss")
    local sqlBoundary = #recorded.sql
    local spawnsBefore = recorded.spawnAttempts or 0
    if tick ~= nil then tick(0, 1000, 0) end

    local recoveredEvent, persistedStatus = false, nil
    for index = sqlBoundary + 1, #recorded.sql do
        local sql = recorded.sql[index].sql
        if sql:find("'runtime_recovered'", 1, true) then recoveredEvent = true end
    end
    persistedStatus = runtimeWriteValue(sqlBoundary + 1, "health_pct", "'spawned'")

    return {
        tickFound = tick ~= nil,
        loadedLog = loadedLog,
        spawned = (recorded.spawnAttempts or 0) - spawnsBefore,
        maxHealth = spawnedBoss.maxHealth,
        health = spawnedBoss.health,
        recoveredEvent = recoveredEvent,
        healthPctPersisted = persistedStatus,
        presetKey = bossLocal("ACTIVE_SKILL_PRESET_KEY", context),
        yells = table.concat(spawnedBoss.yells, " | "),
    }
end)

assertTrue(recoveryRun ~= nil, "恢复段（成功路径）跑完")
if recoveryRun ~= nil then
    assertTrue(recoveryRun.loadedLog ~= nil,
        "加载期检测到停服前的活跃 Boss 并只置标志（" .. tostring(recoveryRun.loadedLog) .. "）")
    assertTrue(recoveryRun.tickFound, "恢复段：拿到每秒 tick")
    assertEq(recoveryRun.spawned, 1, "首个 tick 重建了一只 Boss（PerformIngameSpawn 被调用 1 次）")
    assertEq(recoveryRun.health, math.floor(recoveryRun.maxHealth * 60 / 100 + 0.5),
        string.format("血量按 health_pct=60 折算（%d / %d）", recoveryRun.health, recoveryRun.maxHealth))
    assertTrue(recoveryRun.health < recoveryRun.maxHealth, "折算后血量低于满血（没有被 ApplyBossTraits 回满）")
    assertEq(recoveryRun.presetKey, "iron_vanguard",
        "技能预设沿用运行态里那一套（不是回落到配置默认 spellbreak_bulwark）")
    assertTrue(recoveryRun.recoveredEvent, "重建写入 event_type='runtime_recovered'")
    assertEq(tonumber(recoveryRun.healthPctPersisted), 60, "重建后把 health_pct 落库（面板运行状态可读）")
    assertTrue(tostring(recoveryRun.yells):find("DB恢复喊话-60%", 1, true) ~= nil,
        "恢复喊话里的 {HEALTH_PCT} 被替换（" .. tostring(recoveryRun.yells) .. "）")
end

-- 2) 时段外：不重建，写 runtime_recovered_skipped 并复位 idle
setNow(os.time{year = 2026, month = 9, day = 1, hour = 23, min = 0, sec = 0})
local skippedRun = withFreshBoss(runtimeValues({}), {
    PerformIngameSpawn = function() recorded.spawnAttempts = (recorded.spawnAttempts or 0) + 1; return nil end,
}, function(context)
    local tick = nil
    for index = context.scheduledFrom, #context.scheduled do
        if context.scheduled[index].delay == 1000 and context.scheduled[index].repeats == 0 then
            tick = context.scheduled[index].fn
        end
    end

    local sqlBoundary = #recorded.sql
    local spawnsBefore = recorded.spawnAttempts or 0
    if tick ~= nil then tick(0, 1000, 0) end

    local skippedEvent = false
    for index = sqlBoundary + 1, #recorded.sql do
        if recorded.sql[index].sql:find("'runtime_recovered_skipped'", 1, true) then skippedEvent = true end
    end

    return {
        spawned = (recorded.spawnAttempts or 0) - spawnsBefore,
        skippedEvent = skippedEvent,
        idleStatus = runtimeWriteValue(sqlBoundary + 1, "status", "'idle'"),
    }
end)

assertTrue(skippedRun ~= nil, "恢复段（时段外）跑完")
if skippedRun ~= nil then
    assertEq(skippedRun.spawned, 0, "时段外不重建 Boss（0 次生成尝试）")
    assertTrue(skippedRun.skippedEvent, "时段外写 event_type='runtime_recovered_skipped'")
    assertEq(scalarValue(skippedRun.idleStatus), "idle", "时段外把运行态复位为 idle")
end

-- 3) 运行态 entry 非法：写 runtime_recovery_failed + 复位 idle，且不重试
setNow(os.time{year = 2026, month = 9, day = 1, hour = 21, min = 0, sec = 0})
local failedRun = withFreshBoss(runtimeValues({boss_entry = 999999}), {
    PerformIngameSpawn = function() recorded.spawnAttempts = (recorded.spawnAttempts or 0) + 1; return nil end,
}, function(context)
    local tick = nil
    for index = context.scheduledFrom, #context.scheduled do
        if context.scheduled[index].delay == 1000 and context.scheduled[index].repeats == 0 then
            tick = context.scheduled[index].fn
        end
    end

    local firstBoundary = #recorded.sql
    local spawnsBefore = recorded.spawnAttempts or 0
    if tick ~= nil then tick(0, 1000, 0) end
    local spawnsAfterFirstTick = recorded.spawnAttempts or 0

    local failedEvent = false
    for index = firstBoundary + 1, #recorded.sql do
        if recorded.sql[index].sql:find("'runtime_recovery_failed'", 1, true) then failedEvent = true end
    end
    local idleAfterFailure = runtimeWriteValue(firstBoundary + 1, "status", "'idle'")

    -- 第二个 tick 必须不再写恢复事件（不重试）
    local secondBoundary = #recorded.sql
    local spawnsAfterFirst = recorded.spawnAttempts or 0
    if tick ~= nil then tick(0, 1000, 0) end

    local retriedEvent, secondSpawn = false, (recorded.spawnAttempts or 0) - spawnsAfterFirst
    for index = secondBoundary + 1, #recorded.sql do
        if recorded.sql[index].sql:find("'runtime_recovery_failed'", 1, true)
            or recorded.sql[index].sql:find("'runtime_recovered'", 1, true) then retriedEvent = true end
    end

    return {
        spawned = spawnsAfterFirstTick - spawnsBefore,
        failedEvent = failedEvent,
        idleStatus = idleAfterFailure,
        retriedEvent = retriedEvent,
        secondSpawn = secondSpawn,
    }
end)

assertTrue(failedRun ~= nil, "恢复段（entry 非法）跑完")
if failedRun ~= nil then
    assertEq(failedRun.spawned, 0, "entry 非法时不重建（PerformIngameSpawn 未被调用）")
    assertTrue(failedRun.failedEvent, "写 event_type='runtime_recovery_failed'")
    assertEq(scalarValue(failedRun.idleStatus), "idle", "失败后运行态复位为 idle")
    assertTrue(not failedRun.retriedEvent, "失败不在第二个 tick 重试（只写一次恢复事件）")
    -- 第二个 tick 会回到定时启停的正常分支（时段内 + 没有活跃 Boss → 正常补刷）：这是设计
    io.write(string.format("  [info] 恢复失败后的第二个 tick：补刷尝试 %d 次（回到定时启停的正常分支，属设计）\n",
        failedRun.secondSpawn))
end

assertTrue(findLogLine("[恢复]") ~= nil, "恢复段会写 [恢复] 日志")
end

-- ------------------------------------------------- 写库失败可见性（BossSql.exec）
-- CharDBExecute 在 mod-ale 里**没有返回值**，所以"写失败"只能靠 pcall + 回读校验暴露：
-- 失败要计数、要打印日志、要能从 .boss config reload 的回执里看到，且不能让脚本半死不活。
io.write("\n== 写库失败可见性 ==\n")
do
local bossSql = bossLocal("BossSql")
assertTrue(type(bossSql) == "table" and type(bossSql.failures) == "table",
    "取到文件内 local BossSql（写库失败计数）")

local failuresBefore = type(bossSql) == "table" and tonumber(bossSql.failures.count) or 0
recorded.failNextExecute = true
local reloadMessages = runConsoleCommand("boss config reload")
local reloadMarkers, reloadText = markersOf(reloadMessages)
local failuresAfter = type(bossSql) == "table" and tonumber(bossSql.failures.count) or 0

assertEq(failuresAfter, failuresBefore + 1, "一次写库异常 → 失败计数 +1（失败不会静默）")
assertTrue(findLogLine("[配置]写库失败[") ~= nil,
    "写库失败会打印 [配置]写库失败[...] 日志（" .. tostring(findLogLine("[配置]写库失败[")) .. "）")
assertTrue(reloadMarkers:find("AGMP_OK", 1, true) ~= nil,
    "一次写库失败不会让 .boss config reload 变成失败（脚本没有半死）")
assertTrue(reloadText:find("写库失败: " .. tostring(failuresAfter), 1, true) ~= nil,
    "reload 回执里带上写库失败次数（" .. tostring(failuresAfter) .. " 次），GM 能看到")
assertEq(recorded.failNextExecute, false, "注入只用一次（后续写入正常）")

-- 回读校验也走同一条路：写入执行成功但读不回来 → 同样计入失败
local verifiedBefore = tonumber(bossSql.failures.count) or 0
recorded.runtimeVerifyFails = true
runConsoleCommand("boss config reload")
recorded.runtimeVerifyFails = false
assertTrue((tonumber(bossSql.failures.count) or 0) > verifiedBefore,
    "写入后回读不到数据也计入失败（语句执行成功 ≠ 数据落地）")

local helpText = table.concat(runConsoleCommand("boss help"), " | ")
assertTrue(helpText:find("写库失败", 1, true) ~= nil, ".boss help 报告写库失败状态")
end

-- ------------------------------------------------- 多区绑定（本区库名 / state_key）

-- boss.lua 的「多区支持」只有一句话：部署到不同区时只改 §2 的 key
-- （BOSS_RUNTIME_KEY / BOSS_CONFIG_KEY，两行必须相同），四张表都靠这个 state_key 分租。
-- 这里把常量改写后**重新加载一遍**，既核对 SQL 用的库名，也核对写入带的是本区 key。
-- 为什么必须动态重载而不是只看源码：真正的风险是"某处又写死了 ac_eluna / 'current'"，
-- 写死的值不会出现在源码里那两个常量上，只有跑起来才会在 SQL 里露出来。
io.write("\n== 多区绑定（共用库 + state_key 分租） ==\n")

local function isDbQualified(sql)
    return sql:find("`boss_activity", 1, true) ~= nil
        or sql:find("`boss_reward_pools`", 1, true) ~= nil
        or sql:find("CREATE DATABASE", 1, true) ~= nil
end

-- 返回 (引用了库名的语句数, 其中库名不对的语句数)
local function auditBinding(sqlList, expectDb, label)
    local qualified, wrong = 0, 0
    local samples = {}
    for _, item in ipairs(sqlList) do
        if isDbQualified(item.sql) then
            qualified = qualified + 1
            local rest = item.sql:gsub("`" .. expectDb .. "`", "")
            if item.sql:find("`" .. expectDb .. "`", 1, true) == nil or rest:find("`ac_eluna", 1, true) ~= nil then
                wrong = wrong + 1
                samples[#samples + 1] = item.sql
            end
        end
    end

    assertTrue(qualified > 0, label .. "：存在引用本区库的语句（检查项没有空跑）")
    assertTrue(wrong == 0, label .. "：每条都指向 " .. expectDb .. "（不符 " .. wrong .. "/" .. qualified .. " 条）")
    for i = 1, math.min(#samples, 3) do
        io.write("        " .. samples[i]:sub(1, 160) .. "\n")
    end
end

-- 取 INSERT 语句的第一个字符串值 —— 事件/贡献表里它就是 state_key
local function firstInsertValue(sql)
    return sql:match("VALUES%s*%(%s*'([^']*)'")
end

auditBinding(recorded.sql, "ac_eluna", "默认部署(ac_eluna)")

-- 模拟把同一份 boss.lua 部署到第二个区：多区共用库，所以只改 §2 的 key（库名不变）
local sourceHandle = assert(io.open(bossPath, "r"))
local source = sourceHandle:read("*a")
sourceHandle:close()

local targetDb, targetRuntimeKey = "ac_eluna", "realm-b"
local rewritten, dbSubs = source:gsub('(local BOSS_DB_NAME%s*=%s*")[^"]*(")', "%1" .. targetDb .. "%2", 1)
local rewrittenKey, keySubs = rewritten:gsub('(local BOSS_RUNTIME_KEY%s*=%s*")[^"]*(")', "%1" .. targetRuntimeKey .. "%2", 1)
local rewrittenConfigKey, configKeySubs = rewrittenKey:gsub('(local BOSS_CONFIG_KEY%s*=%s*")[^"]*(")', "%1" .. targetRuntimeKey .. "%2", 1)
assertTrue(dbSubs == 1, "BOSS_DB_NAME 常量可被改写（deploy-realm 脚本依赖同一处）")
assertTrue(keySubs == 1, "BOSS_RUNTIME_KEY 常量可被改写")
assertTrue(configKeySubs == 1, "BOSS_CONFIG_KEY 常量可被改写（面板用同一个 key 读写四张表）")

local bindingLogs = {}
local childEnv = setmetatable({
    print = function(msg) table.insert(bindingLogs, tostring(msg)) end,
}, { __index = env })

local boundary = #recorded.sql
-- 子环境加载会把自己的回调注册进 engineCallbacks，若共用同一张表就会**顶掉主会话的回调**
-- （后续 bossLocal 会取到子环境的 local）。这里临时换成空表，跑完再把主会话的表装回去。
local savedEngineCreature, savedEnginePlayer = engineCallbacks.creature, engineCallbacks.player
engineCallbacks.creature, engineCallbacks.player = {}, {}
local childChunk, childErr = load(rewrittenConfigKey, "@" .. bossPath .. ":realm-rewrite", "t", childEnv)
if not childChunk then
    fail("改写后加载失败: " .. tostring(childErr))
else
    local childOk, childRunErr = pcall(childChunk)
    if not childOk then
        fail("改写后运行期错误: " .. tostring(childRunErr))
    end
end

-- 用子环境跑一条会写事件的命令（boss config reload → command_config_reload，无活跃 Boss 也会写），
-- 断言事件 INSERT 带的是**本区 key** 而不是默认的 current。注意命令串按核心的约定不带前导点
-- （AzerothCore 把 "." 去掉后才交给 handler，runConsoleCommand 传的是去掉点之后的字符串）。
-- 贡献表的写入在离线环境里跑不到（需要真的打死 Boss），所以它的列清单用源码静态检查兜底。
runConsoleCommand("boss config reload")
engineCallbacks.creature, engineCallbacks.player = savedEngineCreature, savedEnginePlayer
local childSql = {}
for i = boundary + 1, #recorded.sql do childSql[#childSql + 1] = recorded.sql[i] end
auditBinding(childSql, targetDb, "改为 key=" .. targetRuntimeKey .. " 的部署")

local eventInsertKey, eventInsertSeen = nil, false
for _, item in ipairs(childSql) do
    if item.sql:find("INSERT INTO", 1, true) and item.sql:find("boss_activity_events", 1, true) then
        eventInsertSeen = true
        eventInsertKey = firstInsertValue(item.sql)
    end
end
assertTrue(eventInsertSeen, "改写 key 后仍有事件写入语句（boss config reload → command_config_reload）")
assertTrue(eventInsertKey == targetRuntimeKey,
    "事件写入带的是本区 key（实际 " .. tostring(eventInsertKey) .. "，期望 " .. targetRuntimeKey .. "）")

assertTrue(source:find("`state_key`, `boss_guid`, `boss_entry`, `boss_name`, `event_type`", 1, true) ~= nil,
    "事件表 INSERT 的列清单含 state_key（结构回归）")
assertTrue(source:find("`state_key`, `boss_guid`, `boss_entry`, `boss_name`, `player_guid`", 1, true) ~= nil,
    "贡献表 INSERT 的列清单含 state_key（结构回归）")
assertTrue(source:find("EnsureBossSchemaColumn(BOSS_EVENT_TABLE, 'state_key'", 1, true) ~= nil
    and source:find("EnsureBossSchemaColumn(BOSS_CONTRIBUTOR_TABLE, 'state_key'", 1, true) ~= nil,
    "老库缺列时自动补 state_key（零迁移升级）")
assertTrue(source:find("EnsureBossSchemaIndex(BOSS_EVENT_TABLE, 'idx_state_key_id'", 1, true) ~= nil,
    "事件表自动补 (state_key, id) 索引")

-- 启动自检日志必须报出本区绑定：运维靠它确认没串区
local bindingLine = nil
for _, line in ipairs(bindingLogs) do
    if line:find("本区绑定", 1, true) then bindingLine = line end
end
assertTrue(bindingLine ~= nil, "启动时打印本区绑定日志")
if bindingLine then
    assertTrue(bindingLine:find(targetDb, 1, true) ~= nil
        and bindingLine:find(targetRuntimeKey, 1, true) ~= nil,
        "绑定日志内容与本区一致（库名 + state_key）")
end

-- state_key 也必须跟着走：runtime 的引导/查询语句里要用改写后的 key
local keySeen = false
for _, item in ipairs(childSql) do
    if item.sql:find("boss_activity_runtime", 1, true) and item.sql:find(targetRuntimeKey, 1, true) then
        keySeen = true
    end
end
assertTrue(keySeen, "runtime 语句使用本区 state_key（" .. targetRuntimeKey .. "）")

-- 奖池查询同样按改写后的 key 走（不是写死的 'current'）
local poolKeySeen = false
for _, item in ipairs(childSql) do
    if item.sql:find("`boss_reward_pools`", 1, true) and item.sql:find("SELECT", 1, true)
        and item.sql:find("`state_key` = '" .. targetRuntimeKey .. "'", 1, true) then
        poolKeySeen = true
    end
end
assertTrue(poolKeySeen, "奖池查询使用本区 state_key（" .. targetRuntimeKey .. "）")

-- ===================================================================== 批 5：趣味与智能增强
-- 覆盖：条件阈值/评分权重/连招概率/条目启停/读条开关（参数层）、威胁因子与终选窗口、
--       软狂暴、团灭判定、点名预警、生成/阶段/恢复世界公告、移动门控接入。
io.write("\n== 批 5：趣味与智能增强 ==\n")
;(function()
local feelConfig = bossLocal("BOSS_CONFIG")
local feelSkillAI = bossLocal("SkillAI")
local feelTargetSelector = bossLocal("TargetSelector")
local applySkillConfig = bossLocal("ApplySkillConfig")
assertTrue(type(feelConfig) == "table", "批 5：取到运行期 BOSS_CONFIG")
assertTrue(type(feelSkillAI) == "table" and type(feelTargetSelector) == "table",
    "批 5：取到 SkillAI / TargetSelector")

-- 假对象按 userdata 处理（IsUnitValid 要求 type() == "userdata"），与连招段/奖池实发段同一手法
local savedFeelType = env.type
env.type = function(value)
    if type(value) == "table" and rawget(value, "__fake") then return "userdata" end
    return savedFeelType(value)
end

-- ---------------------------------------------------------------- 1. 参数层：新分组取自数据库
assertTrue(showGroup("enrage"):find("soft_enrage_seconds (softEnrageSeconds) = 120", 1, true) ~= nil,
    "批 5：[enrage] 秒数取自数据库（120，非文件默认 300）")
assertTrue(showGroup("feel_target"):find("target_random_spread_pct (targetRandomSpreadPct) = 0", 1, true) ~= nil,
    "批 5：[feel_target] 终选窗口取自数据库（0，非文件默认 25）")
assertTrue(showGroup("wipe"):find("wipe_grace_seconds (wipeGraceSec) = 20", 1, true) ~= nil,
    "批 5：[wipe] 宽限期取自数据库（20，非文件默认 12）")
assertTrue(showGroup("announce"):find("announce_phase_enabled (announcePhaseEnabled) = false", 1, true) ~= nil,
    "批 5：[announce] 阶段公告开关取自数据库（关）")
assertTrue(showGroup("marker"):find("marker_warning_delay_seconds (markerWarningDelaySec) = 3", 1, true) ~= nil,
    "批 5：[marker] 预警延迟取自数据库（3，非文件默认 2）")
assertTrue(showGroup("taunts"):find("DB团灭喊话", 1, true) ~= nil,
    "批 5：[taunts] 新增三组喊话取自数据库")

assertEq(env.GetConditionThreshold("many_attackers"), 5,
    "批 5：条件阈值取数据库值（many_attackers=5，非文件默认 4）")
assertEq(env.GetConditionThreshold("multi_melee_range"), 8,
    "批 5：数据库没写到的条件键回退脚本默认（multi_melee_range=8）")
assertEq(env.GetScoreWeight("casting"), 45,
    "批 5：评分权重取数据库值（casting=45，非文件默认 50）")
assertEq(env.GetScoreWeight("class_healer"), 40,
    "批 5：数据库没写到的权重键回退脚本默认（class_healer=40）")

-- ---------------------------------------------------------------- 2. 条件阈值真的参与判定
local function feelUnit(guidLow, unitName, classId)
    local unit = {__fake = true, guidLow = guidLow, name = unitName, classId = classId or 1,
        threat = 0, healthPct = 100, casting = false, alive = true}
    unit.IsInWorld = function() return true end
    unit.IsAlive = function() return unit.alive end
    unit.IsPlayer = function() return true end
    unit.GetGUIDLow = function() return unit.guidLow end
    unit.GetGUID = function() return unit.guidLow end
    unit.GetName = function() return unit.name end
    unit.GetClass = function() return unit.classId end
    unit.GetHealthPct = function() return unit.healthPct end
    unit.IsCasting = function() return unit.casting end
    unit.GetDistance = function() return 5 end
    return unit
end

local thresholdCreature = {__fake = true, healthPct = 100}
thresholdCreature.IsInWorld = function() return true end
thresholdCreature.GetHealthPct = function() return thresholdCreature.healthPct end
thresholdCreature.GetThreatList = function() return {} end
thresholdCreature.GetDistance = function() return 5 end

local fourEnemies = {}
for i = 1, 4 do fourEnemies[i] = feelUnit(900 + i, "敌方" .. i) end
thresholdCreature.GetThreatList = function() return fourEnemies end
assertTrue(feelSkillAI:CheckCondition("many_attackers", thresholdCreature, nil) == false,
    "批 5：many_attackers 阈值 5 时 4 个敌人不成立（阈值来自数据库）")

local fiveEnemies = {}
for i = 1, 5 do fiveEnemies[i] = feelUnit(910 + i, "敌方" .. i) end
thresholdCreature.GetThreatList = function() return fiveEnemies end
assertTrue(feelSkillAI:CheckCondition("many_attackers", thresholdCreature, nil) == true,
    "批 5：many_attackers 阈值 5 时 5 个敌人成立")

local targetLowHp = feelUnit(930, "残血目标")
targetLowHp.healthPct = 20
assertTrue(feelSkillAI:CheckCondition("low_hp_target", thresholdCreature, targetLowHp) == true,
    "批 5：low_hp_target 用脚本默认阈值（25%）判定成立")
targetLowHp.healthPct = 40
assertTrue(feelSkillAI:CheckCondition("low_hp_target", thresholdCreature, targetLowHp) == false,
    "批 5：low_hp_target 在 40% 血时不成立")

-- ---------------------------------------------------------------- 3. 威胁因子与终选窗口
local tank = feelUnit(601, "坦克"); tank.threat = 900; tank.classId = 1
local dps = feelUnit(602, "输出"); dps.threat = 100; dps.classId = 1
local threatCreature = {__fake = true}
threatCreature.IsInWorld = function() return true end
threatCreature.GetDistance = function() return 5 end
threatCreature.GetThreat = function(_, unit) return unit.threat or 0 end

feelConfig.threatFactorEnabled = true
local threatContext = env.BuildThreatContext(threatCreature, {tank, dps})
assertEq(threatContext.maxThreat, 900, "批 5：威胁上下文记录最高威胁值")
local tankScore = feelTargetSelector:GetThreatScore(tank, threatCreature, threatContext)
local dpsScore = feelTargetSelector:GetThreatScore(dps, threatCreature, threatContext)
assertTrue(tankScore > dpsScore,
    string.format("批 5：威胁因子开启后高仇恨目标评分更高（坦克 %.1f > 输出 %.1f）", tankScore, dpsScore))
feelConfig.threatFactorEnabled = false
local noThreatContext = env.BuildThreatContext(threatCreature, {tank, dps})
local tankScoreOff = feelTargetSelector:GetThreatScore(tank, threatCreature, noThreatContext)
local dpsScoreOff = feelTargetSelector:GetThreatScore(dps, threatCreature, noThreatContext)
assertEq(tankScoreOff, dpsScoreOff, "批 5：威胁因子关闭时同职业同血量目标评分相同（仇恨不参与）")
assertTrue(tankScoreOff < tankScore, "批 5：关闭威胁因子后评分回落（威胁加分被移除）")
feelConfig.threatFactorEnabled = true

local pickCandidates = {
    {unit = tank, score = 100},
    {unit = dps, score = 95},
}
local narrowPick = env.PickCandidateWithinSpread(pickCandidates, 0)
assertTrue(narrowPick.unit == tank, "批 5：终选窗口 0 → 只取最高分候选")
local seenInWindow = {}
for _ = 1, 100 do
    local picked = env.PickCandidateWithinSpread(pickCandidates, 25)
    seenInWindow[picked.unit] = true
end
assertTrue(seenInWindow[tank] == true and seenInWindow[dps] == true,
    "批 5：终选窗口 25% → 分差在窗口内的两个候选都会被选中")
local wideCandidates = {
    {unit = tank, score = 100},
    {unit = dps, score = 50},
}
local strictPick = env.PickCandidateWithinSpread(wideCandidates, 25)
assertTrue(strictPick.unit == tank, "批 5：分差超出窗口的候选不参与随机（100 vs 50）")

-- ---------------------------------------------------------------- 4. 世界公告
feelConfig.announcePhaseEnabled = true
local beforeAnnounce = #recorded.replies
env.BossAnnounce("phase", {BOSS_NAME = "送财童子", PHASE = 2, HEALTH_PCT = 55})
local announceText = table.concat(recorded.replies, " | ", beforeAnnounce + 1, #recorded.replies)
assertTrue(announceText:find("[WORLD]", 1, true) ~= nil, "批 5：阶段世界公告已发出")
assertTrue(announceText:find("DB 阶段公告 2", 1, true) ~= nil,
    "批 5：公告文案取自数据库且 {PHASE} 已替换")
feelConfig.announcePhaseEnabled = false
local beforeSilent = #recorded.replies
env.BossAnnounce("phase", {BOSS_NAME = "送财童子", PHASE = 3})
assertEq(#recorded.replies, beforeSilent, "批 5：关闭开关后不发世界公告")
feelConfig.announcePhaseEnabled = true
local unknownEvent = env.BossAnnounce("no_such_event", {})
assertTrue(unknownEvent == false, "批 5：未登记的事件键不发公告")

-- ---------------------------------------------------------------- 5. 软狂暴
local function feelBossShell(guidLow)
    local boss = {__fake = true, guidLow = guidLow, casts = {}, yells = {}, speeds = {},
        maxHealth = 1000, health = 1000, moved = 0}
    boss.IsInWorld = function() return true end
    boss.IsAlive = function() return true end
    boss.GetGUIDLow = function() return boss.guidLow end
    boss.GetEntry = function() return 190090 end
    boss.GetName = function() return "送财童子" end
    boss.GetMapId = function() return 571 end
    boss.GetInstanceId = function() return 0 end
    boss.GetX = function() return 4108.16 end
    boss.GetY = function() return 5316.85 end
    boss.GetZ = function() return 28.76 end
    boss.GetMaxHealth = function() return boss.maxHealth end
    boss.SetHealth = function(_, value) boss.health = value end
    boss.GetHealthPct = function() return 90 end
    boss.GetSpeedRate = function() return 1 end
    boss.SetSpeed = function(_, moveType, rate) table.insert(boss.speeds, {moveType = moveType, rate = rate}) end
    boss.CastSpell = function(_, target, spellId, triggered)
        table.insert(boss.casts, {spellId = tonumber(spellId), target = target, triggered = triggered})
        return true
    end
    boss.SendUnitYell = function(_, message) table.insert(boss.yells, tostring(message)) end
    boss.AttackStop = function() boss.attackStopped = true end
    boss.ClearThreatList = function() boss.threatCleared = true end
    boss.GetThreatList = function() return boss.threatList or {} end
    boss.GetVictim = function() return boss.victim end
    boss.GetDistance = function() return 5 end
    return boss
end

local enrageBoss = feelBossShell(8801)
feelConfig.softEnrageEnabled = true
local enrageState = {combatTime = 0}
env.UpdateSoftEnrage(enrageBoss, enrageState)
assertEq(enrageState.softEnrageStacks or 0, 0, "批 5：未到软狂暴起算时间不叠层")
enrageState.combatTime = 120000
env.UpdateSoftEnrage(enrageBoss, enrageState)
assertEq(enrageState.softEnrageStacks, 1, "批 5：到 120 秒叠第 1 层（起算时间取自数据库）")
assertEq(#enrageBoss.casts, 1, "批 5：叠层施放强化法术")
assertEq(enrageBoss.casts[1].spellId, 8600, "批 5：强化法术取数据库值（8600）")
assertEq(#enrageBoss.speeds, 1, "批 5：叠层调整移动速度")
assertTrue(math.abs(enrageBoss.speeds[1].rate - 1.07) < 1e-6,
    "批 5：移速 = 基准 × (1 + 7% × 层数)（实际 " .. tostring(enrageBoss.speeds[1].rate) .. "）")
assertEq(#enrageBoss.yells, 1, "批 5：叠层喊话一次（文本取自数据库）")
for _ = 1, 8 do
    enrageState.combatTime = enrageState.combatTime + 15000
    env.UpdateSoftEnrage(enrageBoss, enrageState)
end
assertEq(enrageState.softEnrageStacks, 4, "批 5：层数不超过上限（数据库值 4）")
feelConfig.softEnrageEnabled = false

-- ---------------------------------------------------------------- 6. 团灭判定
local wipeBoss = feelBossShell(8802)
local wipeState = {}
local deadPlayer = feelUnit(940, "已阵亡"); deadPlayer.alive = false
local wipeThreat = {deadPlayer}
feelConfig.wipeDetectEnabled = true
assertTrue(env.CheckBossWipe(wipeBoss, wipeState, wipeThreat, 5000) == false,
    "批 5：团灭宽限期内不停手")
for _ = 1, 5 do env.CheckBossWipe(wipeBoss, wipeState, wipeThreat, 5000) end
assertTrue(wipeBoss.attackStopped == true, "批 5：团灭后停手（AttackStop）")
assertTrue(wipeBoss.threatCleared == true, "批 5：团灭后清仇恨（ClearThreatList）")
assertEq(wipeBoss.health, 800, "批 5：团灭后回血到数据库值 80%")
assertTrue(#wipeBoss.yells >= 1 and wipeBoss.yells[1]:find("DB团灭喊话", 1, true) ~= nil,
    "批 5：团灭喊话取自数据库")
local alivePlayer = feelUnit(941, "存活者")
assertTrue(env.CheckBossWipe(wipeBoss, wipeState, {alivePlayer}, 5000) == false,
    "批 5：威胁表里还有存活单位时不判团灭")
assertEq(wipeState.wipeElapsedMs, 0, "批 5：出现存活单位后团灭计时清零")

-- ---------------------------------------------------------------- 7. 点名预警
local warnBoss = feelBossShell(8803)
local warnPlayer = feelUnit(501, "测试玩家")
local warnState = {combatTime = 1000}
local warnSkill = {spellId = 64213, name = "闪电链", minCD = 5, maxCD = 6,
    target = "victim", priority = 7, condition = "none"}
feelConfig.markerWarningEnabled = true
assertTrue(feelSkillAI:TryMarkerWarning(warnBoss, warnPlayer, warnSkill, warnState, "phase1CD") == true,
    "批 5：单体点名技能先进入预警（不立即出手）")
assertEq(warnBoss.casts[1].spellId, 467, "批 5：预警给目标挂标记光环（数据库法术 467）")
assertEq(warnBoss.casts[1].triggered, true, "批 5：标记光环按触发式施放（无前摇）")
assertTrue(type(warnState.pendingWarn) == "table" and warnState.pendingWarn.skill == warnSkill,
    "批 5：预警记入 pendingWarn（同一技能不会重复预警）")
assertEq(#warnBoss.yells, 1, "批 5：预警喊话一次")
assertTrue(warnBoss.yells[1]:find("测试玩家", 1, true) ~= nil,
    "批 5：预警喊话的 {PLAYER_NAME} 已替换为被点名者")
feelSkillAI:ResolvePendingWarning(warnBoss, warnState)
assertEq(#warnBoss.casts, 1, "批 5：未到预警延迟不出手")
warnState.combatTime = warnState.combatTime + 3000
feelSkillAI:ResolvePendingWarning(warnBoss, warnState)
assertEq(#warnBoss.casts, 2, "批 5：延迟到点后真正出手")
assertEq(warnBoss.casts[2].spellId, 64213, "批 5：延迟后施放的是被预警的原技能")
assertTrue(warnState.pendingWarn == nil, "批 5：出手后清空预警状态")
assertTrue(warnState.phase1CD ~= nil, "批 5：出手后按技能冷却记账（phase1CD）")
assertTrue(feelSkillAI:TryMarkerWarning(warnBoss, warnPlayer, {spellId = 1, target = "self"}, warnState, "phase1CD") == false,
    "批 5：自身目标技能不触发点名预警")
feelConfig.markerWarningEnabled = false
assertTrue(feelSkillAI:TryMarkerWarning(warnBoss, warnPlayer, warnSkill, warnState, "phase1CD") == false,
    "批 5：关闭点名预警后直接出手（不预警）")
feelConfig.markerWarningEnabled = true

-- ---------------------------------------------------------------- 8. 读条 / 瞬发开关
local castBoss = feelBossShell(8804)
local castState = {}
feelConfig.skillInstantCast = true
feelSkillAI:CastSkill(castBoss, warnPlayer, warnSkill, castState)
assertEq(castBoss.casts[1].triggered, true, "批 5：瞬发开关开启时按触发式施放（无前摇）")
feelConfig.skillInstantCast = false
feelSkillAI:CastSkill(castBoss, warnPlayer, warnSkill, castState)
assertEq(castBoss.casts[2].triggered, false, "批 5：瞬发开关关闭时走读条（有前摇、可被打断）")

-- ---------------------------------------------------------------- 9. 条目启停（每预设禁用 spellId）
local activePresetKey = bossLocal("ACTIVE_SKILL_PRESET_KEY")
assertTrue(type(activePresetKey) == "string", "批 5：取到当前生效预设 key（" .. tostring(activePresetKey) .. "）")
local function poolSpellIds()
    local ids, pools = {}, bossLocal("SKILL_POOLS") or {}
    for _, pool in pairs(pools) do
        for _, skill in ipairs(pool) do ids[#ids + 1] = tonumber(skill.spellId) end
    end
    return ids
end
local idsBefore = poolSpellIds()
assertTrue(#idsBefore > 0, "批 5：禁用前技能池非空")
local disabledSpellId = idsBefore[1]
if type(applySkillConfig) == "function" and type(activePresetKey) == "string" then
    feelConfig.disabledSkills = {[activePresetKey] = tostring(disabledSpellId)}
    applySkillConfig(activePresetKey, "standard")
    local idsAfter = poolSpellIds()
    local stillPresent = false
    for _, spellId in ipairs(idsAfter) do
        if spellId == disabledSpellId then stillPresent = true end
    end
    assertTrue(stillPresent == false,
        "批 5：被禁用的 spellId 已从技能池剔除（" .. tostring(disabledSpellId) .. "）")
    assertEq(#idsAfter, #idsBefore - (function()
        local count = 0
        for _, spellId in ipairs(idsBefore) do if spellId == disabledSpellId then count = count + 1 end end
        return count
    end)(), "批 5：启停只剔除目标条目，其余技能池条目数量不变")

    local comboStillPresent = false
    for _, combo in ipairs(bossLocal("COMBO_CHAINS") or {}) do
        for _, skillInfo in ipairs(combo.skills or {}) do
            if tonumber(skillInfo[1]) == disabledSpellId then comboStillPresent = true end
        end
    end
    assertTrue(comboStillPresent == false, "批 5：被禁用的 spellId 也已从连招里剔除")

    local openingStillPresent = false
    for _, skill in ipairs(bossLocal("OPENING_SKILLS") or {}) do
        if tonumber(skill.spellId) == disabledSpellId then openingStillPresent = true end
    end
    assertTrue(openingStillPresent == false, "批 5：被禁用的 spellId 也已从开场技能里剔除")

    feelConfig.disabledSkills = {}
    applySkillConfig(activePresetKey, "standard")
    assertEq(#poolSpellIds(), #idsBefore, "批 5：清空启停配置后技能池恢复原样")
else
    fail("批 5：取不到 ApplySkillConfig，无法验证条目启停")
end

-- ---------------------------------------------------------------- 10. 主循环接入（结构回归）
assertTrue(type(env.VerifyBossSchemaContracts) == "function", "批 5：列契约自检可作为全局函数调用")
if type(env.VerifyBossSchemaContracts) == "function" then
    local contractOk, contractMissing = env.VerifyBossSchemaContracts()
    assertTrue(contractOk == true or type(contractMissing) == "table",
        "批 5：健康快照下列契约自检可正常求值")
end
-- 列契约自检与"刚补列"过滤：实机（2026-10-01）发现 information_schema 对刚 ALTER 的列可能滞后读到，
-- 会把补列成功误报成缺列 → 本轮写库被整轮跳过；这里直接驱动过滤函数核对语义。
local filterJustAdded = env.FilterJustAddedColumns
local markJustAdded = env.MarkBossSchemaColumnJustAdded
assertTrue(type(filterJustAdded) == "function" and type(markJustAdded) == "function",
    "批 5：取到列契约的「刚补列」过滤函数")
if type(filterJustAdded) == "function" and type(markJustAdded) == "function" then
    markJustAdded("smoke_tmp_table", "just_added_col")
    local remainingMissing = filterJustAdded({
        "smoke_tmp_table.just_added_col", "smoke_tmp_table.still_missing_col",
    })
    assertEq(#remainingMissing, 1, "批 5：刚补成功的列被摘出缺列名单，其余缺列保留")
    assertEq(remainingMissing[1], "smoke_tmp_table.still_missing_col",
        "批 5：摘出的正是刚补的那一列（其余缺列仍会上报 → 跳过写库）")
end
assertTrue(source:find("FilterJustAddedColumns(missingColumns)", 1, true) ~= nil,
    "批 5：列契约自检接入「刚补列」过滤（避免 I_S 滞后误报导致跳过写库）")
assertTrue(source:find("MarkBossSchemaColumnJustAdded(tableName, columnName)", 1, true) ~= nil,
    "批 5：只有补列 + 回读校验都成功才登记为刚补列（真补失败仍报缺列）")
assertTrue(source:find("BossSql.record(\"列契约自检\"", 1, true) ~= nil,
    "批 5：列契约自检失败仍计入写库失败可见性（.boss config show 能看到）")
assertTrue(source:find("UpdateSoftEnrage(creature, state)", 1, true) ~= nil,
    "批 5：主循环接入软狂暴")
assertTrue(source:find("if CheckBossWipe(creature, state, currentThreatList, delay) then return end", 1, true) ~= nil,
    "批 5：主循环接入团灭判定")
assertTrue(source:find("SkillAI:ResolvePendingWarning(creature, state)", 1, true) ~= nil,
    "批 5：主循环接入点名预警结算")
assertTrue(source:find("not TargetSelector:IsCasting(creature) and TacticalAI:ShouldChase(creature, target)", 1, true) ~= nil,
    "批 5：移动纳入空闲门控（读条期间不下发移动指令）")
assertTrue(source:find('BossAnnounce("spawn", {BOSS_NAME = bossName', 1, true) ~= nil,
    "批 5：生成路径接世界公告")
assertTrue(source:find('BossAnnounce("restore", {BOSS_NAME = bossName', 1, true) ~= nil,
    "批 5：跨重启恢复路径接世界公告")
assertTrue(source:find('BossAnnounce("phase"', 1, true) ~= nil,
    "批 5：阶段切换接世界公告")
assertTrue(source:find("skill.condition, creature, target", 1, true) ~= nil and
    source:find('GetConditionThreshold("many_attackers")', 1, true) ~= nil,
    "批 5：条件判定走可配阈值（CheckCondition 已改用 GetConditionThreshold）")
env.type = savedFeelType
end)()


-- --------------------------------------------------------------------- 汇总
-- 可选：把本次运行生成的所有 SQL 落盘，便于人工复核语句是否符合预期。
--   lua.exe smoke.lua <boss.lua> --dump-sql <out.sql>
--   lua.exe smoke.lua <boss.lua> --dump-sql <out.sql> --include-ddl
--
-- ⚠⚠ 安全警告（2026-09-23 真的踩过）：
--   不要把导出的 SQL 直接丢进「真实库 + START TRANSACTION / ROLLBACK」里跑！
--   导出文件里含 CREATE DATABASE / CREATE TABLE 这类 DDL，而 MySQL 的 DDL 会**隐式提交**，
--   事务会被提前结束，后面的 UPDATE / REPLACE INTO 就真的落库了（当时覆盖了线上
--   boss_activity_config 的 spawn_points_text、skill_preset 等字段）。
--   要校验 DML 语法，请改用**一次性 scratch 库**：
--       CREATE DATABASE boss_verify;  -- 建同名结构（CREATE TABLE ... LIKE / INSERT ... SELECT）
--       把导出 SQL 里的 `ac_eluna` 替换成 `boss_verify` 后执行，最后 DROP DATABASE。
--   因此默认导出会**过滤掉 DDL**，只留 INSERT/REPLACE/UPDATE/DELETE（--include-ddl 可强制包含）。
local dumpIndex = nil
local includeDdl = false
for i = 1, #arg do
    if arg[i] == "--dump-sql" then dumpIndex = i end
    if arg[i] == "--include-ddl" then includeDdl = true end
end
if dumpIndex and arg[dumpIndex + 1] then
    local out = io.open(arg[dumpIndex + 1], "w")
    if out then
        local written, skipped = 0, 0
        for _, item in ipairs(recorded.sql) do
            local head = item.sql:gsub("^%s+", ""):upper()
            local isDdl = head:match("^CREATE") or head:match("^DROP") or head:match("^ALTER")
            if isDdl and not includeDdl then
                skipped = skipped + 1
            else
                out:write(item.sql:gsub(";%s*$", "") .. ";\n")
                written = written + 1
            end
        end
        out:close()
        io.write(string.format("  已导出 SQL: %s（%d 条；跳过 DDL %d 条）\n",
            arg[dumpIndex + 1], written, skipped))
    else
        fail("无法写入 SQL 导出文件: " .. tostring(arg[dumpIndex + 1]))
    end
end

io.write("\n== 汇总 ==\n")
io.write(string.format("  记录 SQL 语句: %d 条\n", #recorded.sql))
io.write(string.format("  注册 creature 事件: %d 个\n", (function()
    local n = 0
    for _ in pairs(engineCallbacks.creature) do n = n + 1 end
    return n
end)()))
if #recorded.failures == 0 then
    io.write("  RESULT: PASS\n")
    os.exit(0)
end
io.write(string.format("  RESULT: FAIL（%d 项）\n", #recorded.failures))
for _, f in ipairs(recorded.failures) do io.write("   - " .. f .. "\n") end
os.exit(1)
