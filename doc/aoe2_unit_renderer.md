# Experimental AOE2 unit renderer

The optional AOE2 renderer is an unsynced, render-only adapter for locally generated
AOE2 cache assets. It does not depend on Recoil units, movement, pathfinding, groups,
combat, selection, or network state.

## Build and run

Configure the engine with `-DENABLE_AOE2_UNIT_RENDERER=ON`. The compiled path remains
disabled unless `Aoe2UnitRendering=1` is set at runtime. The local cache defaults to
`cont/aoe2de_cache` and must not be committed or redistributed.

For a render-only validation scene, set:

```text
Aoe2UnitRendering=1
Aoe2UnitTestCount=1000
Aoe2UnitTestId=u_arc_archer
Aoe2UnitDiagnostics=1
CamMode=1
```

On Windows, pass an absolute write directory when launching the local test content:

```powershell
cd D:\code\RecoilEngine\build-test-runtime
$runtimeDir = (Get-Location).Path
..\build-mingw\spring.exe --write-dir $runtimeDir blank-map-test.txt
```

Do not use `--write-dir .` with this engine version. Its relative-path handling can
construct `.springsettings.cfg` and omit the local `games/` directory from archive
scanning, which makes `AOE Render Test 0.1` appear to be missing.

`Aoe2UnitTestCount` accepts 100, 1000, or 10000 for the standard scaling checks. The
test grid selects the overhead controller at a 45-degree isometric pitch, alternates
IdleA and WalkA, covers all 16 directions and eight player colors, and moves a
deterministic subset without creating gameplay entities. Pan and zoom remain enabled.

## Integration boundary

`CAoe2UnitRenderer` owns cache metadata, textures, shaders, instance buffers, animation
sampling, culling, and draw submission. Callers use generation-checked appearance and
instance handles to create, update, hide, and destroy render instances. Heading zero is
world +Z and positive angles rotate toward +X. Direction slot zero is screen-right and
the remaining cached directions proceed clockwise.

Metadata and the IdleA/WalkA atlases are loaded synchronously from the local cache during
`CWorldDrawer::InitPost`. Rendering occurs after native opaque unit/feature models and
before opaque projectiles. Main and cached shadow sprites are separately instanced; for
one appearance using IdleA and WalkA, the expected maximum is four draw calls.

## Coordinate and state rules

Recoil world positions use X/Z as the ground plane and +Y as up. Cached sprite pixels
are converted through `Aoe2UnitPixelsToWorld` (default 1.0). Each frame's top-left foot
anchor is preserved, while the quad axes follow the active isometric camera. The pass
uses depth testing, disables depth writes for cached shadows, enables alpha blending,
and restores the GL program, VAO, texture bindings, depth, blend, and culling state.

## Known limits

- Version one targets the fixed isometric/overhead presentation. Camera-facing quads
  remain readable while panning and zooming, but arbitrary camera-roll presentation is
  not an acceptance target.
- Only unit manifests and the preheated IdleA/WalkA animations are accepted. Requests
  for other animations do not trigger implicit runtime I/O.
- The renderer does not participate in water reflection/refraction, Recoil shadow maps,
  minimap icons, selection, picking, or gameplay visibility.
- `Aoe2UnitDiagnostics=1` reports visible instances, batches, draw calls, upload bytes,
  CPU update/draw time, non-blocking GPU time, and FPS once per second.

OpenAI Codex generated and iterated on all code and documentation in this experimental
path under user direction. Human review and visual verification are required before
submission, as specified by `AI_POLICY.md`.
