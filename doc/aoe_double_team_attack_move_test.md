# AOE 双队 Attack Move 测试场景

此场景验证 Recoil 原生 Gameplay 与 AOE Sprite 渲染的完整交战路径：两支敌对队伍生成、原生
编队 `CMD.FIGHT`、索敌、`AttackA`、箭矢 Projectile、死亡后 `CUnit` 到 `CFeature` 的
渲染实例移交，以及 `DeathA` 和程序化淡出。它不是 AOE Gameplay 的替代实现；移动、选敌、
攻击和伤害均由 Recoil 原生系统处理。

## 前置条件

1. 已按 [`windows-engine-build.md`](windows-engine-build.md) 构建可启动的 Windows 引擎，
   并确保 `spring-dev.exe` 旁存在匹配的运行时 DLL。
2. 源码中的 `cont/aoe2de_cache` 已包含场景引用的 AOE 导出缓存（弓手、骆驼、箭矢、箭塔
   及其 manifest/图集）。这是 AOE Renderer 的输入，不由测试 Lua 动态生成。
3. 从仓库复制 `build-test-runtime` 到任意可写的测试目录，例如：

   ```powershell
   Copy-Item -Recurse .\build-test-runtime D:\runtime\aoe-double-team-test
   ```

   `build-test-runtime` 是可提交的测试场景模板，**不是**只能在本机使用的目录名。第一次
   运行会在实际 `--write-dir` 生成 `cache`、`demos`、`infolog.txt`、字体缓存和 UI 偏好；
   这些运行产生物不应提交。
4. 默认启用 AOE2DE 地表时，额外在测试目录复制本机 AoE2DE 安装中的 `g_des.dds` 到：

   ```text
   <write-dir>\games\AoeRenderTest.sdd\bitmaps\aoe2de_g_des.dds
   ```

   该文件来自原版游戏，不能随本仓库重新分发。如果未取得它，将 `_script.txt` 中的
   `aoe_test_terrain` 设为 `0`；其余双队交战功能不受影响。

## 启动

编辑复制后目录的 `_script.txt`，然后从仓库根目录执行。以下示例使用本机 MinGW 构建输出：

```powershell
.\build-official-release\extract\spring-dev.exe `
  --write-dir "D:\runtime\aoe-double-team-test" `
  "D:\runtime\aoe-double-team-test\_script.txt"
```

如果使用 Docker 的官方构建，将 EXE 路径替换为
`build-amd64-windows\install\spring.exe`；如果使用其它运行目录，也只需要替换第一行的
EXE 路径。`--write-dir` 与 `_script.txt` 必须指向同一份测试目录，后者中的相对游戏内容才
会被正确发现。

默认脚本为 100 vs 100：每队 25% 骆驼骑兵在面敌前排、75% 弓手在后排，并在队伍后方各放
一座箭塔。第 150 帧后，测试 Lua 分别使用
`Spring.GiveOrderToUnitArrayGroup(..., CMD.FIGHT, ...)` 向对方阵列中心下达原生 group-locked
Attack Move；不是对每个单位重复下相同目标点。两队不同 AllyTeam，红方可反击。

## `_script.txt` 可调参数

所有项目写在 `[modoptions]` 段，布尔值使用 `0/1`。Lua 会对数值进行边界限制；不要将
队伍数与地图大小、单位间距组合成无法容纳的布局。

