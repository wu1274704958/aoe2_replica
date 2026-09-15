# AOE Gameplay / Render 已知问题

本文记录 AOE Gameplay 与 Sprite 渲染接入 RecoilEngine 后已经复现、但尚未完成正式修复的问题。每项问题分别注明根因确认程度、临时规避方法和建议修复方向，避免后续仅通过调整表现参数掩盖 Gameplay 或渲染时序缺陷。

## 1. 慢速抛射武器在前摇结束后向不可达位置发射

### 状态

- 问题状态：已增加默认关闭的正式修复路径；诸葛连弩尚未切换该开关并完成回归。
- 根因状态：已确认。
- 典型资源：`aoe_chukonu` / `aoe_chukonu_arrow`。

### 表现

少量位于阵型前部的诸葛弩会比主力提前数秒开始攻击。部分箭矢在真正的敌方 Unit 之前很远的位置落地；将 UnitDef 武器槽的 `accurateLeading` 从 `0` 改为 `1` 或 `2` 后仍然可以复现。

### 已确认根因

这不是 AOE Projectile Renderer 的位置换算问题，也不是 `accurateLeading` 的迭代精度不足。Projectile Renderer 只显示原生 Projectile 的 `drawPos`；错误已经发生在原生 Gameplay 弹道的创建阶段。

触发时序如下：

1. `CWeapon::UpdateFire()` 在攻击前摇开始前，以目标当前速度推算提前瞄准点，并通过 `TryTarget()` 验证射程、弹道和射界。
2. 接近中的目标会让预测命中点提前进入物理射程，因此攻击者可以在目标本体仍较远时开始前摇。
3. `aoe_chukonu_arrow` 的第一支箭约在 AttackA 第 19 帧释放。前摇期间，目标可能因为接敌、攻击或碰撞避让而减速或停止；`currentTargetPos` 会随目标当前速度逐帧更新，并退回目标当前位置。
4. `CWeapon::UpdateSalvo()` 到达释放帧后不会再次调用 `TryTarget()`、`TestRange()` 或 `HaveFreeLineOfFire()`，而是直接调用 `Fire()`。
5. 当更新后的目标点已经超过低速 Cannon 的物理抛射范围时，`CCannon::CalcWantedDir()` 无法求得抛物线解，最终退化为近似水平发射。箭矢随后撞地，落在目标之前。
6. 默认 `burstControlWhenOutOfArc = 0` 时，即使第一箭后武器已经丢失目标，后续 burst 仍会向保存的旧 `currentTargetPos` 发射。此时 Projectile 的目标类型会从 Unit 退化为 Ground，进一步产生空射。

固定随机种子的诊断样本记录到：

- 发射点到目标 Unit 中心的水平距离约为 `213.27 elmo`；
- `weaponVelocity = 120` 在模拟中为 `4 elmo/frame`；
- 箭矢初始 Y 速度为 `0`，说明释放时已经不存在有效抛物线解；
- 箭矢只飞行 `108.89 elmo` 后落地，此时目标仍在约 `99 elmo` 之外；
- 同一 burst 第一箭仍引用 Unit，后两箭引用相同的 Ground 目标点。

相关源码：

- `rts/Sim/Weapons/Weapon.cpp`：`CWeapon::Update()`、`CWeapon::UpdateFire()`、`CWeapon::UpdateSalvo()`、`CWeapon::GetLeadVec()`；
- `rts/Sim/Weapons/Cannon.cpp`：`CCannon::FireImpl()`、`CCannon::CalcWantedDir()`；
- `rts/Sim/Units/UnitDef.cpp`：UnitDef 武器槽的 `accurateLeading` 解析；
- `rts/Sim/Weapons/WeaponDef.cpp`：WeaponDef 的 `leadLimit`、`leadBonus` 和 `predictBoost` 定义。

### 配置层临时规避

`accurateLeading` 不能关闭提前量：

- `accurateLeading = 0`：使用原生近似预测，仍然会提前瞄准；
- `accurateLeading = 1`：提高非重力弹道精度，并改善抛物线预测；
- `accurateLeading >= 2`：继续迭代抛物线命中时间。

如需完全关闭某个 WeaponDef 的目标提前量，可配置：

