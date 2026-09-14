# AOE2DE 资源 Roster

本清单对应当前 `cont/aoe2de_cache` 中已导出的资源。`unitId` 为资源目录名，`DAT-ID` 为 AoE2DE `empires2_x2_p1.dat` 中的 Unit ID；Projectile 栏同时列出 DAT 投射物 ID 和实际使用的资源目录。

## Units

| unitId | DAT-ID | 惯用中文名 | Projectile（主；次） |
|---|---:|---|---|
| `u_arc_archer` | 4 | 弓兵 | `363 / p_arrow`；`1930 / p_arrow` |
| `u_arc_chukonu` | 73 | 诸葛连弩 | `510 / p_arrow`；`510 / p_arrow` |
| `u_arc_crossbowman` | 24 | 弩手 | `364 / p_arrow`；`1930 / p_arrow` |
| `u_arc_handcannoneer` | 5 | 火枪兵 | `380 / p_shot` |
| `u_cam_camel_heavy` | 330 | 骆驼重甲骑兵 | 无（近战） |
| `u_cam_camel_scout` | 1755 | 骆驼斥候 | 无（近战） |
| `u_cav_knight` | 38 | 重甲骑兵（骑士） | 无（近战） |
| `u_cav_light` | 546 | 轻甲骑兵 | 无（近战） |
| `u_inf_samurai` | 291 | 武士 | 无（近战） |
| `u_inf_spearman` | 93 | 长矛兵 | 无（近战） |
| `u_sie_bombard_cannon` | 36 | 手推炮 | `368 / p_ball` |
| `u_sie_mangonel` | 280 | 小型抛石机 | `656 / p_mangonel`；`369 / p_mangonel` |
| `u_sie_unpacked_trebuchet` | 42 | 投石机（未展开） | `371 / p_rock` |

## Buildings

建筑也使用 DAT Unit ID，并单独列在此处。

| unitId | DAT-ID | 惯用中文名 | Projectile（主；次） |
|---|---:|---|---|
| `b_afri_tower_age2` | 79 | 非洲箭塔 | `504 / p_arrow`；`505 / p_arrow` |
| `b_west_castle_age3` | 82 | 西方城堡 | `746 / p_arrow`；`746 / p_arrow` |

## Projectile 资源

| resourceId | 对应投射物 |
|---|---|
| `p_arrow` | 普通箭矢、弩箭、诸葛连弩箭、箭塔/城堡箭矢 |
| `p_shot` | 火枪弹 |
| `p_ball` | 手推炮炮弹 |
| `p_mangonel` | 小型抛石机石弹 |
| `p_rock` | 投石机石块 |

## 备注

- 已生成可由现有 Recoil 原生 Gameplay 完整承载的 Def：长矛兵、弩手、武士、轻甲骑兵、重甲骑兵、骆驼重甲骑兵、火枪兵。它们使用一个原生武器槽、AOE Render Bridge、CFeature 尸体宿主，以及 `SUPPORT_AOE_ARMOR` 的 DAT 攻击/护甲类别。
- 上述克制数据要求运行**从当前源码重新构建**且 `SUPPORT_AOE_ARMOR=ON` 的 Windows 引擎。当前已按此配置重建 `build-official-release/extract/spring-dev.exe`。加载期的 `aoeDamage.* unknown-tag` 是 Recoil 通用 Def-tag 元数据校验对手工解析扩展表的已知提示；实际 `WeaponDef`/`UnitDef` 构造仍会在 `SUPPORT_AOE_ARMOR` 路径读取该表，不能将该提示视为宏未开启。
- 弓兵改为官方射程标尺：`4 AoE range × 60 = 240 Recoil world units`，且以 `highTrajectory = 1` 走高抛物线；弩手为独立 `aoe_crossbow_bolt`，射程 `5 × 60 = 300`、2 秒装填并走低弹道；火枪兵使用独立 `aoe_handcannon_shot`、`p_shot` 与低弹道。
- 诸葛连弩已生成 Def：`aoe_chukonu` / `aoe_chukonu_arrow` 使用 `SUPPORT_AOE_ARMOR` 的 `aoeSalvoDamage` 每发次伤害覆盖表表达一轮 3 箭中首箭满伤、后两箭各 3 穿刺，需按上述要求重新构建引擎方可生效。已通过 `aoe-chukonu-test.txt` 验收；结果与遗留项见 `doc/todo/aoe-strict-gameplay-gaps.md`。
- AOE 攻击类别现按 DAT 的稀疏语义匹配：只有目标显式声明的护甲类别才参与计算。诸葛连弩打普通弓兵时不再错误叠加反长矛加成；精确类别可使用 `class_N` 键。详见 `doc/aoe2_armor.md` 与 `doc/todo/aoe-strict-gameplay-gaps.md`。
- 手推炮已生成 `aoe_bombard_cannon` / `aoe_bombard_cannon_shot`：引擎新增的 `WeaponDef.minRange` 覆盖索敌、CommandAI、开火和释放阶段，炮弹使用原生 Cannon 弹道与原生范围伤害。小型抛石机和投石机仍未生成 Def；它们另有辅助投射物语义，未展开投石机还缺少打包/展开状态机。
- 箭塔和城堡保留现有测试 Def，未作为严格 AoE 数值转换重写：它们同样有 AoE 最小射程，当前仅是可运行的近似实现。
- 弓兵、弩手、诸葛连弩以及两种建筑的 DAT 投射物最终都映射到已有的 `p_arrow`，没有重复导出。
- `p_shot` 源 SLD 只有 1 个方向。`p_ball` 的 DAT Graphic 语义是 1 个方向、30 个时间动画帧（`time_loop`），并不是 30 个方向；`p_mangonel`、`p_rock` 尚未用 Projectile DAT 元数据重新验证。
- 弩手和小型抛石机的 `decayA` 源资源存在缺失主图帧，manifest 已标记为不可用；当前 Recoil AOE 渲染路径只加载 Idle/Walk/Attack/Death，Decay 使用程序化处理，因此核心渲染不受影响。
- `u_sie_unpacked_trebuchet` 采用标准西方未展开投石机资源（DAT-ID 42），不是新式牵引投石机或移动投石机变体。
- 本文件记录资源映射及当前 Def 接入状态；不包含引擎逻辑修改。
