# AOE2 manifest 到 Recoil Def 的权威转换规范

## 文档地位

本文件是 `gld/res/aoe2de_cache/**/manifest.json` 转换为 RecoilEngine
`UnitDef`、`WeaponDef`、`FeatureDef` 和 AOE Bridge `customParams` 的唯一权威指导文档。

- 新增或修改转换规则时，必须先更新本文件。
- 其他文档可以讲解校准工具、渲染器或 Gameplay 实现，但不得定义另一套转换规则。
- 手工 Def 和未来自动转换工具必须生成相同语义的结果。
- `Defs.lua` 只允许使用本文件定义的可读护甲类别，不允许出现 `class_N`。
- 尚未被本文件覆盖的 DAT 字段不得猜测。转换器必须报告并停止生成相关配置。

当前转换仍以手工验证为主，尚未实现批量转换命令。建议未来工具放在
`tools/aoe2manifest_to_recoil.py`，只生成 Lua 片段和转换报告，不直接覆盖手工 Def。

## 输入、版本和来源优先级

支持的输入类型：

| manifest | 当前 schema | 用途 |
| --- | ---: | --- |
| `kind = aoe2de_unit` | 3 | Unit Sprite、动画和部分 DAT Gameplay 元数据 |
| `kind = aoe2de_building` | 4 | Building Sprite、状态、锚点和部分 DAT Gameplay 元数据 |
| `kind = aoe2de_graphics` | 2 | Projectile Sprite 和采样语义 |

每次转换必须在报告中记录 manifest schema、`dat.source`、`dat.civ_id`、
`dat.unit_id`、conversion profile 版本及人工 override 来源。来源优先级为：

1. 已审核的单位级人工 override；
2. 本文件定义且通过校准的转换规则；
3. manifest 中的 DAT 原值；
4. 明确写入报告的测试默认值。

低优先级数据不得静默覆盖高优先级数据。当前 manifest 尚未包含 HP、完整
Attack/Armor 数组、资源成本和全部移动参数；这些字段在 exporter 扩展前必须从
同一 DAT 版本手工补录并在 Def 注释中标明，不能从 Sprite 尺寸或单位名称推断。

## 命名和资源绑定

- Unit manifest `id` 写入 `customParams.aoe2_unit_id`。
- Building manifest `id` 写入 `customParams.aoe2_building_id`。
- Projectile graphics manifest `id` 写入
  `WeaponDef.customParams.aoe2_projectile_id`。
- DAT Unit ID 和 Graphic ID 分别写入
  `aoe2_projectile_source_unit_id`、`aoe2_projectile_source_graphic_id`，用于追溯，
  不参与运行时 Gameplay。
- Recoil Def 名称使用小写 snake_case；AOE 资源 ID 保持 exporter 输出，不得改写。

## 坐标系和长度换算

当前验证 profile 使用：

```text
AOE DAT x（横向） -> Recoil local right，  × 60 elmo
AOE DAT y（前向） -> Recoil local forward，× 60 elmo
AOE DAT z（高度） -> Recoil local up，     × 30 elmo
AOE 距离/速度     -> Recoil 水平单位，      × 60 elmo
时间              -> 秒，不缩放
动画时间          -> frame / 最终导出 fps
```

这是当前 Recoil AOE 测试内容的 profile，不代表 AOE 文件格式自身规定了 60/30。
若未来更换世界比例，必须建立新 profile 并整体迁移，禁止在单个 Def 中散落比例魔法数。

### 碰撞体和受击点

DAT `collision_size.x/y` 是地面半径，`collision_size.z` 是完整高度。默认 `CylY`：

```text
collisionVolumeScales.x = collision_size.x * 2 * 60
collisionVolumeScales.z = collision_size.y * 2 * 60
collisionVolumeScales.y = collision_size.z * 30
aoe2_aim_local.y         = collisionVolumeScales.y / 2
aoe2_collision_local.y   = collisionVolumeScales.y / 2
```

`aoe2_collision_local` 默认等于碰撞中心；大型 Sprite 可以通过校准独立覆盖。
AOE Bridge 会以 Sprite 脚点为局部原点，因此不得再用 placeholder 模型的 `midPos`
推导偏移，也不得生成 `collisionVolumeOffsets` 进行二次补偿。

建筑优先使用与占地匹配的原生碰撞体。菱形底座需要 `AoeBox` 时，
`aoe2_collision_yaw_degrees` 必须来自预览工具校准；不得仅凭 Sprite 看起来是等距视角
就固定写成 45 度。`footprintX/Z`、`yardMap` 与碰撞体分别控制占地和物理碰撞，不能互相替代。

### 发射点

仅当 `dat.combat.projectile_unit_id >= 0` 时生成远程 muzzle：

```text
rawMuzzle.right   = weapon_offset.x * 60
rawMuzzle.up      = weapon_offset.z * 30
rawMuzzle.forward = weapon_offset.y * 60
finalMuzzle       = rawMuzzle + reviewed muzzle_correction_local
```

输出为：

