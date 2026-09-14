# AOE Projectile Explosion Effect 通用接入方案

> 实施状态（2026-09-14）：通用 exporter、`TimeOnce` renderer、Explosion 事件桥、
> `smoke_hit` 资源与手推炮配置均已完成。导出器回归测试、Windows 完整构建及手推炮
> 校准场景运行验证通过；运行中效果实例可按 1.5 秒生命周期归零，未出现丢弃或泄漏。

## 1. 结论与当前样本

手推炮 Projectile DAT Unit `368` 的飞行 Graphic 是 `3382`（`p_ball_x1`），命中后使用
`dying_graphic = 1744`。Graphic `1744` 不引用 SLD：

- `name = "Impact Building"`
- `file_name = "None"`
- `particle_effect_name = "smoke_hit"`
- `sound_id = 677`

`smoke_hit` 是 AoE2DE 独立粒子资源，不属于 SLD：

- 配置：`resources/_common/particles/smoke_hit.json`
- 图片：`resources/_common/particles/textures/smoke/smoke_hit/smoke_hit_01.png` 到
  `smoke_hit_40.png`
- 播放语义：`Type=Once`、`Duration=1.5` 秒、`Scale=0.5`、`Alpha=0.75`
- 每帧为固定 `300 x 300 RGBA8` 画布，共 40 帧

因此现有 `--graphics` SLD 导出路径不能直接导出它。当前 AOE Renderer 也只有 Unit、
Building 和“飞行中的 Projectile”实例，没有命中事件驱动的一次性 Effect 生命周期。
不能只在 WeaponDef 中填写一个资源 ID 完成正确接入。

## 2. 边界原则

- Recoil Projectile/Weapon 继续负责命中时机、命中位置、范围伤害和同步状态。
- AOE Effect 只消费只读的命中事件快照，不参与伤害、碰撞或 Projectile 生命周期。
- Effect 使用独立、非循环的资源语义，不把它伪装成飞行 Projectile 或 Unit Idle。
- 不保留原生 CEG 作为资源缺失时的回退；AOE Effect 创建失败时不显示，并记录错误日志。

## 3. gld exporter 扩展

### 3.1 新命令

增加显式模式：

```powershell
python tools/aoe2de_export/aoe2de_export.py `
  --aoe2 "D:\program1\steam\steamapps\common\AoE2DE" `
  --out "E:\code\gld\res\aoe2de_cache" `
  --particle-effect smoke_hit
```

第一阶段只支持经过验证的 `AtlasImagesRaw`：

```json
{
  "Format": "textures\\smoke\\smoke_hit\\smoke_hit_%02d.png",
  "First": 1,
  "Last": 40
}
```

遇到 `AtlasFile`、组合发射器或未知字段时应在清理旧输出前失败，不猜测语义。

### 3.2 输出格式

输出到 `effects/<effect-id>/`，使用独立 schema：

```text
effects/smoke_hit/
  manifest.json
  graphics/smoke_hit.json
  graphics/smoke_hit.png
