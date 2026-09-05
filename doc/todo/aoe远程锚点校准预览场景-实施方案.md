# AOE 远程单位锚点校准预览场景：实施方案

## 调研结论

- Recoil 原生 `DebugColVolDrawer` 能准确绘制最终 CollisionVolume、`aimPos`、
  muzzle 和 selection volume，入口为 `rts/Rendering/DebugColVolDrawer.cpp`；但它
  是全局开关，无法筛选本场景、呈现 AOE 局部数据或提供校准交互。
- 测试场景 Gadget 的 unsynced 半部可使用 `DrawWorld`、`DrawScreen` 和 `gl.*`。
  该路径仅在渲染线程运行，不影响同步模拟，适合测试专用叠加层。
- `Spring.GetUnitPosition(..., true, true)`、`GetUnitDirection`、
  `GetUnitWeaponVectors` 和 `GetUnitCollisionVolumeData` 均返回运行时对象数据。
  由同步 Gadget 采样后通过 `SendToUnsynced` 发送，避免 UI 自行猜测物理锚点。
- `Spring.SetClipboard` 可复制文本；Lua I/O 可写相对安全路径。导出固定在
  `LuaUI/Config/AOEAnchorCalibration/`，文件名带 game frame，绝不改写 UnitDef。

## 实施边界

启用 `aoe_anchor_calibration=1` 后，常规双队战斗和旧的 anchor projectile test
均停用。场景以 4x4 网格创建 16 名 `u_arc_archer`，覆盖 Sprite 的全部 16 个方向，
并为 Team 0 开启全图 LOS。

同步 Gadget 每 15 帧采样真实脚点、mid、aim、weapon muzzle、weapon direction、
局部轴和最终 collision volume。非同步 Gadget 使用该快照绘制：

- 绿色：脚点；紫色：mid；红色：aim；黄色：真实 muzzle/weapon direction；
- 紫色线框：真实最终 CollisionVolume；
- 红/绿/蓝：right/up/front；
- 青色：当前选择 Unit 的本地预览，及仅作参考的虚线抛物线。

青色预览不会改动同步 Gameplay；这是刻意的安全边界。`heading` 是唯一直接作用于
测试 Unit 的交互，走 `SendToSynced -> Spring.SetUnitDirection`。其余 anchor 与
collision 参数只能导出到配置片段后人工审阅、合入 Def、重启场景验证。

`sprite_pixels_to_world` 使用 `Spring.SetConfigFloat(..., true)` 作为仅本次运行
的 renderer overlay；AOE renderer 每帧读取该 renderer-only 配置，因此可即时预览，
不会写入 `springsettings.cfg` 或影响同步状态。

## 操作和导出

| 操作 | 按键 |
| --- | --- |
| 切换方向 Unit | `Tab` |
| 选择字段 | `Up` / `Down` |
| 调整字段 | `Left` / `Right` |
| 十倍步进 | `Shift` + `Left` / `Right` |
| 恢复 Def 默认预览 | `R` |
| 导出并复制到剪贴板 | `E` |

导出只生成新的 override 片段，路径为：

```text
LuaUI/Config/AOEAnchorCalibration/u_arc_archer_override_<frame>_<serial>.lua
```

它不自动加载、不覆盖 `defs.lua`、不触碰 manifest/cache，也不执行外部程序；开发者
应在审阅 diff 后手工合入 `build-test-runtime/.../gamedata/defs.lua`。

要求：
  - 尽量使用独立的场景，独立的配置
  - 功能实现尽量全部使用Lua实现，如果lua做不到，可以在c++中增加通用接口
  - 要把操作方式，工具使用边界显示在屏幕上

## 性能与限制

该工具固定 16 个 Unit，每 15 帧同步一次；渲染仅提交少量 Lua immediate-mode 辅助线，
不进入 AOE Sprite 批次，不适用于大规模场景。当前只支持 upright 的远程 `CylY`
测试单位；近战 contact socket、逐帧手部 socket、Projectile sprite tip/tail anchor
和真实弹道求解均不在本阶段范围内。
