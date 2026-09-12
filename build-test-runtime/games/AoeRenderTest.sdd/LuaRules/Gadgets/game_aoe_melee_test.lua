function gadget:GetInfo()
	return {
		name = "AOE Melee Test",
		desc = "All-direction Camel Scout melee calibration and native battle test",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = 2,
		enabled = true,
	}
end

local UNIT_NAME = "aoe_light_cavalry"
local WEAPON_NAME = "aoe_light_cavalry_melee"
local DIRECTION_COUNT = 16
local COLUMN_COUNT = 4
local SNAPSHOT_PERIOD = 5
local CONTROL_PREFIX = "aoe_melee_test:"
local DEFAULT_ORIGIN = { 0, 30, 0 }
local DEFAULT_COLLISION = { 30, 60, 30 }
local DEFAULT_RANGE = 32

local options = Spring.GetModOptions()

local function ReadBoolean(name, defaultValue)
	local value = options[name]
	if value == nil then
		return defaultValue
	end
	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function ReadNumber(name, defaultValue, minimum, maximum)
	local value = tonumber(options[name]) or defaultValue
	return math.max(minimum, math.min(maximum, value))
end

local calibrationEnabled = ReadBoolean("aoe_melee_calibration", false)
local battleEnabled = ReadBoolean("aoe_melee_battle", false)
if not calibrationEnabled and not battleEnabled then
	return
end