```lua
leadLimit = 0,
leadBonus = 0,
```

`leadLimit` 属于 WeaponDef，不是 UnitDef 的 `weapons` 槽位参数。`CWeapon::GetLeadVec()` 会将提前向量限制到 `leadLimit + leadBonus * experience`；两者均为零时，最终提前向量为零。

该配置可以阻止“接近中的目标预测位置先进入射程”这一触发路径，但有以下限制：

- 箭矢只瞄准目标当前点，移动目标的未命中率会提高；
- 目标仍可能在 19 帧前摇期间移出射程；
- 释放帧缺少二次验证的问题仍然存在，因此它不是完整修复。

提高 `weaponVelocity`、降低 `range` 或降低 Projectile 重力也能让配置射程落在物理射程内，但会改变已经校准的箭矢弧度和飞行时间，不应作为默认修复。

### 建议正式修复

增加一个默认关闭、由 WeaponDef 显式启用的“salvo 释放时重新验证目标”能力，并保持非 AOE 武器的原生行为不变：

1. 第一支 Projectile 释放前，基于最新 `currentTargetPos` 重新执行目标有效性、物理射程、射界和弹道遮挡检查。
2. 第一箭验证失败时取消本轮释放，解除 `attackCannotMove` 攻击锁并让 CommandAI 继续追击；需要明确是否退还 reload。
3. burst 后续箭逐支复查。目标丢失或当前弹道不可达时结束剩余连发，不再向旧 Ground 点发射；已经成功释放的第一箭不退还 reload。
4. 保持校验为每次释放 O(1)，不增加寻路、邻居扫描或单位间配对。
5. 回归覆盖目标在 Windup 中停止、转向、死亡、离开射程，以及第一箭后丢失目标的三连发场景。

仅设置 `burstControlWhenOutOfArc` 最多可以减少丢失目标后的后续空射，不能解决第一箭在过期弹道上释放的问题。

### 已实现的引擎能力

`WeaponDef.revalidateTargetOnSalvo` 已按上述约束实现，默认值为 `false`。手推炮
`aoe_bombard_cannon_shot` 已启用：每发释放前重新运行 `TryTarget()`；首发失败取消
Windup、退还已提交的 reload 并解除移动锁，后续 burst 失败只截断未释放部分。
该路径还需要在移动目标停止、目标离开射程、弹道被地形阻挡和目标死亡四类运行时
场景中继续回归。诸葛连弩在完成该回归前维持原配置，因此本节对它仍属于已知问题。

## 2. 相邻骑兵 Sprite 的头尾区域交替覆盖

### 状态

- 问题状态：渲染层稳定深度桶已显著缓解高频交替覆盖；仍有少量桶边界附近的重叠切换。
- 根因状态：Gameplay 触发源与渲染放大机制均已确认；Gameplay 行为未修改。
- 典型资源：两个前后相邻、朝向相近且屏幕轮廓重叠的骆驼骑兵或其他长轮廓单位。

### 表现

前方骑兵的尾部与后方骑兵的头部相交时，两者会在相邻帧间交替覆盖，产生高频闪烁。透视相机拉得越远，现象通常越明显。单纯添加固定摄像机方向偏移或按 Unit ID 添加微小深度偏移不能稳定解决。

### 已确认根因

该问题不是纯粹由 Renderer 随机产生的静态 z-fighting，也不是 AOE Gameplay Bridge 修改了 Unit 位置，而是以下两层因素叠加：

1. Gameplay 中相邻骑兵的真实位置会发生很小的前后换位。编队移动、局部路径方向和原生 Unit 碰撞响应使相邻成员即使速度模长相同，相对于摄像机方向的位置分量仍会在若干帧内反复越过彼此。
2. Renderer 以每个 Unit 的 `drawPos` 作为整张 Sprite 的深度，并使用普通深度测试和深度写入。两个长轮廓 Sprite 的脚点深度顺序一旦越过零点，整个重叠区域的覆盖关系就会立即交换。5° 长焦透视下，远处亚 elmo 到数 elmo 的相机空间差值又会被压缩到深度缓冲的零个或一个最小步长，使切换更突兀。

