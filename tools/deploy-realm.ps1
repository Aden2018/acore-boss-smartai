# ============================================================================
#  deploy-realm.ps1 — 把 boss.lua 部署到某个区（多区部署标准步骤）
# ----------------------------------------------------------------------------
#  多区（多个 realm 共用一套 auth）各区共用同一个库（默认 ac_eluna），靠 state_key 分租；
#  各区之间唯一的差别就是 boss.lua §2 的那一个 key（BOSS_RUNTIME_KEY + BOSS_CONFIG_KEY，两行必须相同）。
#
#    1. 从仓库取 boss.lua，改写 §2 的本区 key → 写入 <RealmRoot>\lua_scripts\boss.lua
#       （-DbName 只在给某个区单独一个库时才需要；默认 ac_eluna）
#    2. 写入前自动备份（boss.lua.<时间戳>.bak），写完打印源/目标 SHA256
#    3. 可选：语法检查（-LuaExe）、**对部署件跑离线冒烟**（-SmokeScript，消除"测试件≠部署件"）、
#       导入难度档位 SQL（-ApplyTierSql <world 库>）、导入配置类 SQL
#       （-ApplyConfigSql <配置库>：奖池 v2 + 跨重启恢复列 + 批 5 手感列，带命中数断言）；
#       导入前会把 SQL 里写死的库名**与本区 key** 一起改写，避免动到别的区
#    4. 打印 AGMP 面板 config/boss.php 需要同步的 server_overrides 片段
#
#  用法：
#    # 主区（从单区升级上来）：key 保持 current，不改库名
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-a>
#    # 第二个区：必须给它自己的 key（不能是 current，否则与主区共用一份数据）
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b>
#    # 部署 + 语法检查 + 部署件冒烟 + 配置 SQL + 难度档位模板
#    pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> `
#        -LuaExe <lua.exe> -SmokeScript tools\boss-lua-smoke\smoke.lua `
#        -ApplyConfigSql <配置库> -ApplyTierSql <该区 world 库> -DbPassword <密码>
#
#  部署完：让该区 worldserver 重新加载 Eluna（.reload ale 或重启），并把面板
#          config/generated/boss.php 的 server_overrides 加上该区（脚本会打印片段）。
# ============================================================================

