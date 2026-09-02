# Experimental AOE2 unit renderer

The optional AOE2 renderer is an unsynced adapter for locally generated AOE2 cache
assets. `CAoe2UnitRenderer` remains independent of Recoil units, movement,
pathfinding, groups, combat, selection, and network state. The optional
`CAoe2UnitGameplayRenderBridge` translates native Gameplay Unit state into the
renderer instance API without adding render state to synced `CUnit` objects.

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
scanning, which makes the local `AOE Render Test` game appear to be missing.

`Aoe2UnitTestCount` accepts 100, 1000, or 10000 for the standard scaling checks. The
test grid selects the overhead controller at a 45-degree isometric pitch, alternates
IdleA and WalkA, covers all 16 directions and eight player colors, and moves a
deterministic subset without creating gameplay entities. Pan and zoom remain enabled.

For native Gameplay Unit validation, disable the render-only grid and enable the
independent bridge:

```text
Aoe2UnitRendering=1
Aoe2UnitGameplayBridge=1
Aoe2UnitTestCount=0
Aoe2UnitGameplayDiagnostics=1
```

The bridge is disabled by default. Disabling it leaves native Unit rendering and
Gameplay behavior unchanged.

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

The Gameplay bridge listens for render-safe Unit create/destroy events. Event callbacks
only queue `unitID` plus a pointer-valued lifetime token; all appearance and instance
operations run later from `CWorldDrawer::Update`. A dense Unit-ID registry and an active
ID array make per-frame work O(M), where M is the number of successfully mapped native
Units. Reused Unit IDs cannot update an older renderer handle.

## Gameplay UnitDef mapping

Mapping is opt-in and cached once per UnitDef through `customParams`:

```lua
customParams = {
    aoe2_unit_id = "u_arc_archer",
    aoe2_scale = "1.0",
    aoe2_ground_offset = "0.0",
    aoe2_player_color = "team", -- or a fixed AOE player color from 1 through 8
    aoe2_hide_native_model = "true",
    aoe2_animation_speed = "1.0",
}
```

Appearances are shared and preloaded when the bridge is first enabled. A missing or
invalid cache resource logs one mapping error and leaves the native model enabled.
`aoe2_ground_offset` changes only the renderer instance position; the synced Gameplay
position and the renderer's camera/depth bias remain separate.

Heading uses Recoil's signed heading multiplied by `PI / SPRING_MAX_HEADING`. Both
systems therefore define heading zero as world +Z and positive rotation toward +X.
Team player color currently maps `teamID % 8` to the eight AOE palette slots.

Horizontal `CUnit::speed` selects IdleA/WalkA with hysteresis. The defaults are
`Aoe2UnitIdleSpeedThreshold=0.03` and `Aoe2UnitMoveSpeedThreshold=0.08`, in
elmos/frame. Animation time resets on a state transition. Walk playback follows the
ratio between actual horizontal speed and the UnitDef maximum, clamped to 0.5x-2x,
then applies `aoe2_animation_speed`.

Native visibility is calculated first by `CUnitDrawerData`, including LOS, spectator,
icon, void, `noDraw`, alpha, and player-camera rules. The same result drives the AOE
instance. Only after a valid AOE instance exists does UnitDrawer clear native model
draw flags; selection, picking, commands, collision, LOS/radar, icons, and UI continue
to use the original native Unit.

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
- AOE sprites do not participate in water reflection/refraction or Recoil shadow maps.
  The Gameplay bridge reuses native main-view visibility but deliberately leaves
  minimap icons, selection, picking, and other Gameplay/UI behavior to Recoil.
- Gameplay animation mapping currently covers only IdleA and WalkA. Build, attack,
  gather, death, and decay animation states are not implemented.
- `Aoe2UnitDiagnostics=1` reports visible instances, batches, draw calls, upload bytes,
  CPU update/draw time, non-blocking GPU time, and FPS once per second.

OpenAI Codex generated and iterated on all code and documentation in this experimental
path under user direction. Human review and visual verification are required before
submission, as specified by `AI_POLICY.md`.
