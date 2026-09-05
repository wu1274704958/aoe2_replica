# AOE 远程单位锚点校准场景

这是一个仅用于本地开发的 `u_arc_archer` 远程单位校准场景。它复用 Recoil 原生
Unit、Weapon 和 CollisionVolume 数据，并将其以非同步调试叠加层显示；不包含战斗、
寻路或批量渲染压测。

## 启动

校准工具使用独立启动脚本，不修改常规双队 Gameplay 测试的 `_script.txt`：

```text
build-test-runtime/aoe-anchor-calibration-test.txt
```

需要调整网格间距时，编辑该文件中的
`aoe_anchor_calibration_spacing`；默认值为 260。

然后构建并运行：

```powershell
Set-Location D:\code\RecoilEngine
powershell -ExecutionPolicy Bypass -File .\tools\windows-engine-build.ps1 -Incremental -Jobs 12
Start-Process .\build-official-release\extract\spring-dev.exe -ArgumentList @(
  '--write-dir', "$PWD\build-test-runtime", "$PWD\build-test-runtime\aoe-anchor-calibration-test.txt"
) -WorkingDirectory $PWD
```

场景会生成 16 名静止弓手，按 4×4 网格排列，分别覆盖 16 个 Sprite 朝向，并为测试
玩家开启全图 LOS。固定长焦相机由
`LuaRules/aoe_fixed_test_camera.lua` 集中定义，并与开启
`aoe_fixed_test_camera` 的双队 Gameplay 测试共用。

## 图例

- 绿色十字：单位脚点 `pos`
- 紫色十字：`midPos`
- 红色十字：真实 `aimPos`
- 黄色十字和线：真实 `weaponMuzzlePos` 与 `weaponDir`
- 紫色线框：运行时最终 CollisionVolume
- 红、绿、蓝线：Unit 的 right、up、front 局部轴
- 青色：选中方向的本地参数预览；青色虚线是参考抛物线，不是 Recoil Cannon 的真实求解结果

快照来自同步 Gadget 的 `GetUnitPosition`、`GetUnitDirection`、
`GetUnitWeaponVectors` 和 `GetUnitCollisionVolumeData`，再通过
`SendToUnsynced` 传给 `DrawWorld`。因此紫色碰撞器与黄色发射点反映的是引擎实际
使用的数据，而非另一套 Lua 近似。

## 交互

| 按键 | 操作 |
| --- | --- |
| `Tab` | 切换预览 Unit/方向 |
| `Up` / `Down` | 选择参数 |
| `Left` / `Right` | 按步长调整 |
| `Shift` + `Left` / `Right` | 十倍步长 |
| `R` | 恢复 Def 默认预览 |
| `E` | 导出 Lua override，复制到系统剪贴板 |

`heading` 调整会通过同步 Gadget 修改当前测试 Unit 的真实方向。当引擎以
`AOE_DEV_TOOL=1` 构建时，`muzzle` 调整会通过测试专用 API 实时应用到 16 个 Unit 的
真实 Weapon muzzle；`R` 清除运行时 override 并恢复 UnitDef。`aim`、forward 和 Collision
仍只是青色本地预览，不会改变同步 Gameplay。确认后应导出、审阅并手工合入
对应 UnitDef，再重启场景验证。`sprite_pixels_to_world` 是 renderer-only 临时 Config
overlay，可即时作用于 AOE Sprite，不写入用户配置。

操作方式、颜色图例、快照状态和工具安全边界会始终显示在屏幕左上角。即使同步快照
尚未到达，面板也会显示 `waiting for synced data`，便于区分数据链未就绪和世界叠加
不可见。碰撞中心与引擎实现保持一致，由 `aoe2_aim_local` 驱动；工具只单独调整并导出
碰撞体尺寸。forward 在导出时会归一化，零向量则明确显示警告并使用 `(0, 0, 1)` 兜底。

## 导出安全边界

按 `E` 时会：

1. 将可直接编辑的 Lua override 复制到系统剪贴板；
2. 新建文件 `LuaUI/Config/AOEAnchorCalibration/u_arc_archer_override_<frame>_<serial>.lua`。

导出文件不自动加载、不会覆盖 `defs.lua`、manifest、缓存资源或引擎配置。其文件名
带帧号以避免覆盖既有导出；请审阅 diff 后再人工合并。

## 相关实现

- `build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_anchor_calibration.lua`
- `build-test-runtime/games/AoeRenderTest.sdd/LuaRules/draw.lua`：加载 unsynced Gadget Handler
- `build-test-runtime/aoe-anchor-calibration-test.txt`：独立校准启动配置
- `rts/Rendering/DebugColVolDrawer.cpp`：原生 collision/aim/muzzle 调试绘制参考
- `rts/Lua/LuaSyncedRead.cpp`：运行时 Unit/CollisionVolume 查询
- `rts/Lua/LuaUnsyncedCtrl.cpp`：剪贴板、临时 Config overlay 与安全目录能力
