# Player Camera 正交投影

Recoil Player Camera 默认仍使用透视投影。Lua 可通过 `Spring.SetCameraState` 对当前
运行的相机启用真实正交投影：

```lua
Spring.SetCameraState({
	mode = 1,
	projection = 1,
	orthoHeight = 828.427,
	px = Game.mapSizeX * 0.5,
	py = 0,
	pz = Game.mapSizeZ * 0.5,
	height = 1000,
	angle = math.pi * 0.25,
}, 0)
```

- `projection=0`：透视投影，保持原引擎行为。
- `projection=1`：正交投影。
- `orthoHeight`：视口完整垂直方向覆盖的世界单位数，必须大于 0；水平跨度为
  `orthoHeight * viewportAspectRatio`。

`Spring.GetCameraState()` 会返回 `projection` 和 `orthoHeight`。保存/恢复引擎视角时
这两个字段也会随视角状态保存。

## 屏幕射线

透视投影的所有鼠标射线从相机位置出发；正交投影的射线方向相同，但每个屏幕像素
拥有不同起点。因此需要同时使用起点和方向的 Lua 代码应调用：

```lua
local ox, oy, oz, dx, dy, dz = Spring.GetPixelRay(screenX, screenY)
```

`Spring.GetPixelDir` 为兼容旧代码而保留，在正交模式下只返回共同方向。
`Spring.TraceScreenRay`、引擎原生单击选择、地面命令和框选已经在内部使用完整射线。
`Spring.GetMouseStartPosition` 返回的第 3～5 项在正交模式下表示按下像素对应的射线
起点，而不是所有像素共享的物理相机位置。