```

Manifest 至少记录：

- `kind = "aoe2de_effect"` 和独立 schema version；
- 原始粒子 JSON 相对路径；
- `playback = "once"`；
- `duration_seconds = 1.5`；
- `fps = frame_count / duration_seconds`；
- `scale`、`alpha`、`stop_mode`；
- 原始首尾帧、输出帧数和缺失帧诊断。

Atlas 可裁掉透明边界，但每帧必须根据原始 `300 x 300` 画布中心记录一致的 effect anchor；
禁止让逐帧裁切改变爆炸中心。透明首尾帧必须保留，以复刻原始播放时间。

### 3.3 校验和测试

- 路径必须解析在 AoE2DE `resources/_common/particles` 或其 textures 子目录内，拒绝路径逃逸。
- 所有帧必须为 RGBA 且画布尺寸一致。
- `Duration`、`Scale`、`Alpha` 必须有限且在合法范围。
- 测试缺帧、空序列、格式占位符错误、尺寸不一致和未知播放类型。
- 原有 Unit/Building/Projectile 导出测试必须保持不变。

## 4. Recoil AOE Effect 渲染

### 4.1 资源 API

在现有 `CAoe2UnitRenderer` 批处理基础上增加清晰的 Effect 边界：

- `PreloadEffectAppearance(effectId)`：读取 `effects/<id>/manifest.json`；
- 一次性采样模式 `TimeOnce`，采样到最后一帧后不回绕；
- Effect appearance 不创建 player-color 和 shadow texture；
- Effect instance 默认关闭稳定脚点深度桶，并使用摄像机朝向 Billboard；画布中心锚点以下的
  像素仍使用通用的摄像机侧地形深度修正，避免地面命中特效被地形裁切；
- 主体深度测试开启、深度写入关闭，避免烟雾遮挡后续透明效果或写坏地形深度。

不要把 Effect 填入 `IdleA` 再依靠外部恰好及时删除来规避循环。资源类型、采样模式和生命周期
都应显式表达。

### 4.2 命中事件桥接

扩展 `Aoe2ProjectileGameplayRenderBridge`（或拆出很薄的
`Aoe2ProjectileEffectRenderBridge`）：

1. WeaponDef 通过 customParams 配置：

   ```lua
   aoe2_projectile_impact_effect_id = "smoke_hit",
   aoe2_projectile_impact_effect_scale = "1.0",
   aoe2_projectile_impact_effect_height_offset = "0.0",
   ```

2. 订阅原生 `Explosion` 事件，只复制 `weaponDefID`、世界命中位置、方向、产生帧和可见性；
   不保存 `CExplosionParams`、Projectile 或目标对象指针。
3. 回调始终返回 `false`，不能吞掉 Recoil 原生 Explosion 事件。
4. Render Update 消费队列并创建 transient instance。
5. `animationTime >= durationSeconds` 时回收实例。
6. 使用 Recoil 原生爆炸 LOS 判定；测试场景的 global LOS 会自然显示全部效果，普通游戏不能泄露
   战争迷雾后的命中位置。

命中位置以 `CExplosionParams.pos` 为权威。只允许通过集中配置增加高度偏移，不能在 Shader 中写
Projectile 类型相关魔法常量。

### 4.3 生命周期和性能

- 预加载后热路径不做文件 IO、JSON 解析或资源名查找。
- 事件队列、active list 和 free list 预留固定容量；单次创建/销毁为 O(1)。
- 每帧 transient 更新为 O(M)，其中 M 是当前仍在播放的效果数量。
- 同一 effect atlas 合批，理想 Draw Call 为每个可见 effect resource 每层一次，而非每次命中一次。
- 提供 `Aoe2ProjectileEffectMaxInstances` 上限；超限时丢弃新的纯视觉实例并累计诊断，不影响同步
  Gameplay。
- 诊断至少包含 spawned、live、visible、dropped、batches 和 drawCalls。

## 5. 手推炮接入

完成通用路径后：

1. 用扩展后的 exporter 导出 `smoke_hit`。
2. 将 `effects/smoke_hit` 同步到 Recoil `cont/aoe2de_cache/effects/`。
3. 给 `aoe_bombard_cannon_shot` 增加 effect customParams。
4. 将 `AOE_BOMBARD_IMPACT` 设为空的 custom CEG，阻止 Recoil 回退到标准爆炸表现；命中声音
   仍由 WeaponDef 独立播放。资源加载或实例创建失败时只记录诊断，不生成另一套视觉效果。
5. `cegTag` 飞行尾烟和 muzzle CEG 与 impact effect 分开配置，互不影响。

## 6. 验证顺序

1. exporter 单元测试和一次真实 `smoke_hit` 导出。
2. 独立 Effect 预览：单个、连续和批量生成，确认 40 帧只播放一次且中心不跳动。
3. Bombard 校准场景：分别命中地面、Unit 和 Building，确认命中位置一致。
4. 双队 16v16：确认爆炸触发、LOS、资源回收和原生伤害不变。
5. 双队 100v100：记录 CPU/GPU 时间、Draw Call、峰值 live effects 和 dropped 数量。
6. 关闭 AOE Projectile Bridge：Gameplay 伤害与命中声音不变，但按边界原则不再显示 impact CEG。

## 8. 实际验证结果

- exporter：`python -m unittest tools.aoe2de_export.tests.test_aoe2de_export` 全部通过；
- 真实资源：成功导出 40 帧、300 × 300 RGBA、1.5 秒的 `smoke_hit`；
- 引擎：Windows 无缓存完整构建成功；
- 运行：手推炮校准场景连续多轮命中均生成 Effect，峰值实例能够在播放结束后回到 0，
  `droppedEffects=0`；
- 性能：事件/free/active 容器和 renderer handle storage 预留容量，创建/销毁为 O(1)，
  活跃效果更新为 O(M)；同一 effect 共享 atlas 并合批；
- 显存：`smoke_hit` atlas 为 2100 × 1800 RGBA8，约 14.4 MiB，所有实例共享一份纹理。

## 7. 不推荐的捷径

Recoil CEG 支持 flipbook `animParams`，理论上可以把 40 帧打成网格后交给
`CSimpleParticleSystem`。但自定义纹理必须进入 ProjectileDrawer 的全局
`gamedata/resources.lua` 纹理表；测试 Mod 覆盖该文件容易丢失 springcontent 默认纹理，并把大型
AOE atlas 混入全局粒子 atlas。该方案可用于一次性原型，不应作为正式 AOE 缓存接入边界。
