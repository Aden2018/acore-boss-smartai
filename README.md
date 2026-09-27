# Acore Boss SmartAI Lua

AzerothCore 3.3.5a Eluna Boss activity script with runtime persistence, hot-reload config, event tracking, and contributor snapshots.

## Features

- Smart combat AI with multiple skill presets and difficulty modes.
- **Random skill preset**: when enabled, every spawn/respawn draws one preset from the pool ticked in the panel (AGMP → Extended config → Random skill preset); see [Random skill preset](#random-skill-preset).
- **Six independent reward pools**: enable switch / chance / winner count (every eligible player or a fixed number) / prize item list,
  each configured on its own; the panel takes item IDs and shows the resolved item names, and prizes are
  filtered per class so nobody is handed gear they cannot use (see [Rewards: six independent pools](#rewards-six-independent-pools)).
- **Selectable power tiers** backed by dedicated `creature_template` entries (see [Difficulty tiers](#difficulty-tiers)).
- **Daily schedule**: start and stop the activity automatically by time windows (AGMP → Extended config → Schedule); see [Daily schedule](#daily-schedule).
- **All settings live in the database**: the script only ships defaults, the running config comes from `ac_eluna` (see [Where to change config](#where-to-change-config)).
- Runtime persistence in `ac_eluna`: `boss_activity_runtime`, `boss_activity_config` (shared with the AGMP panel),
  `boss_activity_config_ext` (script-private settings), `boss_activity_events`, `boss_activity_contributors`.
- Automatic schema bootstrap and migration in Lua (no Web-side table creation required).
- Dedicated boss templates: no core `SmartAI` scripts run on top of Eluna.
- In-game / console commands:

| Command | Effect |
|---|---|
| `.boss` / `.boss spawn` | Spawn the boss at a configured spawn point (refused outside a schedule window) |
| `.boss spawn force` | Spawn anyway while the schedule says otherwise (debugging) |
| `.boss schedule` | Show the schedule, whether the current time is inside a window, and the next switch |
| `.boss kill` | Kill the active boss through the normal death + reward flow |
| `.boss clear` (alias `.boss despawn`) | Remove the active boss without rewards and reset the runtime row |
| `.boss rebase` | Recompute base health from the template and re-apply the multiplier (**out of combat only**) |
| `.boss config reload` | Hot reload config from `ac_eluna` (used by AGMP after saving) |
| `.boss config show [group]` | Print the effective config (no group = list the 24 groups) |
| `.boss preset list` / `.boss preset <key>` | List / switch the skill preset |
| `.boss preset random on\|off` | Toggle "draw a random skill preset on every spawn" (same ext config as the panel) |
| `.boss preset pool <key,key>` / `pool all` | Set the random pool / clear it (empty = every preset) |
| `.boss difficulty list` / `.boss difficulty <key>` | List / switch the skill cadence tier |
| `.boss help` | Help |

## Where to change config

`boss.lua` keeps **shipped defaults** in one place (§3 "配置区" at the top of the file). Once a row
exists in the database those defaults are no longer used — bootstrap writes happen with `INSERT IGNORE`. Precedence:

1. **AGMP panel** — the *Basic config* tab edits `boss_activity_config` (boss identity, stats, spawn points, skill preset, participation weights); the *Extended config* tab edits `boss_activity_config_ext` (yells, taunts, AI cadence, phase thresholds, patrol, minions, helpers, classes, managed tiers, random skill preset, **the six reward pools**, schedule), grouped into second-level tabs.
2. **Database** — `boss_activity_config` (panel-shared columns) and `boss_activity_config_ext` (script-private columns).
3. **Script §3 defaults** — only for a brand-new deployment without a config row.

After editing, run `.boss config reload` (the panel does this automatically) or restart worldserver.

### The two config tables

| Table | Contents | Written by |
|---|---|---|
| `boss_activity_config` | Boss identity, level/scale/health multiplier, auras, ally helper, spawn points, skill preset, **participation weights / eligible range** (reward items live in the six pools of the ext table) | AGMP panel (`REPLACE INTO`, whole row) + Lua |
| `boss_activity_config_ext` | Yells, combat taunts (12 text lists), AI cadence, phase thresholds, patrol, minion AI, helper entries, class types + class reward pools, managed tier entries, **random skill preset**, **six independent reward pools**, **daily schedule** | Lua (create/seed) + AGMP panel (`INSERT ... ON DUPLICATE KEY UPDATE`, submitted columns only) |

The split is required: AGMP saves the main table with `REPLACE INTO`, which resets every column it
does not know about to the table default; the panel only upserts the ext table, so script-private
columns survive a panel save. **Ext-table columns must stay in the order the panel mirrors** —
append new columns at the end, because `tools/verify_boss_ext_page.php` compares panel schema and
Lua descriptor table column by column.

### Adding a config item

1. Add the default value in §3 (or reuse an existing field).
2. Add one row to `BOSS_CONFIG_SCHEMA_MAIN` (panel-shared column: also update AGMP and the
   `CREATE TABLE`) or `BOSS_CONFIG_SCHEMA_EXT` (script-private) with
   `group / column / kind / target / key` (ext rows also need `ddl`).
3. The ext table DDL, the read path, the write path and `.boss config show` all follow
   automatically. To make it editable in the panel, add the column at the end of AGMP's
   `config/boss.php` (`ext_fields`, with type/bounds) plus its zh_CN/en label —
   `php tools/verify_boss_ext_page.php` cross-checks the panel schema against this
   descriptor table column by column.

Value kinds (`kind`): `int`, `bool`, `scaled` (decimal ×100 stored as INT), `text`,
`text_keep`, `intlist`, `lines`, `keyedlines`, `keyedword`, `keyedintlist`, `spawnpoints`.
The panel adds two of its own: `schedule_windows` (daily windows, validated and normalised by
`Domain\Support\ScheduleWindows` before saving) and `preset_multi` (preset checkboxes, still stored
as a comma-separated key list).

### What intentionally stays in the script

- Skill presets / difficulty coefficients / interrupt spell pool (§5 content library): combat
  *content* (spell ids, cooldowns, trigger conditions), released with the version; the selectable
  parts (which preset, which tier, which presets are in the random pool) are in the database.
- **10 skill presets** (expanded from 6 in 2026-09): the original `storm_siege` / `ember_storm` /
  `frost_whiteout` / `venom_pursuit` / `grave_bombard` / `spellbreak_bulwark`, plus
  `arcane_cataclysm` / `plague_swarm` / `iron_vanguard` / `blood_covenant`.
  Each preset = a 3-phase skill pool + **6 combo chains** (`comboChains`; expanded from 3 to 6 per
  preset in 2026-09, **60 total**) + 3 opening skills. A combo is a fixed 3-spell sequence cast in order
  with no further target-condition checks (`SkillAI:TryComboChain` + the cast loop). Hard invariant:
  **every spell a combo uses must exist in that preset's own skill pool** (enforced by the smoke test);
  combo names are globally unique. With 4 new presets the panel's "random skill preset" checkbox list
  grows from 6 to 10 entries, so the panel must list the same keys (`config/boss.php` `preset_values`
  plus the `resources/lang/{zh_CN,en}/boss.php` labels/summaries) or it will not accept them.
- Spell provenance and validation: all spell ids come from WotLK raid content. The two expansions added
  **53 new spells** in total (unique spell ids 37 -> 66 -> **99**, pool entries 72 -> 101 -> **144**), each
  one's `name` copied byte-for-byte from the enCN name slot of the client `Spell.dbc`.
  `tools/spell-check/spell-check.lua` checks existence plus that name comparison; provenance comes from
  the `SPELL_* = <id>` enums and real `CastSpell/DoCast` call sites in AzerothCore's per-raid boss
  scripts (strongest evidence), backed by `spell_script_names` (anything scripted is flagged
  "needs care").
  Two traps worth knowing: **`creature_template_spell` does not contain WotLK raid abilities** (they are
  core-hardcoded), so it proves nothing; **`spelldifficulty_dbc` is largely useless for WotLK raids**
  (the 10/25-man variants are `_10N/_25N/_10H/_25H` constants in C++), and
  `SpellMgr::GetSpellIdForDifficulty` **returns the original spellId outside dungeons/battlegrounds** -
  so for open-world AI the base id is the final effect, and pools only ever use base ids.
  **22 legacy spell names were corrected to the DBC names** (e.g. `69055` "骨刃分劈" -> "军刀猛刺",
  `72034` "白茫" -> "霜至"). The rename ships with `sql/2026_09_26_skill_yells_rename.sql` and **the two
  must be applied together**: `skillCastYells` and the ext-table column `taunt_skill_cast_yells_text`
  are keyed by spell name, so renaming only the script silently kills those 22 cast yells on a live realm
  (and the rename needs `.reload ale`, not `.boss config reload`). The script anchors on line starts and is
  safe to re-run. Three pool spells come from **5-man dungeons** (King Dred / Drak'Tharon Keep,
  Slad'ran / Gundrak, Krick & Ick / Pit of Saron) and are now annotated as such; replacing them with raid
  equivalents is a content decision, not a bug fix.
- **Cast mode (changed 2026-09)**: `SkillAI:CastSkill` now calls
  `CastSpell(target, spellId, SKILL_CAST_TRIGGERED)` with the constant set to **`false` = dungeon-style
  casting** (wind-up from the Spell.dbc cast time, interruptible). Two supporting changes: (1) every AI
  tick first checks `TargetSelector:IsCasting(creature)` and issues no new order while casting, and
  (2) combos are no longer fired in a single tick - they are pushed into `state.pendingCasts` and drained
  one spell per idle tick (the core rejects the trailing spells otherwise). About a third of the pool
  spells have `cast=0` in the DBC and are instant by nature. To go back to the old instant feel, flip the
  constant to `true` (the interrupt spell pool stays triggered either way).
- **Radius limit**: every pool spell must have `SpellRadius` <= 99yd - anything above is effectively a
  zone-wide AoE in the open world, and **50000yd is SpellRadius.dbc's "unlimited" placeholder** (fine
  inside a raid, hits the whole map outdoors). In 2026-09 eleven over-limit spells were swapped for
  role-equivalent raid spells, including two 50000yd ones from the original content
  (`64386 惊骇尖啸`, `72034 霜至`). When adding spells, verify the `radius` column with
  `sp2.lua oneline <id>`.
  Combo yells for the expansions ship as `sql/2026_09_26_combo_yells_expansion.sql` (first expansion)
  and `sql/2026_09_26_combo_yells_new_presets.sql` (the four new presets): yells live in the
  ext-table column `taunt_combo_yells_text`, and **the database value replaces the script defaults
  wholesale**, so editing the script defaults alone has no effect on a live realm.
- Display strings (class names), minion scatter distances and a few condition constants:
  logic constants rather than tunables.

## Rewards: six independent pools

Six identically shaped, fully independent reward pools live in `boss_activity_config_ext`
(AGMP → Extended config → Reward pools); each pool has six fields:

| Field | Meaning |
|---|---|
| `reward_pool_N_enabled` | Whether the pool takes part in the payout at all |
| `reward_pool_N_chance` | Trigger chance (%), rolled once per kill for every enabled pool |
| `reward_pool_N_winner_mode` | `all` = every eligible player wins; `count` = draw a fixed number of winners (weighted by contribution or pure random, see `random_reward_mode`) |
| `reward_pool_N_winner_count` | Winner count for `count` mode (never more than the number of eligible players) |
| `reward_pool_N_class_filter` | "Only prizes the winner can actually use" (on by default) |
| `reward_pool_N_items_text` | Prize item IDs; each winner draws **one** item from the pool |

Settlement on boss death: build the eligible-participant list → roll each enabled pool once → turn the winner mode into a winner
list → every winner draws one item **they can use** from that pool. Pools never affect each other, the per-pool win bitmap is stored
in `boss_activity_contributors.reward_pools_mask` (bit N = pool N won) and the `reward_granted` event carries the full breakdown.

**Class filtering (never hand out unusable gear)** — with `class_filter=1`, usability of each prize is decided like this:

1. the item appears in *Class config → class reward pools* (`class_reward_items_text`, key = class ID) → **that map is authoritative**:
   only a class whose list contains the item may receive it;
2. the item is absent from the map (mounts / formulas / generic items) → ask the core `Player:CanUseItem`
   (class/race/level restrictions);
3. the core gives no verdict (old build / exception) → treat the item as unrestricted so a pool never silently dries up.

Pools may therefore mix all classes' gear: warriors only receive warrior-list items, mages only
mage-list items, and a winner with nothing usable in that pool skips it (the log says why).

Factory defaults: pool 1 "guaranteed" everyone 100% (`40753`), pool 2 "base" 3 winners 100%,
pool 3 "formula" 3 winners 10%, pool 4 "mount" 1 winner 15%, pool 5 "class" 3 winners 60% (union of
the 27 class items + class filter), pool 6 off as a spare.

**Upgrading an existing deployment**: run `sql/2026_09_26_reward_pools.sql` once (idempotent: adds the six pools' columns → seeds the
default prize lists on existing rows → drops the 13 legacy reward columns), then `.reload ale` or restart the worldserver; `boss.lua`
performs the same add/drop migration at load time.

## Random skill preset

When enabled, **every spawn/respawn draws one skill preset at random** from the pool (that boss
keeps the drawn preset until it dies) instead of the fixed `skill_preset`.

Settings live in `boss_activity_config_ext` (AGMP → Extended config → Random skill preset):

| Column | Default | Meaning |
|---|---|---|
| `skill_preset_random_enabled` | `0` | Draw one preset per spawn |
| `skill_preset_pool_text` | `''` | Pool: comma-separated preset keys (checkboxes in the panel); **empty = every preset** |

Behaviour:

- The draw happens **before spawning** — `.boss spawn`, the schedule tick, a GM spawning at their own position
  and the respawn timer all count as one spawn. A refused spawn neither consumes a draw nor changes the current preset.
- Unknown keys in the pool are logged and skipped; an empty pool (or one with no valid key) falls back to every preset
  in `SKILL_PRESET_ORDER`, so a mistyped pool never turns into a boss that casts nothing.
- With random off the fixed `boss_activity_config.skill_preset` is used; with random on that value is only a fallback.
- **Saving in the panel never re-rolls a live boss**: the draw only changes on the next spawn/respawn
  (a manual `.boss preset <key>` is remembered the same way).
- Use `.boss preset list` (or the panel runtime card) to see which preset is actually active;
  `boss_activity_runtime.skill_preset` stores the preset the live boss is using.

> **Upgrade order**: these two columns are created/migrated by `boss.lua`. Update `boss.lua` and let worldserver load it
> once (`EnsureBossExtTableColumns` adds the columns), then update the AGMP panel. The other way round (panel first) the
> extended config page keeps reporting a read/save failure until Lua has added the columns.

## Daily schedule

Run the activity only inside configured daily windows: **a boss is spawned when a window opens and the pending
respawn timer is dropped when it closes** (by default the boss that is up is removed as well).

Settings live in `boss_activity_config_ext` (AGMP → Extended config → Schedule):

| Column | Default | Meaning |
|---|---|---|
| `activity_schedule_enabled` | `0` | Start/stop automatically by the windows below |
| `activity_schedule_windows` | `''` | Window text, syntax below |
| `activity_schedule_clear_on_close` | `1` | Remove the active boss when a window closes (`0` = only stop new spawns) |

Window syntax (identical to AGMP's `app/Domain/Support/ScheduleWindows.php` — change both sides together):

```
08:00-09:00                  every day 08:00-09:00
08:00-09:00; 20:00-22:00     several windows, separated by ";"
1-5@20:00-23:00              Mon-Fri (1=Mon … 7=Sun; mon-fri and 一/日 also accepted)
6,7@10:00-12:00              Sat + Sun
22:00-02:00                  overnight (until 02:00 the next day)
```

Behaviour:

- **The plan outranks manual control**: outside a window `.boss spawn` is refused with a hint
  (`.boss spawn force` bypasses it for debugging). Inside a window the tick spawns a boss when none is up and no
  respawn timer is pending (a failed spawn is retried after 30 seconds).
- Enabled with empty/invalid windows = **never switches automatically** (a typo must not wipe a live boss);
  invalid fragments only log one line and are skipped.
- A killed boss still respawns after `respawn_time_minutes`; if that moment falls outside a window nothing is
  scheduled and the next window spawns instead.
- `.boss schedule` prints the plan and the current state. The runtime state (`off` / `empty` / `open` / `closed`,
  the matched window and the next switch timestamp) is written to `boss_activity_runtime`
  (`schedule_state` / `schedule_window` / `schedule_next_change_at`) and shown by the AGMP runtime card.
- Time comes from the server's local clock (`os.date`); weekday masks refer to the day the window *starts*,
  which is also how overnight windows are matched.

The parser is shared with the chat-quiz module (`Acme\Panel\Domain\Support\ScheduleWindows`): the panel validates
and normalises on save, and all switching happens in the Lua tick.

## Difficulty tiers

The activity boss uses dedicated level-83 templates with no `AIName`, no `smart_scripts` and no loot:

| entry | tier | HealthModifier | DamageModifier | rank | health @ multiplier 1500 |
|---|---|---|---|---|---|
| 190090 | entry (live-equivalent) | 0.21 | 1.0 | 1 | 4,392,675 |
| 190091 | standard (5 players) | 0.60 | 2.0 | 1 | 12,550,500 |
| 190092 | hard (10 players) | 1.45 | 4.0 | 3 | 30,330,376 |
| 190093 | raid (25 players) | 3.60 | 7.0 | 3 | 75,302,998 |

- Health formula: `creature_classlevelstats(level=83, class=1).basehp2(=13945) × HealthModifier × (boss_health_multiplier_scaled / 100)`.
- The tier is stored in `boss_activity_config.boss_entry`; AGMP exposes it as a "difficulty tier" dropdown and shows the estimated health for the current multiplier.
- The panel's health multiplier is a global knob: changing it scales all tiers proportionally.
- SQL for the templates: `sql/2026_09_23_activity_boss_tiers_190090_190093.sql` (see `sql/README.md` for the deploy runbook).

## Regression constraints (guarded by the smoke test)

- `GetCreatureByGUID()` does not exist in mod-ale/Eluna — look a live boss up with `GetMapById()` + `GetUnitGUID(low, entry)` + `Map:GetWorldObject()`.
- `IsManagedBossEntry`, `DEFAULT_SPAWN_POINTS` and `activeBossInfo` must be forward declared: references before their `local` declaration resolve to globals (`nil`).
- `rebase` / `config reload` must recompute the base health from the template (`Creature:UpdateEntry()`, **out of combat** only — it resets the threat table); in combat fall back to `current / multiplier` so the multiplier never compounds.
- `Unit:SetLevel()` only writes `UNIT_FIELD_LEVEL` and does not recompute creature stats; level-83 templates with real WotLK stat rows (`exp=2`) are required.
- Contribution stats accumulate per boss guid and are released only on death settlement or `.boss clear`.
- Config auras are tracked per guid and the difference is `RemoveAura`-ed on reload.
- `print` is shadowed file-locally (`local print = BossLog`) — overriding the global `print` sends every later Eluna script's output into `boss.log`.
- Logs rotate at 5 MB to `boss.log.<timestamp>.bak`; event/contributor text is truncated UTF-8-safely at the column width; an empty `SPAWN_POINTS` raises `math.random(0)` and needs an explicit guard.
- Info-only subcommands (`.boss help`, `preset list`, `difficulty list`) must send their first line through `BossReply` so strict callers see the `[AGMP_OK]` / `[AGMP_ERROR]` marker.
- `bossRewardedGUIDs` is cleared on death.

## Testing without a server

`tools/boss-lua-smoke/smoke.lua` loads `boss.lua` into a stubbed Eluna environment (no `worldserver` needed) and asserts 219 invariants: load-time behaviour, SQL construction for both config tables, ext-table DDL/INSERT column consistency, command markers, `.boss config show` output, "database values win over script defaults", `.boss clear` side effects, event registration, the daily schedule, the random skill preset, **skill pool / combo content** (every combo spell must live in its preset's pools, combo names globally unique, at least 6 combos per preset, 4 difficulties x 10 presets scale without hitting the `ClampNumber(10,80)` clamp, default-library yell coverage for every combo), **combo casting (offline driven)** (fake boss + fake player drive the real `TryComboChain` and cast loop: the trigger tick only fires the first spell and queues the rest, the queue drains one spell per idle tick, the accumulated cast sequence equals a declared combo, per-combo and global cooldowns are written at trigger time, the yell equals the configured text), the six reward pools (including a full `OnBossDied` payout run), multi-realm binding, and the regressions above. See `tools/boss-lua-smoke/README.md`.

```
lua smoke.lua /path/to/boss.lua          # exit 0 = all assertions pass
```

## Requirements

- AzerothCore 3.3.5a with Eluna enabled (tested against `mod-ale`, the Eluna fork used by AzerothCore).
- MySQL/MariaDB with the `characters` DB accessible.
- Script placed in the `lua_scripts` load path.
- The script talks to the `ac_eluna` schema through `CharDBQuery`/`CharDBExecute`; the name is the `BOSS_DB_NAME` constant at the top of `boss.lua`. When several realms share one auth database, give each realm its own schema (see "Multi-realm deployment" below) and mirror it in the panel's `config/boss.php` `server_overrides`.

## Install

1. Copy `boss.lua` to your Eluna scripts folder.
2. (Optional) Create the dedicated templates with `sql/2026_09_23_activity_boss_tiers_190090_190093.sql`, then `.reload creature_template`.
3. Restart `worldserver` (or `.reload ale`).
4. Verify server logs for schema bootstrap output.
5. Verify the realm binding: `lua_scripts/lua_logs/boss.log` must contain
   `[BOSS] 本区绑定: db=... configKey=... runtimeKey=...`.

## Multi-realm deployment (several realms sharing one auth database)

Each realm runs its own `worldserver` **and its own copy of `boss.lua`**, but they **share one
schema** (default `ac_eluna`) and are kept apart by `state_key` — **no per-realm database needed**.
All four tables are separated by that key:

| Table | How it is separated |
|---|---|
| `boss_activity_config` / `boss_activity_config_ext` / `boss_activity_runtime` | `state_key` is the primary key |
| `boss_activity_events` / `boss_activity_contributors` | have a `state_key` column (added, with its index, by `boss.lua` on an old schema) |

So the only per-realm difference in `boss.lua` is that **one key** in §2 (both lines must match):

```lua
local BOSS_DB_NAME = "ac_eluna"       -- shared schema, normally left alone
local BOSS_RUNTIME_KEY = "current"    -- this realm's key: runtime/events/contributors
local BOSS_CONFIG_KEY = "current"     -- this realm's key: config tables (must equal the line above)
```

| Realm | worldserver dir | key (both lines) | panel `server_overrides[<index>].runtime_key` |
|---|---|---|---|
| main (upgraded from single-realm) | `D:\AzerothCore\release\<realm-a>` | `current` (unchanged → existing rows keep belonging to it, **zero migration**) | `current` |
| second | `D:\AzerothCore\release\<realm-b>` | `<realm-b>` | `<realm-b>` |
| third | … | `<realm-c>` | `<realm-c>` |

**Two realms with the same key share one config/runtime/event set** — give every realm its own key.

Deploy with `tools/deploy-realm.ps1` (rewrites the key, backs up the previous file, optionally
syntax-checks it, prints the panel snippet):

```powershell
# dry run first
pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> -DryRun
# real deployment, including the difficulty-tier templates for that realm's world DB
pwsh -File tools\deploy-realm.ps1 -RealmRoot D:\AzerothCore\release\<realm-b> -RuntimeKey <realm-b> `
    -LuaExe <lua.exe> -ApplyTierSql <that realm's world DB> -DbPassword <pw>
```

A new realm gets its own row seeded with defaults (`INSERT IGNORE`) on first load. To carry an
existing realm's activity config over, export that realm's row (`WHERE state_key = '<old key>'`),
change the key in the dump and import it.

## Standalone Mode (Without Web)

The script runs independently: Lua ensures database/table existence, inserts missing config
defaults, and is the only writer of runtime/event/contributor records. No AGMP/Web dependency is
required for core functionality.

## Using With AGMP Web Management

### Responsibility Split

- Lua owns schema creation/migration and runtime persistence.
- AGMP only reads/writes data and sends SOAP commands (including the difficulty tier selection and the kill/reset buttons).
- If tables are missing, AGMP shows warnings instead of creating schema.
- Console/SOAP replies carry an `[AGMP_OK]` / `[AGMP_ERROR]` marker; AGMP treats a reply without a marker as a failure, so a command that never reached the game is not reported as success.

### Recommended AGMP Flow

1. Ensure `boss.lua` has been loaded at least once (creates schema).
2. Open AGMP Boss page.
3. Edit config in Web UI (including spawn points text and difficulty tier).
4. Save config in AGMP.
5. AGMP calls `.boss config reload` via SOAP.

### Key AGMP Config Expectations

- AGMP points to `ac_eluna` as custom DB for Boss module.
- `boss_activity_config` contains a `spawn_points_text` column.
- The panel writes the main table with `REPLACE INTO` (fixed column list) and the ext table with
  `INSERT ... ON DUPLICATE KEY UPDATE` (submitted columns only) — add a main-table column only
  together with the panel code; an ext-table column is safe on its own, but must be appended at the
  end of both the Lua descriptor table and the panel's `ext_fields`.
- SOAP account has permission to execute Boss commands.
- `php tools/verify_boss_ext_page.php` cross-checks the panel's ext schema against `boss.lua`'s
  descriptor table and renders the page in both locales (81 checks).

## Security and Ops Notes

- Restrict command permissions to trusted GM/admin roles.
- Back up `ac_eluna` before major tuning changes.
- Keep the script and AGMP module versions aligned.
- Never replay a dumped SQL file containing `CREATE`/`ALTER` against a live database inside `START TRANSACTION`/`ROLLBACK`: MySQL DDL implicitly commits. Use a scratch schema instead (see `tools/boss-lua-smoke/README.md`).

## License

MIT. See `LICENSE`.
