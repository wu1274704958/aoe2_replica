# Windows Engine 构建脚本

`tools/windows-engine-build.ps1` 用于在 Windows 本机重新构建 RecoilEngine 的
`engine-legacy`，并生成测试场景使用的 `spring-dev.exe`。

脚本默认执行完整的目标清理和重编译。当前 MinGW/Ninja 构建目录曾出现头文件依赖未被
记录的问题；修改 `UnitDef`、`CUnit`、`WeaponDef`、`CWeapon` 等 C++ 类型布局后，普通
增量编译可能把新旧对象文件链接进同一个程序，造成随机越界或崩溃。因此日常验证布局
相关修改时应保留默认的 clean 模式。

## 前置条件

- Windows PowerShell 5.1 或 PowerShell 7；
- CMake 和 Ninja 可从 `PATH` 找到；
- MinGW 编译器及 `strip.exe` 可用；
- 已准备 `mingwlibs64`；
- 已存在配置完成的 CMake 构建目录，默认是 `build-mingw`；
- 运行目录中已有 RecoilEngine 所需 DLL。当前开发环境使用
  `build-official-release/extract`，其中的 DLL 来自官方 Release 包。

如果还没有构建目录，可在仓库根目录进行一次配置。下面的命令适用于当前 Strawberry
MinGW 环境；使用其他工具链时应相应调整编译器路径：

```powershell
cmake -S . -B build-mingw -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DMINGWLIBS="$PWD\mingwlibs64" `
  -DBUILD_spring-legacy=ON
```

## 默认构建

在仓库根目录执行：

```powershell
pwsh -File .\tools\windows-engine-build.ps1
```

如果系统没有 `pwsh`，可使用 Windows PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows-engine-build.ps1
```

默认流程为：

1. 校验 `build-mingw/CMakeCache.txt` 属于当前仓库；
2. 以 clean 模式完整构建 `engine-legacy`；
3. 保留带调试信息的 `build-mingw/spring.exe`；
4. 使用 CMake 配置的 `strip.exe` 生成尺寸较小、Windows 可加载的
   `build-official-release/extract/spring-dev.exe`；
5. 执行一次 `--version` 启动检查；
6. 启动检查成功后才替换旧的 `spring-dev.exe`。

## 常用参数

指定并行任务数：

```powershell
pwsh -File .\tools\windows-engine-build.ps1 -Jobs 8
```

指定其他构建目录或运行目录：

```powershell
pwsh -File .\tools\windows-engine-build.ps1 `
  -BuildDirectory D:\build\recoil-mingw `
  -RuntimeDirectory D:\runtime\recoil
```

仅在没有修改任何会影响 C++ 类型布局的头文件时，才建议使用增量模式：

```powershell
pwsh -File .\tools\windows-engine-build.ps1 -Incremental
```

诊断用途参数：

- `-SkipStrip`：直接复制未剥离的程序。当前 MinGW 调试程序可能过大并被 Windows 拒绝
  加载，因此通常不要使用。
- `-SkipVersionCheck`：跳过生成程序的启动检查。
- `-OutputName <name.exe>`：修改运行程序文件名。

## 运行 AOE 测试场景

构建成功后执行：

```powershell
.\build-official-release\extract\spring-dev.exe `
  --write-dir "$PWD\build-test-runtime" `
  "$PWD\build-test-runtime\_script.txt"
```

若提示缺少 `SDL2.dll`、`OpenAL32.dll` 等文件，应检查
`build-official-release/extract` 是否包含官方 Release 的运行时 DLL。构建脚本只替换
`spring-dev.exe`，不会覆盖或重新分发这些第三方运行时文件。
