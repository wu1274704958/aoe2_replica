# AOE2 Unit 锚点接入设计

## 目标与边界

本设计让 AOE2 sprite Unit 在保留 Recoil 原生 Unit、Weapon、Cannon
Projectile、碰撞和伤害逻辑的前提下，使用 AOE 数据定义受击点和发射点。
锚点是 Gameplay 数据；renderer 只使用 Unit/Projectile 的 `drawPos`，不参与
命中或弹道计算。

本阶段只接入了 `u_arc_archer` 的手工数据，不实现 manifest 批量转换工具。

## Manifest 数据语义

| 字段 | 含义 | 用途 |
| --- | --- | --- |
| 每帧 `foot` | SLD 图像热点，坐标相对帧左上角 | sprite 的渲染锚点，不是 Gameplay 受击点 |
| `collision_size` | DAT X/Y 地面半径、DAT Z 完整高度 | Recoil collision/selection volume 和默认 aim 的来源 |
| `combat.weapon_offset` | DAT Unit 局部的静态远程武器偏移 | 原生 weapon muzzle 的来源 |
| `combat.frame_delay` | 攻击动画的发射帧 | 后续驱动 AttackA 与发射时刻对应 |
| projectile manifest 的 `foot` | projectile 各方向/仰角图像热点 | 将 AOE projectile sprite 对齐到原生 projectile `drawPos` |

manifest 不包含逐方向、逐帧的手部、弓弦、武器尖端或受击骨骼。因而本设计
保证物理锚点正确，不能从数据中保证武器像素级 socket 对齐。

## 原生锚点路径

`UnitDef` 解析以下 `customParams`，将字符串只解析一次为 `UnitDefAnchorSet`：

```lua
aoe2_aim_local = "x y z"
aoe2_weapon1_muzzle_local = "x y z"
aoe2_weapon1_forward_local = "x y z"
```

这些数值处于 Recoil Unit 局部空间：`x` 使用引擎的 `rightdir`，`y` 使用
`updir`，`z` 使用 `frontdir`。其世界变换由
`CSolidObject::GetObjectSpacePos()` 完成：

```text
world = unit.pos + unit.rightdir * local.x
                  + unit.updir    * local.y
                  + unit.frontdir * local.z
```

因此朝向为连续角度而非 sprite 的 16/32 个离散方向；转向和斜坡上的 updir
变化也会自动更新锚点，不需要每帧 Lua 同步。

`CUnit::PreInit()` 使用 `aim_local` 初始化本地 `aimPos`。随后
`UpdateMidAndAimPos()` 在引擎方向变化时维护世界 `aimPos`。

`CWeapon::UpdateWeaponVectors()` 检测对应 weapon anchor 后直接生成
`aimFromPos`、`weaponMuzzlePos` 和 `weaponDir`，并跳过
`QueryWeapon()`/`AimFromWeapon()` 的占位 S3O piece 查询。其他 Unit 和武器
仍走原始路径。

调用链：

```text
UnitDef customParams -> UnitDefAnchorSet
  -> CUnit::PreInit (relAimPos / aimPos)
  -> CWeapon::UpdateWeaponVectors (muzzle)
  -> CWeapon::GetUnitLeadTargetPos (target aimPos)
  -> CCannon::FireImpl (native projectile origin and parabola)
  -> Aoe2ProjectileGameplayRenderBridge (projectile drawPos)
```

## 弓手手工校准

`u_arc_archer` 的 DAT 数据为：

```text
collision_size = (0.2, 0.2, 2.0)
weapon_offset  = (0.0, 0.5, 1.5)
```

当前测试场景采用的暂定水平转换为：

```text
DAT -> Recoil local horizontal
(x, y) -> (right=x * 60, front=y * 60)
```

2026-09-04 的 Sprite 与原生碰撞线框对比证明，billboard 的屏幕像素高度不能
直接作为世界 Y 高度。弓手身体高度校准为 60，发射点经运行时工具人工调整为：

