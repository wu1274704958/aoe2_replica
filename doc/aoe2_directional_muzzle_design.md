# AOE2 Unit 方向发射 Socket 配置与实现方案

## 当前结论（2026-09-04）

弓手经运行时校准后使用单一物理发射点 `(0,55.5,30)`，在 16 个 Sprite
方向上人工观察均对齐正确。因此当前不实现逐方向 muzzle，也不为 UnitDef 生成
16 份物理偏移。本文以下方案降级为备选：只有未来其他资源在共享 Unit-local
发射点下仍存在明显像素级残差时，才考虑仅用于渲染的 `visual_muzzle_socket`。

## 目标与边界

AOE2 Unit 使用按观察方向预渲染的二维 Sprite，Recoil 的 `CWeapon` 和
Projectile 使用摄像机无关的三维同步坐标。若未来某个资源的单一三维
`muzzle_local` 不能在所有 Sprite 方向上像素级贴合弓口，可将发射点拆成两层：

- `physics_muzzle_local`：继续由 UnitDef 驱动，参与同步弹道和 Gameplay；
- `visual_muzzle_socket`：按 Sprite 方向配置，只修正箭矢出现的位置，不改变同步状态。

碰撞体、`aimPos`、武器射程和 Projectile 命中不得依赖本地摄像机或当前选择的
Sprite 方向。当前弓手仍只有一个 Weapon；数据格式保留 weapon index，但本阶段
不扩展多武器 AOE Unit 的 Gameplay 语义。

## 数据文件

不把 16 组二维坐标塞进 UnitDef 的 `customParams`。在 Unit 缓存目录中增加可选的
`visual_anchors.json`，与生成的 `manifest.json` 分离，避免重新导出 Sprite 时覆盖
人工校准结果：

```text
cont/aoe2de_cache/units/u_arc_archer/visual_anchors.json
```

建议 schema：

```json
{
  "schema_version": 1,
  "unit": "u_arc_archer",
  "coordinate_space": "frame_pixels_from_foot",
  "weapons": {
    "1": {
      "attackA": {
        "release_frame": 15,
        "muzzle": {
          "direction_count": 16,
          "offsets": [
            [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0],
            [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0],
            [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0],
            [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0]
          ]
        }
      }
    }
  }
}
```

`offsets[direction]` 与动画 JSON 的方向顺序完全一致。每个值为
`[right_pixels, up_pixels]`：原点是该帧 `foot`，向右和向画面上方为正。使用脚点
相对坐标而不是裁剪帧绝对坐标，可避免帧矩形尺寸或 atlas 排布变化导致数据失效。

首个版本只保存 AttackA 放箭帧上的 16 个 muzzle。未来若近战接触点或复杂攻击需要
逐帧数据，schema 2 可把单个 `release_frame + offsets` 扩展为稀疏的
`direction/frame/socket` 样本；运行时接口不需要改变。

## 坐标解析

渲染器已经使用相同的 billboard 基向量绘制 Sprite：

```text
axisX = camera.right * instanceScale * pixelsToWorld
axisY = camera.up    * instanceScale * pixelsToWorld
```

方向 socket 的世界位置为：

```text
visualMuzzle = spriteOrigin
             + axisX * rightPixels
             + axisY * upPixels
```

`spriteOrigin` 必须与主体 Sprite 使用同一个 `mainCameraBias` 后的位置，不能从 Unit
原始 `pos` 单独计算。这样偏移、缩放和未来的深度处理都与主体一致。

方向索引必须复用 Unit Renderer 最终选择的帧方向。正式校准前应先修正
`DirectionForHeading()`：使用摄像机投影到 XZ 平面的水平 right/forward 计算相对
yaw，不能让摄像机俯角参与方向量化。否则同一套方向 socket 会被错误帧索引。

## 运行时实现

### 1. 资源加载

在 `Aoe2UnitRenderer` 的 `Appearance` 中增加只读视觉锚点表：

- Preload Unit appearance 时可选加载相邻的 `visual_anchors.json`；
- 严格校验 schema、Unit ID、weapon index、动画名、方向数量、有限数值和
  `release_frame` 范围；
- 文件不存在时保持现有渲染；字段无效时输出一次 warning 并禁用该 track；
- 每个 Unit 类型只解析一次，实例共享数据，不产生逐 Unit 内存分配。

### 2. Socket 查询接口

为 renderer 增加只读接口，输入 instance handle、weapon index、动画槽和方向，输出
世界 socket：

```text
ResolveVisualSocket(instance, weaponIndex, AttackA, Muzzle, outWorldPosition)
```

查询使用实例当前的 appearance、scale、方向和 Sprite origin，复杂度为 O(1)。方向
计算只执行一次，并同时供帧选择和 socket 查询使用，避免两套取整规则。

### 3. Unit 与 Projectile Bridge 衔接

`Aoe2UnitGameplayRenderBridge` 已保存 `unitID -> renderer instance`，增加一个只读查询，
让 Projectile Bridge 能按 owner Unit 和 weapon index 取得放箭 socket。Projectile
创建事件中：

1. 从 `CWeaponProjectile::owner()` 获取发射 Unit；
2. 通过 Projectile 的 weapon index 找到 Unit renderer instance；
3. 查询创建瞬间的视觉 muzzle；
4. 保存 `visualMuzzle - projectile.drawPos` 为该 Projectile 的初始渲染偏移；
5. 不修改 `CProjectile::pos`、`drawPos`、速度、`startPos` 或目标点。

当前 `CWeaponProjectile` 没有公开 weapon index getter，实现时应增加只读
`GetWeaponNum()`，不得直接扩大字段可见性。

### 4. 接入原生弹道

箭矢实例创建时从 visual muzzle 出现，然后在一个很短的可配置时间内平滑汇入原生
Projectile 路径：

```text
renderPos = projectile.drawPos
          + initialVisualOffset * (1 - smoothstep(0, blendTime, age))
```

建议默认 `blendTime=0.08s`，并限制最大偏移，防止错误配置产生大幅跳跃。物理 muzzle
应先校准到视觉位置附近，使这一修正仅处理方向 Sprite 的少量残差。Owner 已销毁、
没有 socket 或方向数据无效时，直接使用原生 `projectile.drawPos`。

## 校准工具扩展

校准场景增加 `AttackA release frame` 模式：

- 16 个 Unit 固定显示各自方向的 AttackA 第 15 帧；
- 当前方向显示可调的青色 visual muzzle；
- 左右键调整 X，上下键调整 Y，Shift 使用大步长；
- 同时保留黄色物理 muzzle，直观看到物理值和视觉残差；
- 导出完整 `visual_anchors.json`，不自动覆盖 UnitDef 或 manifest；
- 缺少任一方向时拒绝标记为完整配置。

校准必须在修正方向选择后进行。标准摄像机用于制作数据，但运行时 socket 始终按
当前 billboard 基向量解析，因此旋转摄像机不会改变同步 Gameplay。

## 性能与验收

- 16 个 `float2` 每个 weapon/animation 仅 128 字节，按 Unit 类型共享；
- Unit 帧选择和 socket 查询均为 O(1)，不扫描像素、不遍历成员；
- ProjectileSlot 只增加初始偏移和创建时间，不进行逐帧分配；
- 无配置时保持当前路径和性能；
- 关闭 AOE renderer 后不影响原生 Unit、Weapon 和 Projectile。

验收至少覆盖：16 个方向、摄像机旋转、不同缩放、AttackA 放箭帧、Projectile 起飞
连续性、Owner 在射出后死亡，以及 10,000 Unit 场景下未攻击单位的零额外热路径。