AOE Sprite Quad 使用 `camera->GetRight()` 和 `camera->GetUp()` 构造。两个轴都与相机前向垂直，所以同一 Sprite 的所有顶点实际具有相同的相机空间深度。动画帧宽高变化不会让骑兵头部和尾部分别获得不同深度；此前“两个倾斜 Quad 在头尾区域逐像素相交”的推断不成立。

Gameplay Bridge 每帧直接将 `unit->drawPos` 传给 `CAoe2UnitRenderer::SetTransform()`，只增加固定 `groundOffset`。`drawPos` 由 Recoil 在上一同步位置和当前同步位置之间做线性插值，因此 Bridge 和 AOE Renderer 没有额外制造随机位置抖动；但线性插值会在两个同步位置的深度顺序发生交换时，连续穿过等深点。

2026-09-13 使用固定随机种子的 16 vs 16 `aoe_light_cavalry` 场景进行了临时运行时采样：

- 静止阶段存在屏幕距离约 `65 px`、相机深度完全相同的相邻对，但没有发生顺序翻转，排除了“静止等深本身会随机闪烁”的判断；
- 移动后的帧 `158`，代表性相邻对的插值 `drawPos` 深度从 `-0.000122` 变为 `+0.000610`，同步 Gameplay 深度已经变为 `+0.012939`，证明覆盖换向对应真实位置顺序越过；
- 统计到帧 `510` 时，候选重叠对累计发生 `348` 次同步 Gameplay 深度顺序翻转和 `330` 次 `drawPos` 深度顺序翻转，其中 `245` 次插值越过发生在同一模拟帧的不同渲染帧内；
- 代表性相邻对在帧 `300 / 330 / 360` 的同步相机深度差依次约为 `+0.245 / -0.428 / +0.495 elmo`，屏幕脚点间距约 `33–35 px`，属于真实但很小的前后往返；
- 相同样本的投影深度差经常为 `0` 或约 `5.96e-8`，对应 24-bit 深度缓冲的相邻量化级，解释了拉远视角后覆盖切换更明显的现象。

因此应将问题定性为：**Gameplay 的微小相机深度往返是覆盖顺序变化的触发源；AOE 整图深度裁决和远距离透视深度量化是肉眼高频闪烁的放大器。** 它不是单独修改 Gameplay 或单独提高深度缓冲位数就一定能彻底解决的经典 z-fighting。

当前 `CAoe2UnitRenderer::Draw()` 会为主体 Sprite 开启深度测试并写入深度。gld 的 AOE 批处理路径同样主要依赖渲染 Pass 的深度状态，目前没有可直接移植的成熟稳定排序方案。

曾验证过“按稳定 Unit/Feature ID 添加少量深度层级 + depth pre-pass”的实验，效果不理想，代码保存在 Git stash `WIP failed AOE sprite depth tie and prepass experiment` 中，未进入正式分支。该方案没有定义允许保持稳定顺序的空间容差区间，且只有四个循环层级，因此既不能吸收真实位置的反复越界，也可能让无关实例使用相同层级。

相关源码：

- `rts/Rendering/Aoe2/Aoe2UnitRenderer.cpp`：主体 Sprite 的 Billboard 顶点计算、深度测试和批次绘制；
- `rts/Rendering/Aoe2/Aoe2UnitGameplayRenderBridge.cpp`：Gameplay 实例到渲染实例的位置和可见性同步；
- gld `aoe2/src/Aoe2Batch.cpp`：原始 AOE 批处理和 Render Pass 深度状态。

### 当前缓解方法

- 测试场景使用真正的正交相机，可以消除远距离透视深度精度快速下降这一放大因素；
- 增加阵型间距、避免长轮廓单位完全前后贴合，可以降低重叠概率；
- `CAoe2UnitRenderer` 现在默认使用 `4 elmo` 的相机空间脚点深度桶；同一桶内按稳定的 renderer instance slot 生成次级深度，只有实例跨出桶边界后才改变主要覆盖层级；
- 桶内次级深度位于当前桶近侧边界朝摄像机方向的半个桶宽内，保证稳定脚点永远不会比真实脚点更远，同时在相邻桶之间保留半个桶宽的明确间隔；Projectile 显式绕过该规则，保持连续飞行深度；
- `Aoe2UnitDepthBucketSize` 可在运行时调整，建议先在 `2–4 elmo` 范围内验证，设置为 `0` 可关闭；
- 实现没有 CPU 全局排序或实例两两比较，批次结构与 Draw Call 数量不变，实例收集仍为 `O(N)`；每个顶点仅增加常数次量化与稳定哈希计算。