if not gadgetHandler:IsSyncedCode() then
	local fixedTestCamera = VFS.Include("LuaRules/aoe_fixed_test_camera.lua")
	local snapshots = {}
	local selectedIndex = 1
	local selectedField = 1
	local showAnchors = true
	local showCollision = true
	local showRange = true
	local autoAttack = false
	local damageEnabled = ReadBoolean("aoe_melee_damage", true)
	local attackMode = "stopped"
	local exportSerial = 0
	local lastExportStatus = "not exported"
	local preview = {
		origin = { DEFAULT_ORIGIN[1], DEFAULT_ORIGIN[2], DEFAULT_ORIGIN[3] },
		collision = { DEFAULT_COLLISION[1], DEFAULT_COLLISION[2], DEFAULT_COLLISION[3] },
		range = DEFAULT_RANGE,
	}
	local controls = {
		{ label = "attack_origin.x", vector = preview.origin, index = 1, step = 1, kind = "origin" },
		{ label = "attack_origin.y", vector = preview.origin, index = 2, step = 1, kind = "origin" },
		{ label = "attack_origin.z", vector = preview.origin, index = 3, step = 1, kind = "origin" },
		{ label = "collision.x", vector = preview.collision, index = 1, step = 1, minimum = 1, kind = "collision" },
		{ label = "collision.y", vector = preview.collision, index = 2, step = 1, minimum = 1, kind = "collision" },
		{ label = "collision.z", vector = preview.collision, index = 3, step = 1, minimum = 1, kind = "collision" },
		{ label = "weapon.range", key = "range", step = 1, minimum = 1, maximum = 256, kind = "range" },
	}

	local function Add(a, b)
		return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
	end

	local function Scale(a, scalar)
		return { a[1] * scalar, a[2] * scalar, a[3] * scalar }
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

	local function DrawRangeRing(center, radius)
		gl.BeginEnd(GL.LINE_LOOP, function()
			for index = 0, 47 do
				local angle = index * math.pi * 2 / 48
				gl.Vertex(center[1] + math.sin(angle) * radius, center[2], center[3] + math.cos(angle) * radius)
			end
		end)
	end

	local function DrawUnitSnapshot(unit, color)
		if showAnchors then
			gl.Color(color[1], color[2], color[3], 1)
			DrawCross(unit.base, 4)
			gl.Color(1, 0.25, 0.25, 1)
			DrawCross(unit.aim, 4)
			gl.Color(1, 0.82, 0.1, 1)
			DrawCross(unit.origin, 4)
			gl.BeginEnd(GL.LINES, function()
				DrawLine(unit.origin, Add(unit.origin, Scale(unit.weaponDirection, 34)))
			end)
		end
		if showCollision then
			gl.Color(0.8, 0.1, 0.9, 0.85)
			DrawCylinder(unit.collisionCenter, unit.right, unit.up, unit.front, unit.collisionScale)
		end
	end

	function gadget:DrawWorld()
		if not calibrationEnabled then
			return
		end
		gl.DepthTest(false)
		for index = 1, DIRECTION_COUNT do
			local snapshot = snapshots[index]
			if snapshot ~= nil then
				gl.LineWidth(index == selectedIndex and 2.5 or 1.25)
				DrawUnitSnapshot(snapshot.attacker, { 0.2, 1, 0.2 })
				DrawUnitSnapshot(snapshot.target, { 1, 0.35, 0.25 })
				gl.Color(0.2, 0.8, 1, 0.9)
				gl.BeginEnd(GL.LINES, function()
					DrawLine(snapshot.attacker.origin, snapshot.target.aim)
				end)
				if showRange then
					gl.Color(1, 0.72, 0.1, 0.8)
					DrawRangeRing(snapshot.attacker.origin, snapshot.range)
				end
				if snapshot.lastDamageFrame >= 0 then
					gl.Color(1, 0.05, 0.05, 1)
					DrawCross(snapshot.target.aim, 7)
				end
				gl.Text(string.format("%02d %.0fdeg d=%.1f gap=%.1f", index, snapshot.heading, snapshot.distance, snapshot.surfaceGap),
					snapshot.attacker.base[1], snapshot.attacker.base[2] + 10, snapshot.attacker.base[3], 10, "oc")
			end
		end
		gl.LineWidth(1)
		gl.DepthTest(true)
	end

	local function SendControl(command)
		Spring.SendLuaRulesMsg(CONTROL_PREFIX .. command)
	end

	local function SendPreview(kind)
		if kind == "origin" then
			SendControl(string.format("origin:%.17g:%.17g:%.17g", preview.origin[1], preview.origin[2], preview.origin[3]))
		elseif kind == "collision" then
			SendControl(string.format("collision:%.17g:%.17g:%.17g", preview.collision[1], preview.collision[2], preview.collision[3]))
		elseif kind == "range" then
			SendControl(string.format("range:%.17g", preview.range))
		end
	end

	local function AdjustSelected(direction, multiplier)
		local control = controls[selectedField]
		local delta = direction * control.step * multiplier
		if control.key ~= nil then
			preview[control.key] = math.max(control.minimum or -math.huge, math.min(control.maximum or math.huge, preview[control.key] + delta))
		else
			control.vector[control.index] = math.max(control.minimum or -math.huge, math.min(control.maximum or math.huge, control.vector[control.index] + delta))
		end
		SendPreview(control.kind)
	end

	local function BuildExport()
		return string.format([[-- Generated by AOE Melee Calibration. Review before merging.
-- DAT collision_size=(0.25,0.25,2.0), projectile_unit_id=-1, frame_delay=10.
return {
	aoe_camel_scout = {
		collisionVolumeScales = "%.3f %.3f %.3f",
		customParams = {
			aoe2_aim_local = "0 30 0",
			aoe2_weapon1_muzzle_local = "%.3f %.3f %.3f",
			aoe2_weapon1_forward_local = "0 0 1",
		},
	},
	aoe_camel_scout_melee = {
		range = %.3f,
		windup = 0.3333333333,
		attackRecoveryTime = 0.6666666667,
	},
}
]], preview.collision[1], preview.collision[2], preview.collision[3],
			preview.origin[1], preview.origin[2], preview.origin[3], preview.range)
	end

	local function ExportPreview()
		local content = BuildExport()
		Spring.SetClipboard(content)
		Spring.CreateDir("LuaUI/Config/AOEMeleeCalibration")
		exportSerial = exportSerial + 1
		local path = string.format("LuaUI/Config/AOEMeleeCalibration/u_cam_camel_scout_override_%d_%d.lua", Spring.GetGameFrame(), exportSerial)
		local file = io.open(path, "w")
		if file ~= nil then
			file:write(content)
			file:close()
			lastExportStatus = "saved: " .. path
		else
			lastExportStatus = "clipboard only"
		end
		Spring.Echo("[AOE Melee Calibration] export " .. lastExportStatus)
	end

	function gadget:KeyPress(key, mods, isRepeat)
		if not calibrationEnabled or isRepeat then
			return false
		end
		local multiplier = mods and mods.shift and 10 or 1
		if key == 9 then
			selectedIndex = selectedIndex % DIRECTION_COUNT + 1
		elseif key == 273 then
			selectedField = ((selectedField - 2) % #controls) + 1
		elseif key == 274 then
			selectedField = selectedField % #controls + 1
		elseif key == 276 then
			AdjustSelected(-1, multiplier)
		elseif key == 275 then
			AdjustSelected(1, multiplier)
		elseif key == 115 then
			SendControl("single:" .. selectedIndex)
		elseif key == 97 then
			autoAttack = not autoAttack
			SendControl("auto:" .. (autoAttack and "1" or "0"))
		elseif key == 99 then
			SendControl("approach")
		elseif key == 100 then
			damageEnabled = not damageEnabled
			SendControl("damage:" .. (damageEnabled and "1" or "0"))
		elseif key == 114 then
			preview.origin = { DEFAULT_ORIGIN[1], DEFAULT_ORIGIN[2], DEFAULT_ORIGIN[3] }
			preview.collision = { DEFAULT_COLLISION[1], DEFAULT_COLLISION[2], DEFAULT_COLLISION[3] }
			preview.range = DEFAULT_RANGE
			for index = 1, 3 do
				controls[index].vector = preview.origin
				controls[index + 3].vector = preview.collision
			end
			SendControl("reset")
		elseif key == 101 then
			ExportPreview()
		elseif key == 118 then
			showCollision = not showCollision
		elseif key == 112 then
			showAnchors = not showAnchors
		elseif key == 103 then
			showRange = not showRange
		else
			return false
		end
		return true
	end

	function gadget:DrawScreen(viewSizeX, viewSizeY)
		if not calibrationEnabled then
			return
		end
		local x = 20
		local y = viewSizeY - 28
		local selected = snapshots[selectedIndex]
		gl.Color(0, 0, 0, 0.68)
		gl.Rect(x - 8, y - 245, x + 690, y + 8)
		gl.Color(1, 1, 1, 1)
		gl.Text("AOE Camel Scout Melee Calibration", x, y, 14, "o")
		y = y - 19
		gl.Text(string.format("direction=%02d [Tab] next | [S] single | [A] auto=%s | [C] approach | [R] reset", selectedIndex, tostring(autoAttack)), x, y, 12, "o")
		y = y - 17
		gl.Text(string.format("[D] damage=%s | [P] anchors=%s | [V] collision=%s | [G] range=%s | [E] export", tostring(damageEnabled), tostring(showAnchors), tostring(showCollision), tostring(showRange)), x, y, 12, "o")
		y = y - 17
		gl.Text("[Up/Down] field [Left/Right] adjust [Shift] x10; Reset restores UnitDef runtime values", x, y, 11, "o")
		y = y - 17
		if selected ~= nil then
			gl.Text(string.format("mode=%s phase=%s distance=%.2f surfaceGap=%.2f range=%.2f health=%.1f damageFrame=%d delta=%d",
				attackMode, selected.phase, selected.distance, selected.surfaceGap, selected.range,
				selected.target.health, selected.lastDamageFrame, selected.releaseDelta), x, y, 11, "o")
		else
			gl.Text("waiting for synced snapshots", x, y, 11, "o")
		end
		for index, control in ipairs(controls) do
			y = y - 15
			gl.Color(index == selectedField and 0.1 or 0.85, index == selectedField and 0.9 or 0.85, index == selectedField and 1 or 0.85, 1)
			local value = control.key and preview[control.key] or control.vector[control.index]
			gl.Text(string.format("%s = %.3f", control.label, value), x, y, 11, "o")
		end
		y = y - 17
		gl.Color(0.75, 0.9, 1, 1)
		gl.Text("export: " .. lastExportStatus, x, y, 11, "o")
		gl.Color(1, 1, 1, 1)
	end

	local function Vec(values, offset)
		return { values[offset], values[offset + 1], values[offset + 2] }
	end

	local function ReadUnit(values, offset)
		return {
			unitID = values[offset],
			base = Vec(values, offset + 1),
			aim = Vec(values, offset + 4),
			front = Vec(values, offset + 7),
			right = Vec(values, offset + 10),
			up = Vec(values, offset + 13),
			origin = Vec(values, offset + 16),
			weaponDirection = Vec(values, offset + 19),
			collisionScale = Vec(values, offset + 22),
			collisionCenter = Vec(values, offset + 25),
			health = values[offset + 28],
		}
	end

	function gadget:RecvFromSynced(eventName, ...)
		if eventName == "aoe_melee_state" then
			autoAttack, damageEnabled, attackMode = ...
			return
		end
		if eventName ~= "aoe_melee_snapshot" then
			return
		end
		local values = { ... }
		local index = values[1]
		snapshots[index] = {
			attacker = ReadUnit(values, 2),
			target = ReadUnit(values, 31),
			range = values[60],
			distance = values[61],
			surfaceGap = values[62],
			heading = values[63],
			phase = values[64],
			lastDamageFrame = values[65],
			releaseDelta = values[66],
		}
	end

	function gadget:Initialize()
		local applied, fov, height, angle = fixedTestCamera.Apply()
		Spring.SendCommands("debugcolvol")
		Spring.Echo(string.format("[AOE Melee Calibration] camera applied=%s fov=%.1f height=%.1f angle=%.1f", tostring(applied), fov, height, angle))
	end

	return
end

local calibrationSpacing = ReadNumber("aoe_melee_calibration_spacing", 260, 160, 1024)
local targetDistance = ReadNumber("aoe_melee_target_distance", 44, 30, 128)
local approachDistance = ReadNumber("aoe_melee_approach_distance", 96, 48, 256)
local damageEnabled = ReadBoolean("aoe_melee_damage", true)
local startAutoAttack = ReadBoolean("aoe_melee_start_auto_attack", false)
local attackStartFrame = math.floor(ReadNumber("aoe_attack_move_start_frame", 150, 1, 36000))
local pairs = {}
local targetLookup = {}
local attackerLookup = {}
local autoAttack = false
local attackMode = "stopped"
local currentOrigin = { DEFAULT_ORIGIN[1], DEFAULT_ORIGIN[2], DEFAULT_ORIGIN[3] }
local currentCollision = { DEFAULT_COLLISION[1], DEFAULT_COLLISION[2], DEFAULT_COLLISION[3] }
local currentRange = DEFAULT_RANGE
local lastDamageFrame = {}
local lastReleaseDelta = {}
local singleAttackers = {}
local battleTeams = { {}, {} }
local collisionOffsets = {}
-- Frames from attack start to the native hit, read back from the WeaponDef in
-- GameStart so the calibration report follows the def rather than a duplicated
-- literal.
local expectedReleaseFrames = 0

local function SetDirection(unitID, frontX, frontZ)
	Spring.SetUnitDirection(unitID, frontX, 0, frontZ, -frontZ, 0, frontX)
end

local function SnapDirectionComponent(value)
	return math.abs(value) < 0.000001 and 0 or value
end

local function StopUnit(unitID)
	Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, {})
	Spring.GiveOrderToUnit(unitID, CMD.FIRE_STATE, { 0 }, {})
