# AOE2-style armor and attack classes

`SUPPORT_AOE_ARMOR` enables the experimental AOE2 numerical damage path. It is
enabled by default on `aoe_dev`; use `-DSUPPORT_AOE_ARMOR=OFF` to compile the
unchanged Recoil damage path without the AOE Lua APIs.

## Definition data

An AOE unit declares integer armor by class and an optional list of upgrade
tags:

```lua
aoeArmor = { melee = 1, pierce = 2, cavalry = 0 },
aoeUpgradeTags = { "cavalry" },
```

An AOE weapon declares its attack entries and its own upgrade tags:

```lua
aoeDamage = { melee = 7, cavalry = 2 },
aoeUpgradeTags = { "cavalry" },
```

Class names are case-insensitive and normalized to lowercase. Values must be
integers. The entries are not Recoil `ArmorDefs`; they are independent AOE
attack and armor classes.

When an `aoeDamage` weapon hits a unit, the engine calculates:

```text
max(1, sum(max(0, attack[class] - targetArmor[class])))
```

Missing target armor is zero. The resulting base damage then continues through
the existing Recoil flank modifier, armored multiplier, `UnitPreDamaged`,
impulse, and health paths. Normal weapons, environmental damage, collisions,
and Features retain their existing damage behavior.

Projectile weapons retain their `DamageArray` at launch, so an upgrade applied
after firing affects subsequent projectiles but not arrows already in flight.

## Technologies

`LuaRules/Configs/aoe_upgrades.lua` maps a technology ID to tag selectors and
integer deltas or native weapon-state overrides. `weaponTags` select WeaponDefs
for attack and weapon-state changes and `unitTags` select UnitDefs for armor
deltas. A selector matches when any tag matches.

```lua
fletching = {
  weaponTags = { "archer" },
  damage = { pierce = 1 },
}

castle_rapid_fire = {
  weaponTags = { "castle" },
  weaponState = { burst = 10 },
}
```

`weaponState` values are absolute native weapon values, applied through the
synchronized `Spring.SetUnitWeaponState` API. The Castle's base WeaponDef has
`burst = 5` and `burstRate = 0.12`; `castle_rapid_fire` changes only `burst`
to `10`, retaining the cadence. This deliberately keeps the Castle in one
weapon slot, so the AOE bridge continues to drive one `AttackA` animation.

The synced upgrade gadget exposes:

```lua
GG.AoeArmor.ApplyTeamUpgrade(teamID, upgradeID)
```

It is idempotent, updates the team’s existing units immediately, and applies
all completed upgrades to future units in `UnitCreated`. Research timing,
resources, commands, and UI remain the responsibility of the gameplay Lua
layer.

## Local test

The AOE test Mod enables `aoe_armor_upgrade_test` in
`build-test-runtime/aoe-armor-test.txt`. It applies `fletching` to Team A and
`padded_archer_armor` to Team B on frame 60. Launch it with the locally built
engine, for example:

```powershell
& .\build-mingw\spring.exe --write-dir "$PWD\build-test-runtime" "$PWD\build-test-runtime\aoe-armor-test.txt"
```