该方案不阻止 Gameplay 位置本身发生微小的前后换位，而是在渲染层过滤桶内换位。仍需专项验证桶边界、地形遮挡、建筑、尸体 Feature，以及正交/透视相机下的视觉结果；如果问题只迁移到桶边界，应再评估单实例滞回。

扩大骑兵 Gameplay 碰撞体可以通过增加成员间距降低 Sprite 重叠概率，但不是该问题的渲染层根治方案。当前骑兵使用 `CylY`，Recoil 的地面移动碰撞主要按 Unit 包围半径执行；增大水平尺寸会在所有方向扩大推挤距离，并可能改变阵型密度、窄路通行、拥堵、近战接敌距离和碰撞响应。因此不应只为消除残余闪烁而无限增大碰撞体。

### 暂缓的后续方案：单实例桶滞回

固定深度桶在边界上没有历史状态。Unit 的真实或插值脚点深度反复跨过同一边界时，仍可能在相邻桶之间切换，这与当前仅剩少量骑兵交替覆盖的表现一致。后续可在 Unsynced Renderer 内为每个实例保存上一深度桶，并增加约 `1 elmo` 的退出阈值：只有深度越过当前桶边界与滞回区之后才切换桶。

建议实现约束：

1. 状态只保存在 AOE Renderer instance 中，不写入 `CUnit`、`CFeature`、MoveType 或其他同步 Gameplay 状态。
2. 继续保持每实例独立计算，不进行实例两两比较或全局排序；时间复杂度仍为 `O(N)`。
3. 每实例预计增加 `4–8 bytes` 状态；一万实例约增加 `40–80 KB`，十万实例约增加 `0.4–0.8 MB`。
4. 每帧只增加一次相机深度点积和常数次边界比较，不增加 Draw Call；稳定桶深度可以复用 `WorldInstance::origin.w` 传入 Shader，避免扩展 GPU instance buffer。
5. 摄像机观察方向明显变化时重置桶状态，避免沿用基于旧相机方向计算的历史桶；单纯缩放或平移不应无条件清空。
6. Projectile 继续绕过深度桶和滞回；Unit 转移为尸体 Feature 时应保留同一 renderer instance 及其历史桶。
7. 建议默认组合为 `bucketSize = 4 elmo`、`hysteresis = 1 elmo`，并回归桶边界低速移动、正交/透视相机、斜坡、建筑与尸体 Feature。

该方案目前仅记录，暂不实施。现阶段保留无状态单向深度桶，先继续观察残余问题的频率和影响。

### 已实施方案与验证要求

不建议为了表现问题直接禁止 GroundMoveType 的碰撞位移；它会改变同步 Gameplay、拥堵和寻路行为，并且普通 3D Unit 也依赖这些响应。当前 AOE Renderer 的无状态稳定深度桶遵循以下约束，后续回归也应继续保持：

1. 继续使用摄像机空间脚点深度作为主要遮挡键，但将深度量化到一个可配置的小桶，例如先从 `2–4 elmo` 进行验证。
2. 仅在同一深度桶内使用稳定的次级顺序键；可以使用实例创建序或 Unit ID，但不能像失败实验一样在所有深度上循环施加少量固定偏移。
3. 深度差跨过桶边界后才允许覆盖顺序变化，从而过滤碰撞响应造成的亚 elmo 往返，同时保留单位真正前后穿行时的顺序变化。
4. 优先验证可在 Shader 或实例数据中完成的 O(N) 深度量化，保持现有按资源/动画的 Instanced Rendering，不引入成员两两比较。
5. 以“全局按脚点深度从后向前排序、对 AOE 主体关闭深度写入”作为正确性对照基线；该方案能确认二维 Sprite 的期望遮挡，但会破坏跨资源合批，不应直接作为万级单位的最终实现。
6. 专项验证正交/透视相机、斜坡、建筑、Projectile、尸体 Feature、地形遮挡，以及深度桶边界附近的低速移动。当前已确认固定分桶仍可能在边界留下少量切换；是否实施上节记录的单实例滞回，应根据后续观感和性能回归决定。

