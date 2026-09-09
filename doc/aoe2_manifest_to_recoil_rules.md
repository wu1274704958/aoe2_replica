# AOE2 Manifest 到 Recoil Def 的数据转换规则

## 状态

本文件定义未来转换工具应执行的规则。它以 `u_arc_archer` 的手工验证为依据；
当前仓库尚未实现批量转换命令。

建议工具位置：`tools/aoe2manifest_to_recoil.py`。工具只生成 Lua 配置和报告，
不改写用户手工维护的 UnitDef/WeaponDef。

## 输入

工具输入为：

1. 一个 AOE unit manifest；
2. 可选 projectile graphics manifest；
3. 显式 conversion profile；
4. 可选人工 anchor override 文件。

profile 必须包含版本、DAT 到 Recoil 的轴映射、每轴比例、符号和朝向零点。不得
把这些规则隐含在工具代码或 renderer 中。

```json
{
  "schema": 1,
  "dat_to_recoil_local": {
    "right": { "source": "x", "scale": 60.0, "sign": 1 },
    "up":    { "source": "z", "scale": 30.0, "sign": 1 },
    "front": { "source": "y", "scale": 60.0, "sign": 1 }
  },
  "aim_strategy": "collision_center",
  "unit_overrides": {
    "u_arc_archer": {
      "muzzle_correction_local": [0.0, 10.5, 0.0],
      "source": "manual_calibration_2026-09-04"
    }
  }
}
```

以上是弓手测试 profile 的结构示例，不是对所有 AOE asset 已验证的全局默认值。

## 输出

每个可用 Unit 生成可合入 UnitDef 的片段：

```lua
customParams = {
  aoe2_unit_id = "u_arc_archer",
  aoe2_aim_local = "0 30 0",
  aoe2_collision_local = "0 30 0",
  aoe2_weapon1_muzzle_local = "0 55.5 30",
  aoe2_weapon1_forward_local = "0 0 1",
}
```

同时生成：

- collision/selection volume 推荐值；
- WeaponDef 的 projectile resource 映射和 AttackA release time；
- 机器可读转换报告，保留 DAT 原值、profile、生成值及所有警告；
- 不确定项清单，例如缺少 projectile graphics 或缺少 socket override。

## 规则

### 受击点和碰撞

- DAT `collision_size.x/y` 是地面半径，Recoil full scale 应为两倍半径后再乘对应轴比例。
- DAT `collision_size.z` 是完整高度，Recoil `CylY` 的 Y scale 是高度乘垂直比例。
- `aim_local.y` 应为完整高度的一半，使单位由地面延伸至顶部。`collision_local` 默认
  等于 `aim_local`，但大型建筑可独立设置它，使碰撞体底部贴地而不改变受击／瞄准点。
  AOE anchor 启用时，引擎将 UnitDef collision offset 从 placeholder model 的 midPos
  坐标转换为该 sprite-foot-relative centre；转换工具不应再生成
  `collisionVolumeOffsets`。
- 默认 aim strategy 为 `collision_center`；若 override 提供 `aim_local`，它优先。

### 远程发射点

- 仅当 `combat.projectile_unit_id >= 0` 时生成 muzzle。
- 将 `combat.weapon_offset` 按 profile 生成 raw muzzle，再叠加可选的 Unit 级
  `muzzle_correction_local`，输出 `aoe2_weaponN_muzzle_local`。报告必须分别保留 DAT 原值、
  raw 生成值、correction 和 final 值，便于追溯。
- 弓手当前 raw 值为 `(0,45,30)`，人工 correction 为 `(0,10.5,0)`，final 为
  `(0,55.5,30)`。不得根据这一个样本把全局 up scale 改为 37。
- 默认 `forward_local=(0,0,1)`；它描述 Unit 本地前方，不是弹道方向。实际弹道方向仍由 Recoil 对 target aimPos 的原生求解确定。
- `frame_delay / attack_animation.fps` 生成 AttackA 的发射时刻候选值；如果动画被重采样，必须使用最终 fps。

### Projectile sprite

- projectile graphics manifest 的每帧 `foot` 继续由 renderer 用于将 sprite 对齐到 native `drawPos`。
- 不将 projectile `foot` 写入 WeaponDef；它是渲染数据而非 muzzle 或 hit point。
- 没有箭头尖端 anchor 时，允许一个显式 visual offset override，但它不得改变 native projectile 的 collision origin。

### 近战

- `projectile_unit_id = -1` 不生成 projectile renderer 或 muzzle projectile 配置。
- 仍生成 collision、aim、AttackA timing 和 weapon range 建议。
- `contact_local` 是可选视觉锚点；需要动作/方向变化时使用以下人工数据，绝不从缺失的 manifest 字段伪造：

```json
{
  "anchors": {
    "attackA": {
      "contact": {
        "mode": "per_direction_frame",
        "values": { "0": { "12": [0.1, 0.8, 1.0] } }
      }
    }
  }
}
```

## 校验与拒绝条件

工具必须：

- 校验 manifest schema、`foot`、`collision_size`、`weapon_offset` 和 `frame_delay` 的类型/有限性；
- 校验 main/shadow/player-color 图层的帧尺寸与 foot 是否一致；
- 对 profile 生成 0、90、180、270 度及多个随机连续 heading 的 local-to-world 样本；
- 报告 projectile resource ID 无法解析、攻击动画不存在、DAT 横向偏移为零而无法校准轴符号等情况；
- 将缺失逐帧 socket 标为限制，而非输出虚假的精确 attachment。

工具不得：

- 按 16/32 个 sprite 方向生成物理 muzzle 坐标；
- 每帧通过 Lua 重写 aimPos；
- 用 placeholder S3O 的 piece 代替导出的 AOE anchor；
- 修改 renderer、寻路或群组 Gameplay。

## 实施前提

在正式批量转换前，至少再验证一个 DAT `weapon_offset.x != 0` 的远程 Unit，以
确认 profile 的横向符号；并对至少一个近战 Unit 验证 collision/aim 与原生攻击
距离的配合。还需至少一个 `weapon_offset.z != 0` 的其他远程 Unit 验证 up scale
与 correction 是否可泛化。仅在这些验证完成后，才可将弓手 profile 升级为可复用默认 profile。
