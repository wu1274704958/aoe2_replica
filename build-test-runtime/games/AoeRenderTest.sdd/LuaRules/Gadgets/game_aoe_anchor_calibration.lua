function gadget:GetInfo()
	return {
		name = "AOE Remote Anchor Calibration",
		desc = "Static all-direction visual calibration scene for AOE remote-unit anchors",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = 1,
		enabled = true,
	}
end

local CALIBRATION_DIRECTION_COUNT = 16
local CALIBRATION_COLUMNS = 4
local SNAPSHOT_PERIOD = 15
local GROUND_ATTACK_START_FRAME = 30
-- Every calibration unit gets its own hostile target. Keeping that target on
-- the unit's forward axis and inside weapon range makes all 16 sprite sectors
-- test the native object-attack path without asking units to form up first.
local CALIBRATION_TARGET_TEAM = 1
local CALIBRATION_TARGET_HEALTH = 100000
local CALIBRATION_TARGET_EDGE_MARGIN = 32
local CONTROL_MESSAGE_PREFIX = "aoe_anchor_calibration:"

local function ReadBooleanOption(options, name, defaultValue)
	local value = options[name]
	if value == nil then
		return defaultValue
	end
	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function ReadNumberOption(options, name, defaultValue, minimum, maximum)
	local value = tonumber(options[name]) or defaultValue
	return math.max(minimum, math.min(maximum, value))
end

local options = Spring.GetModOptions()
if not ReadBooleanOption(options, "aoe_anchor_calibration", false) then
	return
end
local calibrationUnitName = tostring(options.aoe_anchor_calibration_unit or "aoe_chukonu")
local calibrationTargetUnitName = tostring(options.aoe_anchor_calibration_target_unit or "aoe_spearman")
local calibrationTargetDistance = ReadNumberOption(options, "aoe_anchor_calibration_target_distance", 180, 32, 1024)
local calibrationMoveState = ReadNumberOption(options, "aoe_anchor_calibration_move_state", 0, 0, 2)
local calibrationUnitDef = UnitDefNames[calibrationUnitName] and UnitDefs[UnitDefNames[calibrationUnitName].id]
if calibrationUnitDef == nil then
	error("[AOE Anchor Calibration] unknown calibration unit: " .. calibrationUnitName)
end
local calibrationBaseMuzzleLocal = { 0, 45, 30 }
do
	local muzzle = (calibrationUnitDef.customParams or {}).aoe2_weapon1_muzzle_local or ""
	local x, y, z = string.match(muzzle, "([^%s]+)%s+([^%s]+)%s+([^%s]+)")
	calibrationBaseMuzzleLocal = { tonumber(x) or 0, tonumber(y) or 45, tonumber(z) or 30 }
end
local calibrationGroundAttack = ReadBooleanOption(options, "aoe_anchor_calibration_ground_attack", false)

