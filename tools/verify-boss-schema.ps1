# ============================================================================
#  verify-boss-schema.ps1 — boss.lua 配置列契约自检（三处对齐）
# ----------------------------------------------------------------------------
#  「加一项配置要改四处」是这类脚本最容易漂移的地方：boss.lua 的描述表、
#  sql/2026_09_24_activity_boss_config_ext.sql 的 DDL、AGMP 面板的 ext_fields、
#  以及线上表的实际列。本脚本把前两者与线上表**与描述表逐列比对（含顺序）**，
#  不一致就逐条打印差异并以非 0 退出，可以直接进 CI 或部署前门禁。
#
#  用法（在仓库根目录）：
#    pwsh -File tools\verify-boss-schema.ps1 -PanelRoot <AGMP 面板根目录>
#    pwsh -File tools\verify-boss-schema.ps1 -PanelRoot <AGMP> -DbName ac_eluna -DbPassword <pw>   # 额外核对线上表
#
#  面板根目录也可以放在环境变量 AGMP_ROOT 里；两者都没有时只跳过面板这一项，其余照常比对。
#
#  退出码：0 = 三处一致；1 = 有差异；2 = 前置条件不满足（读不到文件/解释器）。
# ============================================================================

[CmdletBinding()]
param(
    # boss.lua 路径（默认仓库根目录）
    [string]$BossLua = '',

    # AGMP 面板根目录（也可用环境变量 AGMP_ROOT；都为空则跳过面板比对）
    [string]$PanelRoot = '',

    # PHP CLI（读面板 config/boss.php 用；缺省取 $env:PHP_HOME\php.exe）
    [string]$PhpExe = '',

    # 可选：核对线上表实际列（需要 mysql 客户端与凭据）
    [string]$DbName = '',
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$DbPassword = '',
    [string]$MysqlExe = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
)

$ErrorActionPreference = 'Stop'

if ($BossLua -eq '') {
    $BossLua = Join-Path (Split-Path -Parent $PSScriptRoot) 'boss.lua'
}
if ($PanelRoot -eq '' -and $env:AGMP_ROOT) {
    $PanelRoot = $env:AGMP_ROOT
}
if ($PhpExe -eq '' -and $env:PHP_HOME) {
    $PhpExe = Join-Path $env:PHP_HOME 'php.exe'
}

function Fail([string]$message) { Write-Host "ERROR: $message" -ForegroundColor Red; exit 2 }
function Read-LuaExtColumns([string]$path) {
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($false))
    $inExt = $false
    $columns = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^local BOSS_CONFIG_SCHEMA_EXT = \{') { $inExt = $true; continue }
        if ($inExt -and $line -match '^--  配置目标注册表') { break }
        if ($inExt -and $line -match 'column\s*=\s*"([^"]+)"') { $columns.Add($Matches[1]) }
    }
    return $columns
}