end

local function ApplyRuntimeValues()
	for _, pair in ipairs(pairs) do
		for _, unitID in ipairs({ pair.attacker, pair.target }) do
			if Spring.ValidUnitID(unitID) then
				local offset = collisionOffsets[unitID] or { 0, 0, 0 }
				Spring.SetUnitCollisionVolumeData(unitID, currentCollision[1], currentCollision[2], currentCollision[3], offset[1], offset[2], offset[3], 1, 1, 1)
				Spring.SetUnitWeaponState(unitID, 1, "range", currentRange)
				Spring.SetUnitMaxRange(unitID, currentRange)
				if Spring.SetUnitAoe2WeaponMuzzleOverride ~= nil then
					Spring.SetUnitAoe2WeaponMuzzleOverride(unitID, 1, currentOrigin[1], currentOrigin[2], currentOrigin[3])
				end
			end
		end
	end
end

local function PositionPair(pair, distance)
	StopUnit(pair.attacker)
	StopUnit(pair.target)
	Spring.SetUnitPosition(pair.attacker, pair.centerX - pair.frontX * distance * 0.5, pair.centerZ - pair.frontZ * distance * 0.5)
	Spring.SetUnitPosition(pair.target, pair.centerX + pair.frontX * distance * 0.5, pair.centerZ + pair.frontZ * distance * 0.5)
	SetDirection(pair.attacker, pair.frontX, pair.frontZ)
	SetDirection(pair.target, -pair.frontX, -pair.frontZ)
	Spring.SetUnitHealth(pair.attacker, { health = 120 })
	Spring.SetUnitMaxHealth(pair.target, 100000)
	Spring.SetUnitHealth(pair.target, { health = 100000 })