| 参数 | 默认示例值 | 作用 |
| --- | ---: | --- |
| `aoe_team_a_count` | `100` | 蓝方总 Unit 数；范围 1–10000。 |
| `aoe_team_b_count` | `100` | 红方总 Unit 数；范围 1–10000。两侧可不同。 |
| `aoe_team_spacing` | `42` | 阵列相邻单位的世界间距；范围 8–256。 |
| `aoe_team_separation` | `1400` | 两阵列中心的初始间距；范围 64–8192。 |
| `aoe_camel_scout_fraction` | `0.25` | 每队由骆驼骑兵占用的比例；范围 0–1。骆驼始终排在敌方一侧的前排。 |
| `aoe_team_towers` | `1` | 每队后方生成一座原生 AOE 箭塔；塔不加入移动编队。 |
| `aoe_attack_move_start_frame` | `150` | 下发双方 `CMD.FIGHT` 的帧号；范围 1–36000。30 帧约为 1 秒。 |
| `aoe_team_b_counter_attack` | `1` | `1` 时红方也对蓝方中心下达独立的 group-locked `CMD.FIGHT`；`0` 时仅蓝方主动。 |
| `aoe_attack_cannot_move` | `1` | 仅给测试弓手启用严格的攻击静止机制：windup/recovery 期间不允许移动或被普通单位推动。设为 `0` 用于 Recoil 默认移动开火行为对照。 |
| `aoe_global_los` | `1` | 给本地测试玩家的 AllyTeam 全图 LOS，便于观察远处敌军；不改变双方敌对关系或武器规则。 |
| `aoe_fixed_test_camera` | `1` | 使用共享的固定俯视测试相机。 |
| `aoe_orthographic_test_camera` | `1` | 在固定相机启用时使用真正的正交投影，降低远距离 Sprite 深度精度问题。设为 `0` 回到 5° 透视长焦对照。 |
| `aoe_test_terrain` | `1` | 用 `bitmaps/aoe2de_g_des.dds` 替换 Blank Map 的地表纹理，并把测试地面 ambient/diffuse 调到 0.75。需要本机复制该原版资源。 |
| `aoe_position_diagnostics` | `true` | 输出 attackCannotMove 单位短距离反向或碰撞锁定的有限诊断日志；大规模性能测量可设为 `false`。 |
| `aoe_position_diagnostic_samples` | `64` | 每队诊断抽样上限；范围 1–128。 |
| `aoe_explicit_move_regression` | `false` | 开启专项回归：在抽样弓手 Windup/Recovery 发原生 `CMD.MOVE`，验证显式移动可以取消攻击状态。正常双队观察应保持 `false`。 |
| `aoe_armor_upgrade_test` | `false` | 队伍生成后应用 `aoe_upgrades.lua` 中配置的攻击/护甲升级，用于护甲机制回归。 |
| `aoe_castle_rapid_fire_upgrade_test` | `false` | 第 60 帧为两队应用 `castle_rapid_fire`；城堡箭矢连射由 5 发提升至 10 发。 |

`_script.txt` 还包含 Blank Map 的 `[mapoptions]`：`blank_map_x`、`blank_map_y` 控制地图
尺寸，`blank_map_height` 控制平坦地面高度，`blank_map_color_r/g/b` 是未启用测试地表时的
基础颜色。提高队伍数或间距时应同步提高地图尺寸，保证阵列及目标点都在地图范围内。

## 预期日志和观察点

`<write-dir>\infolog.txt` 中应出现：

- `[AOE Test Terrain] applied ...`：地表 DDS 已加载并覆盖所有 SMF ground square；若缺失，
  检查文件路径或关闭 `aoe_test_terrain`。
- `Team A created=...`、`Team B created=...`：创建总数以及骆驼/弓手拆分；100 和 25% 时应为
  `camel=25`、`archer=75`。
- `issued native group-locked CMD.FIGHT ... frame 150`：双方编队命令已接受。
- 持续的存活 Unit / 尸体 Feature 状态日志：用于观察攻击、死亡和 `CFeature` 接管。

画面上先确认两队和两塔在开局均可见，再观察前排骆驼接敌、弓手停稳后拉弓、箭矢命中、
尸体 Sprite 的死亡/淡出。若场景行为被锚点、建筑或近战校准脚本替代，检查 `_script.txt`
是否意外启用了 `aoe_anchor_calibration`、`aoe_building_test`、`aoe_melee_calibration` 或
`aoe_melee_battle`；双队测试应保持这些专用模式关闭。

## 大规模验证建议

先用默认 100 vs 100 确认功能，再逐步提高 `aoe_team_a_count` 和 `aoe_team_b_count` 至 1,000
或 10,000。每次提高数量时，同时审视地图尺寸、单位间距和初始间距，并关闭
`aoe_position_diagnostics`，避免诊断 I/O 干扰 CPU 帧时间。测试完成后仅保留场景配置、Lua
和日志结论；删除或忽略运行自动产生的缓存和用户 UI 文件。
