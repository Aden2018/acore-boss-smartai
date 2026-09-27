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
--  覆盖：配置加载(SQL 构造/两张配置表)、扩展表建表与写入列一致、
--        「数据库值覆盖脚本默认值」、运行时持久化、
--        help/config/config show/preset/difficulty/rebase/kill/clear/spawn/未知子命令、
--        非 boss 命令放行，以及「全局 print 未被覆盖」「不再泄漏全局函数」两项回归断言。
-- ============================================================================

local bossPath = arg and arg[1] or "lua_scripts/boss.lua"

-- 技能池 / 连招内容回归的阈值：每个预设至少要有的连招条数。
-- 内容扩充（18 → 36 条、每套 6 条）时**只改这一处**，断言里不写死数字。
local MIN_COMBOS_PER_PRESET = 6

-- ---------------------------------------------------------------- 记录与断言
local recorded = { sql = {}, events = {}, replies = {}, failures = {}, alters = {}, spawnAttempts = 0 }
local scheduledEvents = {}

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
local originalPrint = print
local engineCallbacks = { creature = {}, player = {} }

local function mockQuery(values)
    return {
        GetUInt32 = function(_, i) return values[i + 1] end,
        GetInt32 = function(_, i) return values[i + 1] end,
        GetFloat = function(_, i) return values[i + 1] end,
        GetString = function(_, i) return tostring(values[i + 1] or "") end,
    }
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
    -- [reward_pool_1..6] 6 个独立奖池：故意用与文件内默认值不同的值（证明运行时以数据库为准）
    reward_pool_1_enabled = 1, reward_pool_1_chance = 88, reward_pool_1_winner_mode = "all",
    reward_pool_1_winner_count = 7, reward_pool_1_class_filter = 1, reward_pool_1_items_text = "11111,22222",
    reward_pool_2_enabled = 0, reward_pool_2_chance = 77, reward_pool_2_winner_mode = "count",
    reward_pool_2_winner_count = 6, reward_pool_2_class_filter = 0, reward_pool_2_items_text = "33333",
    reward_pool_3_enabled = 1, reward_pool_3_chance = 66, reward_pool_3_winner_mode = "count",
    reward_pool_3_winner_count = 5, reward_pool_3_class_filter = 1, reward_pool_3_items_text = "44444,55555",
    reward_pool_4_enabled = 1, reward_pool_4_chance = 55, reward_pool_4_winner_mode = "all",
    reward_pool_4_winner_count = 4, reward_pool_4_class_filter = 1, reward_pool_4_items_text = "66666",
    reward_pool_5_enabled = 0, reward_pool_5_chance = 44, reward_pool_5_winner_mode = "count",
    reward_pool_5_winner_count = 3, reward_pool_5_class_filter = 0, reward_pool_5_items_text = "77777,88888",
    reward_pool_6_enabled = 1, reward_pool_6_chance = 33, reward_pool_6_winner_mode = "count",
    reward_pool_6_winner_count = 2, reward_pool_6_class_filter = 1, reward_pool_6_items_text = "99999",
    -- [schedule] 定时启停：故意用与文件内默认值不同的值（脚本默认是关闭 + 空时间段）
    activity_schedule_enabled = 1,
    activity_schedule_windows = "20:00-22:00; 1-5@08:00-09:00",
    activity_schedule_clear_on_close = 1,
}

-- 模拟「扩展表已存在、但脚本升级后描述表多了列」的线上状态：
-- 加载时必须先 ALTER 补列，否则引导写入会因 Unknown column 整条失败。
local PHASE_COLUMNS = {
    "phase2_hp_threshold", "phase3_hp_threshold", "critical_hp_threshold",
    "low_hp_taunt_threshold", "low_hp_taunt_cooldown_ms", "long_combat_taunt_interval_ms",
    "target_reeval_loops", "phase2_summon_count_min", "phase2_summon_count_max",
    "phase3_summon_count", "phase2_spell_id", "phase3_spell_id",
}

local mockExtColumns = { state_key = true, updated_at = true }
for column in pairs(EXT_VALUES) do mockExtColumns[column] = true end
for _, column in ipairs(PHASE_COLUMNS) do mockExtColumns[column] = nil end

-- 再模拟一次"脚本升级后描述表又多了定时启停三列"：加载时必须自动补列。
local SCHEDULE_COLUMNS = {
    "activity_schedule_enabled", "activity_schedule_windows", "activity_schedule_clear_on_close",
}
for _, column in ipairs(SCHEDULE_COLUMNS) do mockExtColumns[column] = nil end

