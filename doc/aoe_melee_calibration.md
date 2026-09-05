# AOE Camel Scout 近战校准与 Gameplay 测试

## 接入边界

`aoe_camel_scout` 使用 Recoil 原生 `weaponType="Melee"`。CommandAI 负责索敌、
接近和转向，`CMeleeWeapon` 在释放帧直接调用目标 `DoDamage`；AOE Renderer 仅根据
`CUnit` 的攻击状态播放 `AttackA`，不生成 Projectile，也不参与命中判断。

资源 manifest 提供 16 方向、30 FPS 的 `AttackA`，`frame_delay=10`。测试
WeaponDef 因此配置 `windup=10/30` 秒和 `attackRecoveryTime=20/30` 秒，使直接伤害
发生在动画第 10 帧，整个 AttackA 的 30 帧均由 Gameplay 攻击状态覆盖。首版固定使用
IdleA、WalkA、AttackA 和 DeathA；IdleB/AttackB 留待通用动画变体支持。

DAT `collision_size=(0.25,0.25,2.0)` 沿用已验证的水平乘 60、垂直乘 30 规则，
得到 `30×60×30` 的 CylY 碰撞体。近战没有 muzzle，测试将身体中心
`(0,30,0)` 同时作为 aim 和原生 weapon attack origin，避免隐藏的占位 S3O piece
影响距离判断。

## 全方向校准场景

构建后使用独立启动脚本：

```powershell
Set-Location D:\code\RecoilEngine
powershell -ExecutionPolicy Bypass -File .\tools\windows-engine-build.ps1 -Incremental -Jobs 12
& .\build-official-release\extract\spring-dev.exe --write-dir "$PWD\build-test-runtime" "$PWD\build-test-runtime\aoe-melee-calibration-test.txt"
```

场景生成 16 对 Camel Scout。每名蓝方攻击者固定一个方向，红方静止目标位于正前方；
它使用真实敌对 Unit 而不是地面目标，因为原生 `Melee` 只对 Unit 直接造成伤害。
默认中心距离 44，接敌测试距离 96，使用共享的 5° 长焦相机和原生
`/debugcolvol`。

快捷键：

| 按键 | 行为 |
| --- | --- |
| `Tab` | 选择下一方向 |
| `S` | 选择方向执行一次真实攻击，首次伤害后 Stop |
| `A` | 开关全部单位循环攻击 |
| `C` | 重置到远距离并使用原生追击接敌 |
| `D` | 开关真实伤害；关闭时只拦截校准目标的伤害 |
| `R` | 恢复 Def 的攻击原点、碰撞体、range、位置和生命值 |
| `P` / `V` / `G` | 显示或隐藏锚点、碰撞体、射程 |
| `Up/Down`、`Left/Right` | 选择并调整攻击原点、碰撞尺寸和 range；Shift 为十倍步长 |
| `E` | 复制并安全导出建议 Lua，不覆盖正式 Def |

黄色圆表示从真实 attack origin 测得的 Weapon range；蓝线连接攻击原点和目标
aimPos。红色伤害标记位于目标 aimPos，它表示 `DoDamage` 事件，不代表不存在的
Projectile 或物理刀尖碰撞点。日志中的 `delta` 是伤害帧减攻击状态起始帧，默认应为 10。
自动回归时可临时将启动脚本中的 `aoe_melee_start_auto_attack` 设为 `1`；人工校准默认
保持为 `0`，以便启动后先观察静态线框。

## 小规模实战场景

```powershell
Set-Location D:\code\RecoilEngine
& .\build-official-release\extract\spring-dev.exe --write-dir "$PWD\build-test-runtime" "$PWD\build-test-runtime\aoe-melee-gameplay-test.txt"
```

默认生成互为敌对的 16v16 Camel Scout，并在第 150 帧通过
`Spring.GiveOrderToUnitArrayGroup` 向双方下达原生 group-locked `CMD.FIGHT`。可在启动
脚本中调整 `aoe_melee_team_a_count`、`aoe_melee_team_b_count`、`aoe_team_spacing`、
`aoe_team_separation` 和 `aoe_attack_move_start_frame`。

该场景用于验证原生追击、严格停步攻击、碰撞保护、直接伤害、DeathA、CFeature
所有权转移及程序化渐隐。DecayA 资源不会加载。

## 运行时覆盖安全边界

工具只复用已有开发接口：攻击原点使用受 `AOE_DEV_TOOL` 保护的 muzzle override，
碰撞体和 range 使用 Recoil 原生同步 Lua API。Reset 会还原 UnitDef 值；Export 只写入
`LuaUI/Config/AOEMeleeCalibration` 的新文件并复制剪贴板，不会自动加载或覆盖 Def。