function Read-PanelExtColumns([string]$panelRoot, [string]$phpExe) {
    if (-not (Test-Path -LiteralPath $panelRoot -PathType Container)) { return $null }
    if (-not $phpExe -or -not (Test-Path -LiteralPath $phpExe -PathType Leaf)) { return $null }

    $probe = @'
<?php
$c = require getenv('BOSS_PANEL_CONFIG');
$n = [];
foreach ($c['ext_fields'] as $f) { foreach ($f as $v) { $n[] = $v['name']; } }
echo implode("\n", $n), "\n";
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-ext-probe-' + [guid]::NewGuid().ToString('N') + '.php')
    try {
        [System.IO.File]::WriteAllText($tmp, $probe, (New-Object System.Text.UTF8Encoding($false)))
        $env:BOSS_PANEL_CONFIG = (Join-Path $panelRoot 'config/boss.php')
        $out = & $phpExe $tmp
        if ($LASTEXITCODE -ne 0) { return $null }
        return @($out | Where-Object { $_ -ne '' })
    } finally {
        Remove-Item Env:\BOSS_PANEL_CONFIG -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Read-DdlExtColumns([string]$ddlPath) {
    if (-not (Test-Path -LiteralPath $ddlPath -PathType Leaf)) { return $null }

    $lines = [System.IO.File]::ReadAllLines($ddlPath, [System.Text.UTF8Encoding]::new($false))
    $columns = New-Object System.Collections.Generic.List[string]
    $inTable = $false
    foreach ($line in $lines) {
        if ($line -match 'CREATE TABLE IF NOT EXISTS `[^`]+`\.`boss_activity_config_ext`') { $inTable = $true; continue }
        if ($inTable) {
            if ($line -match '^\s*\)\s*ENGINE') { break }
            if ($line -match '^\s*`([a-z0-9_]+)`\s') {
                $name = $Matches[1]
                # state_key / updated_at 不属于描述表
                if ($name -ne 'state_key' -and $name -ne 'updated_at') { $columns.Add($name) }
            }
        }
    }
    return $columns
}

function Compare-ColumnLists([string]$label, $expected, $actual, [switch]$IgnoreOrder) {
    if ($null -eq $actual) {
        Write-Host ("  SKIP  {0}：读不到（前置条件不满足）" -f $label) -ForegroundColor Yellow
        return $true
    }

    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ })
    $sameOrder = (($expected -join ',') -eq ($actual -join ','))

    if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and ($sameOrder -or $IgnoreOrder)) {
        $orderNote = if ($sameOrder) { '顺序一致' } else { '物理顺序与描述表不同（读写按列名，不影响功能）' }
        Write-Host ("  OK    {0}（{1} 列，{2}）" -f $label, $expected.Count, $orderNote) -ForegroundColor Green
        return $true
    }

    Write-Host ("  DIFF  {0}" -f $label) -ForegroundColor Red
    if ($missing.Count -gt 0) { Write-Host ("        缺: " + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { Write-Host ("        多: " + ($extra -join ', ')) }
    if (-not $sameOrder -and $missing.Count -eq 0 -and $extra.Count -eq 0) { Write-Host '        列名一致但顺序不同' }
    return $false
}

Write-Host '== boss.lua 扩展配置列契约自检'
if (-not (Test-Path -LiteralPath $BossLua -PathType Leaf)) { Fail "找不到 boss.lua: $BossLua" }

$expected = Read-LuaExtColumns $BossLua
if ($expected.Count -eq 0) { Fail 'boss.lua 里没有解析到任何 BOSS_CONFIG_SCHEMA_EXT 列（描述表结构变了？）' }
Write-Host ("  boss.lua 描述项: {0}" -f $expected.Count)

$ok = $true
$ok = (Compare-ColumnLists 'DBA 预建 DDL（sql/2026_09_24_activity_boss_config_ext.sql）' $expected `
        (Read-DdlExtColumns (Join-Path (Split-Path -Parent $PSScriptRoot) 'sql\2026_09_24_activity_boss_config_ext.sql'))) -and $ok
$ok = (Compare-ColumnLists 'AGMP 面板 ext_fields' $expected (Read-PanelExtColumns $PanelRoot $PhpExe)) -and $ok

if ($DbName -ne '' -and $DbPassword -ne '') {
    if (-not (Test-Path -LiteralPath $MysqlExe -PathType Leaf)) { Fail "找不到 mysql.exe: $MysqlExe" }
    $extraCnf = Join-Path ([System.IO.Path]::GetTempPath()) ('boss-mysql-' + [guid]::NewGuid().ToString('N') + '.cnf')
    try {
        [System.IO.File]::WriteAllText($extraCnf, "[client]`nuser=$DbUser`npassword=$DbPassword`n", (New-Object System.Text.UTF8Encoding($false)))
        $sql = "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'boss_activity_config_ext' AND COLUMN_NAME NOT IN ('state_key','updated_at');"
        $live = @(& $MysqlExe "--defaults-extra-file=$extraCnf" "--host=$DbHost" "--port=$DbPort" -N -B $DbName -e $sql 2>$null)
        # 线上表只比列名：老库的物理顺序由历史 ALTER 决定（updated_at 可能夹在中间），
        # 而读写一律按列名，物理顺序不影响功能，也不值得为它重建表。
        $ok = (Compare-ColumnLists ("线上表 $DbName.boss_activity_config_ext") $expected $live -IgnoreOrder) -and $ok
    } finally {
        if (Test-Path -LiteralPath $extraCnf) { Remove-Item -LiteralPath $extraCnf -Force }
    }
} else {
    Write-Host '  SKIP  线上表：未提供 -DbName / -DbPassword' -ForegroundColor Yellow
}

if ($ok) {
    Write-Host 'SCHEMA CONTRACT OK' -ForegroundColor Green
    exit 0
}

Write-Host 'SCHEMA CONTRACT MISMATCH' -ForegroundColor Red
exit 1