```lua
customParams = {
    aoe2_aim_local = "0 30 0",
    aoe2_collision_local = "0 30 0",
    aoe2_weapon1_muzzle_local = "0 55.5 30",
    aoe2_weapon1_forward_local = "0 0 1",
}
```

`forward_local` 描述 Unit 局部前方，不是最终弹道方向。实际弹道继续由 Recoil 使用
目标 aim position 求解。人工修正必须在转换报告中同时保留 DAT 原值、raw、correction
和 final。例如弓手 raw 为 `(0,45,30)`，当前人工修正为 `(0,10.5,0)`，最终为
`(0,55.5,30)`；该修正不能升级成全局高度比例。

## 动画和生命周期

### Unit

| manifest 动画 | Recoil/AOE Bridge |
| --- | --- |
| `idleA` | Idle |
| `walkA` | Move |
| `attackA` | Attack |
| `deathA` | Death |
| `decayA` | 不加载；保持 Death 最后一帧并程序化渐隐 |

- `frame_delay / attackA.fps` 是 `WeaponDef.windup` 的候选值。
- `attackA.frames_per_direction / fps - windup` 是
  `attackRecoveryTime` 的候选值。
- DAT timing 与视觉接触帧冲突时，以校准后的人工 override 为准，并在 Def 注释中记录原因。
- `attackCannotMove` 只用于要求严格停步攻击的 AOE Unit；它不是从 manifest 自动推导的属性。

### Building

| manifest state | Recoil/AOE Bridge |
| --- | --- |
| `built` | 存活状态 |
| `attack` | 可用时作为攻击状态；缺失时不得伪造 |
| `destruction` | Death |
| `rubble` | CFeature 尸体/废墟宿主 |
| `construction/open/closed` | 仅在导出且 Gameplay 确实需要时接入 |

Unit 死亡后由专用 `FeatureDef` 承接 AOE renderer instance。AOE 尸体默认：

```lua
blocking = false,
noselect = true,
resurrectable = 0,
```

### Projectile graphics

- `sampling_mode = pitch_pose`：根据原生 Projectile 速度的俯仰选择姿态帧。
- `sampling_mode = time_loop`：按时间循环播放，例如 `p_ball` 的 1×30 帧动画。
- `sampling_mode = timeline`：普通时间轴动画。
- Projectile 每帧 `foot` 仅用于渲染对齐，不写入 WeaponDef，也不改变原生碰撞原点。

## Gameplay 字段转换

在当前 60 elmo profile 下：

| manifest/DAT | Recoil Def | 规则 |
| --- | --- | --- |
| Hit Points | `UnitDef.maxDamage` | 数值直接使用；当前 manifest 缺失时手工从同版 DAT 补录 |
| Speed | `UnitDef.speed` | `speed * 60` |
| Line of Sight | `sightDistance` | `line_of_sight * 60` |
| `combat.min_range` | `WeaponDef.minRange` | `min_range * 60` |
| `combat.max_range` | `WeaponDef.range` | `max_range * 60` |
| `combat.reload_time` | `reloadtime` | 秒，直接使用 |
| `combat.frame_delay` | `windup` | `frame_delay / attackA.fps` 候选值 |
| `combat.blast_width` | `areaOfEffect` | 当前按直径 `blast_width * 2 * 60` 近似 |
| projectile speed | `weaponVelocity` | `speed * 60` 起始值，必须进行弹道校准 |
| `projectile_arc` | `myGravity` | 不是无损一一映射；必须按 Projectile 类型校准 |
| projectile count | `burst`/原生多弹道 | 仅静态连发可直接映射；驻军等动态数量需 Gameplay 支持 |

以下字段不能机械直译：

- `accuracy_percent`、`accuracy_dispersion` 与 Recoil 的 `accuracy` 单位不同；未校准前不得直接赋值。
- `blast_attack_level`、`blast_defense_level`、`blast_damage` 和
  `friendly_fire_damage` 暂时只能用 Recoil 原生范围伤害近似。
- `projectile_arc` 不能通过 `highTrajectory` 模拟；应使用合适的原生 Projectile 类型、
  `weaponVelocity` 和重力校准。
- `projectile_min_count/max_count` 可能依赖驻军或额外 Gameplay，不能一律当作固定 `burst`。

## AOE 护甲与伤害类别

### Def 书写规则

`UnitDef.aoeArmor` 和 `WeaponDef.aoeDamage` 必须使用下表中的可读名称。`class_N`
只允许出现在 manifest、DAT 调试输出和转换报告中，禁止进入 `Defs.lua`。

类别名称使用小写 snake_case，且同一物理类别只能出现一次。比如 `pierce` 与
`class_3` 不能并存。当前 C++ 按字符串匹配，不会自动合并别名；重复写入会造成重复伤害。

### DAT Class ID 映射