[CmdletBinding()]
param(
    # 该区的 worldserver 根目录（里面应有 lua_scripts\ 与 worldserver.exe），例如 D:\AzerothCore\release\<realm-b>
    [Parameter(Mandatory = $true)][string]$RealmRoot,

    # 数据库名；多区共用库时保持默认 ac_eluna 即可（只有想给该区单独一个库时才改）
    [string]$DbName = 'ac_eluna',

    [string]$RuntimeKey = 'current',

    # 源文件；默认取本仓库根目录的 boss.lua
    [string]$Source = '',

    # 可选：Lua 解释器路径，给了就对新文件做一次语法检查
    [string]$LuaExe = '',

    # 可选：冒烟测试脚本路径（tools\boss-lua-smoke\smoke.lua）；给了就对**部署后的文件**跑一次，
    # 确保"测试件 = 部署件"（需要 -LuaExe）
    [string]$SmokeScript = '',

    # 可选：把难度档位 SQL 导入这个 world 库（如 <该区 world 库>）
    [string]$ApplyTierSql = '',

    # 可选：把配置类 SQL（奖池 v2 + 跨重启恢复列）导入这个配置库（如 ac_eluna），
    # 导入后按行数断言，避免"脚本跑了但一行没进去"
    [string]$ApplyConfigSql = '',

    # 可选：MySQL 客户端与连接参数（仅在 -ApplyTierSql 时需要）
    [string]$MysqlExe = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$DbPassword = '',

    # 只打印将要发生的改动，不写文件
    [switch]$DryRun,

    # 不备份原文件（不推荐）
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if ($Source -eq '') {
    $Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'boss.lua'
}

function Write-Step([string]$text) { Write-Host "== $text" }
function Write-Detail([string]$text) { Write-Host "   $text" }

# 导入一个 SQL 文件到指定库。密码走临时 defaults-extra-file（不落在命令行/进程列表里）。
function Invoke-BossSqlFile {
    param(
        [Parameter(Mandatory = $true)][string]$SqlPath,
        [Parameter(Mandatory = $true)][string]$Database,
        [string]$Label = ''
    )

    if (-not (Test-Path -LiteralPath $MysqlExe -PathType Leaf)) {
        throw "找不到 mysql.exe: $MysqlExe（可用 -MysqlExe 指定）"
    }
    if ($DbPassword -eq '') {
        throw "导入 SQL 需要 -DbPassword（或用面板/手工导入），避免在命令行里留下空密码提示。"
    }

    $extra = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-mysql-' + [guid]::NewGuid().ToString('N') + '.cnf')
    try {
        [System.IO.File]::WriteAllText($extra, "[client]`nuser=$DbUser`npassword=$DbPassword`n", $utf8NoBom)
        $mysqlArgs = @("--defaults-extra-file=$extra", "--host=$DbHost", "--port=$DbPort",
                       '--default-character-set=utf8mb4', $Database)
        $output = Get-Content -LiteralPath $SqlPath -Raw | & $MysqlExe @mysqlArgs 2>&1
        $exit = $LASTEXITCODE
        $output | Where-Object { $_ -notmatch 'Using a password' } | ForEach-Object { Write-Detail ([string]$_) }
        if ($exit -ne 0) { throw "$Label 导入失败（mysql 退出码 $exit）：$SqlPath" }
        return $output
    } finally {
        if (Test-Path -LiteralPath $extra) { Remove-Item -LiteralPath $extra -Force }
    }
}

# ---------------------------------------------------------------------- 校验
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "找不到源文件 boss.lua: $Source"
}
if (-not (Test-Path -LiteralPath $RealmRoot -PathType Container)) {
    throw "找不到区服目录: $RealmRoot（应指向该区 worldserver.exe 所在目录）"
}

$luaDir = Join-Path $RealmRoot 'lua_scripts'
if (-not (Test-Path -LiteralPath $luaDir -PathType Container)) {
    throw "$RealmRoot 下没有 lua_scripts\ 目录；这不像一个已部署的 worldserver 目录。"
}

if ($DbName -notmatch '^[A-Za-z0-9_]+$') {
    throw "库名只允许字母/数字/下划线: $DbName"
}
if ($RuntimeKey -notmatch '^[A-Za-z0-9_]+$') {
    throw "state_key 只允许字母/数字/下划线: $RuntimeKey"
}

$target = Join-Path $luaDir 'boss.lua'
$sourceText = [System.IO.File]::ReadAllText($Source)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------------- 改写常量
Write-Step "改写 §2 本区绑定"

$dbPattern = '(local BOSS_DB_NAME\s*=\s*")[^"]*(")'
$keyPattern = '(local BOSS_RUNTIME_KEY\s*=\s*")[^"]*(")'
$configKeyPattern = '(local BOSS_CONFIG_KEY\s*=\s*")[^"]*(")'

$dbMatches = [regex]::Matches($sourceText, $dbPattern)
$keyMatches = [regex]::Matches($sourceText, $keyPattern)
$configKeyMatches = [regex]::Matches($sourceText, $configKeyPattern)

if ($dbMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($dbMatches.Count) 处 BOSS_DB_NAME 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}
if ($keyMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($keyMatches.Count) 处 BOSS_RUNTIME_KEY 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}
if ($configKeyMatches.Count -ne 1) {
    throw "在 boss.lua 里匹配到 $($configKeyMatches.Count) 处 BOSS_CONFIG_KEY 赋值（应为 1 处）；常量位置变了，请同步本脚本与 smoke.lua。"
}

