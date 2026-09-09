# Windows Engine 构建指南

本文从一个**没有 CMake build cache** 的全新 Windows 工作副本开始，构建
RecoilEngine 的 `engine-legacy`，并说明如何得到可启动的运行目录。AOE 双队
Attack Move 场景的启动与参数说明见
[`aoe_double_team_attack_move_test.md`](aoe_double_team_attack_move_test.md)。

## 0. 获取完整源码

在仓库根目录执行以下命令，确保所有子模块已经取回：

```powershell
git submodule update --init --recursive
```

构建前关闭所有正在运行的 `spring*.exe`，否则 Windows 可能锁住待替换的可执行文件。
以下示例均从仓库根目录执行，并且每种工具链使用自己的 build 目录；不要让不同
generator 复用同一个目录。

## 1. 推荐：本机 MinGW + Ninja

这是 `tools/windows-engine-build.ps1` 所支持的开发路径。它要求：

- CMake 3.27 或更高版本；
- Ninja、64 位 MinGW GCC/G++ 和 `strip.exe` 均可从 `PATH` 找到；
- 与工具链匹配的 `mingwlibs64` 依赖目录（含 `include`、`lib`、`dll`）。默认可放在
  仓库根目录，也可由环境变量 `MINGWLIBS` 或 `-DMINGWLIBS` 指向其它位置；
- 用于实际启动的运行时 DLL。开发环境可将官方 Windows Release 解压到任意目录，作为
  下文的运行目录；构建脚本只更新 EXE，不下载或覆盖 DLL。

先检查工具链：

```powershell
cmake --version
ninja --version
g++ --version
strip --version
```

### 首次配置（不依赖已有 cache）

```powershell
cmake -S . -B build-mingw -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DMINGWLIBS="$PWD\mingwlibs64" `
  -DBUILD_spring-legacy=ON
```

若依赖位于其它位置，只替换 `-DMINGWLIBS` 的绝对路径。配置成功后应存在
`build-mingw\CMakeCache.txt`；它是下一步构建脚本的输入，而不是前置假设。

### 构建并部署到运行目录

```powershell
pwsh -File .\tools\windows-engine-build.ps1 `
  -BuildDirectory build-mingw `
  -RuntimeDirectory D:\runtime\recoil-dev
```

如果系统只有 Windows PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows-engine-build.ps1 `
  -BuildDirectory build-mingw `
  -RuntimeDirectory D:\runtime\recoil-dev
```

首次使用前，`D:\runtime\recoil-dev` 应已包含与该 MinGW 构建兼容的 Release 运行时
DLL（例如 `SDL2.dll`、`OpenAL32.dll` 等）。可先把官方 Release 的解压内容复制到该目录。
脚本会：

1. 校验 cache 归属当前源码树；
2. 默认以 `--clean-first` 构建 `engine-legacy`；
3. 保留 `build-mingw\spring.exe` 的未剥离版本；
4. 用当前工具链的 `strip` 生成 `<RuntimeDirectory>\spring-dev.exe`；
5. 用 `--version` 验证新 EXE 可以启动后才替换旧文件。

头文件或 C++ 类型布局（例如 `UnitDef`、`CUnit`、`WeaponDef`、`CWeapon`）变动后必须
保留默认 clean 构建，避免旧对象文件混入。仅在确认没有此类变动时才使用：

```powershell
pwsh -File .\tools\windows-engine-build.ps1 -BuildDirectory build-mingw -Incremental -Jobs 8
```

`-SkipStrip` 与 `-SkipVersionCheck` 仅用于诊断；正常 Windows 验证不建议使用。

## 2. 没有 MinGW 时的选择

### 2.1 安装或准备 MinGW（建议长期本机开发时使用）

安装 64 位 MinGW-w64 GCC、Ninja 和 CMake，并将其 `bin` 目录加入 `PATH`。依赖不能只靠
编译器本身：还需要取得与该工具链兼容的 `mingwlibs64`，将其置于仓库根目录或设置
`MINGWLIBS` 环境变量。然后回到“首次配置”，从零生成 `build-mingw`。

不要把 MSVC 的 `vclibs64` 用给 MinGW，也不要把 MSVC 编译出的 EXE 与 MinGW Release 的
DLL 混用。

### 2.2 MSVC 手工构建（本机 MinGW 的替代方案）

安装 Visual Studio 2022 或 Build Tools，并勾选“使用 C++ 的桌面开发”。从 *x64 Native
Tools Command Prompt for VS 2022* 或已初始化的开发者 PowerShell 执行：