end

local function PublishState()
	SendToUnsynced("aoe_melee_state", autoAttack, damageEnabled, attackMode)
end

local function ResetCalibration()
	autoAttack = false
	attackMode = "stopped"
	currentOrigin = { DEFAULT_ORIGIN[1], DEFAULT_ORIGIN[2], DEFAULT_ORIGIN[3] }
	currentCollision = { DEFAULT_COLLISION[1], DEFAULT_COLLISION[2], DEFAULT_COLLISION[3] }
	currentRange = DEFAULT_RANGE
	lastDamageFrame = {}
	lastReleaseDelta = {}
	singleAttackers = {}
	for _, pair in ipairs(pairs) do
		PositionPair(pair, targetDistance)
		for _, unitID in ipairs({ pair.attacker, pair.target }) do
			local offset = collisionOffsets[unitID] or { 0, 0, 0 }
			Spring.SetUnitCollisionVolumeData(unitID, DEFAULT_COLLISION[1], DEFAULT_COLLISION[2], DEFAULT_COLLISION[3], offset[1], offset[2], offset[3], 1, 1, 1)
			if Spring.SetUnitAoe2WeaponMuzzleOverride ~= nil then
				Spring.SetUnitAoe2WeaponMuzzleOverride(unitID, 1)
			end
			Spring.SetUnitWeaponState(unitID, 1, "range", DEFAULT_RANGE)
			Spring.SetUnitMaxRange(unitID, DEFAULT_RANGE)
		end
	end
	PublishState()
	Spring.Echo("[AOE Melee Calibration] reset to UnitDef values")
