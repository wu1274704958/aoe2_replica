# AOE Release 诊断日志清理清单

本文记录当前 AOE 开发路径中的诊断日志和配套诊断接口。Release 前应逐项确认：高频诊断应删除、默认关闭或受开发构建开关保护；初始化失败、资源无效等真正的运行时错误不应误删。

## 测试场景日志

### `[AOE Position Diagnostic]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_gameplay_test.lua`
- 入口：`InitializePositionDiagnostic`、`UpdatePositionDiagnostic`、`LogPositionSnapshot`，以及 `GameFrame` 中的 collision-lock audit 汇总。
- 开关：ModOption `aoe_position_diagnostics`；采样规模由 `aoe_position_diagnostic_samples` 控制。
- 诊断问题：`attackCannotMove` 单位攻击时发生肉眼可见的位置抖动。日志记录位置增量、两帧往返位移、速度、移动/碰撞锁、攻击阶段、武器目标、移动目标和命令队列，用来区分碰撞推挤、锁切换、目标死亡/切换与短距离反向位移。
- Release 处理：从发布测试配置中默认关闭；稳定回归结束后删除逐帧 history/follow 明细，或只在专用开发 Gadget 中保留。不得在正式大规模战斗中开启。

### `[AOE Move Diagnostic]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_gameplay_test.lua`
- 入口：`UpdatePositionDiagnostic` 中的 `UnitMoveFailed` 采样、`UpdateEliminationDiagnostic`、`LogPostEliminationSnapshot`。
- 诊断问题：Attack Move 交战结束后，幸存单位停在战场中间而未继续走向原 `CMD.FIGHT` 目标；同时统计目标死亡后的命令队列、停滞距离、移动失败次数和尸体数量。
- Release 处理：该日志仅属于 AOE 双队回归场景。发布内容不携带该测试 Gadget 时一并排除；若保留内部测试场景，保持低频并默认关闭详细明细。

### `[AOE Attack Regression]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_gameplay_test.lua`
- 入口：`InitializeExplicitMoveRegression`、`UpdateExplicitMoveRegression`、目标死亡检测及定时汇总。
- 启动配置：`build-test-runtime/aoe-attack-regression-test.txt`。
- 诊断问题：
  - 玩家显式 `CMD.MOVE` 是否能在 Windup/Recovery 阶段取消攻击并恢复移动；
  - 临时攻击目标死亡后，内部 `CMD.ATTACK` 是否正确退出且原 `CMD.FIGHT` 仍被保留；
  - 上述切换过程中是否错误解除或残留 `attackCannotMove` 锁。
- Release 处理：作为自动/人工回归用例保留在开发测试资产中，不进入普通游戏日志；Release 包若不包含测试资产则整体排除。

### `[AOE Gameplay Test]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_gameplay_test.lua`
- 入口：固定长焦相机初始化、`SpawnFormation`、`GiveAttackMove`、`GameStart`、`LogStatus`、`AuditAttackStartSpeed` 和定时汇总。
- 诊断问题：确认双队生成、敌对关系、全图视野、原生 group-locked `CMD.FIGHT` 下发、武器参数、存活/受伤/Projectile/CFeature 数量；其中 `attack-start speed violation` 专门检查单位是否在速度超过阈值时错误开始攻击。
- Release 处理：场景状态日志只服务本地测试，应随测试场景排除或改为显式诊断开关；攻击起始速度检查在回归稳定后移入测试断言，不应长期输出正式日志。

### `[AOE Anchor Test]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_gameplay_test.lua`
- 入口：`SpawnAnchorValidation`、`LogAnchorState`、`ProjectileCreated`、`UnitDamaged`。
- 诊断问题：验证各朝向下 Unit 脚点、aim/受击点、muzzle/发射点、武器方向、Projectile 实际出生点和命中时目标受击点是否一致。
- Release 处理：仅在锚点验证模式使用；发布时排除该模式及地图 Marker 输出，或确保默认关闭。

### `[AOE Anchor Calibration]`

- 位置：`build-test-runtime/games/AoeRenderTest.sdd/LuaRules/Gadgets/game_aoe_anchor_calibration.lua`
- 启动配置：`build-test-runtime/aoe-anchor-calibration-test.txt`。
- 诊断问题：锚点校准工具的初始化、固定相机、原生碰撞体对照、运行时 muzzle override、地面攻击、Reset 和导出状态；用于定位 Sprite 与 3D 碰撞体、受击点及发射点不重合的问题。
- Release 处理：这是开发工具交互日志，不应逐条当作异常删除。Release 包应排除整套校准场景，或仅在 `AOE_DEV_TOOL=1` 的开发构建中提供。

