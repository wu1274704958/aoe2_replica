function gadget:GetInfo()
	return {
		name = "AOE Building Bridge Test",
		desc = "Four native AOE castles with runtime anchor and collision calibration",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = 2,
		enabled = true,
	}
end

local function ReadBooleanOption(options, name, defaultValue)
	local value = options[name]
	if value == nil then
		return defaultValue
	end
	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local options = Spring.GetModOptions()
if not ReadBooleanOption(options, "aoe_building_test", false) then
	return
end

-- b_west_castle_age3 is a fixed-orientation (one-direction) schema-4 building.
-- The four native headings deliberately exercise the Bridge's transform,
-- collision and weapon-anchor handling without pretending that the Sprite has
-- four distinct visual facings.
local BUILDING_NAME = "aoe_west_castle_age3"
local BUILDING_RESOURCE_ID = "b_west_castle_age3"
local BUILDING_DISPLAY_NAME = "Western Age III Castle"
local ENEMY_NAME = "aoe_archer"
local CONTROL_MESSAGE_PREFIX = "aoe_building_test:"
local SPAWN_MESSAGE = CONTROL_MESSAGE_PREFIX .. "spawn_enemy"
local SNAPSHOT_PERIOD = 15
local SPAWN_COOLDOWN = 10
local TOWER_COUNT = 4
-- Source DAT Unit 82 graphic_displacement=(0,1,4), converted by the shared
-- profile: (right=x*60, up=z*30, front=y*60). This is intentionally an
-- uncalibrated baseline for the preview tool.
local BASE_MUZZLE_LOCAL = { 0, 120, 60 }
local BELOW_FOOT_CAMERA_BIAS_SCALE = 1.0