if not gadgetHandler:IsSyncedCode() then
	local fixedTestCamera = VFS.Include("LuaRules/aoe_fixed_test_camera.lua")
	local snapshots = {}
	local selectedIndex = 1
	local selectedField = 1
	local exportSerial = 0
	local snapshotCount = 0
	local lastExportStatus = "not exported"
	local firstSnapshotLogged = false
	local runtimeMuzzleOverrideEnabled = false
	local runtimeMuzzleOverrideAvailable = true
	local preview = {
		aim = { 0, 30, 0 },
		muzzle = { 0, 55.5, 30 },
		forward = { 0, 0, 1 },
		collisionScale = { 24, 60, 24 },
		pixelScale = 0.55,
	}
	local previewCollisionScaleInitialized = false
	local controls = {
		{ label = "aim_local.x", value = preview.aim, index = 1, step = 1 },
		{ label = "aim_local.y", value = preview.aim, index = 2, step = 1 },
		{ label = "aim_local.z", value = preview.aim, index = 3, step = 1 },
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
		{ label = "heading (real unit)", value = nil, step = math.rad(5), heading = true },
	}

	local function CopyVector(destination, source)
		destination[1], destination[2], destination[3] = source[1], source[2], source[3]
	end

	local function ParseVector(value, fallback)
		local x, y, z = string.match(value or "", "([^%s]+)%s+([^%s]+)%s+([^%s]+)")
		return { tonumber(x) or fallback[1], tonumber(y) or fallback[2], tonumber(z) or fallback[3] }
	end

	local function ResetPreview(clearRuntimeOverride)
		local unitDef = UnitDefs[UnitDefNames[calibrationUnitName].id]
		local params = unitDef.customParams or {}
		CopyVector(preview.aim, ParseVector(params.aoe2_aim_local, { 0, 30, 0 }))
		CopyVector(preview.muzzle, ParseVector(params.aoe2_weapon1_muzzle_local, { 0, 55.5, 30 }))
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

	local function Add(a, b)
		return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
	end

	local function Scale(a, scalar)
		return { a[1] * scalar, a[2] * scalar, a[3] * scalar }
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
		return Add(origin, Add(Scale(snapshot.right, localPoint[1]), Add(Scale(snapshot.up, localPoint[2]), Scale(snapshot.front, localPoint[3]))))
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

	local function DrawCylinder(center, right, up, front, scale)
		local radiusX = scale[1] * 0.5
		local radiusZ = scale[3] * 0.5
		local halfHeight = scale[2] * 0.5
		local bottom = Add(center, Scale(up, -halfHeight))
		local top = Add(center, Scale(up, halfHeight))
		local segments = 16
		local function Ring(origin)
			gl.BeginEnd(GL.LINE_LOOP, function()
				for index = 0, segments - 1 do
					local angle = index * math.pi * 2 / segments
					local point = Add(origin, Add(Scale(right, math.cos(angle) * radiusX), Scale(front, math.sin(angle) * radiusZ)))
					gl.Vertex(point[1], point[2], point[3])
				end
			end)
		end
		Ring(bottom)
		Ring(top)
		gl.BeginEnd(GL.LINES, function()
			for index = 0, segments - 1, 4 do
				local angle = index * math.pi * 2 / segments
				local side = Add(Scale(right, math.cos(angle) * radiusX), Scale(front, math.sin(angle) * radiusZ))
				DrawLine(Add(bottom, side), Add(top, side))
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

	local function DrawReferenceTrajectory(muzzle, aim)
		local previous = muzzle
		gl.BeginEnd(GL.LINES, function()
			for index = 1, 10 do
				local t = index / 10
				local bow = math.sin(t * math.pi) * 18
				local point = {
					muzzle[1] + (aim[1] - muzzle[1]) * t,
					muzzle[2] + (aim[2] - muzzle[2]) * t + bow,
					muzzle[3] + (aim[3] - muzzle[3]) * t,
				}
				if index % 2 == 0 then
					DrawLine(previous, point)
				end
				previous = point
			end
		end)
	end

	local function DrawSnapshot(snapshot, index)
		gl.LineWidth((index == selectedIndex) and 2.5 or 1.25)
		gl.Color(0.2, 1.0, 0.2, 1)
		DrawCross(snapshot.base, 4)
		gl.Color(0.85, 0.2, 1.0, 1)
		DrawCross(snapshot.mid, 3)
		gl.Color(1, 0.25, 0.25, 1)
		DrawCross(snapshot.aim, 4)
		gl.Color(1, 0.82, 0.1, 1)
		DrawCross(snapshot.muzzle, 4)
		gl.Color(0.8, 0.1, 0.9, 0.85)
		DrawCylinder(snapshot.collisionCenter, snapshot.right, snapshot.up, snapshot.front, snapshot.collisionScale)
		DrawAxes(snapshot)
		gl.Color(1, 0.82, 0.1, 1)
		gl.BeginEnd(GL.LINES, function()
			DrawLine(snapshot.muzzle, Add(snapshot.muzzle, Scale(snapshot.weaponDirection, 38)))
		end)
		gl.Text(string.format("%02d  %.0fdeg", index, snapshot.headingDegrees), snapshot.base[1], snapshot.base[2] + 8, snapshot.base[3], 11, "oc")
	end

	local function DrawPreview(snapshot)
		local previewAim = LocalToWorld(snapshot, preview.aim)
		local previewMuzzle = LocalToWorld(snapshot, preview.muzzle)
		local previewCenter = previewAim
		local normalizedForward = Normalize(preview.forward)
		local previewDirection = LocalToWorld(snapshot, normalizedForward, { 0, 0, 0 })
		gl.LineWidth(3)
		gl.Color(0.1, 0.9, 1, 1)
		DrawCross(previewAim, 5)
		DrawCross(previewMuzzle, 5)
		DrawCylinder(previewCenter, snapshot.right, snapshot.up, snapshot.front, preview.collisionScale)
		gl.BeginEnd(GL.LINES, function()
			DrawLine(previewMuzzle, Add(previewMuzzle, Scale(previewDirection, 42)))
		end)
		gl.Color(0.1, 0.9, 1, 0.85)
		DrawReferenceTrajectory(previewMuzzle, previewAim)
		gl.Text("CYAN: local preview only", previewMuzzle[1], previewMuzzle[2] + 8, previewMuzzle[3], 11, "oc")
	end

	function gadget:DrawWorld()
		if snapshots[1] == nil then
			return
		end
		gl.DepthTest(false)
		for index = 1, CALIBRATION_DIRECTION_COUNT do
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

	local function BuildExport()
		local normalizedForward = Normalize(preview.forward)
		local muzzleCorrection = {
			preview.muzzle[1] - calibrationBaseMuzzleLocal[1],
			preview.muzzle[2] - calibrationBaseMuzzleLocal[2],
			preview.muzzle[3] - calibrationBaseMuzzleLocal[3],
		}
		return string.format([[-- Generated by AOE Anchor Calibration. Review before merging.
-- UnitDef: %s
-- Base profile: DAT (x,y,z) -> Recoil (right=x*60, up=z*30, front=y*60)
-- Raw muzzle from base profile: (%.3f,%.3f,%.3f)
-- Calibrated muzzle correction: (%.3f,%.3f,%.3f)
-- Collision centre follows aoe2_aim_local in CUnit::PreInit.
return {
	["%s"] = {
		collisionVolumeScales = "%.3f %.3f %.3f",
		customParams = {
			aoe2_aim_local = "%.3f %.3f %.3f",
			aoe2_weapon1_muzzle_local = "%.3f %.3f %.3f",
			aoe2_weapon1_forward_local = "%.3f %.3f %.3f",
		},
	},
}
]],
			calibrationUnitName,
			calibrationBaseMuzzleLocal[1], calibrationBaseMuzzleLocal[2], calibrationBaseMuzzleLocal[3],
			muzzleCorrection[1], muzzleCorrection[2], muzzleCorrection[3],
			calibrationUnitName,
			preview.collisionScale[1], preview.collisionScale[2], preview.collisionScale[3],
			preview.aim[1], preview.aim[2], preview.aim[3],
			preview.muzzle[1], preview.muzzle[2], preview.muzzle[3],
			normalizedForward[1], normalizedForward[2], normalizedForward[3])
	end

	local function ExportPreview()
		local content = BuildExport()
		Spring.SetClipboard(content)
		Spring.CreateDir("LuaUI/Config/AOEAnchorCalibration")
		exportSerial = exportSerial + 1
		local path = string.format(
			"LuaUI/Config/AOEAnchorCalibration/%s_override_%d_%d.lua",
			calibrationUnitName, Spring.GetGameFrame(), exportSerial)
		local file = io.open(path, "w")
		if file ~= nil then
			file:write(content)
			file:close()
			lastExportStatus = "saved: " .. path
			Spring.Echo("[AOE Anchor Calibration] exported to clipboard and " .. path)
		else
			lastExportStatus = "clipboard only; file write failed"
			Spring.Echo("[AOE Anchor Calibration] copied export to clipboard; unable to write " .. path)
		end
	end

	local function AdjustSelected(direction, multiplier)
		local control = controls[selectedField]
		if control.heading then
			Spring.SendLuaRulesMsg(string.format(
				"%sheading:%d:%.17g",
				CONTROL_MESSAGE_PREFIX, selectedIndex, direction * control.step * multiplier))
			return
		end
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
			selectedIndex = selectedIndex % CALIBRATION_DIRECTION_COUNT + 1
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
		elseif key == 103 then
			Spring.SendLuaRulesMsg(CONTROL_MESSAGE_PREFIX .. "ground_attack_toggle")
			return true
		end
		return false
	end

	function gadget:DrawScreen(viewSizeX, viewSizeY)
		local x = 20
		local y = viewSizeY - 28
		local selectedSnapshot = snapshots[selectedIndex]
		local _, forwardValid = Normalize(preview.forward)
		gl.Color(0, 0, 0, 0.65)
		gl.Rect(x - 8, y - (#controls + 12) * 15, x + 620, y + 8)
		gl.Color(1, 1, 1, 1)
		gl.Text("AOE Remote Anchor Calibration  |  cyan = local preview", x, y, 13, "o")
		y = y - 17
		if selectedSnapshot == nil then
			gl.Color(1, 0.75, 0.2, 1)
			gl.Text(string.format("snapshot status: waiting for synced data (%d/%d)", snapshotCount, CALIBRATION_DIRECTION_COUNT), x, y, 12, "o")
		else
			gl.Color(0.35, 1, 0.45, 1)
			gl.Text(string.format("snapshot status: ready (%d/%d)    selected UnitID: %d", snapshotCount, CALIBRATION_DIRECTION_COUNT, selectedSnapshot.unitID), x, y, 12, "o")
		end
		y = y - 17
		gl.Color(1, 1, 1, 1)
		gl.Text(string.format("selected direction: %02d    [Tab] next    [R] reset    [E] export + clipboard", selectedIndex), x, y, 12, "o")
		y = y - 17
		gl.Color(calibrationGroundAttack and 0.35 or 1, calibrationGroundAttack and 1 or 0.75, 0.35, 1)
		gl.Text(string.format("[G] 16 forward hostile-target attacks: %s", calibrationGroundAttack and "ON" or "OFF"), x, y, 12, "o")
		y = y - 17
		gl.Color(1, 1, 1, 1)
		gl.Text("[Up/Down] field    [Left/Right] adjust    [Shift] x10    heading is real; others are preview", x, y, 11, "o")
		y = y - 15
		gl.Text("REAL: heading + sprite scale + muzzle override    PREVIEW ONLY: aim / forward / collision scale", x, y, 11, "o")
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
			local value = control.heading and (selectedSnapshot and selectedSnapshot.headingDegrees or 0) or (control.key and preview[control.key] or control.value[control.index])
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
		if eventName == "aoe_anchor_calibration_ground_attack_state" then
			calibrationGroundAttack = (...)
			return
		end
		if eventName == "aoe_anchor_calibration_muzzle_override_state" then
			runtimeMuzzleOverrideEnabled, runtimeMuzzleOverrideAvailable = ...
			return
		end
		if eventName ~= "aoe_anchor_calibration_snapshot" then
			return
		end
		local values = { ... }
		local index = values[1]
		local function Vec(offset)
			return { values[offset], values[offset + 1], values[offset + 2] }
		end
		local front = Vec(12)
		local headingDegrees = math.deg(math.atan2(front[1], front[3]))
		if snapshots[index] == nil then
			snapshotCount = snapshotCount + 1
		end
		snapshots[index] = {
			unitID = values[2],
			base = Vec(3),
			mid = Vec(6),
			aim = Vec(9),
			front = front,
			right = Vec(15),
			up = Vec(18),
			muzzle = Vec(21),
			weaponDirection = Vec(24),
			collisionScale = Vec(27),
			collisionOffset = Vec(30),
			collisionCenter = Vec(33),
			headingDegrees = headingDegrees,
		}
		if index == selectedIndex and not previewCollisionScaleInitialized then
			CopyVector(preview.collisionScale, snapshots[index].collisionScale)
			previewCollisionScaleInitialized = true
		end
		if not firstSnapshotLogged then
			firstSnapshotLogged = true
			Spring.Echo("[AOE Anchor Calibration] unsynced received first runtime snapshot")
		end
	end

	function gadget:Initialize()
		ResetPreview(false)
		local cameraApplied, cameraFov, cameraHeight, cameraAngle, featureDrawDistance, featureFadeDistance,
			cameraProjection, cameraOrthoHeight = fixedTestCamera.Apply()
		Spring.SendCommands("debugcolvol")
		Spring.Echo("[AOE Anchor Calibration] unsynced overlay initialized")
		Spring.Echo(string.format(
			"[AOE Anchor Calibration] fixed camera applied=%s projection=%s fov=%.1f orthoHeight=%.1f height=%.1f angle=%.1fdeg featureDraw=%.1f featureFade=%.1f",
			tostring(cameraApplied), cameraProjection, cameraFov, cameraOrthoHeight,
			cameraHeight, cameraAngle, featureDrawDistance, featureFadeDistance))
		Spring.Echo("[AOE Anchor Calibration] native /debugcolvol enabled for overlay comparison")
	end

	return
end

local calibrationUnits = {}
local calibrationTargets = {}
local calibrationSpacing = ReadNumberOption(options, "aoe_anchor_calibration_spacing", 260, 64, 1024)
local runtimeMuzzleOverride = nil
local setRuntimeMuzzleOverride = Spring.SetUnitAoe2WeaponMuzzleOverride

local function PublishRuntimeMuzzleOverrideState()
	SendToUnsynced(
		"aoe_anchor_calibration_muzzle_override_state",
		runtimeMuzzleOverride ~= nil,
		setRuntimeMuzzleOverride ~= nil
	)
end

local function ApplyRuntimeMuzzleOverride()
	if setRuntimeMuzzleOverride == nil then
		Spring.Echo("[AOE Anchor Calibration] runtime muzzle override unavailable; rebuild with AOE_DEV_TOOL=1")
		PublishRuntimeMuzzleOverrideState()
		return
	end

	local appliedCount = 0
	for _, unitID in ipairs(calibrationUnits) do
		local applied
		if runtimeMuzzleOverride == nil then
			applied = setRuntimeMuzzleOverride(unitID, 1)
		else
			applied = setRuntimeMuzzleOverride(
				unitID, 1,
				runtimeMuzzleOverride[1], runtimeMuzzleOverride[2], runtimeMuzzleOverride[3])
		end
		if applied then
			appliedCount = appliedCount + 1
		end
	end

	if runtimeMuzzleOverride == nil then
		Spring.Echo(string.format(
			"[AOE Anchor Calibration] cleared runtime muzzle override for %d/%d units",
			appliedCount, #calibrationUnits))
	else
		Spring.Echo(string.format(
			"[AOE Anchor Calibration] applied runtime muzzle override to %d/%d units; local=(%.3f, %.3f, %.3f)",
			appliedCount, #calibrationUnits,
			runtimeMuzzleOverride[1], runtimeMuzzleOverride[2], runtimeMuzzleOverride[3]))
	end
	PublishRuntimeMuzzleOverrideState()
end

local function GiveHostileTargetAttack(index, unitID)
	local targetID = calibrationTargets[index]
	if not Spring.ValidUnitID(unitID) or not Spring.ValidUnitID(targetID) then
		return false
	end
	return Spring.GiveOrderToUnit(unitID, CMD.ATTACK, { targetID }, {})
end

local function GiveCalibrationHostileTargetAttacks()
	local orderCount = 0
	for index, unitID in ipairs(calibrationUnits) do
		if GiveHostileTargetAttack(index, unitID) then
			orderCount = orderCount + 1
		end
	end
	Spring.Echo(string.format(
		"[AOE Anchor Calibration] issued forward hostile-target attack orders to %d/%d unit pairs; distance<=%.1f",
		orderCount, #calibrationUnits, calibrationTargetDistance))
end

local function GetForwardTargetPosition(unitID)
	local unitX, _, unitZ = Spring.GetUnitPosition(unitID)
	local frontX, _, frontZ = Spring.GetUnitDirection(unitID)
	if unitX == nil or frontX == nil then
		return nil
	end

	-- Do not clamp a point after it has been calculated: that would move a
	-- boundary target off its unit's forward axis. Reduce its distance instead.
	local distance = calibrationTargetDistance
	if frontX > 0 then
		distance = math.min(distance, (Game.mapSizeX - CALIBRATION_TARGET_EDGE_MARGIN - unitX) / frontX)
	elseif frontX < 0 then
		distance = math.min(distance, (unitX - CALIBRATION_TARGET_EDGE_MARGIN) / -frontX)
	end
	if frontZ > 0 then
		distance = math.min(distance, (Game.mapSizeZ - CALIBRATION_TARGET_EDGE_MARGIN - unitZ) / frontZ)
	elseif frontZ < 0 then
		distance = math.min(distance, (unitZ - CALIBRATION_TARGET_EDGE_MARGIN) / -frontZ)
	end
	distance = math.max(0, distance)
	local targetX = unitX + frontX * distance
	local targetZ = unitZ + frontZ * distance
	return targetX, Spring.GetGroundHeight(targetX, targetZ), targetZ, distance
end

local function PositionHostileTarget(index, unitID)
	local targetID = calibrationTargets[index]
	local targetX, _, targetZ = GetForwardTargetPosition(unitID)
	if not Spring.ValidUnitID(targetID) or targetX == nil then
		return false
	end
	Spring.SetUnitPosition(targetID, targetX, targetZ)
	return true
end

local function SetCalibrationGroundAttack(enabled)
	calibrationGroundAttack = enabled
	if calibrationGroundAttack then
		-- The calibration scene normally holds fire so the units stay static.
		-- Restore Fire At Will before asking native CommandAI to attack the
		-- hostile target, otherwise the target command can remain queued without
		-- ever reaching CWeapon.
		for _, unitID in ipairs(calibrationUnits) do
			if Spring.ValidUnitID(unitID) then
				Spring.GiveOrderToUnit(unitID, CMD.FIRE_STATE, { 2 }, {})
			end
		end
		GiveCalibrationHostileTargetAttacks()
	else
		local orderCount = 0
		for _, unitID in ipairs(calibrationUnits) do
			if Spring.ValidUnitID(unitID) and Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, {}) then
				orderCount = orderCount + 1
			end
			if Spring.ValidUnitID(unitID) then
				Spring.GiveOrderToUnit(unitID, CMD.FIRE_STATE, { 0 }, {})
			end
		end
		Spring.Echo(string.format(
			"[AOE Anchor Calibration] stopped hostile-target attack for %d/%d units",
			orderCount, #calibrationUnits))
	end
	SendToUnsynced("aoe_anchor_calibration_ground_attack_state", calibrationGroundAttack)
end

local function SendSnapshot(index, unitID)
	if not Spring.ValidUnitID(unitID) then
		return
	end
	local baseX, baseY, baseZ, midX, midY, midZ, aimX, aimY, aimZ = Spring.GetUnitPosition(unitID, true, true)
	local frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ = Spring.GetUnitDirection(unitID)
	local muzzleX, muzzleY, muzzleZ, directionX, directionY, directionZ = Spring.GetUnitWeaponVectors(unitID, 1)
	local scaleX, scaleY, scaleZ, offsetX, offsetY, offsetZ = Spring.GetUnitCollisionVolumeData(unitID)
	if baseX == nil or frontX == nil or muzzleX == nil or scaleX == nil then
		return
	end
	local collisionX = midX + rightX * offsetX + upX * offsetY + frontX * offsetZ
	local collisionY = midY + rightY * offsetX + upY * offsetY + frontY * offsetZ
	local collisionZ = midZ + rightZ * offsetX + upZ * offsetY + frontZ * offsetZ
	SendToUnsynced(
		"aoe_anchor_calibration_snapshot", index, unitID,
		baseX, baseY, baseZ, midX, midY, midZ, aimX, aimY, aimZ,
		frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ,
		muzzleX, muzzleY, muzzleZ, directionX, directionY, directionZ,
		scaleX, scaleY, scaleZ, offsetX, offsetY, offsetZ, collisionX, collisionY, collisionZ
	)
end

local function SendSnapshots()
	for index, unitID in ipairs(calibrationUnits) do
		SendSnapshot(index, unitID)
	end
end

local function SetCalibrationHeading(index, radians)
	local unitID = calibrationUnits[index]
	if unitID == nil or not Spring.ValidUnitID(unitID) then
		return
	end
	local frontX, _, frontZ = Spring.GetUnitDirection(unitID)
	local current = math.atan2(frontX, frontZ)
	local heading = current + radians
	local directionX = math.sin(heading)
	local directionZ = math.cos(heading)
	Spring.SetUnitDirection(unitID, directionX, 0, directionZ, -directionZ, 0, directionX)
	PositionHostileTarget(index, unitID)
	if calibrationGroundAttack then
		GiveHostileTargetAttack(index, unitID)
	end
	SendSnapshot(index, unitID)
end

local function SpawnCalibrationScene()
	local rows = math.ceil(CALIBRATION_DIRECTION_COUNT / CALIBRATION_COLUMNS)
	local width = (CALIBRATION_COLUMNS - 1) * calibrationSpacing
	local depth = (rows - 1) * calibrationSpacing
	local margin = 64
	if width + margin * 2 > Game.mapSizeX or depth + margin * 2 > Game.mapSizeZ then
		error(string.format("[AOE Anchor Calibration] layout %.1fx%.1f does not fit map %dx%d", width, depth, Game.mapSizeX, Game.mapSizeZ))
	end
	local originX = Game.mapSizeX * 0.5 - width * 0.5
	local originZ = Game.mapSizeZ * 0.5 - depth * 0.5
	for index = 1, CALIBRATION_DIRECTION_COUNT do
		local column = (index - 1) % CALIBRATION_COLUMNS
		local row = math.floor((index - 1) / CALIBRATION_COLUMNS)
		local x = originX + column * calibrationSpacing
		local z = originZ + row * calibrationSpacing
		local unitID = Spring.CreateUnit(calibrationUnitName, x, Spring.GetGroundHeight(x, z), z, "south", 0)
		if unitID == nil then
			error("[AOE Anchor Calibration] failed to create " .. calibrationUnitName)
		end
		local heading = (index - 1) * math.pi * 2 / CALIBRATION_DIRECTION_COUNT
		local frontX = math.sin(heading)
		local frontZ = math.cos(heading)
		Spring.SetUnitDirection(unitID, frontX, 0, frontZ, -frontZ, 0, frontX)
		Spring.GiveOrderToUnit(unitID, CMD.MOVE_STATE, { calibrationMoveState }, {})
		Spring.GiveOrderToUnit(unitID, CMD.FIRE_STATE, { 0 }, {})
		calibrationUnits[index] = unitID
		local targetX, targetY, targetZ = GetForwardTargetPosition(unitID)
		local targetID = Spring.CreateUnit(
			calibrationTargetUnitName, targetX, targetY, targetZ, "south", CALIBRATION_TARGET_TEAM)
		if targetID == nil then
			error("[AOE Anchor Calibration] failed to create hostile target for unit " .. index)
		end
		-- Targets are durable passive markers; they must not retaliate or vanish
		-- while an operator compares the same direction repeatedly.
		Spring.SetUnitMaxHealth(targetID, CALIBRATION_TARGET_HEALTH)
		Spring.SetUnitHealth(targetID, { health = CALIBRATION_TARGET_HEALTH })
		Spring.GiveOrderToUnit(targetID, CMD.FIRE_STATE, { 0 }, {})
		calibrationTargets[index] = targetID
	end
	Spring.SetGlobalLos(0, true)
	if runtimeMuzzleOverride ~= nil then
		ApplyRuntimeMuzzleOverride()
	else
		PublishRuntimeMuzzleOverrideState()
	end
	Spring.Echo(string.format(
		"[AOE Anchor Calibration] created %d %s/%s forward unit-target pairs; spacing=%.1f moveState=%d hostileTargetAttack=%s",
		CALIBRATION_DIRECTION_COUNT, calibrationUnitName, calibrationTargetUnitName,
		calibrationSpacing, calibrationMoveState, tostring(calibrationGroundAttack)))
end

function gadget:GameStart()
	SpawnCalibrationScene()
end

function gadget:GameFrame(frame)
	if calibrationGroundAttack and frame == GROUND_ATTACK_START_FRAME then
		GiveCalibrationHostileTargetAttacks()
	end
	if frame == 15 or frame % SNAPSHOT_PERIOD == 0 then
		SendSnapshots()
	end
end

function gadget:RecvLuaMsg(message, playerID)
	if message == CONTROL_MESSAGE_PREFIX .. "ground_attack_toggle" then
		SetCalibrationGroundAttack(not calibrationGroundAttack)
		return true
	end
	local index, radians = string.match(message, "^" .. CONTROL_MESSAGE_PREFIX .. "heading:(%d+):([%+%-%.%deE]+)$")
	if index ~= nil and radians ~= nil then
		SetCalibrationHeading(tonumber(index), tonumber(radians))
		return true
	end
	if message == CONTROL_MESSAGE_PREFIX .. "muzzle_reset" then
		runtimeMuzzleOverride = nil
		ApplyRuntimeMuzzleOverride()
		SendSnapshots()
		return true
	end
	local muzzleX, muzzleY, muzzleZ = string.match(
		message,
		"^" .. CONTROL_MESSAGE_PREFIX .. "muzzle:([%+%-%.%deE]+):([%+%-%.%deE]+):([%+%-%.%deE]+)$")
	if muzzleX ~= nil and muzzleY ~= nil and muzzleZ ~= nil then
		runtimeMuzzleOverride = { tonumber(muzzleX), tonumber(muzzleY), tonumber(muzzleZ) }
		ApplyRuntimeMuzzleOverride()
		SendSnapshots()
		return true
	end
	return false
end