## C++ 渲染诊断日志

### `[Aoe2UnitRenderer]`

- 位置：`rts/Rendering/Aoe2/Aoe2UnitRenderer.cpp`
- 入口：渲染器初始化/资源预加载，以及 `CAoe2UnitRenderer::Update` 的周期性能统计。
- 诊断问题：OpenGL/Shader/缓存资源初始化失败；实例数、可见数、批次数、Draw Call、上传字节、纹理显存、CPU/GPU 帧耗时和 FPS，用于检查实例化是否退化、显存占用和性能瓶颈。
- Release 处理：保留不可恢复的 warning/error；周期性能行和成功初始化明细改为开发级日志、配置开关或 Release 默认关闭。

### `[Aoe2GameplayBridge]`

- 位置：`rts/Rendering/Aoe2/Aoe2UnitGameplayRenderBridge.cpp`
- 入口：映射解析、Enable/Disable、`AddFeature` 尸体转移记录和 `Aoe2GameplayBridgeImpl::Update` 周期统计。
- 诊断问题：UnitDef 映射错误、多武器约束、AOE 资源缺失；CUnit 到 CFeature 的渲染实例所有权转移、Death/程序化 Decay 可见性、实例泄漏和 Bridge CPU 开销。
- Release 处理：保留配置/资源错误 warning；`corpse feature=...` 单尸体明细和周期统计应删除、降级或由开发诊断开关控制。

### `[Aoe2ProjectileBridge]`

- 位置：`rts/Rendering/Aoe2/Aoe2ProjectileGameplayRenderBridge.cpp`
- 入口：映射解析、Enable/Disable 和 `Aoe2ProjectileGameplayRenderBridgeImpl::Update` 周期统计。
- 诊断问题：Projectile 资源映射失败、AOE Projectile 实例创建/销毁泄漏、可见性数量及 Bridge CPU 开销。
- Release 处理：保留无效配置/资源缺失 warning；周期实例/性能统计改为开发级日志或默认关闭。

## 配套诊断接口与构建开关

这些位置本身不一定输出日志，但为上述日志或校准工具提供额外状态，Release 时必须一起审计：

- `rts/Lua/LuaSyncedRead.cpp`：`GetUnitMoveTypeData` 在 `AOE_DEV_TOOL` 下暴露 `attackMovementLocked`、`attackCollisionLocked`、`attackAnimationActive`、攻击阶段和关键帧，供位置抖动/攻击状态诊断使用。
- `rts/Lua/LuaSyncedCtrl.cpp`、`rts/Lua/LuaSyncedCtrl.h`：测试专用运行时 muzzle override API，供锚点校准工具 Apply/Reset 使用。
- `CMakeLists.txt`：当前 `AOE_DEV_TOOL` 默认值为 `ON`。正式 Release 前应改为默认 `OFF`，并确认发行构建显式使用 `-DAOE_DEV_TOOL=OFF`。
- `build-test-runtime/games/AoeRenderTest.sdd/modoptions.lua`：集中暴露位置诊断、回归、锚点验证/校准等开关；Release 不应让普通 Mod 意外开启高频诊断。

## Release 前验收清单

- [ ] 正式构建使用 `AOE_DEV_TOOL=0`，Lua 中无法调用运行时 muzzle override。
- [ ] 普通游戏不会加载 AOE 校准、锚点验证、位置诊断和 attack regression Gadget 路径。
- [ ] 大规模战斗日志中不再出现逐 Unit、逐帧或固定周期的诊断输出。
- [ ] 保留 OpenGL、Shader、资源缺失、非法 UnitDef/WeaponDef 等可操作的 warning/error。
- [ ] 如需保留性能指标，改为显式配置开启，并确认关闭时没有额外逐帧扫描或格式化开销。
- [ ] 用 `rg "AOE Position Diagnostic|AOE Move Diagnostic|AOE Attack Regression|AOE Gameplay Test|AOE Anchor Test|AOE Anchor Calibration|Aoe2UnitRenderer|Aoe2GameplayBridge|Aoe2ProjectileBridge"` 复核遗漏。