Write-Detail ("库名     : " + $dbMatches[0].Value.Trim() + "  →  local BOSS_DB_NAME = `"$DbName`"")
Write-Detail ("本区 key : " + $keyMatches[0].Value.Trim() + "  →  local BOSS_RUNTIME_KEY = `"$RuntimeKey`"")
Write-Detail ("配置 key : " + $configKeyMatches[0].Value.Trim() + "  →  local BOSS_CONFIG_KEY = `"$RuntimeKey`"")

if ($RuntimeKey -eq 'current' -and $DbName -eq 'ac_eluna') {
    Write-Host "   [注意] key 仍是 current：只有『主区』（从单区升级上来的那个区）可以这样。" -ForegroundColor Yellow
    Write-Host "          其它区必须各给一个不同的 -RuntimeKey，否则两个区共用同一份配置/运行态/事件。" -ForegroundColor Yellow
}

# 保留原有换行符（仓库里是 CRLF，原样带过去）
$newText = [regex]::Replace($sourceText, $dbPattern, ('${1}' + $DbName + '${2}'), 1)
$newText = [regex]::Replace($newText, $keyPattern, ('${1}' + $RuntimeKey + '${2}'), 1)
$newText = [regex]::Replace($newText, $configKeyPattern, ('${1}' + $RuntimeKey + '${2}'), 1)

$sourceBytes = [System.IO.File]::ReadAllBytes($Source)
$hasBom = ($sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 0xEF -and $sourceBytes[1] -eq 0xBB -and $sourceBytes[2] -eq 0xBF)
Write-Detail ("源文件: $Source ($($sourceBytes.Length) 字节, BOM: $(if ($hasBom) { '有' } else { '无' }))")
Write-Detail ("目标文件: $target")

# ------------------------------------------------------------------ 语法检查
if ($LuaExe -ne '') {
    Write-Step '语法检查（改写后的内容）'
    if (-not (Test-Path -LiteralPath $LuaExe -PathType Leaf)) {
        throw "找不到 Lua 解释器: $LuaExe"
    }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-realm-check-' + [guid]::NewGuid().ToString('N') + '.lua')
    try {
        [System.IO.File]::WriteAllText($probe, $newText, $utf8NoBom)
        $checkScript = "local f, err = loadfile([[$probe]]); if f then print('SYNTAX OK') else print('SYNTAX ERROR: '..tostring(err)) end"
        $checkOut = & $LuaExe -e $checkScript
        Write-Detail ([string]$checkOut)
        if ([string]$checkOut -notmatch 'SYNTAX OK') {
            throw '改写后的 boss.lua 语法检查失败，未写入目标文件。'
        }
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
    }
} else {
    Write-Step '语法检查：跳过（未提供 -LuaExe）'
}

# ---------------------------------------------------------------------- 写入
if ($DryRun) {
    Write-Step 'DryRun：不写任何文件'
} else {
    Write-Step '写入目标文件'
    if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$target.$stamp.bak"
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Detail "已备份原文件: $backup"
    } elseif ($NoBackup) {
        Write-Detail '未备份（-NoBackup）'
    }

    [System.IO.File]::WriteAllText($target, $newText, $utf8NoBom)
    $written = [System.IO.File]::ReadAllBytes($target)
    $writtenHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    Write-Detail "写入完成: $($written.Length) 字节（全库字形保持一致；Eluna 读该文件无需 BOM）"
    Write-Detail "目标 SHA256: $writtenHash"
    Write-Detail "源   SHA256: $sourceHash（与目标不同是正常的：本区 key 被改写）"
}

# ------------------------------------------------------------------ 部署件冒烟
# "测试件 ≠ 部署件"是这类部署最容易出的事故：跑过冒烟的是仓库文件，真正上线的是改写过的副本。
if ($SmokeScript -ne '') {
    Write-Step '对部署后的文件跑离线冒烟'
    if ($LuaExe -eq '') { throw 'SmokeScript 需要同时给 -LuaExe' }
    if (-not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) { throw "找不到冒烟脚本: $SmokeScript" }
    if ($DryRun) {
        Write-Detail "DryRun：将执行 $LuaExe $SmokeScript $target"
    } else {
        $smokeOut = & $LuaExe $SmokeScript $target 2>&1
        $smokeCode = $LASTEXITCODE
        $smokeOut | Where-Object { $_ -match 'FAIL|RESULT|汇总|记录 SQL' } | ForEach-Object { Write-Detail ([string]$_) }
        if ($smokeCode -ne 0) { throw "部署件冒烟未通过（退出码 $smokeCode）：$target" }
        Write-Detail "部署件冒烟通过（退出码 0）"
    }
}

# --------------------------------------------------------------- 难度档位 SQL
if ($ApplyTierSql -ne '') {
    $tierSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql\2026_09_23_activity_boss_tiers_190090_190093.sql'
    Write-Step "导入难度档位模板 → $ApplyTierSql"
    if (-not (Test-Path -LiteralPath $tierSql -PathType Leaf)) {
        throw "找不到难度档位 SQL: $tierSql"
    }

    # 该文件的 creature_template 部分作用在默认库（= -ApplyTierSql），但末尾那次
    # `ac_eluna`.`boss_activity_config` 切换既写死了库名、也用 `state_key = 'current'`
    # 选中「主区」那一行 —— 多区共用库时两个都要改写，否则会去改主区的活动配置。
    $tierText = [System.IO.File]::ReadAllText($tierSql)
    $schemaHits = ([regex]::Matches($tierText, '`ac_eluna`')).Count
    $keyHits = ([regex]::Matches($tierText, "state_key`` = 'current'")).Count
    $tierForRealm = $tierText -replace '`ac_eluna`', ('`' + $DbName + '`')
    $tierForRealm = $tierForRealm -replace "state_key`` = 'current'", ("state_key`` = '" + $RuntimeKey + "'")
    Write-Detail "SQL 内写死的库名 ``ac_eluna``: $schemaHits 处 → ``$DbName``"
    Write-Detail "SQL 内写死的本区 key 'current': $keyHits 处 → '$RuntimeKey'"

    if ($DryRun) {
        Write-Detail "DryRun：将执行 mysql < 改写后的 SQL（库 $ApplyTierSql）"
    } else {
        $tmpSql = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-realm-tiers-' + [guid]::NewGuid().ToString('N') + '.sql')
        try {
            [System.IO.File]::WriteAllText($tmpSql, $tierForRealm, $utf8NoBom)
            Invoke-BossSqlFile -SqlPath $tmpSql -Database $ApplyTierSql -Label '难度档位 SQL' | Out-Null
        } finally {
            if (Test-Path -LiteralPath $tmpSql) { Remove-Item -LiteralPath $tmpSql -Force }
        }

        Write-Detail '导入完成；该区 worldserver 里执行 .reload creature_template 后生效。'
    }
}

# --------------------------------------------------------------- 配置类 SQL
# 奖池 v2（建 boss_reward_pools 并迁移金币）与跨重启恢复的新列。两者都幂等，可重复执行。
# 顺序固定：先建表迁移，再补列（补列脚本依赖旧主表金币列还在，必须在 boss.lua 加载前跑）。
if ($ApplyConfigSql -ne '') {
    $sqlRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql'
    $configSqls = @(
        '2026_09_30_reward_pools_v2.sql',
        '2026_09_30_boss_recovery_columns.sql',
        '2026_10_01_play_feel_columns.sql'
    )

    Write-Step "导入配置类 SQL → $ApplyConfigSql"
    foreach ($name in $configSqls) {
        $path = Join-Path $sqlRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "找不到 SQL: $path" }
        if ($DryRun) {
            Write-Detail "DryRun：将导入 $name"
            continue
        }

        Invoke-BossSqlFile -SqlPath $path -Database $ApplyConfigSql -Label $name | Out-Null
        Write-Detail "已导入 $name"
    }

    if (-not $DryRun) {
        # 命中数断言：脚本跑过不等于数据进去了（缺列/权限不对时 MySQL 会中途报错）
        # 注意：这里必须用单引号 here-string —— 双引号会把反引号当转义字符，把 `boss_reward_pools` 吃成 oss_reward_pools。
        $assertSql = @'
SELECT '奖池行数' AS check_item, COUNT(*) AS found FROM `boss_reward_pools`
UNION ALL SELECT '有金币的池数（>0 即可）', COUNT(*) FROM `boss_reward_pools` WHERE `gold_max_copper` > 0
UNION ALL SELECT 'runtime 新列', COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'boss_activity_runtime'
    AND COLUMN_NAME IN ('health_pct','spawn_point_index','last_health_sample_at')
UNION ALL SELECT 'ext 新列', COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'boss_activity_config_ext'
    AND COLUMN_NAME IN ('health_sample_interval_sec','recovery_min_health_pct','boss_recovered_yell','last_hit_only_qualifies','offline_reward_delivery')
UNION ALL SELECT '批 5 手感列', COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'boss_activity_config_ext'
    AND COLUMN_NAME IN ('skill_instant_cast','combo_trigger_chance_pct','combo_global_cooldown_seconds',
      'skill_pick_random_top','skill_condition_thresholds_text','skill_disabled_spells_text',
      'target_random_spread_pct','threat_factor_enabled','target_score_weights_text',
      'soft_enrage_enabled','soft_enrage_seconds','soft_enrage_interval_seconds','soft_enrage_spell_id',
      'soft_enrage_speed_pct_per_stack','soft_enrage_max_stacks',
      'wipe_detect_enabled','wipe_grace_seconds','wipe_reset_health_pct',
      'announce_spawn_enabled','announce_phase_enabled','announce_restore_enabled','announce_texts_text',
      'marker_warning_enabled','marker_warning_delay_seconds','marker_warning_spell_id',
      'taunt_soft_enrage_yells_text','taunt_wipe_yells_text','taunt_marker_warning_yells_text');
'@
        $assertFile = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-assert-' + [guid]::NewGuid().ToString('N') + '.sql')
        try {
            [System.IO.File]::WriteAllText($assertFile, $assertSql, $utf8NoBom)
            $rows = Invoke-BossSqlFile -SqlPath $assertFile -Database $ApplyConfigSql -Label '命中数断言'
            $poolTotal = 0
            $feelColumns = -1
            foreach ($line in $rows) {
                $cells = ([string]$line) -split "`t"
                if ($cells.Count -ge 2 -and $cells[0] -eq '奖池行数') { $poolTotal = [int]$cells[1] }
                if ($cells.Count -ge 2 -and $cells[0] -eq '批 5 手感列') { $feelColumns = [int]$cells[1] }
            }
            if ($poolTotal -le 0) { throw "命中数断言失败：boss_reward_pools 里没有任何行" }
            if ($feelColumns -ne 28) { throw "命中数断言失败：扩展表批 5 手感列应为 28 列，实际 $feelColumns 列" }
            Write-Detail "命中数断言通过：奖池 $poolTotal 行、批 5 手感列 $feelColumns 列"
        } finally {
            if (Test-Path -LiteralPath $assertFile) { Remove-Item -LiteralPath $assertFile -Force }
        }
    }
}

# --------------------------------------------------------- 面板需要同步的片段
Write-Step 'AGMP 面板需要同步的配置（config/generated/boss.php → server_overrides）'
Write-Host @"
   <该区的 server 索引> => [
       'custom_db_name' => '$DbName',
       'runtime_key'   => '$RuntimeKey',   // 必须与该区 boss.lua §2 的 key 相同
   ],
"@
Write-Host ''
Write-Step '收尾'
Write-Detail '让该区 worldserver 重新加载 Eluna 脚本：游戏内 .reload ale（或重启该区）'
Write-Detail "确认绑定：该区 lua_scripts\lua_logs\boss.log 里应出现 [BOSS] 本区绑定: db=$DbName configKey=$RuntimeKey runtimeKey=$RuntimeKey"
Write-Detail '确认没串区：面板「Boss 活动管理」页头显示的 state_key 应与上面一致'
Write-Detail '★ 每个区的 key 必须不同：两个区用同一个 key 就是共用同一份配置/运行态/事件'
Write-Step '完成'