-- 再模拟一次"脚本升级后描述表又多了 6 个奖池的列"（每池抽几列模拟老库缺列）
local REWARD_POOL_PROBE_COLUMNS = {
    "reward_pool_1_items_text", "reward_pool_1_class_filter",
    "reward_pool_4_items_text", "reward_pool_6_enabled", "reward_pool_6_items_text",
}
for _, column in ipairs(REWARD_POOL_PROBE_COLUMNS) do mockExtColumns[column] = nil end

-- 运行态表的定时启停三列也按"老库还没有"处理（面板读不到时会降级显示，脚本自己要补）
local mockRuntimeColumns = {
    schedule_state = false, schedule_window = false, schedule_next_change_at = false,
}

local function mockInformationSchema(sql)
    -- 只有扩展表的列状态是「脚本升级后缺列」的模拟状态；其它表按列齐全处理
    if not sql:find("boss_activity_config_ext", 1, true) then
        if sql:find("boss_activity_runtime", 1, true) then
            local runtimeColumn = sql:match("COLUMN_NAME = '([%w_]+)'")
            if runtimeColumn then
                return mockQuery({ mockRuntimeColumns[runtimeColumn] and 1 or 0 })
            end
        end
        return mockQuery({ 1 })
    end

    local inList = sql:match("COLUMN_NAME IN %((.-)%)")
    if inList then
        local present = 0
        for name in inList:gmatch("'([%w_]+)'") do
            if mockExtColumns[name] then present = present + 1 end
        end
        return mockQuery({ present })
    end

    local single = sql:match("COLUMN_NAME = '([%w_]+)'")
    if single then
        return mockQuery({ mockExtColumns[single] and 1 or 0 })
    end

    return mockQuery({ 1 })
end

-- 按 SELECT 里的列名组装一行数据；缺列直接判失败（描述表加了列而快照没跟上时立刻暴露）
local function rowFromSelect(sql, values)
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
        fail("数据库快照缺少列: " .. table.concat(missing, ", "))
    end

    return mockQuery(row)
end

local env = setmetatable({}, { __index = _G })

env.CharDBQuery = function(sql)
    table.insert(recorded.sql, { kind = "query", sql = sql })
    if sql:find("information_schema") then
        return mockInformationSchema(sql)
    end
    if sql:find("boss_activity_config_ext", 1, true) and sql:find("SELECT", 1, true) then
        return rowFromSelect(sql, EXT_VALUES)
    end
    if sql:find("boss_activity_config", 1, true) and sql:find("SELECT", 1, true) then
        return rowFromSelect(sql, CONFIG_VALUES)
    end
    return nil -- runtime / 其它：模拟“没有行”
end

env.CharDBExecute = function(sql)
    table.insert(recorded.sql, { kind = "execute", sql = sql })

    -- 补列必须真的改变「表结构」，否则后面的查询/写入还是按缺列状态走
    local addedColumn = sql:match("ADD COLUMN `([%w_]+)`")
    if addedColumn then
        if sql:find("boss_activity_runtime", 1, true) then
            if mockRuntimeColumns[addedColumn] == true then
                fail("重复补列(runtime): " .. addedColumn)
            end
            mockRuntimeColumns[addedColumn] = true
        else
            if mockExtColumns[addedColumn] then
                fail("重复补列: " .. addedColumn)
            end
            mockExtColumns[addedColumn] = true
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

-- ------------------------------------------------------------------- 加载脚本
io.write("== 加载 " .. bossPath .. " ==\n")
local chunk, loadErr = loadfile(bossPath, "t", env)
if not chunk then
    io.write("LOAD ERROR: " .. tostring(loadErr) .. "\n")
    os.exit(2)
end

local runOk, runErr = pcall(chunk)
if not runOk then
    io.write("RUNTIME ERROR during load: " .. tostring(runErr) .. "\n")
    os.exit(2)
end
ok("脚本加载执行完成（EnsureBossSchema / LoadBossConfigFromDB / LoadBossRuntimeFromDB / 事件注册）")

