# AOE roster 严格 Gameplay 接入缺口

## 背景

当前 AOE Render Bridge 只由单位的第一个 Recoil WeaponDef 驱动一个 `AttackA` 状态。本待办记录需要 Lua/C++ 扩展才能严格复刻、因此没有生成 Def 的资源；不得以错误的 Def 近似替代。

## 已实现：诸葛连弩（DAT 73）

- 源数据：每轮 3 枚 `p_arrow`；首箭 8 穿刺并带 +2 反长矛加成，后两箭各 3 穿刺，装填 3 秒。
- 实现：`WeaponDef` 新增仅 `SUPPORT_AOE_ARMOR` 生效的 `aoeSalvoDamage` 每发次伤害覆盖表；`CWeapon::UpdateSalvo()` 用 `salvoSize - salvoLeft - 1` 得到本次发次序号，经 `ProjectileParams` 传给投射物，由 `CWeaponProjectile` 在命中结算时使用。标记 `inheritWeaponDamage` 的发次沿用武器实例的可变伤害表，因此仍受运行时 AOE 升级影响；其余发次使用 `WeaponDef` 持有的不可变 profile。AOE Bridge 仍只观察第一个武器，保持单一 `AttackA`。
- 验收场景 `build-test-runtime/aoe-chukonu-test.txt` + `game_aoe_chukonu_test.lua`，实测通过：

  ```text
  PASS volley=base             hits=[1:8.00 2:3.00 3:3.00] expected=[8.00,3.00,3.00]
  PASS volley=after-fletching  hits=[1:9.00 2:3.00 3:3.00] expected=[9.00,3.00,3.00]
  ```

  首箭吃 `fletching`（+1 穿刺）升到 9，后两箭稳定 3 不变，与 DAT 的"后续箭不继承主箭升级"一致。测试目标用 `Spring.SetUnitFlanking` 把 Recoil 的 flanking 伤害系数固定在 1.0，以隔离与该机制无关的 0.9 下限。
- 遗留：`burstRate` 目前是 6/30 的占位值，后两箭的精确释放帧仍需从 AttackA 逐帧标定，manifest 未记录该数据。

## 已实现：AOE 攻击类别与护甲的稀疏匹配

- 实现：`CalculateAoeArmorDamage()` 现在只计算攻击和目标护甲表中同时存在的类别；目标缺失类别不再隐式视为零护甲。最低总伤害仍为 1。
- Def 策略：保留已有可读类别，并为 DAT 精确映射补充 `class_N` 数字键。Bombard 等新武器只使用数字键，避免未知或复用类别被错误命名。武器不能同时配置同一类别的别名和数字键，否则两者会作为不同类别相加。
- 影响：诸葛连弩的 `spearman` 加成不再作用于未声明 `spearman` 护甲的普通弓兵；火枪兵的 Infantry/Ram 等加成也仅命中显式类别。
- 回归脚本的首箭期望值已随稀疏类别语义从旧错误的 10/11 更新为 8/9；新引擎实测基础轮次 `8/3/3`、Fletching 后 `9/3/3`，两轮均 PASS。

## 已实现：最小射程与释放时弹道复查

受影响资源：非洲箭塔（DAT 79）、西方城堡（DAT 82）、手推炮（DAT 36）、小型抛石机（DAT 280）、未展开投石机（DAT 42）。

- 源数据的 min range 分别为 1、1、5、3、4 个 AoE 射程单位。
- `WeaponDef.minRange` 默认 0，在自动索敌、`CWeapon::TryTarget/TestRange`、移动单位对象/地面攻击 CommandAI 中统一执行水平距离检查。
- `CMD.FIGHT` 的临时目标过近时会被跳过并继续原路线；显式 `CMD.ATTACK` 会后退到可攻击距离；Hold Position 不后退。
- `WeaponDef.revalidateTargetOnSalvo` 默认关闭。启用后在每发 Projectile 释放前，以最新目标位置重新验证有效性、范围、射界和弹道；首发失败会取消本轮并退还 reload，burst 后续失败只截断未发射部分。
- `aoe_bombard_cannon_shot` 首次使用上述两个开关。非最小射程、未开启释放复查的武器保持原路径。

## 攻城器额外语义

- 小型抛石机（DAT 280）已生成可运行 Def：固定 6 枚石弹使用一帧间隔的原生
  `burst`，首枚继承 DAT 280 的完整 Attack 数组，后五枚通过 `aoeSalvoDamage` 使用
  Secondary Projectile DAT 369 的最低 1 点 fallback；主/副 Projectile 实际引用同一
  `p_mangonel_x1` 图像，因此共享一个 60 FPS `time_loop` 渲染资源。`impact_dust` 已从
  16 方向 TexturePacker 粒子图集导出并接入命中视觉。
- 小型抛石机仍需人工校准 `projectile_arc=0.4` 对应的 Recoil 重力，以及 DAT 1x1、
  randomness=99 的发射区域与当前 `sprayAngle` 近似。AoE blast level、友伤和
  Recoil `areaOfEffect` 的边界差异也仍属严格复刻缺口，不影响当前原生 Gameplay 闭环。
- 未展开投石机仅有静态资源；严格接入需要 Pack/Unpack 状态、移动限制及相应动画/资源状态机。
- 手推炮和小型抛石机已经生成可测试 Def；未展开投石机仍等待展开状态语义后再接入。