| DAT ID | Def 可读名称 | 含义 |
| ---: | --- | --- |
| 1 | `infantry` | 步兵 |
| 2 | `turtle_ship` | 龟船 |
| 3 | `pierce` | 基础穿刺伤害/护甲 |
| 4 | `melee` | 基础近战伤害/护甲 |
| 5 | `elephant` | 战象类 |
| 8 | `cavalry` | 骑兵 |
| 11 | `building` | 建筑通用类别 |
| 13 | `stone_defense` | 石质防御建筑 |
| 14 | `predator` | 猛兽 |
| 15 | `archer` | 弓兵 |
| 16 | `ships` | 船只 |
| 17 | `ram` | 冲车 |
| 18 | `tree` | 树木 |
| 19 | `unique_unit` | 独特单位 |
| 20 | `siege` | 攻城武器 |
| 21 | `standard_building` | 标准建筑 |
| 22 | `wall_and_gate` | 城墙和城门 |
| 23 | `gunpowder` | 火药单位 |
| 24 | `boar` | 野猪 |
| 25 | `monk` | 僧侣 |
| 26 | `castle` | 城堡类建筑 |
| 27 | `spearman` | 长矛兵 |
| 28 | `cavalry_archer` | 骑射手 |
| 29 | `eagle_warrior` | 鹰勇士 |
| 30 | `camel` | 骆驼单位 |
| 31 | `anti_leitis` | Anti-Leitis/历史兼容类别 |
| 32 | `condottiero` | 意大利佣兵 |
| 33 | `projectile_gunpowder_secondary` | 火药 Projectile 次级类别 |
| 34 | `fishing_ship` | 渔船 |
| 35 | `mameluke` | 马穆鲁克 |
| 36 | `hero_and_king` | 英雄与国王 |
| 37 | `hussite_wagon` | 胡斯战车类 |
| 38 | `skirmisher` | 散兵相关类别 |
| 39 | `royal_heir` | Royal Heirs 骑乘伤害调整类别 |

未列出的 ID 视为未支持。转换器不得回退输出 `class_N`，必须停止对应 Def 的生成，
输出 DAT ID、涉及的 Unit/Weapon，并要求先审核后更新本表。这样保证 `Defs.lua`
始终可读，也避免给版本新增类别起错误名称。

### 伤害计算

只有目标显式声明的类别参与：

```text
max(1, sum(max(0, attack[class] - targetArmor[class])))
```

数值为 `0` 仍然有意义：它表示目标属于该类别但没有减伤。例如
`cavalry = 0` 会使反骑兵 bonus 生效；缺少 `cavalry` 则该 bonus 完全不参与。
负数类别及 AOE2 特殊扣减机制必须单独验证；当前 `max(0, ...)` 实现不能视为已经
完整覆盖所有 DAT 负数语义。

`damage.default` 仅作为 Recoil 原生兼容/回退值。开启 `SUPPORT_AOE_ARMOR` 且武器
声明 `aoeDamage` 时，引擎进入 AOE 类别计算；目标没有任何匹配类别时结果为最低 1 点。

## 配置模板

```lua
UnitDefs.aoe_example = {
    maxDamage = 100,
    speed = 90,
    collisionVolumeType = "CylY",
    collisionVolumeScales = "24 60 24",
    aoeArmor = {
        melee = 0,
        pierce = 0,
        archer = 0,
        anti_leitis = 0,
    },
    customParams = {
        aoe2_unit_id = "u_example",
        aoe2_scale = "1.0",
        aoe2_ground_offset = "0.0",
        aoe2_player_color = "team",
        aoe2_hide_native_model = "true",
        aoe2_aim_local = "0 30 0",
        aoe2_collision_local = "0 30 0",
        aoe2_weapon1_muzzle_local = "0 45 30",
        aoe2_weapon1_forward_local = "0 0 1",
    },
}

WeaponDefs.aoe_example_weapon = {
    weaponType = "Cannon",
    range = 240,
    reloadtime = 2.0,
    windup = 0.5,
    damage = { default = 5 },
    aoeDamage = {
        pierce = 5,
        spearman = 3,
    },
    customParams = {
        aoe2_projectile_id = "p_arrow",
        aoe2_projectile_source_unit_id = "363",
    },
}
```

## 校验和拒绝条件

转换器和人工评审必须确认：

- manifest kind/schema、所有数值有限且维度合法；
- requested state 的 `status = exported`，缺失状态不会被伪造；
- main/shadow/player-color 的帧数、方向数、尺寸和 foot 一致；
- UnitDef/WeaponDef 中不存在 `class_N` 或同义类别重复；
- Projectile resource、DAT Unit ID 和 Graphic ID 可追溯；
- 0/90/180/270 度及至少四个中间方向的碰撞、aim、muzzle 正确；
- Attack 动画释放帧、原生伤害时刻和 Projectile 出现时刻一致；
- `minRange`、最大射程、弹道遮挡和释放前复验行为正确；
- Death 到 CFeature 的 instance 转移没有重叠、泄漏或复活入口；
- 至少执行一个小规模战斗场景和对应的校准场景。

以下情况必须拒绝自动生成，而不是使用默认值掩盖：

- 未知护甲 Class ID；
- 必需 DAT 字段缺失；
- `weapon_offset` 非有限值或坐标 profile 未声明；
- Projectile Graphic 的 DAT 帧数与 SLD 实际帧数不一致；
- 多武器 AOE Unit 没有明确的主武器/动画驱动规则；
- 需要逐方向或逐帧 socket，但 manifest 未提供人工 override。