end

local function GiveAttack(pair, single)
	if not Spring.ValidUnitID(pair.attacker) or not Spring.ValidUnitID(pair.target) then
		return
	end
	Spring.GiveOrderToUnit(pair.attacker, CMD.FIRE_STATE, { 2 }, {})
	Spring.GiveOrderToUnit(pair.attacker, CMD.ATTACK, { pair.target }, {})
	if single then
		singleAttackers[pair.attacker] = true
	end
end

local function SetAutoAttack(enabled)
	autoAttack = enabled
	attackMode = enabled and "auto" or "stopped"
	for _, pair in ipairs(pairs) do
		if enabled then
			GiveAttack(pair, false)
		else
			StopUnit(pair.attacker)
		end
	end
	PublishState()
end

local function StartApproach()
	autoAttack = false
	attackMode = "approach"
	for _, pair in ipairs(pairs) do
		PositionPair(pair, approachDistance)
		GiveAttack(pair, false)
	end
	PublishState()
end

local function SpawnCalibration()
	local rows = math.ceil(DIRECTION_COUNT / COLUMN_COUNT)
	local width = (COLUMN_COUNT - 1) * calibrationSpacing
	local depth = (rows - 1) * calibrationSpacing
	local originX = Game.mapSizeX * 0.5 - width * 0.5
	local originZ = Game.mapSizeZ * 0.5 - depth * 0.5
	if width + 320 > Game.mapSizeX or depth + 320 > Game.mapSizeZ then
		error("[AOE Melee Calibration] layout does not fit map")
	end
	for index = 1, DIRECTION_COUNT do
		local column = (index - 1) % COLUMN_COUNT
		local row = math.floor((index - 1) / COLUMN_COUNT)
		local heading = (index - 1) * math.pi * 2 / DIRECTION_COUNT
		-- Cardinal headings must be exact. Tiny sin/cos remainders at 180°
		-- otherwise straddle Recoil's signed heading boundary and make the west
		-- calibration case spend several frames performing a redundant turn.
		local frontX = SnapDirectionComponent(math.sin(heading))
		local frontZ = SnapDirectionComponent(math.cos(heading))
		if frontX == -1 and frontZ == 0 then
			-- A signed 16-bit heading represents west at its wrap boundary. Keep
			-- the visual direction in the same sprite sector but stay one small
			-- step inside the range so native facing checks do not take the long
			-- path around the boundary during scene initialization.
			frontZ = 0.001
			frontX = -math.sqrt(1 - frontZ * frontZ)
		end
		local centerX = originX + column * calibrationSpacing
		local centerZ = originZ + row * calibrationSpacing
		local attacker = Spring.CreateUnit(UNIT_NAME, centerX, Spring.GetGroundHeight(centerX, centerZ), centerZ, "south", 0)
		local target = Spring.CreateUnit(UNIT_NAME, centerX, Spring.GetGroundHeight(centerX, centerZ), centerZ, "north", 1)
		if attacker == nil or target == nil then
			error("[AOE Melee Calibration] failed to create pair " .. index)
		end
		local pair = { index = index, attacker = attacker, target = target, centerX = centerX, centerZ = centerZ, frontX = frontX, frontZ = frontZ }
		pairs[index] = pair
		targetLookup[target] = pair
		attackerLookup[attacker] = pair
		for _, unitID in ipairs({ attacker, target }) do
			local _, _, _, offsetX, offsetY, offsetZ = Spring.GetUnitCollisionVolumeData(unitID)
			collisionOffsets[unitID] = { offsetX, offsetY, offsetZ }
		end
		PositionPair(pair, targetDistance)
	end
	Spring.SetGlobalLos(0, true)
	PublishState()
	Spring.Echo(string.format("[AOE Melee Calibration] created=%d pairs distance=%.1f approach=%.1f range=%.1f damage=%s",
		#pairs, targetDistance, approachDistance, currentRange, tostring(damageEnabled)))
	if startAutoAttack then
		SetAutoAttack(true)
	end
end

local function Formation(count, teamID, centerX, centerZ, facing, spacing)
	local columns = math.ceil(math.sqrt(count))
	local rows = math.ceil(count / columns)
	local width = (columns - 1) * spacing
	local depth = (rows - 1) * spacing
	local units = {}
	for index = 1, count do
		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		local x = centerX - width * 0.5 + column * spacing
		local z = centerZ - depth * 0.5 + row * spacing
		local unitID = Spring.CreateUnit(UNIT_NAME, x, Spring.GetGroundHeight(x, z), z, facing, teamID)
		if unitID ~= nil then
			units[#units + 1] = unitID
		end
	end
	return units
end

local function SpawnBattle()
	local countA = math.floor(ReadNumber("aoe_melee_team_a_count", 16, 1, 1000))
	local countB = math.floor(ReadNumber("aoe_melee_team_b_count", 16, 1, 1000))
	local spacing = ReadNumber("aoe_team_spacing", 48, 32, 256)
	local separation = ReadNumber("aoe_team_separation", 900, 128, math.max(128, Game.mapSizeX - 256))
	local centerX = Game.mapSizeX * 0.5
	local centerZ = Game.mapSizeZ * 0.5
	battleTeams[1] = Formation(countA, 0, centerX - separation * 0.5, centerZ, "east", spacing)
	battleTeams[2] = Formation(countB, 1, centerX + separation * 0.5, centerZ, "west", spacing)
	Spring.SetGlobalLos(0, true)
	Spring.Echo(string.format("[AOE Melee Battle] created A=%d/%d B=%d/%d spacing=%.1f separation=%.1f fightFrame=%d",
		#battleTeams[1], countA, #battleTeams[2], countB, spacing, separation, attackStartFrame))
end

local function IssueBattleFight()
	local centerX = Game.mapSizeX * 0.5
	local centerZ = Game.mapSizeZ * 0.5
	local targetA = { centerX + ReadNumber("aoe_team_separation", 900, 128, Game.mapSizeX) * 0.5, Spring.GetGroundHeight(centerX, centerZ), centerZ }
	local targetB = { centerX - ReadNumber("aoe_team_separation", 900, 128, Game.mapSizeX) * 0.5, Spring.GetGroundHeight(centerX, centerZ), centerZ }
	local acceptedA = Spring.GiveOrderToUnitArrayGroup(battleTeams[1], CMD.FIGHT, targetA, {})
	local acceptedB = Spring.GiveOrderToUnitArrayGroup(battleTeams[2], CMD.FIGHT, targetB, {})
	Spring.Echo(string.format("[AOE Melee Battle] group-locked CMD.FIGHT frame=%d acceptedA=%s acceptedB=%s", Spring.GetGameFrame(), tostring(acceptedA), tostring(acceptedB)))
end

local function UnitSnapshot(unitID)
	local baseX, baseY, baseZ, midX, midY, midZ, aimX, aimY, aimZ = Spring.GetUnitPosition(unitID, true, true)
	local frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ = Spring.GetUnitDirection(unitID)
	local originX, originY, originZ, dirX, dirY, dirZ = Spring.GetUnitWeaponVectors(unitID, 1)
	local scaleX, scaleY, scaleZ, offsetX, offsetY, offsetZ = Spring.GetUnitCollisionVolumeData(unitID)
	local health = Spring.GetUnitHealth(unitID) or 0
	local collisionX = midX + rightX * offsetX + upX * offsetY + frontX * offsetZ
	local collisionY = midY + rightY * offsetX + upY * offsetY + frontY * offsetZ
	local collisionZ = midZ + rightZ * offsetX + upZ * offsetY + frontZ * offsetZ
	return {
		unitID, baseX, baseY, baseZ, aimX, aimY, aimZ,
		frontX, frontY, frontZ, rightX, rightY, rightZ, upX, upY, upZ,
		originX, originY, originZ, dirX, dirY, dirZ,
		scaleX, scaleY, scaleZ, collisionX, collisionY, collisionZ, health,
	}
end

local function SendSnapshots()
	for index, pair in ipairs(pairs) do
		if Spring.ValidUnitID(pair.attacker) and Spring.ValidUnitID(pair.target) then
			local attacker = UnitSnapshot(pair.attacker)
			local target = UnitSnapshot(pair.target)
			local dx = target[2] - attacker[2]
			local dz = target[4] - attacker[4]
			local distance = math.sqrt(dx * dx + dz * dz)
			local surfaceGap = distance - (attacker[23] + target[23]) * 0.5
			local moveData = Spring.GetUnitMoveTypeData(pair.attacker) or {}
			local phase = moveData.attackMotionPhase or "n/a"
			local heading = math.deg(math.atan2(attacker[8], attacker[10]))
			local values = { index }
			for _, value in ipairs(attacker) do values[#values + 1] = value end
			for _, value in ipairs(target) do values[#values + 1] = value end
			values[#values + 1] = currentRange
			values[#values + 1] = distance
			values[#values + 1] = surfaceGap
			values[#values + 1] = heading
			values[#values + 1] = phase
			values[#values + 1] = lastDamageFrame[pair.target] or -1
			values[#values + 1] = lastReleaseDelta[pair.target] or -1
			SendToUnsynced("aoe_melee_snapshot", unpack(values))
		end
	end
end

function gadget:GameStart()
	expectedReleaseFrames = math.floor(WeaponDefs[WeaponDefNames[WEAPON_NAME].id].windup * 30 + 0.5)
	if calibrationEnabled then
		SpawnCalibration()
	else
		SpawnBattle()
	end
end

function gadget:GameFrame(frame)
	if calibrationEnabled and (frame == 15 or frame % SNAPSHOT_PERIOD == 0) then
		SendSnapshots()
	elseif battleEnabled and frame == attackStartFrame then
		IssueBattleFight()
	elseif battleEnabled and frame % 150 == 0 then
		local aliveA = #Spring.GetTeamUnits(0)
		local aliveB = #Spring.GetTeamUnits(1)
		Spring.Echo(string.format("[AOE Melee Battle] frame=%d aliveA=%d aliveB=%d", frame, aliveA, aliveB))
	end
end

function gadget:UnitPreDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID)
	if calibrationEnabled and targetLookup[unitID] ~= nil and weaponDefID == WeaponDefNames[WEAPON_NAME].id and not damageEnabled then
		return 0, 0
	end
	return damage, 1
end

function gadget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID)
	if not calibrationEnabled or targetLookup[unitID] == nil or attackerLookup[attackerID] == nil or weaponDefID ~= WeaponDefNames[WEAPON_NAME].id then
		return
	end
	local frame = Spring.GetGameFrame()
	lastDamageFrame[unitID] = frame
	local moveData = Spring.GetUnitMoveTypeData(attackerID) or {}
	local startFrame = moveData.attackMotionStartFrame or -1
	lastReleaseDelta[unitID] = startFrame >= 0 and frame - startFrame or -1
	local pair = targetLookup[unitID]
	Spring.Echo(string.format("[AOE Melee Calibration] damage direction=%d frame=%d attacker=%d target=%d amount=%.1f start=%d delta=%d expected=%d",
		pair.index, frame, attackerID, unitID, damage, startFrame, lastReleaseDelta[unitID], expectedReleaseFrames))
	if singleAttackers[attackerID] then
		singleAttackers[attackerID] = nil
		StopUnit(attackerID)
	end
end

function gadget:RecvLuaMsg(message, playerID)
	if not calibrationEnabled or string.sub(message, 1, #CONTROL_PREFIX) ~= CONTROL_PREFIX then
		return false
	end
	local command = string.sub(message, #CONTROL_PREFIX + 1)
	local index = string.match(command, "^single:(%d+)$")
	if index ~= nil then
		local pair = pairs[tonumber(index)]
		if pair ~= nil then
			attackMode = "single"
			GiveAttack(pair, true)
			PublishState()
		end
		return true
	end
	local enabled = string.match(command, "^auto:([01])$")
	if enabled ~= nil then
		SetAutoAttack(enabled == "1")
		return true
	end
	enabled = string.match(command, "^damage:([01])$")
	if enabled ~= nil then
		damageEnabled = enabled == "1"
		PublishState()
		return true
	end
	if command == "approach" then
		StartApproach()
		return true
	end
	if command == "reset" then
		ResetCalibration()
		return true
	end
	local x, y, z = string.match(command, "^origin:([%+%-%.%deE]+):([%+%-%.%deE]+):([%+%-%.%deE]+)$")
	if x ~= nil then
		currentOrigin = { tonumber(x), tonumber(y), tonumber(z) }
		ApplyRuntimeValues()
		return true
	end
	x, y, z = string.match(command, "^collision:([%+%-%.%deE]+):([%+%-%.%deE]+):([%+%-%.%deE]+)$")
	if x ~= nil then
		currentCollision = { tonumber(x), tonumber(y), tonumber(z) }
		ApplyRuntimeValues()
		return true
	end
	local range = string.match(command, "^range:([%+%-%.%deE]+)$")
	if range ~= nil then
		currentRange = tonumber(range)
		ApplyRuntimeValues()
		return true
	end
	return false
end
