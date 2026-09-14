# AOE Bombard Cannon integration

This test integration maps AOE2DE DAT Unit `36` (`u_sie_bombard_cannon`) and
Projectile Unit `368` (`p_ball`) onto native Recoil gameplay. The AOE renderer
only owns Sprite sampling; targeting, movement, ballistics, collision, radial
damage and death remain native engine behavior.

## Gameplay mapping

The test profile uses 60 Recoil elmos per AOE tile and 30 simulation frames per
second:

| AOE/DAT value | Recoil definition |
| --- | --- |
| hit points 80 | `maxDamage = 80` |
| speed 0.7 | `speed = 42` |
| line of sight 14 | `sightDistance = 840` |
| range 5..12 | `minRange = 300`, `range = 720` |
| reload 6.5 s | `reloadtime = 6.5` |
| release frame 7 | `windup = 7 / 30` |
| projectile speed 4 | `weaponVelocity = 240` |
| projectile arc -0.05 | native Cannon with `myGravity = 0.05` |
| blast width 0.5 | `areaOfEffect = 60` diameter approximation |

`WeaponDef.minRange` is measured horizontally from the stable Unit chassis
position to the current target aim point; the directional muzzle is deliberately
excluded so a `turret = false` unit cannot cross the threshold merely by turning.
It is enforced in target acquisition, CommandAI, the normal
fire gate and immediately before projectile release. A temporary `CMD.FIGHT`
target inside the dead zone is skipped so the unit resumes its route. An
explicit `CMD.ATTACK` backs away unless Move State is Hold Position; Hold
Position waits without retreating. `revalidateTargetOnSalvo = true` cancels an
invalid first release and refunds the committed reload timer. If a temporary
Fight target becomes invalid during Windup, only its internal attack command is
finished and the underlying Fight route resumes; automatic targeting marks that
target for replacement. Defaults are zero and false, so ordinary Recoil weapons
keep their previous behavior.

The weapon uses the canonical readable names mapped from its exact DAT attack
class IDs. The authoritative ID mapping and all manifest-to-Def rules live in
[aoe2_manifest_to_recoil_rules.md](aoe2_manifest_to_recoil_rules.md). Damage
only considers classes also present on the target; see
[aoe2_armor.md](aoe2_armor.md) for the runtime calculation.

## Projectile sampling

The original Graphic `3382` is not 30 directions. DAT declares one angle, 30
frames, sequence type 1 and a frame duration of approximately 0.0155 seconds.
The exporter records `sampling_mode = "time_loop"`; the projectile bridge lets
the renderer advance those frames by time while gameplay orientation continues
to come from the projectile velocity. Existing arrow-like resources without
this metadata retain the legacy `pitch_pose` fallback.

The release-frame muzzle flash/smoke, projectile trail and impact use native
Recoil CEGs in `gamedata/explosions/aoe_bombard.lua`. The dedicated Unit script
spawns the muzzle CEG from Recoil's live weapon vector in `script.Shot`, so it
tracks the calibrated AOE muzzle in every direction. The two test sounds are
existing springcontent placeholders, not exported AOE media.

## Calibration test

Build an engine with `SUPPORT_AOE_ARMOR=ON`, then launch from the repository
root with a complete runtime directory:

```powershell
& .\build-official-release\extract\spring-dev.exe `
  --write-dir "$PWD\build-test-runtime" `
  "$PWD\build-test-runtime\aoe-bombard-calibration-test.txt"
```

The scene reuses the ranged anchor tool and creates 16 Bombard Cannons, one per
Sprite direction, each with a stationary hostile target 480 elmos ahead. Press
`G` to toggle live object attacks; the existing anchor controls and export UI
remain available. Useful ModOptions are:

- `aoe_anchor_calibration_unit`
- `aoe_anchor_calibration_target_unit`
- `aoe_anchor_calibration_target_distance`
- `aoe_anchor_calibration_spacing`
- `aoe_anchor_calibration_move_state` (`0` Hold, `1` Maneuver, `2` Roam)
- `aoe_anchor_calibration_ground_attack`

The minimum-range regression was also run at 250 elmos: Hold Position rejected
the shot without retreating, while Maneuver backed out of the dead zone and all
16 directions subsequently produced native projectiles. The checked-in preset
remains at 480 elmos for uncluttered visual calibration.

## Current approximation and limits

- Recoil's native radial splash is used. Exact AOE blast attack/defense-level
  filtering is not implemented.
- `collideNonTarget = false` keeps the selected target/ground endpoint stable;
  the impact explosion still applies native area damage.
- Sound assets are test placeholders and need art/audio review before release.
- The test UnitDef is hand-authored from DAT. Automatic UnitDef/WeaponDef
  generation remains separate work.