-- --------------------------------------------------------------- 回归断言 1/2
assertTrue(print == originalPrint and rawget(env, "print") == nil,
    "全局 print 未被 boss.lua 覆盖（其它 Eluna 脚本不受影响）")
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

    assertTrue(insertColumnCount >= 32, "扩展表写入覆盖所有配置列（当前 " .. insertColumnCount .. " 列）")
    assertTrue(#missingInCreate == 0,
        "扩展表写入的每一列都在建表语句里" .. (#missingInCreate > 0 and ("（缺: " .. table.concat(missingInCreate, ",") .. "）") or ""))

    for _, column in ipairs({
        "boss_spawn_yell", "taunt_kill_yells_text", "taunt_combo_yells_text",
        "patrol_enabled", "minion_ai_interval_ms", "helper_entries_text",
        "class_reward_items_text", "managed_tier_entries_text",
    }) do
        assertTrue(createColumns[column] == true, "扩展表建表语句含列 " .. column)
    end
end

local runtimeWrites = 0
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_runtime") and item.kind == "execute" then
        runtimeWrites = runtimeWrites + 1
    end
end
assertTrue(runtimeWrites >= 1, "启动时写入了 boss_activity_runtime 引导行")

-- 扩展表迁移：桩状态里故意缺 12 个 [phase] 列，加载时必须先补列再写配置，
-- 否则线上遇到「脚本升级后描述表多了列」会整条写入失败（配置改了却不生效）
io.write("\n== 扩展表缺列迁移 ==\n")
assertTrue(#recorded.alters >= #PHASE_COLUMNS,
    string.format("自动补列 %d 个（缺 %d 个 [phase] 列）", #recorded.alters, #PHASE_COLUMNS))
local missingPhaseColumns = {}
for _, column in ipairs(PHASE_COLUMNS) do
    if not mockExtColumns[column] then missingPhaseColumns[#missingPhaseColumns + 1] = column end
end
assertTrue(#missingPhaseColumns == 0,
    "补列后扩展表列齐全" .. (#missingPhaseColumns > 0 and ("（缺: " .. table.concat(missingPhaseColumns, ",") .. "）") or ""))

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

-- ------------------------------------------------------------ 命令驱动与断言
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

-- 配置展示 + 「运行时以数据库为准」：ext 表里的值必须真的生效，而不是被默认值盖掉
io.write("\n== .boss config show ==\n")
local groupMessages = runConsoleCommand("boss config show")
local groupText = table.concat(groupMessages, " | ")
assertTrue(#groupMessages > 0, ".boss config show 有输出")
local groupKeys = {
    "identity", "basic", "ally", "yells", "taunts", "ai", "phase", "patrol",
    "minion", "skill", "skill_random", "respawn", "spawnpoints", "schedule",
    "helper", "reward", "reward_pool_1", "reward_pool_2", "reward_pool_3",
    "reward_pool_4", "reward_pool_5", "reward_pool_6", "class_ai", "class_reward", "tier",
}
local missingGroups = {}
for _, group in ipairs(groupKeys) do
    if not groupText:find(group, 1, true) then missingGroups[#missingGroups + 1] = group end
end
assertTrue(#missingGroups == 0, "配置分组齐全（25 组：含 6 个独立奖池 + 拆开的职业两组）" ..
    (#missingGroups > 0 and ("（缺: " .. table.concat(missingGroups, ",") .. "）") or ""))

-- 各组声明的项数之和必须等于描述表总数（漏登记会立刻暴露）
local listedTotal = 0
for count in groupText:gmatch("（(%d+) 项）") do
    listedTotal = listedTotal + tonumber(count)
end
assertTrue(listedTotal >= 100, "分组项数之和覆盖全部配置项（当前 " .. listedTotal .. "）")

local function showGroup(group)
    return table.concat(runConsoleCommand("boss config show " .. group), " | ")
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

local badGroupMessages = runConsoleCommand("boss config show nonsense")
local badMarkers = markersOf(badGroupMessages)
assertTrue(badMarkers:find("AGMP_ERROR", 1, true) ~= nil, "未知配置分组返回 AGMP_ERROR")

local badUsage = markersOf(runConsoleCommand("boss config oops"))
assertTrue(badUsage:find("AGMP_ERROR", 1, true) ~= nil, ".boss config <未知子命令> 返回 AGMP_ERROR")

-- 非 boss 命令必须放行（返回 true 表示交给核心继续处理）
io.write("\n== 非 boss 命令放行 ==\n")
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

-- ------------------------------------------------- 定时启停（每天时间段自动开关）
-- 三件事必须成立：
--   1) 三个新配置列真的进了建表 / 引导写入 / 运行时写入（面板读同一份描述表）；
--   2) 时间段解析与命中判定按「星期掩码 + 跨夜」正确（用可控时钟驱动 tick 断言）；
--   3) 门控真的生效：时段外不生成、进入时段自动补生成、离开时段写结束事件。
io.write("\n== 定时启停（时间段） ==\n")

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
for _, column in ipairs(scheduleColumns) do
    assertTrue(mockExtColumns[column] == true, "加载时自动补扩展表列 " .. column)
end
for column in pairs(mockRuntimeColumns) do
    assertTrue(mockRuntimeColumns[column] == true, "加载时自动补运行态列 " .. tostring(column))
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

    -- 4) 离开时间段：写 schedule_close，运行态回到 closed
    recorded.spawnAttempts = 0
    local beforeClose = #recorded.sql
    setNow(outsideNight)
    scheduleTick(0, 1000, 0)
    assertTrue(recorded.spawnAttempts == 0, "离开时间段不会生成 Boss")

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

-- ------------------------------------------------- 技能池随机（每次刷新抽一套预设）
-- 三件事必须成立：
--   1) 两个新配置列真的进了扩展表建表 / 引导写入（面板读同一份描述表）；
--   2) 开启后每次生成都从池子里抽（每次都在池内，且多次生成会抽到不同的预设）；
--   3) 关闭后生成不再抽签（固定用当前预设），命令行开关会写回扩展表。
io.write("\n== 技能池随机（每次刷新抽一套预设） ==\n")

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

-- ------------------------------------------------- 6 个独立奖池（旧奖励模型已删除）
-- 三件事必须成立：
--   1) 每池 6 列都进了扩展表建表/引导写入，老库缺列时自动补；
--   2) 旧奖励模型的列（保底/基础/公式/坐骑/金币）从主表 DROP 掉，建表语句里也不再有它们；
--   3) 面板读到的池配置确实来自数据库（.boss config show reward_pool_N）。
io.write("\n== 6 个独立奖池 ==\n")

local poolColumns = {}
for index = 1, 6 do
    for _, suffix in ipairs({ "enabled", "chance", "winner_mode", "winner_count", "class_filter", "items_text" }) do
        poolColumns[#poolColumns + 1] = string.format("reward_pool_%d_%s", index, suffix)
    end
end
assertTrue(#poolColumns == 36, "奖池列共 36 个（6 池 × 6 字段）")

local poolColumnMissing = {}
for _, column in ipairs(poolColumns) do
    if extCreateSql and not extCreateSql:find("`" .. column .. "`", 1, true) then
        poolColumnMissing[#poolColumnMissing + 1] = "DDL:" .. column
    end
    if extInsertSql and not extInsertSql:find("`" .. column .. "`", 1, true) then
        poolColumnMissing[#poolColumnMissing + 1] = "INSERT:" .. column
    end
end
assertTrue(#poolColumnMissing == 0, "扩展表建表 + 引导写入覆盖 36 个奖池列" ..
    (#poolColumnMissing > 0 and ("（缺: " .. table.concat(poolColumnMissing, ",") .. "）") or ""))

local missingPoolProbe = {}
for _, column in ipairs(REWARD_POOL_PROBE_COLUMNS) do
    if mockExtColumns[column] ~= true then missingPoolProbe[#missingPoolProbe + 1] = column end
end
assertTrue(#missingPoolProbe == 0, "老库缺奖池列时自动补列（" .. table.concat(REWARD_POOL_PROBE_COLUMNS, ", ") .. "）")

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

-- 面板读到的奖池值确实来自数据库
local poolExpect = {
    { 1, {
        "reward_pool_1_enabled (1.enabled) = true",
        "reward_pool_1_chance (1.chance) = 88",
        "reward_pool_1_winner_mode (1.winnerMode) = all",
        "reward_pool_1_winner_count (1.winnerCount) = 7",
        "reward_pool_1_class_filter (1.classFilter) = true",
        "reward_pool_1_items_text (1.items) = 11111,22222",
    } },
    { 2, {
        "reward_pool_2_enabled (2.enabled) = false",
        "reward_pool_2_chance (2.chance) = 77",
        "reward_pool_2_winner_mode (2.winnerMode) = count",
        "reward_pool_2_winner_count (2.winnerCount) = 6",
        "reward_pool_2_class_filter (2.classFilter) = false",
        "reward_pool_2_items_text (2.items) = 33333",
    } },
    { 6, {
        "reward_pool_6_enabled (6.enabled) = true",
        "reward_pool_6_chance (6.chance) = 33",
        "reward_pool_6_winner_mode (6.winnerMode) = count",
        "reward_pool_6_winner_count (6.winnerCount) = 2",
        "reward_pool_6_class_filter (6.classFilter) = true",
        "reward_pool_6_items_text (6.items) = 99999",
    } },
}
for _, case in ipairs(poolExpect) do
    local text = showGroup("reward_pool_" .. case[1])
    local missing = {}
    for _, expected in ipairs(case[2]) do
        if not text:find(expected, 1, true) then missing[#missing + 1] = expected end
    end
    assertTrue(#missing == 0, "奖池 " .. case[1] .. " 的开关/概率/人数模式/人数/职业过滤/奖品都来自数据库" ..
        (#missing > 0 and ("（缺: " .. table.concat(missing, " | ") .. "）") or ""))
end

assertTrue(showGroup("reward_pool_3"):find("44444,55555", 1, true) ~= nil, "奖池 3 的奖品列表来自数据库")

-- reward 组只剩"谁算有效参战 / 怎么抽人"
local rewardText = showGroup("reward")
assertTrue(rewardText:find("participation_range (participationRange) = 80", 1, true) ~= nil,
    "reward 组仍显示有效参与范围")
assertTrue(rewardText:find("guaranteed_reward_enabled", 1, true) == nil
    and rewardText:find("reward_items_text", 1, true) == nil
    and rewardText:find("gold_min_copper", 1, true) == nil,
    "reward 组不再包含旧奖励字段（保底 / 基础池 / 金币）")

-- 职业奖励池映射保留（奖池的 classFilter 依赖它）
assertTrue(showGroup("class_reward"):find("class_reward_items_text", 1, true) ~= nil,
    "职业过滤映射（class_reward_items_text）仍在配置里（奖池的 classFilter 依赖它）")
assertTrue(extInsertSql ~= nil and extInsertSql:find("`class_reward_items_text`", 1, true) ~= nil,
    "职业奖励池映射仍参与引导写入")

-- ------------------------------------------------- 奖池实发（离线驱动：假 Boss + 假玩家）
-- 线上没有玩家时没法验证「真发奖 + 按职业过滤」，这里用假对象把 OnBossDied 整条链路跑一遍：
--   · 6 个奖池改成确定值（全 100% 命中；池 4/5 关闭；池 3 只放"战士专属 + 谁都不可用"）
--   · 职业奖励池映射改成 1=1001（战士专属）/ 8=1002（法师专属）
--   · 两名假玩家（战士 / 法师）各记一笔伤害进贡献池，然后触发死亡结算
-- 关键点：boss.lua 的 IsUnitValid 要求 type(unit)=="userdata"，所以本段临时改写 env.type()，
-- 并让 PerformIngameSpawn 返回假 Boss；段末恢复原样，避免影响后面的多区绑定断言。
io.write("\n== 奖池实发（离线驱动）==\n")

local rewardCase = {
    -- 池 1：100% / 全部有效参战 / 战士专属 1001 + 法师专属 1002（classFilter 开）
    { enabled = 1, chance = 100, mode = "all",   count = 9, classFilter = 1, items = "1001,1002" },
    -- 池 2：100% / 指定 1 人 / 通用物品 2001（不在职业映射里 → 由核心 CanUseItem 判定）
    { enabled = 1, chance = 100, mode = "count", count = 1, classFilter = 1, items = "2001" },
    -- 池 3：100% / 指定 2 人 / 战士专属 1001 + 核心说"谁都不可用"的 9999
    { enabled = 1, chance = 100, mode = "count", count = 2, classFilter = 1, items = "1001,9999" },
    -- 池 4 / 5：关闭（不该发任何东西）
    { enabled = 0, chance = 100, mode = "all",   count = 5, classFilter = 1, items = "4001" },
    { enabled = 0, chance = 100, mode = "count", count = 5, classFilter = 1, items = "5001" },
    -- 池 6：100% / 指定 1 人 / 通用物品 6001（验证第 6 个池独立生效）
    { enabled = 1, chance = 100, mode = "count", count = 1, classFilter = 1, items = "6001" },
}
for index, case in ipairs(rewardCase) do
    EXT_VALUES["reward_pool_" .. index .. "_enabled"] = case.enabled
    EXT_VALUES["reward_pool_" .. index .. "_chance"] = case.chance
    EXT_VALUES["reward_pool_" .. index .. "_winner_mode"] = case.mode
    EXT_VALUES["reward_pool_" .. index .. "_winner_count"] = case.count
    EXT_VALUES["reward_pool_" .. index .. "_class_filter"] = case.classFilter
    EXT_VALUES["reward_pool_" .. index .. "_items_text"] = case.items
end
EXT_VALUES.class_reward_items_text = "1=1001\n8=1002"
runConsoleCommand("boss config reload")

local fakePlayers = {}
local function newFakePlayer(guidLow, playerName, classId, usableItems)
    local player = {
        __fake = true,
        guidLow = guidLow,
        name = playerName,
        classId = classId,
        given = {},
        messages = {},
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
runConsoleCommand("boss spawn force")
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
    "已关闭的奖池 4/5 一件都没发")
assertTrue(containsId(warrior, 6001) or containsId(mage, 6001),
    "池 6 独立生效（指定 1 人拿到 6001）")
assertTrue(containsId(warrior, 2001) or containsId(mage, 2001),
    "池 2 的指定 1 人抽奖发给了其中一位玩家")
assertTrue(#warriorIds >= 2 and #mageIds >= 1,
    "池 1（全部有效参战）+ 池 3（战士专属）按人数模式发放")

-- 奖池位图（贡献快照）：池 1=bit1、池 2=bit2、池 3=bit4、池 4=bit8、池 5=bit16、池 6=bit32
local contributorMasks = {}
for _, item in ipairs(recorded.sql) do
    if item.sql:find("boss_activity_contributors", 1, true) and item.sql:find("INSERT", 1, true) then
        local name = item.sql:match("'(测试[^']*)'")
        local numbers = {}
        for token in item.sql:gmatch("(%d+)") do numbers[#numbers + 1] = tonumber(token) end
        if name and #numbers >= 2 and contributorMasks[name] == nil then
            contributorMasks[name] = numbers[#numbers - 1]   -- 倒数第二个数字 = reward_pools_mask
        end
    end
end

local warriorMask = contributorMasks["测试战士"]
local mageMask = contributorMasks["测试法师"]
print(string.format("  [测试] 位图: 战士=%s 法师=%s",
    tostring(warriorMask), tostring(mageMask)))

if warriorMask and mageMask then
    assertTrue(warriorMask % 2 >= 1, "位图：战士中过池 1（bit1）")
    assertTrue(math.floor(warriorMask / 4) % 2 == 1, "位图：战士中过池 3（bit4，战士专属物品）")
    assertTrue(mageMask % 2 >= 1, "位图：法师中过池 1（bit1）")
    assertTrue(math.floor(mageMask / 4) % 2 == 0,
        "位图：法师没有中池 3（池内只有战士专属 + 不可用物品 → 不发）")
    assertTrue(math.floor(warriorMask / 8) % 2 == 0 and math.floor(mageMask / 8) % 2 == 0,
        "位图：奖池 4 关闭 → bit8 未置位")
    assertTrue(math.floor(warriorMask / 16) % 2 == 0 and math.floor(mageMask / 16) % 2 == 0,
        "位图：奖池 5 关闭 → bit16 未置位")
else
    fail("没抓到贡献快照的奖池位图（reward_pools_mask）")
end

assertTrue(#warrior.messages > 0 and #mage.messages > 0, "获奖者收到了中奖提示")
assertTrue(#recorded.replies > 0 and table.concat(recorded.replies, " "):find("获奖名单", 1, true) ~= nil,
    "击杀后广播了按奖池分组的获奖名单")

-- 恢复场地：桩函数与假对象都要撤掉，后面的多区绑定断言仍用原来的桩
env.type = originalType
env.PerformIngameSpawn = originalPerformIngameSpawn
env.GetPlayerByGUID = originalGetPlayerByGUID

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

-- ------------------------------------------------- 多区绑定（本区库名 / state_key）

-- boss.lua 的「多区支持」只有一句话：部署到不同区时只改 §2 的 key
-- （BOSS_RUNTIME_KEY / BOSS_CONFIG_KEY，两行必须相同），四张表都靠这个 state_key 分租。
-- 这里把常量改写后**重新加载一遍**，既核对 SQL 用的库名，也核对写入带的是本区 key。
-- 为什么必须动态重载而不是只看源码：真正的风险是"某处又写死了 ac_eluna / 'current'"，
-- 写死的值不会出现在源码里那两个常量上，只有跑起来才会在 SQL 里露出来。
io.write("\n== 多区绑定（共用库 + state_key 分租） ==\n")

local function isDbQualified(sql)
    return sql:find("`boss_activity", 1, true) ~= nil
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
