# AOE roster 严格 Gameplay 接入缺口

## 背景

当前 AOE Render Bridge 只由单位的第一个 Recoil WeaponDef 驱动一个 `AttackA` 状态。本待办记录需要 Lua/C++ 扩展才能严格复刻、因此没有生成 Def 的资源；不得以错误的 Def 近似替代。

## 已实现：诸葛连弩（DAT 73）

- 源数据：每轮 3 枚 `p_arrow`；首箭 8 穿刺并带 +2 反长矛加成，后两箭各 3 穿刺，装填 3 秒。
- 实现：`WeaponDef` 新增仅 `SUPPORT_AOE_ARMOR` 生效的 `aoeSalvoDamage` 每发次伤害覆盖表；`CWeapon::UpdateSalvo()` 用 `salvoSize - salvoLeft - 1` 得到本次发次序号，经 `ProjectileParams` 传给投射物，由 `CWeaponProjectile` 在命中结算时使用。标记 `inheritWeaponDamage` 的发次沿用武器实例的可变伤害表，因此仍受运行时 AOE 升级影响；其余发次使用 `WeaponDef` 持有的不可变 profile。AOE Bridge 仍只观察第一个武器，保持单一 `AttackA`。
- 验收场景 `build-test-runtime/aoe-chukonu-test.txt` + `game_aoe_chukonu_test.lua`，实测通过：

  ```text
  PASS volley=base             hits=[1:10.00 2:3.00 3:3.00] expected=[10.00,3.00,3.00]
  PASS volley=after-fletching  hits=[1:11.00 2:3.00 3:3.00] expected=[11.00,3.00,3.00]
  ```

  首箭吃 `fletching`（+1 穿刺）升到 11，后两箭稳定 3 不变，与 DAT 的"后续箭不继承主箭升级"一致。测试目标用 `Spring.SetUnitFlanking` 把 Recoil 的 flanking 伤害系数固定在 1.0，以隔离与该机制无关的 0.9 下限。
- 遗留：`burstRate` 目前是 6/30 的占位值，后两箭的精确释放帧仍需从 AttackA 逐帧标定，manifest 未记录该数据。

## AOE 攻击类别与护甲的匹配（影响整个 roster）

- 现状：`CalculateAoeArmorDamage()` 按 `max(1, sum(max(0, attack[class] - armor[class])))` 计算，且 `doc/aoe2_armor.md` 明确"缺失目标护甲按 0"。因此武器 `aoeDamage` 里的**任何**加成类别都会对**所有**目标生效，而非只对拥有该护甲类别的目标生效。
- 症状：`aoe_chukonu_arrow` 的 `aoeDamage = { spearman = 2, pierce = 8 }` 打无护甲弓兵结算为 10 而不是 8；`aoe_handcannoneer` 的 `{ spearman = 1, infantry = 10, pierce = 17, ram = 2, gunpowder = -10 }` 会结算为 30 而不是 17。受影响的是全部带加成类别的 AOE 武器，不是诸葛连弩特有。
- 待定方案：要么让导出的 `aoeArmor` 为全部加成类别补条目（非本类目标给一个足够大的值），要么把"缺失护甲类别"的语义改为"该类别不参与结算"。两者都会改变现有 AOE 单位的结算数值，需要连同 `doc/aoe2_armor.md` 和现有测试一起评估。

## 最小射程武器

受影响资源：非洲箭塔（DAT 79）、西方城堡（DAT 82）、手推炮（DAT 36）、小型抛石机（DAT 280）、未展开投石机（DAT 42）。

- 源数据的 min range 分别为 1、1、5、3、4 个 AoE 射程单位。
- 缺口：当前 `WeaponDef` 没有最小目标距离，CommandAI、自动索敌和 Weapon 的可开火判断不会拒绝近距离目标。
- 后续 C++ 方案：在 `WeaponDef` 新增可选 `minRange`，并在武器目标有效性、自动目标选择和攻击地面判定中统一按水平距离拒绝低于阈值的目标。默认 0，确保非 AOE 单位的行为不变。
- 验收：目标位于 `[minRange, maxRange]` 时可以开火；低于 minRange 时不锁定、不发射、且不影响普通 Recoil WeaponDef。

## 攻城器额外语义

- 小型抛石机需要核对 AoE 范围伤害、友伤、辅助投射物和 Recoil `areaOfEffect` 的精确差异。
- 未展开投石机仅有静态资源；严格接入需要 Pack/Unpack 状态、移动限制及相应动画/资源状态机。
- 在以上缺口完成前，不为这三个攻城器生成可被测试脚本实例化的 Def。