## 3. AOE2DE 原生 Wwise 音效尚不能按事件 ID 播放

### 状态

- 问题状态：已完成资源引用链调研，当前暂缓实施。
- 根因状态：已确认。
- 影响资源：当前所有需要复刻 AOE2DE 原生攻击、命中、移动和选择音效的 AOE Unit/Building；已接入的小型抛石机和手推炮仍使用测试占位音效。

### 表现

当前 WeaponDef 只能把 `soundStart`、`soundHitDry` 和 `soundHitWet` 配置为 Recoil
可直接加载的 WAV/OGG 文件或已注册声音项，不能像 AOE2DE 一样提交 Wwise Event ID，
因此无法直接复用 AOE2DE SoundBank 内的随机选择、防重复、分层混音、Switch/State 和
Bus 音量规则。

### 已确认根因

Recoil 当前声音实现使用 OpenAL，没有集成 Wwise Runtime，也没有 PCK/BNK Event Graph
解析器。AOE2DE 的 `wwise/Base.pck` 中保存的是 SoundBank 和 WEM；DAT/Graphic 记录的
32-bit Wwise Event ID 并不是可由 OpenAL 直接解码的音频文件 ID。

调研确认的代表性引用如下：

- 小型抛石机 DAT Unit 280 的 Attack Graphic 979 在所有 16 个方向的第 6 帧触发
  `PLAY_ATTACK_MANGONEL`（Event ID `1791648398`），事件从
  `Mangonel_Large_Attack_01..04` 四个音源中随机选择并避免连续重复。
- 手推炮 DAT Unit 36 的 Attack Graphic 654 在所有 16 个方向的第 7 帧触发
  `PLAY_ATTACK_BOMBARD_CANNON`（Event ID `1775735096`），事件从
  `Cannon_Small_Fire_01..08` 八个音源中随机选择。
- 手推炮命中使用 `PLAY_IMPACT_CANNONBALL_SPLASH`（Event ID `3865779263`）的四个
  随机音源。小型抛石机另有地面、石材、木材三类命中事件；其中地面事件还会同时
  播放一层随机攻城弹命中声和一层随机小型建筑爆炸声。

当前 `WeaponDef::LoadSound()` 对开火声只读取一个字符串；命中 `GuiSoundSet` 的两个
固定位置又分别代表 dry/wet，不能直接承载每种介质各自的随机池和分层事件。即使扩展
Lua 配置为数组，也只能解决一部分随机开火声，不能完整复刻 Wwise 事件语义。

### 当前决策与后续方向

现阶段不导出 AOE2DE 音频，也不把随机事件降级成单个代表样本；现有测试占位音效暂时
保留。后续若重新启动该任务，优先评估独立的 Wwise 音频后端：加载兼容版本的 Init/SFX
SoundBank，通过 Event ID 播放，并为 Gameplay 对象同步三维位置和必要的 Switch/State。
实施前必须先确认 Wwise SDK 授权、AOE2DE 本地资源使用边界、SoundBank 版本兼容和
AOE2DE 更新后的稳定性。

如果最终采用按 Event ID 播放，gld exporter 不应导出或解码音频；它只需要从
`Graphic.angle_sounds` 提取触发帧、legacy sound ID、Wwise Event ID 及方向一致性并
写入 manifest。Wwise Runtime 接入应位于 Recoil 声音系统或独立 AOE Audio Bridge，
不应放进 Sprite/Projectile Renderer。

相关源码：

- `rts/System/Sound/`：Recoil 当前 OpenAL 声音后端；
- `rts/Sim/Weapons/WeaponDef.cpp`：WeaponDef 声音字段加载；
- `rts/Sim/Weapons/Weapon.cpp`：开火时播放 `fireSound`；
- `rts/Game/GameHelper.cpp`：命中爆炸时播放 dry/wet `hitSound`；
- gld `tools/aoe2de_export/aoe2de_export.py`：当前 DAT/Graphic manifest 导出路径，尚未序列化 `angle_sounds`。