if not gadgetHandler:IsSyncedCode() then
	local fixedTestCamera = VFS.Include("LuaRules/aoe_fixed_test_camera.lua")
	local snapshots = {}
	local selectedIndex = 1
	local selectedField = 1
	local exportSerial = 0
	local snapshotCount = 0
	local lastExportStatus = "not exported"
	local runtimeMuzzleOverrideEnabled = false
	local runtimeMuzzleOverrideAvailable = true
	local previewCollisionScaleInitialized = false
	local preview = {
		aim = { 0, 120, 0 },
		collision = { 0, 165, 0 },
		muzzle = { 0, 120, 60 },
		forward = { 0, 0, 1 },
		collisionScale = { 400, 330, 400 },
		pixelScale = 0.55,
	}
	local controls = {
		{ label = "aim_local.x", value = preview.aim, index = 1, step = 1 },
		{ label = "aim_local.y", value = preview.aim, index = 2, step = 1 },
		{ label = "aim_local.z", value = preview.aim, index = 3, step = 1 },
		{ label = "collision_local.x", value = preview.collision, index = 1, step = 1 },
		{ label = "collision_local.y", value = preview.collision, index = 2, step = 1 },
		{ label = "collision_local.z", value = preview.collision, index = 3, step = 1 },
		{ label = "muzzle_local.x", value = preview.muzzle, index = 1, step = 1 },
		{ label = "muzzle_local.y", value = preview.muzzle, index = 2, step = 1 },
		{ label = "muzzle_local.z", value = preview.muzzle, index = 3, step = 1 },
		{ label = "forward_local.x", value = preview.forward, index = 1, step = 0.05 },
		{ label = "forward_local.y", value = preview.forward, index = 2, step = 0.05 },
		{ label = "forward_local.z", value = preview.forward, index = 3, step = 0.05 },
		{ label = "collision_scale.x", value = preview.collisionScale, index = 1, step = 1, minimum = 0.01 },
		{ label = "collision_scale.y", value = preview.collisionScale, index = 2, step = 1, minimum = 0.01 },
		{ label = "collision_scale.z", value = preview.collisionScale, index = 3, step = 1, minimum = 0.01 },
		{ label = "sprite_pixels_to_world", value = preview, key = "pixelScale", step = 0.01, minimum = 0.01, maximum = 10 },
	}

	local function CopyVector(destination, source)
		destination[1], destination[2], destination[3] = source[1], source[2], source[3]
	end

	local function ParseVector(value, fallback)
		local x, y, z = string.match(value or "", "([^%s]+)%s+([^%s]+)%s+([^%s]+)")
		return { tonumber(x) or fallback[1], tonumber(y) or fallback[2], tonumber(z) or fallback[3] }
	end

	local function Add(a, b)
		return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
	end

	local function Scale(vector, scalar)
		return { vector[1] * scalar, vector[2] * scalar, vector[3] * scalar }
	end

	local function Normalize(vector)
		local length = math.sqrt(vector[1] * vector[1] + vector[2] * vector[2] + vector[3] * vector[3])
		if length <= 0.000001 then
			return { 0, 0, 1 }, false
		end
		return { vector[1] / length, vector[2] / length, vector[3] / length }, true
	end

	local function LocalToWorld(snapshot, localPoint, origin)
		origin = origin or snapshot.base
		return Add(origin, Add(
			Scale(snapshot.right, localPoint[1]),
			Add(Scale(snapshot.up, localPoint[2]), Scale(snapshot.front, localPoint[3]))))
	end

	local function ResetPreview(clearRuntimeOverride)
		local unitDef = UnitDefs[UnitDefNames[BUILDING_NAME].id]
		local params = unitDef.customParams or {}
		CopyVector(preview.aim, ParseVector(params.aoe2_aim_local, { 0, 120, 0 }))
		CopyVector(preview.collision, ParseVector(params.aoe2_collision_local, preview.aim))
		CopyVector(preview.muzzle, ParseVector(params.aoe2_weapon1_muzzle_local, BASE_MUZZLE_LOCAL))
		CopyVector(preview.forward, ParseVector(params.aoe2_weapon1_forward_local, { 0, 0, 1 }))
		preview.pixelScale = Spring.GetConfigFloat("Aoe2UnitPixelsToWorld", 0.55)

		local snapshot = snapshots[selectedIndex]
		if snapshot ~= nil then
			CopyVector(preview.collisionScale, snapshot.collisionScale)
			previewCollisionScaleInitialized = true
		end
		if clearRuntimeOverride then
			Spring.SendLuaRulesMsg(CONTROL_MESSAGE_PREFIX .. "muzzle_reset")
		end
	end

	local function SendRuntimeMuzzleOverride()
		Spring.SendLuaRulesMsg(string.format(
			"%smuzzle:%.17g:%.17g:%.17g",
			CONTROL_MESSAGE_PREFIX, preview.muzzle[1], preview.muzzle[2], preview.muzzle[3]))
	end

	local function DrawLine(a, b)
		gl.Vertex(a[1], a[2], a[3])
		gl.Vertex(b[1], b[2], b[3])
	end

	local function DrawCross(point, radius)
		gl.BeginEnd(GL.LINES, function()
			DrawLine({ point[1] - radius, point[2], point[3] }, { point[1] + radius, point[2], point[3] })
			DrawLine({ point[1], point[2] - radius, point[3] }, { point[1], point[2] + radius, point[3] })
			DrawLine({ point[1], point[2], point[3] - radius }, { point[1], point[2], point[3] + radius })
		end)
	end

	local function DrawBox(center, right, up, front, scale)
		local halfRight = Scale(right, scale[1] * 0.5)
		local halfUp = Scale(up, scale[2] * 0.5)
		local halfFront = Scale(front, scale[3] * 0.5)
		local corners = {
			Add(center, Add(Scale(halfRight, -1), Add(Scale(halfUp, -1), Scale(halfFront, -1)))),
			Add(center, Add(halfRight, Add(Scale(halfUp, -1), Scale(halfFront, -1)))),
			Add(center, Add(halfRight, Add(halfUp, Scale(halfFront, -1)))),
			Add(center, Add(Scale(halfRight, -1), Add(halfUp, Scale(halfFront, -1)))),
			Add(center, Add(Scale(halfRight, -1), Add(Scale(halfUp, -1), halfFront))),
			Add(center, Add(halfRight, Add(Scale(halfUp, -1), halfFront))),
			Add(center, Add(halfRight, Add(halfUp, halfFront))),
			Add(center, Add(Scale(halfRight, -1), Add(halfUp, halfFront))),
		}
		local edges = {
			{ 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
			{ 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
			{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
		}
		gl.BeginEnd(GL.LINES, function()
			for _, edge in ipairs(edges) do
				DrawLine(corners[edge[1]], corners[edge[2]])
			end
		end)
	end

	local function DrawAxes(snapshot)
		local axisLength = 30
		gl.BeginEnd(GL.LINES, function()
			gl.Color(1, 0.2, 0.2, 1)
			DrawLine(snapshot.base, Add(snapshot.base, Scale(snapshot.right, axisLength)))
			gl.Color(0.2, 1, 0.2, 1)
			DrawLine(snapshot.base, Add(snapshot.base, Scale(snapshot.up, axisLength)))
			gl.Color(0.2, 0.5, 1, 1)
			DrawLine(snapshot.base, Add(snapshot.base, Scale(snapshot.front, axisLength)))
		end)
	end

	local function DrawSnapshot(snapshot, index)
		gl.LineWidth((index == selectedIndex) and 2.5 or 1.25)
		gl.Color(0.2, 1.0, 0.2, 1.0)
		DrawCross(snapshot.base, 7)
		gl.Color(0.85, 0.2, 1.0, 1.0)
		DrawCross(snapshot.mid, 5)
		gl.Color(1.0, 0.25, 0.25, 1.0)
		DrawCross(snapshot.aim, 6)
		gl.Color(1.0, 0.82, 0.1, 1.0)
		DrawCross(snapshot.muzzle, 6)
		gl.BeginEnd(GL.LINES, function()
			DrawLine(snapshot.muzzle, Add(snapshot.muzzle, Scale(snapshot.weaponDirection, 54)))
		end)
		gl.Color(0.8, 0.1, 0.9, 0.9)
		DrawBox(snapshot.collisionCenter, snapshot.right, snapshot.up, snapshot.front, snapshot.collisionScale)
		DrawAxes(snapshot)
		gl.Color(1, 1, 1, 1)
		gl.Text(snapshot.label, snapshot.base[1], snapshot.base[2] + 12, snapshot.base[3], 13, "oc")
	end

	local function DrawPreview(snapshot)
		local previewAim = LocalToWorld(snapshot, preview.aim)
		local previewCollision = LocalToWorld(snapshot, preview.collision)
		local previewMuzzle = LocalToWorld(snapshot, preview.muzzle)
		local previewDirection = LocalToWorld(snapshot, Normalize(preview.forward), { 0, 0, 0 })
		gl.LineWidth(3)
		gl.Color(0.1, 0.9, 1, 1)
		DrawCross(previewAim, 6)
		DrawCross(previewCollision, 6)
		DrawCross(previewMuzzle, 6)
		DrawBox(previewCollision, snapshot.right, snapshot.up, snapshot.front, preview.collisionScale)
		gl.BeginEnd(GL.LINES, function()
			DrawLine(previewMuzzle, Add(previewMuzzle, Scale(previewDirection, 54)))
		end)
		gl.Text("CYAN: local preview only", previewMuzzle[1], previewMuzzle[2] + 9, previewMuzzle[3], 11, "oc")
	end

	local function BuildExport()
		local normalizedForward = Normalize(preview.forward)
		local muzzleCorrection = {
			preview.muzzle[1] - BASE_MUZZLE_LOCAL[1],
			preview.muzzle[2] - BASE_MUZZLE_LOCAL[2],
			preview.muzzle[3] - BASE_MUZZLE_LOCAL[3],
		}
		return string.format([[-- Generated by AOE Building Anchor Calibration. Review before merging.
-- Source DAT: b_west_castle_age3 (Unit 82) collision_size=(2,2,4), weapon_offset=(0,1,4)
-- Base profile: DAT (x,y,z) -> Recoil (right=x*60, up=z*30, front=y*60)
-- Raw muzzle from base profile: (%.3f,%.3f,%.3f)
-- Calibrated muzzle correction: (%.3f,%.3f,%.3f)
-- Collision centre uses aoe2_collision_local independently of aim_local.
return {
	["aoe_west_castle_age3"] = {
		collisionVolumeScales = "%.3f %.3f %.3f",
		customParams = {
			aoe2_aim_local = "%.3f %.3f %.3f",
			aoe2_collision_local = "%.3f %.3f %.3f",
			aoe2_weapon1_muzzle_local = "%.3f %.3f %.3f",
			aoe2_weapon1_forward_local = "%.3f %.3f %.3f",
		},
	},
}
]],
			BASE_MUZZLE_LOCAL[1], BASE_MUZZLE_LOCAL[2], BASE_MUZZLE_LOCAL[3],
			muzzleCorrection[1], muzzleCorrection[2], muzzleCorrection[3],
			preview.collisionScale[1], preview.collisionScale[2], preview.collisionScale[3],
			preview.aim[1], preview.aim[2], preview.aim[3],
			preview.collision[1], preview.collision[2], preview.collision[3],
			preview.muzzle[1], preview.muzzle[2], preview.muzzle[3],
			normalizedForward[1], normalizedForward[2], normalizedForward[3])
	end

	local function ExportPreview()
		local content = BuildExport()
		Spring.SetClipboard(content)
		Spring.CreateDir("LuaUI/Config/AOEAnchorCalibration")
		exportSerial = exportSerial + 1
		local path = string.format("LuaUI/Config/AOEAnchorCalibration/%s_override_%d_%d.lua", BUILDING_RESOURCE_ID, Spring.GetGameFrame(), exportSerial)
		local file = io.open(path, "w")
		if file ~= nil then
			file:write(content)
			file:close()
			lastExportStatus = "saved: " .. path
			Spring.Echo("[AOE Building Test] exported to clipboard and " .. path)
		else
			lastExportStatus = "clipboard only; file write failed"
			Spring.Echo("[AOE Building Test] copied export to clipboard; unable to write " .. path)
		end
	end

	local function AdjustSelected(direction, multiplier)
		local control = controls[selectedField]
		local delta = direction * control.step * multiplier
		if control.key ~= nil then
			preview[control.key] = math.max(control.minimum or -math.huge, math.min(control.maximum or math.huge, preview[control.key] + delta))
			Spring.SetConfigFloat("Aoe2UnitPixelsToWorld", preview.pixelScale, true)
		else
			control.value[control.index] = math.max(control.minimum or -math.huge, math.min(control.maximum or math.huge, control.value[control.index] + delta))
			if control.value == preview.muzzle then
				SendRuntimeMuzzleOverride()
			end
		end
	end

	function gadget:KeyPress(key, mods, isRepeat)
		if isRepeat then
			return false
		end
		local multiplier = mods and mods.shift and 10 or 1
		if key == 9 then
			selectedIndex = selectedIndex % TOWER_COUNT + 1
			return true
		elseif key == 273 then
			selectedField = ((selectedField - 2) % #controls) + 1
			return true
		elseif key == 274 then
			selectedField = selectedField % #controls + 1
			return true
		elseif key == 276 then
			AdjustSelected(-1, multiplier)
			return true
		elseif key == 275 then
			AdjustSelected(1, multiplier)
			return true
		elseif key == 114 then
			ResetPreview(true)
			return true
		elseif key == 101 then
			ExportPreview()
			return true
		elseif key == 98 then
			Spring.SendLuaRulesMsg(SPAWN_MESSAGE)
			return true
		end
		return false
	end

	function gadget:DrawWorld()
		if snapshots[1] == nil then
			return
		end
		gl.DepthTest(false)
		for index = 1, TOWER_COUNT do
			local snapshot = snapshots[index]
			if snapshot ~= nil then
				DrawSnapshot(snapshot, index)
			end
		end
		local selected = snapshots[selectedIndex]
		if selected ~= nil then
			DrawPreview(selected)
		end
		gl.LineWidth(1)
		gl.DepthTest(true)
	end

	function gadget:DrawScreen(viewSizeX, viewSizeY)
		local x = 20
		local y = viewSizeY - 28
		local selectedSnapshot = snapshots[selectedIndex]
		local _, forwardValid = Normalize(preview.forward)
		gl.Color(0, 0, 0, 0.65)
		gl.Rect(x - 8, y - (#controls + 12) * 15, x + 660, y + 8)
		gl.Color(1, 1, 1, 1)
		gl.Text("AOE Building Anchor Calibration (" .. BUILDING_DISPLAY_NAME .. ")  |  cyan = local preview", x, y, 13, "o")
		y = y - 17
		if selectedSnapshot == nil then
			gl.Color(1, 0.75, 0.2, 1)
			gl.Text(string.format("snapshot status: waiting for synced data (%d/%d)", snapshotCount, TOWER_COUNT), x, y, 12, "o")
		else
			gl.Color(0.35, 1, 0.45, 1)
			gl.Text(string.format("snapshot status: ready (%d/%d)    selected castle: %s (%d)", snapshotCount, TOWER_COUNT, selectedSnapshot.label, selectedSnapshot.unitID), x, y, 12, "o")
		end
		y = y - 17
		gl.Color(1, 1, 1, 1)
		gl.Text(string.format("[Tab] castle %d/%d    [R] reset    [E] export + clipboard    [B] spawn enemy CMD.FIGHT", selectedIndex, TOWER_COUNT), x, y, 12, "o")
		y = y - 17
		gl.Text("[Up/Down] field    [Left/Right] adjust    [Shift] x10", x, y, 11, "o")
		y = y - 15
		gl.Text("REAL: sprite scale + muzzle override    PREVIEW ONLY: aim / forward / collision scale", x, y, 11, "o")
		y = y - 15
		if runtimeMuzzleOverrideAvailable then
			gl.Color(runtimeMuzzleOverrideEnabled and 0.35 or 0.75, 1, runtimeMuzzleOverrideEnabled and 0.45 or 0.9, 1)
			gl.Text("runtime muzzle override: " .. (runtimeMuzzleOverrideEnabled and "ON; [R] restores UnitDef" or "OFF; using UnitDef"), x, y, 11, "o")
		else
			gl.Color(1, 0.3, 0.2, 1)
			gl.Text("runtime muzzle override: UNAVAILABLE (build with AOE_DEV_TOOL=1)", x, y, 11, "o")
		end
		y = y - 15
		gl.Color(1, 1, 1, 1)
		gl.Text("SAFE EXPORT: creates a new override + clipboard; never overwrites UnitDef or cache", x, y, 11, "o")
		y = y - 15
		gl.Text("Legend: foot=green  mid=purple  aim=red  muzzle=yellow  axes=RGB  preview=cyan", x, y, 11, "o")
		for index, control in ipairs(controls) do
			y = y - 15
			if index == selectedField then
				gl.Color(0.1, 0.9, 1, 1)
			else
				gl.Color(0.85, 0.85, 0.85, 1)
			end
			local value = control.key and preview[control.key] or control.value[control.index]
			gl.Text(string.format("%s = %.3f", control.label, value), x, y, 11, "o")
		end
		y = y - 17
		if forwardValid then
			gl.Color(0.75, 0.9, 1, 1)
		else
			gl.Color(1, 0.35, 0.25, 1)
		end
		gl.Text("forward status: " .. (forwardValid and "valid; export is normalized" or "ZERO VECTOR; preview/export use fallback 0 0 1"), x, y, 11, "o")
		y = y - 15
		gl.Color(0.75, 0.9, 1, 1)
		gl.Text("export status: " .. lastExportStatus, x, y, 11, "o")
		gl.Color(1, 1, 1, 1)
	end

	function gadget:RecvFromSynced(eventName, ...)
		if eventName == "aoe_building_test_muzzle_override_state" then
			runtimeMuzzleOverrideEnabled, runtimeMuzzleOverrideAvailable = ...
			return
		end
		if eventName ~= "aoe_building_test_snapshot" then
			return
		end
		local values = { ... }
		local function Vec(offset)
			return { values[offset], values[offset + 1], values[offset + 2] }
		end
		local index = values[1]
		if snapshots[index] == nil then
			snapshotCount = snapshotCount + 1
		end
		snapshots[index] = {
			unitID = values[2],
			label = values[3],
			base = Vec(4),
			mid = Vec(7),
			aim = Vec(10),
			front = Vec(13),
			right = Vec(16),
			up = Vec(19),
			muzzle = Vec(22),
			weaponDirection = Vec(25),
			collisionScale = Vec(28),
			collisionOffset = Vec(31),
			collisionCenter = Vec(34),
		}
		if index == selectedIndex and not previewCollisionScaleInitialized then
			CopyVector(preview.collisionScale, snapshots[index].collisionScale)
			previewCollisionScaleInitialized = true
		end
	end

	function gadget:Initialize()
		ResetPreview(false)
		-- The renderer derives the absolute bias from each frame's pixels below
		-- its foot point. This test-scene-only scale preserves the foot anchor
		-- while keeping the castle base in front of triangulated terrain.
		Spring.SetConfigFloat("Aoe2UnitBelowFootCameraBiasScale", BELOW_FOOT_CAMERA_BIAS_SCALE, true)
		local cameraApplied, cameraFov, cameraHeight, cameraAngle, featureDrawDistance, featureFadeDistance,
			projection = fixedTestCamera.Apply()
		Spring.SendCommands("debugcolvol")
		Spring.Echo(string.format(
			"[AOE Building Test] fixed camera applied=%s projection=%s fov=%.1f height=%.1f angle=%.1fdeg belowFootBiasScale=%.2f featureDraw=%.1f featureFade=%.1f; press B to spawn enemy, Tab to select castle",
			tostring(cameraApplied), projection, cameraFov, cameraHeight, cameraAngle, BELOW_FOOT_CAMERA_BIAS_SCALE, featureDrawDistance, featureFadeDistance))
	end

	return
end

local towers = {}
local centerX = Game.mapSizeX * 0.5
local centerZ = Game.mapSizeZ * 0.5
local lastSpawnFrame = -SPAWN_COOLDOWN
local spawnSerial = 0
local runtimeMuzzleOverride = nil
local setRuntimeMuzzleOverride = Spring.SetUnitAoe2WeaponMuzzleOverride

local towerLayout = {
	{ label = "SOUTH", x = -420, z = -420, facing = "south" },
	{ label = "EAST",  x =  420, z = -420, facing = "east"  },
	{ label = "NORTH", x = -420, z =  420, facing = "north" },
	{ label = "WEST",  x =  420, z =  420, facing = "west"  },
}

local function PublishRuntimeMuzzleOverrideState()
	SendToUnsynced(
		"aoe_building_test_muzzle_override_state",
		runtimeMuzzleOverride ~= nil,
		setRuntimeMuzzleOverride ~= nil
	)
end

local function ApplyRuntimeMuzzleOverride()
	if setRuntimeMuzzleOverride == nil then
		Spring.Echo("[AOE Building Test] runtime muzzle override unavailable; rebuild with AOE_DEV_TOOL=1")
		PublishRuntimeMuzzleOverrideState()
		return
	end

	local appliedCount = 0
	for _, tower in ipairs(towers) do
		if Spring.ValidUnitID(tower.unitID) then
			local applied
			if runtimeMuzzleOverride == nil then
				applied = setRuntimeMuzzleOverride(tower.unitID, 1)
			else
				applied = setRuntimeMuzzleOverride(
					tower.unitID, 1,
					runtimeMuzzleOverride[1], runtimeMuzzleOverride[2], runtimeMuzzleOverride[3])
			end
			if applied then
				appliedCount = appliedCount + 1
			end
		end
	end

	if runtimeMuzzleOverride == nil then
		Spring.Echo(string.format("[AOE Building Test] cleared runtime muzzle override for %d/%d castles", appliedCount, #towers))
	else
		Spring.Echo(string.format(
			"[AOE Building Test] applied runtime muzzle override to %d/%d castles; local=(%.3f, %.3f, %.3f)",
			appliedCount, #towers,
			runtimeMuzzleOverride[1], runtimeMuzzleOverride[2], runtimeMuzzleOverride[3]))
	end
	PublishRuntimeMuzzleOverrideState()
end

local function SendTowerSnapshot(index, tower)
	if not Spring.ValidUnitID(tower.unitID) then
		return
	end
	local baseX, baseY, baseZ, midX, midY, midZ, aimX, aimY, aimZ = Spring.GetUnitPosition(tower.unitID, true, true)
	local frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ = Spring.GetUnitDirection(tower.unitID)
	local muzzleX, muzzleY, muzzleZ, directionX, directionY, directionZ = Spring.GetUnitWeaponVectors(tower.unitID, 1)
	local scaleX, scaleY, scaleZ, offsetX, offsetY, offsetZ = Spring.GetUnitCollisionVolumeData(tower.unitID)
	if baseX == nil or midX == nil or frontX == nil or muzzleX == nil or scaleX == nil then
		return
	end
	-- CollisionVolume offsets are relative to midPos, not aimPos. The CUnit
	-- AOE anchor path makes midPos + offset land at collision_local.
	local collisionX = midX + rightX * offsetX + upX * offsetY + frontX * offsetZ
	local collisionY = midY + rightY * offsetX + upY * offsetY + frontY * offsetZ
	local collisionZ = midZ + rightZ * offsetX + upZ * offsetY + frontZ * offsetZ
	SendToUnsynced(
		"aoe_building_test_snapshot", index, tower.unitID, tower.label,
		baseX, baseY, baseZ, midX, midY, midZ, aimX, aimY, aimZ,
		frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ,
		muzzleX, muzzleY, muzzleZ, directionX, directionY, directionZ,
		scaleX, scaleY, scaleZ, offsetX, offsetY, offsetZ, collisionX, collisionY, collisionZ)
end

local function SpawnEnemy()
	local frame = Spring.GetGameFrame()
	if frame - lastSpawnFrame < SPAWN_COOLDOWN then
		return
	end
	lastSpawnFrame = frame
	spawnSerial = spawnSerial + 1
	local angle = (spawnSerial * 2.3999632297) % (math.pi * 2)
	local radius = 950 + (spawnSerial % 5) * 28
	local x = math.max(64, math.min(Game.mapSizeX - 64, centerX + math.cos(angle) * radius))
	local z = math.max(64, math.min(Game.mapSizeZ - 64, centerZ + math.sin(angle) * radius))
	local unitID = Spring.CreateUnit(ENEMY_NAME, x, Spring.GetGroundHeight(x, z), z, "south", 1)
	if unitID == nil then
		Spring.Echo("[AOE Building Test] failed to spawn enemy archer")
		return
	end
	local targetY = Spring.GetGroundHeight(centerX, centerZ)
	Spring.GiveOrderToUnit(unitID, CMD.FIGHT, { centerX, targetY, centerZ }, {})
	Spring.Echo(string.format(
		"[AOE Building Test] spawned enemy archer=%d at (%.1f, %.1f), CMD.FIGHT center=(%.1f, %.1f)",
		unitID, x, z, centerX, centerZ))
end

function gadget:GameStart()
	Spring.SetGlobalLos(0, true)
	for index, entry in ipairs(towerLayout) do
		local x = centerX + entry.x
		local z = centerZ + entry.z
		local unitID = Spring.CreateUnit(BUILDING_NAME, x, Spring.GetGroundHeight(x, z), z, entry.facing, 0)
		if unitID == nil then
			error("[AOE Building Test] failed to create castle " .. entry.label)
		end
		towers[index] = { unitID = unitID, label = entry.label }
		Spring.Echo(string.format("[AOE Building Test] castle=%d facing=%s position=(%.1f, %.1f)",
			unitID, entry.facing, x, z))
	end
	PublishRuntimeMuzzleOverrideState()
end

function gadget:GameFrame(frame)
	if frame % SNAPSHOT_PERIOD == 0 then
		for index, tower in ipairs(towers) do
			SendTowerSnapshot(index, tower)
		end
	end
end

function gadget:RecvLuaMsg(message, playerID)
	if message == SPAWN_MESSAGE then
		SpawnEnemy()
		return true
	end
	if message == CONTROL_MESSAGE_PREFIX .. "muzzle_reset" then
		runtimeMuzzleOverride = nil
		ApplyRuntimeMuzzleOverride()
		return true
	end
	local muzzleX, muzzleY, muzzleZ = string.match(
		message,
		"^" .. CONTROL_MESSAGE_PREFIX .. "muzzle:([%+%-%.%deE]+):([%+%-%.%deE]+):([%+%-%.%deE]+)$")
	if muzzleX ~= nil and muzzleY ~= nil and muzzleZ ~= nil then
		runtimeMuzzleOverride = { tonumber(muzzleX), tonumber(muzzleY), tonumber(muzzleZ) }
		ApplyRuntimeMuzzleOverride()
		return true
	end
	return false
end