```powershell
cmake -S . -B build-msvc -G "Visual Studio 17 2022" -A x64 `
  -DMINGWLIBS="$PWD\vclibs64" `
  -DBUILD_spring-legacy=ON
cmake --build build-msvc --config RelWithDebInfo --target engine-legacy --parallel
```

MSVC 是 multi-config generator，`spring.exe` 通常位于
`build-msvc\RelWithDebInfo\spring.exe`（如目录布局不同，可搜索
`Get-ChildItem build-msvc -Filter spring.exe -Recurse`）。当前
`windows-engine-build.ps1` 专为单配置 MinGW/Ninja 目录和 MinGW `strip` 设计，**不要**
将 MSVC build 目录交给它。应手工建立一个只含 MSVC 匹配 DLL 的运行目录，再复制 EXE：

```powershell
Copy-Item .\build-msvc\RelWithDebInfo\spring.exe D:\runtime\recoil-msvc\spring-dev.exe
& D:\runtime\recoil-msvc\spring-dev.exe --version
```

若 MSVC 依赖或运行时无法匹配，使用下方官方 Docker 路径；它是最可靠的干净环境回退。

### 2.3 官方 Docker 构建（最可复现的回退）

安装并启动 Docker Desktop，以及 Git for Windows（提供 Bash）；也可在 WSL2 内进行。原生
Windows 文件系统上的容器编译较慢，WSL2 中应将源码 clone 到 Linux 文件系统内。

从 Git Bash 或 WSL 的仓库根目录执行：

```bash
docker-build-v2/build.sh windows
```

脚本会拉取官方包含 MinGW、依赖和缓存配置的镜像，进行全新配置、编译并安装。可启动的
完整输出位于：

```text
build-amd64-windows/install/
```

而不是 `build-amd64-windows/` 根目录。首次只检查配置可运行：

```bash
docker-build-v2/build.sh --configure windows
```

更多 Docker 参数见 `docker-build-v2/README.md`；例如 `-j 8` 限制并行度。

## 3. 构建与运行问题排查

- `Configured CMake build directory not found`：尚未执行首次 `cmake -S/-B`，或传给脚本的
  `-BuildDirectory` 不对；重新配置，不要手写 cache。
- `SDL2.dll was not found` / 缺少其它 DLL：编译成功不代表运行目录完整。将同一工具链的
  Release 运行时 DLL 放在 `spring-dev.exe` 旁；不要从不同工具链拼凑 DLL。
- `spring-dev.exe` 不能替换、清理失败：退出所有 Spring 进程、关闭被占用的日志查看器后重试。
- CMake 找不到依赖：确认 `MINGWLIBS` 指向正确的工具链依赖根目录；无法快速修复时转用
  Docker，而不是在已有 build 目录中切换 generator。

## 4. AOE 测试运行目录

测试启动示例中的 `--write-dir` 可以是任意可写绝对目录；文档中的
`build-test-runtime` 只是仓库内随测试场景提交的便携模板，不是引擎固定的本地目录。建议
把它复制到例如 `D:\runtime\aoe-test-write-dir` 后使用该副本作为 write-dir，以免运行产生的
缓存、日志和 UI 偏好污染源码树。完整运行方式、资源前置条件和双队参数见
[`aoe_double_team_attack_move_test.md`](aoe_double_team_attack_move_test.md)。

## 5. 其它 AOE 专项场景

下面的启动文件也在便携测试模板内。将 `$engine` 和 `$writeDir` 替换为实际路径即可；
不要假定 write-dir 位于源码树内。

```powershell
$engine = "D:\runtime\recoil-dev\spring-dev.exe"
$writeDir = "D:\runtime\aoe-test-write-dir"
& $engine --write-dir $writeDir "$writeDir\aoe-anchor-calibration-test.txt"
```

- `aoe-anchor-calibration-test.txt`：16 方向远程单位锚点校准，详见
  `doc/aoe_anchor_calibration.md`。
- `aoe-melee-calibration-test.txt`：Camel Scout 全方向碰撞、射程和伤害帧校准；
  `aoe-melee-gameplay-test.txt`：双队近战原生 `CMD.FIGHT`。
- `aoe-attack-regression-test.txt`：8v1 的 `attackCannotMove` 专项回归；可通过
  `aoe_explicit_move_regression` 验证显式 Move 在 Windup/Recovery 取消攻击。
- `aoe-building-test.txt`：四个方向的原生 AOE 箭塔、锚点/碰撞预览和塔 Projectile 验证。

这些专项模式不要与双队 Attack Move 的 `_script.txt` 混用。