```text
aim_local       = (0, 30, 0)
muzzle_local    = (0, 55.5, 30)
forward_local   = (0, 0, 1)
collision scales  = (24, 60, 24)
collision centre  = (0, 30, 0)
```

`Aoe2UnitPixelsToWorld=0.55` 描述 billboard 平面上的像素缩放。由于 billboard 的
竖轴是 `camera->GetUp()`，它不能直接用于推导世界 Y 碰撞高度。60 是当前标准预览
摄像机下覆盖身体与头部的待验证校准值，不包含弓、手臂、武器或阴影。碰撞体的
配置 offset 仍是相对 placeholder S3O 的 `relMidPos`；引擎在 AOE anchor 启用时
将其转换为 `aim_local - relMidPos`，所以碰撞中心和 aim 点均保持在 `(0,30,0)`。

当前基础候选换算为 `(right=x*60, up=z*30, front=y*60)`，它将弓手
`weapon_offset` 转为 `(0,45,30)`。人工导出值等价于再叠加弓手专用修正
`(0,+10.5,0)`。仅有一个非零高度样本，不应将 `55.5 / 1.5 = 37` 直接升级为
全局垂直比例；转换工具应保留“基础 profile + Unit 级 correction”两层数据。

同一个 `muzzle_local=(0,55.5,30)` 在预览的 16 个方向上都对齐正确。这符合
`weapon_offset` 作为三维 Unit-local 静态偏移的语义：Recoil 使用 Unit 基向量旋转，
无需按 Sprite 方向复制 16 份物理发射点。只有未来某个单位存在可见的像素级残差时，
才考虑只影响渲染的方向 socket。

## 验证场景与结果

通过 `_script.txt` 中的 `aoe_anchor_validation=1` 启用。场景生成一名静止红方
目标和六名蓝方攻击者：北、东、南、西、东北、 southwest。攻击者逐个执行
原生 `CMD.ATTACK`，每次射击后停止，随机散布、喷射角和目标移动误差均为零。

同步日志和地图标记显示脚点、aimPos、muzzle、武器方向、projectile 起点及命中
时的目标 aimPos。

2026-09-03 的运行结果：

| 朝向 | muzzle 相对脚点 | projectile 起点 | 目标 aimPos |
| --- | --- | --- | --- |
| 北 | `(0, 31.5, +30)` | `(5120, 63.5, 2230)` | `(5120, 53, 2560)` |
| 东 | `(+30, 31.5, 0)` | `(4790, 63.5, 2560)` | `(5120, 53, 2560)` |
| 南 | `(0, 31.5, -30)` | `(5119.95, 63.5, 2890)` | `(5120, 53, 2560)` |
| 西 | `(-30, 31.5, 0)` | `(5450, 63.5, 2560)` | `(5120, 53, 2560)` |
| 东北 | `(+21.12, 31.5, +21.31)` | `(4886.56, 63.5, 2326.75)` | `(5120, 53, 2560)` |
| 西南 | `(-21.15, 31.5, -21.28)` | `(5353.41, 63.5, 2793.28)` | `(5120, 53, 2560)` |

六次 projectile 均从对应的 native muzzle 创建，并在飞行后造成目标伤害；目标
转向至东侧后，垂直 `aim_local=(0,21,0)` 的世界 aimPos 保持 `(5120,53,2560)`，
符合预期。该结果验证了 anchor 生命周期、连续旋转和 native 弹道/受击点链路。

## 近战与限制

近战 Unit 即使带有 `combat` 块也可能使用 `projectile_unit_id = -1`。此时仍应
导出 collision、aim 和攻击时刻，但不创建 projectile anchor。Recoil 的近战
命中仍使用原生 weapon 距离和 collision。

若未来需要剑尖/矛尖火花精确贴图，应添加可选 `contact_local`；若动作期间
接触点变化，则采用人工 `per_action/per_direction/per_frame` override。它只驱动
视觉特效，不能替代原生伤害判定。
