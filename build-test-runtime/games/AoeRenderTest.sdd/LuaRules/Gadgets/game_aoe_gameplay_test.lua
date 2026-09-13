function gadget:GetInfo()
	return {
		name = "AOE Gameplay Bridge Test",
		desc = "Creates two native enemy formations and drives them through CommandAI",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = 0,
		enabled = true,
	}
end

local ARMOR_RESET_MESSAGE = "aoe_gameplay_test:reset_armor"

if not gadgetHandler:IsSyncedCode() then
	local modOptions = Spring.GetModOptions()
	local fixedCameraValue = tostring(modOptions.aoe_fixed_test_camera or "false"):lower()
	local fixedCameraEnabled = fixedCameraValue == "1" or fixedCameraValue == "true" or fixedCameraValue == "yes" or fixedCameraValue == "on"
	local meleeCalibrationValue = tostring(modOptions.aoe_melee_calibration or "false"):lower()
	local meleeBattleValue = tostring(modOptions.aoe_melee_battle or "false"):lower()
	local meleeTestEnabled = meleeCalibrationValue == "1" or meleeCalibrationValue == "true" or meleeBattleValue == "1" or meleeBattleValue == "true"
	local armorResetValue = tostring(modOptions.aoe_armor_upgrade_test or "false"):lower()
	local armorResetEnabled = armorResetValue == "1" or armorResetValue == "true" or armorResetValue == "yes" or armorResetValue == "on"
	local fixedTestCamera = VFS.Include("LuaRules/aoe_fixed_test_camera.lua")

	function gadget:Initialize()
		if meleeTestEnabled or not fixedCameraEnabled then
			return
		end
		local cameraApplied, cameraFov, cameraHeight, cameraAngle, featureDrawDistance, featureFadeDistance,
			projection, orthoHeight = fixedTestCamera.Apply()
		Spring.Echo(string.format(
			"[AOE Gameplay Test] fixed camera applied=%s projection=%s fov=%.1f orthoHeight=%.1f height=%.1f angle=%.1fdeg featureDraw=%.1f featureFade=%.1f",
			tostring(cameraApplied), projection, cameraFov, orthoHeight, cameraHeight, cameraAngle,
			featureDrawDistance, featureFadeDistance))
	end

	function gadget:RecvFromSynced(eventName, ...)
		if eventName == "aoe_anchor_point" then
			local x, y, z, label = ...
			Spring.MarkerAddPoint(x, y, z, label, true)
		elseif eventName == "aoe_anchor_line" then
			local x1, y1, z1, x2, y2, z2 = ...
			Spring.MarkerAddLine(x1, y1, z1, x2, y2, z2, true)
		end
	end

	function gadget:KeyPress(key, mods, isRepeat)
		if armorResetEnabled and not isRepeat and key == 114 then
			Spring.SendLuaRulesMsg(ARMOR_RESET_MESSAGE)
			return true
		end
		return false
	end

	function gadget:DrawScreen(viewSizeX, viewSizeY)
		if armorResetEnabled then
			gl.Text("[R] Reset AOE armor battle", 20, viewSizeY - 28, 13, "o")
		end
	end
	return
end

local modOptions = Spring.GetModOptions()

local function ReadNumberOption(name, defaultValue, minimum, maximum)
	local value = tonumber(modOptions[name]) or defaultValue
	return math.max(minimum, math.min(maximum, value))
end

local function ReadBooleanOption(name, defaultValue)
	local value = modOptions[name]
	if value == nil then
		return defaultValue
	end
	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local requestedSpacing = ReadNumberOption("aoe_team_spacing", 42, 8, 256)
local requestedSeparation = ReadNumberOption("aoe_team_separation", 1400, 64, 8192)
local attackMoveStartFrame = math.floor(ReadNumberOption("aoe_attack_move_start_frame", 150, 1, 36000))
local counterAttack = ReadBooleanOption("aoe_team_b_counter_attack", false)
local camelScoutFraction = ReadNumberOption("aoe_camel_scout_fraction", 0, 0, 1)
local globalLosForTeamA = ReadBooleanOption("aoe_global_los", true)
local anchorValidation = ReadBooleanOption("aoe_anchor_validation", false)
local anchorCalibration = ReadBooleanOption("aoe_anchor_calibration", false)
local buildingTest = ReadBooleanOption("aoe_building_test", false)
local teamTowersEnabled = ReadBooleanOption("aoe_team_towers", false)
local meleeCalibration = ReadBooleanOption("aoe_melee_calibration", false)
local meleeBattle = ReadBooleanOption("aoe_melee_battle", false)
local chukonuTest = ReadBooleanOption("aoe_chukonu_test", false)
local positionDiagnosticEnabled = ReadBooleanOption("aoe_position_diagnostics", true)
local positionDiagnosticSamplesPerTeam = math.floor(ReadNumberOption("aoe_position_diagnostic_samples", 64, 1, 128))
local explicitMoveRegressionEnabled = ReadBooleanOption("aoe_explicit_move_regression", false)
local attackCannotMoveConfigured = ReadBooleanOption("aoe_attack_cannot_move", true)
local armorUpgradeTestEnabled = ReadBooleanOption("aoe_armor_upgrade_test", false)
local castleRapidFireUpgradeTestEnabled = ReadBooleanOption("aoe_castle_rapid_fire_upgrade_test", false)
local statusLogPeriod = 150
local eliminationCheckPeriod = 15
local stalledDistanceThreshold = 128
local activeAttackMoveFrame = attackMoveStartFrame
local combatRound = 0
local combatFeatureIDs = {}
local combatProjectileIDs = {}
local attackStartAudit = { checked = {}, samples = 0, violations = 0 }
local expectedFightTargets = {}
local destroyedUnitFrames = {}
local moveDiagnostic = {
	totalFailures = 0,
	failuresByUnit = {},
	eliminationFrame = nil,
	survivorTeamID = nil,
	survivorName = nil,
	eliminatedName = nil,
	snapshotOffsets = { 0, 30, 150, 300, 600, 900 },
	snapshotsLogged = {},
	targetDeathCases = 0,
	targetDeathFightPreserved = 0,
}
local positionDiagnostic = {
	units = {},
	states = {},
	triggerCount = 0,
	maxTriggerCount = 16,
	protectedTriggerCount = 0,
	maxProtectedTriggerCount = 16,
	historyFrames = 8,
	followFrames = 12,
	cooldownFrames = 60,
	collisionLockedFrames = 0,
	collisionLockedDisplacements = 0,
	maxCollisionLockedDisplacement = 0,
}
local explicitMoveRegression = {
	cases = {},
	completed = 0,
	passed = 0,
	deadlineFrame = attackMoveStartFrame + 1200,
}

local teams = {
	{
		name = "A",
		teamID = 0,
		count = math.floor(ReadNumberOption("aoe_team_a_count", 100, 1, 10000)),
		facing = "east",
		units = {},
	},
	{
		name = "B",
		teamID = 1,
		count = math.floor(ReadNumberOption("aoe_team_b_count", 100, 1, 10000)),
		facing = "west",
		units = {},
	},
}

local TEAM_TOWER_NAME = "aoe_afri_tower_age2"
local TEAM_TOWER_REAR_CLEARANCE = 120

local anchorTest = {
	targetID = nil,
	attackers = {},
	projectileOwners = {},
	attackFrames = {},
}

local anchorCases = {
	{ label = "north", x = 0, z = 1 },
	{ label = "east", x = 1, z = 0 },
	{ label = "south", x = 0, z = -1 },
	{ label = "west", x = -1, z = 0 },
	{ label = "north-east", x = 0.70710678, z = 0.70710678 },
	{ label = "south-west", x = -0.70710678, z = -0.70710678 },
}

local function GetFormationDimensions(count, spacing)
	local columns = math.max(1, math.ceil(math.sqrt(count)))
	local rows = math.max(1, math.ceil(count / columns))
	return {
		columns = columns,
		rows = rows,
		width = (columns - 1) * spacing,
		depth = (rows - 1) * spacing,
	}
end

local function ConfigureLayout()
	local margin = math.min(128, Game.mapSizeX * 0.1, Game.mapSizeZ * 0.1)
	local dimensionsA = GetFormationDimensions(teams[1].count, requestedSpacing)
	local dimensionsB = GetFormationDimensions(teams[2].count, requestedSpacing)
	local horizontalSteps = math.max(1, dimensionsA.columns + dimensionsB.columns - 2)
	local verticalSteps = math.max(1, math.max(dimensionsA.rows, dimensionsB.rows) - 1)
	local maxSpacingX = (Game.mapSizeX - 2 * margin - requestedSeparation) / horizontalSteps
	local maxSpacingZ = (Game.mapSizeZ - 2 * margin) / verticalSteps
	local spacing = math.min(requestedSpacing, maxSpacingX, maxSpacingZ)

	if spacing < 8 then
		error(string.format(
			"[AOE Gameplay Test] formations do not fit: A=%d B=%d separation=%.1f map=%dx%d",
			teams[1].count, teams[2].count, requestedSeparation, Game.mapSizeX, Game.mapSizeZ
		))
	end

	dimensionsA = GetFormationDimensions(teams[1].count, spacing)
	dimensionsB = GetFormationDimensions(teams[2].count, spacing)
	local availableSeparation = Game.mapSizeX - 2 * margin - dimensionsA.width - dimensionsB.width
	local separation = math.min(requestedSeparation, availableSeparation)
	if separation < 2 * spacing then
		error("[AOE Gameplay Test] formations would overlap after fitting to map bounds")
	end

	local middleX = Game.mapSizeX * 0.5
	local middleZ = Game.mapSizeZ * 0.5
	teams[1].dimensions = dimensionsA
	teams[1].center = {
		x = middleX - separation * 0.5 - dimensionsA.width * 0.5,
		z = middleZ,
	}
	teams[2].dimensions = dimensionsB
	teams[2].center = {
		x = middleX + separation * 0.5 + dimensionsB.width * 0.5,
		z = middleZ,
	}

	return spacing, separation
end

local formationSpacing, formationSeparation = ConfigureLayout()

local function GetFrontCamelSlots(team, camelCount)
	local dimensions = team.dimensions
	local slots = {}
	for index = 1, team.count do
		local column = (index - 1) % dimensions.columns
		local row = math.floor((index - 1) / dimensions.columns)
		slots[#slots + 1] = {
			index = index,
			column = column,
			row = row,
		}
	end

	table.sort(slots, function(a, b)
		if a.column ~= b.column then
			if team.facing == "east" then
				return a.column > b.column
			end
			return a.column < b.column
		end

		local centerRow = (dimensions.rows - 1) * 0.5
		local aCenterDistance = math.abs(a.row - centerRow)
		local bCenterDistance = math.abs(b.row - centerRow)
		if aCenterDistance ~= bCenterDistance then
			return aCenterDistance < bCenterDistance
		end
		return a.row < b.row
	end)

	local camelSlots = {}
	for index = 1, camelCount do
		camelSlots[slots[index].index] = true
	end
	return camelSlots
end

local function SpawnFormation(team)
	local dimensions = team.dimensions
	local requestedCamelCount = math.floor(team.count * camelScoutFraction + 0.5)
	local camelSlots = GetFrontCamelSlots(team, requestedCamelCount)
	local createdCamelCount = 0
	local createdArcherCount = 0
	for index = 1, team.count do
		local column = (index - 1) % dimensions.columns
		local row = math.floor((index - 1) / dimensions.columns)
		local x = team.center.x - dimensions.width * 0.5 + column * formationSpacing
		local z = team.center.z - dimensions.depth * 0.5 + row * formationSpacing
		local unitName = camelSlots[index] and "aoe_knight" or "aoe_crossbowman"
		local unitID = Spring.CreateUnit(unitName, x, Spring.GetGroundHeight(x, z), z, team.facing, team.teamID)
		if unitID then
			team.units[#team.units + 1] = unitID
			if camelSlots[index] then
				createdCamelCount = createdCamelCount + 1
			else
				createdArcherCount = createdArcherCount + 1
			end
		end
	end

	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team %s created=%d/%d camel=%d/%d archer=%d center=(%.1f, %.1f) grid=%dx%d",
		team.name, #team.units, team.count,
		createdCamelCount, requestedCamelCount, createdArcherCount,
		team.center.x, team.center.z,
		dimensions.columns, dimensions.rows
	))
end

local function SpawnTeamTower(team)
	if not teamTowersEnabled then
		return
	end

	local rearDirection = (team.facing == "east") and -1 or 1
	local x = team.center.x + rearDirection * (team.dimensions.width * 0.5 + TEAM_TOWER_REAR_CLEARANCE)
	local z = team.center.z
	x = math.max(64, math.min(Game.mapSizeX - 64, x))
	z = math.max(64, math.min(Game.mapSizeZ - 64, z))

	local towerID = Spring.CreateUnit(TEAM_TOWER_NAME, x, Spring.GetGroundHeight(x, z), z, team.facing, team.teamID)
	if towerID == nil then
		error(string.format("[AOE Gameplay Test] failed to create Team %s tower", team.name))
	end
	team.towerID = towerID

	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team %s tower=%d rearPosition=(%.1f, %.1f)",
		team.name, towerID, x, z
	))
end

local function RecordExpectedFightTargets(team, target)
	local positions = {}
	local centerX = 0
	local centerZ = 0
	local count = 0

	for _, unitID in ipairs(team.units) do
		local x, _, z = Spring.GetUnitPosition(unitID)
		if x then
			positions[unitID] = { x = x, z = z }
			centerX = centerX + x
			centerZ = centerZ + z
			count = count + 1
		end
	end

	if count == 0 then
		return
	end

	centerX = centerX / count
	centerZ = centerZ / count
	for unitID, position in pairs(positions) do
		expectedFightTargets[unitID] = {
			x = target.x + position.x - centerX,
			z = target.z + position.z - centerZ,
		}
	end
end

local function GiveAttackMove(team, target)
	RecordExpectedFightTargets(team, target)
	local targetY = Spring.GetGroundHeight(target.x, target.z)
	local issued = Spring.GiveOrderToUnitArrayGroup(team.units, CMD.FIGHT, {target.x, targetY, target.z}, {})
	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team %s issued native group-locked CMD.FIGHT to (%.1f, %.1f) members=%d accepted=%s at frame %d",
		team.name, target.x, target.z, #team.units, tostring(issued), Spring.GetGameFrame()
	))
end

local CapturePositionSnapshot

local function InitializeExplicitMoveRegression()
	if not explicitMoveRegressionEnabled then
		return
	end

	local candidateCount = #teams[1].units
	if candidateCount < 2 then
		Spring.Echo("[AOE Attack Regression] FAIL explicit Move requires at least two Team A units")
		return
	end

	local candidateIndexes = { 1, candidateCount }
	local phases = { "windup", "recovery" }
	for index, phase in ipairs(phases) do
		local unitID = teams[1].units[candidateIndexes[index]]
		explicitMoveRegression.cases[#explicitMoveRegression.cases + 1] = {
			unitID = unitID,
			phase = phase,
			issuedFrame = nil,
			finished = false,
			observedMoveFront = false,
			observedMobileUnlocked = false,
			maxDistance = 0,
		}
	end

	Spring.Echo(string.format(
		"[AOE Attack Regression] explicit Move enabled cases=%d deadlineFrame=%d",
		#explicitMoveRegression.cases, explicitMoveRegression.deadlineFrame
	))
end

local function UpdateExplicitMoveRegression(frame)
	if not explicitMoveRegressionEnabled then
		return
	end

	for _, testCase in ipairs(explicitMoveRegression.cases) do
		if not testCase.finished and Spring.ValidUnitID(testCase.unitID) then
			local snapshot = CapturePositionSnapshot(testCase.unitID, frame)
			if snapshot then
				if not testCase.issuedFrame and snapshot.phase == testCase.phase then
					testCase.issuedFrame = frame
					testCase.startX = snapshot.x
					testCase.startZ = snapshot.z
					expectedFightTargets[testCase.unitID] = nil
					local targetX = math.max(64, snapshot.x - 240)
					local targetZ = snapshot.z
					Spring.GiveOrderToUnit(
						testCase.unitID,
						CMD.MOVE,
						{ targetX, Spring.GetGroundHeight(targetX, targetZ), targetZ },
						{}
					)
					Spring.Echo(string.format(
						"[AOE Attack Regression] issued explicit CMD.MOVE unit=%d interruptedPhase=%s frame=%d target=(%.1f,%.1f)",
						testCase.unitID, testCase.phase, frame, targetX, targetZ
					))
				elseif testCase.issuedFrame then
					local dx = snapshot.x - testCase.startX
					local dz = snapshot.z - testCase.startZ
					testCase.maxDistance = math.max(testCase.maxDistance, math.sqrt(dx * dx + dz * dz))
					testCase.observedMobileUnlocked = testCase.observedMobileUnlocked or
						(snapshot.phase == "mobile" and not snapshot.locked)
					local commands = Spring.GetUnitCommands(testCase.unitID, 1) or {}
					testCase.observedMoveFront = testCase.observedMoveFront or
						(commands[1] ~= nil and commands[1].id == CMD.MOVE)

					if frame >= testCase.issuedFrame + 120 then
						testCase.finished = true
						explicitMoveRegression.completed = explicitMoveRegression.completed + 1
						local passed =
							testCase.observedMobileUnlocked and
							testCase.observedMoveFront and
							testCase.maxDistance >= 8
						if passed then
							explicitMoveRegression.passed = explicitMoveRegression.passed + 1
						end
						Spring.Echo(string.format(
							"[AOE Attack Regression] %s explicit Move interruptedPhase=%s unit=%d mobileUnlocked=%s moveFront=%s maxDistance=%.3f",
							passed and "PASS" or "FAIL", testCase.phase, testCase.unitID,
							tostring(testCase.observedMobileUnlocked), tostring(testCase.observedMoveFront), testCase.maxDistance
						))
					end
				end
			end
		elseif not testCase.finished then
			testCase.finished = true
			explicitMoveRegression.completed = explicitMoveRegression.completed + 1
			Spring.Echo(string.format(
				"[AOE Attack Regression] FAIL unit destroyed before explicit Move verification phase=%s unit=%d",
				testCase.phase, testCase.unitID
			))
		end

		if not testCase.finished and not testCase.issuedFrame and frame >= explicitMoveRegression.deadlineFrame then
			testCase.finished = true
			explicitMoveRegression.completed = explicitMoveRegression.completed + 1
			Spring.Echo(string.format(
				"[AOE Attack Regression] FAIL phase not observed before deadline phase=%s unit=%d",
				testCase.phase, testCase.unitID
			))
		end
	end

	if
		explicitMoveRegression.completed == #explicitMoveRegression.cases and
		not explicitMoveRegression.summaryLogged
	then
		explicitMoveRegression.summaryLogged = true
		Spring.Echo(string.format(
			"[AOE Attack Regression] explicit Move summary passed=%d/%d",
			explicitMoveRegression.passed, #explicitMoveRegression.cases
		))
	end
end

local function FormatCommand(command)
	if not command then
		return "none"
	end

	local formattedParams = {}
	local params = command.params or {}
	for index = 1, math.min(6, #params) do
		formattedParams[#formattedParams + 1] = string.format("%.1f", params[index])
	end

	return string.format(
		"id=%s tag=%s params=[%s]",
		tostring(command.id), tostring(command.tag), table.concat(formattedParams, ",")
	)
end

local function FormatWeaponTarget(targetType, targetData)
	if targetType == 1 then
		return "unit:" .. tostring(targetData)
	end
	if targetType == 2 and type(targetData) == "table" then
		return string.format("ground:(%.1f,%.1f,%.1f)", targetData[1] or 0, targetData[2] or 0, targetData[3] or 0)
	end
	if targetType == 3 then
		return "projectile:" .. tostring(targetData)
	end
	return "none"
end

CapturePositionSnapshot = function(unitID, frame)
	local x, y, z = Spring.GetUnitPosition(unitID)
	if not x then
		return nil
	end

	local velocityX, _, velocityZ = Spring.GetUnitVelocity(unitID)
	local speed = math.sqrt((velocityX or 0) ^ 2 + (velocityZ or 0) ^ 2)
	local moveData = Spring.GetUnitMoveTypeData(unitID) or {}
	local targetType, _, targetData = Spring.GetUnitWeaponTarget(unitID, 1)
	local commands = Spring.GetUnitCommands(unitID, 8) or {}
	local hasFightCommand = false
	for _, command in ipairs(commands) do
		if command.id == CMD.FIGHT then
			hasFightCommand = true
			break
		end
	end

	return {
		frame = frame,
		x = x,
		y = y,
		z = z,
		velocityX = velocityX or 0,
		velocityZ = velocityZ or 0,
		speed = speed,
		heading = Spring.GetUnitHeading(unitID) or 0,
		phase = moveData.attackMotionPhase or "unavailable",
		locked = moveData.attackMovementLocked == true,
		collisionLocked = moveData.attackCollisionLocked == true,
		attackAnimation = moveData.attackAnimationActive == true,
		attackStartFrame = moveData.attackMotionStartFrame or -1,
		attackReleaseFrame = moveData.attackMotionReleaseFrame or -1,
		attackEndFrame = moveData.attackMotionEndFrame or -1,
		progress = moveData.progressState or "unknown",
		currentSpeed = moveData.currentSpeed or 0,
		wantedSpeed = moveData.wantedSpeed or 0,
		goalX = moveData.goalx or 0,
		goalZ = moveData.goalz or 0,
		reloadFrame = Spring.GetUnitWeaponState(unitID, 1, "reloadFrame") or -1,
		target = FormatWeaponTarget(targetType, targetData),
		targetUnitID = targetType == 1 and targetData or nil,
		hasFightCommand = hasFightCommand,
		frontCommand = FormatCommand(commands[1]),
	}
end

local function LogPositionSnapshot(reason, unitID, teamName, snapshot)
	Spring.Echo(string.format(
		"[AOE Position Diagnostic] reason=%s frame=%d unit=%d team=%s pos=(%.3f,%.3f,%.3f) delta=(%.3f,%.3f) roundTrip=%.3f velocity=(%.3f,%.3f) speed=%.4f phase=%s moveLocked=%s collisionLocked=%s attackAnim=%s attackFrames=(%d,%d,%d) move={progress=%s current=%.3f wanted=%.3f goal=(%.1f,%.1f)} weapon={target=%s reloadFrame=%d} front={%s}",
		reason, snapshot.frame, unitID, teamName,
		snapshot.x, snapshot.y, snapshot.z, snapshot.deltaX or 0, snapshot.deltaZ or 0,
		snapshot.roundTrip or -1, snapshot.velocityX, snapshot.velocityZ, snapshot.speed,
		snapshot.phase, tostring(snapshot.locked), tostring(snapshot.collisionLocked), tostring(snapshot.attackAnimation),
		snapshot.attackStartFrame, snapshot.attackReleaseFrame, snapshot.attackEndFrame,
		snapshot.progress, snapshot.currentSpeed, snapshot.wantedSpeed, snapshot.goalX, snapshot.goalZ,
		snapshot.target, snapshot.reloadFrame, snapshot.frontCommand
	))
end

local function AddPositionDiagnosticSamples(team)
	local unitCount = #team.units
	local sampleCount = math.min(unitCount, positionDiagnosticSamplesPerTeam)
	if sampleCount == 0 then
		return
	end

	for sampleIndex = 1, sampleCount do
		local unitIndex = (sampleCount == 1)
			and 1
			or (math.floor((sampleIndex - 1) * (unitCount - 1) / (sampleCount - 1)) + 1)
		local unitID = team.units[unitIndex]
		positionDiagnostic.units[#positionDiagnostic.units + 1] = {
			unitID = unitID,
			teamName = team.name,
		}
		positionDiagnostic.states[unitID] = {
			history = {},
			followUntil = -1,
			cooldownUntil = -1,
			moveFailed = false,
		}
	end
end

local function InitializePositionDiagnostic()
	if not positionDiagnosticEnabled then
		Spring.Echo("[AOE Position Diagnostic] disabled")
		return
	end

	AddPositionDiagnosticSamples(teams[1])
	AddPositionDiagnosticSamples(teams[2])
	Spring.Echo(string.format(
		"[AOE Position Diagnostic] enabled sampledUnits=%d samplesPerTeam=%d history=%d follow=%d maxTriggers=%d",
		#positionDiagnostic.units, positionDiagnosticSamplesPerTeam, positionDiagnostic.historyFrames,
		positionDiagnostic.followFrames, positionDiagnostic.maxTriggerCount
	))
end

local function UpdatePositionDiagnostic(frame)
	if not positionDiagnosticEnabled or frame < activeAttackMoveFrame then
		return
	end

	for _, sample in ipairs(positionDiagnostic.units) do
		local unitID = sample.unitID
		local state = positionDiagnostic.states[unitID]
		local snapshot = CapturePositionSnapshot(unitID, frame)
		if snapshot then
			local history = state.history
			local previous = history[#history]
			local twoFramesAgo = history[#history - 1]
			local triggerReason = nil
			local moveFailed = snapshot.progress == "failed"

			if moveFailed and not state.moveFailed then
				moveDiagnostic.totalFailures = moveDiagnostic.totalFailures + 1
				moveDiagnostic.failuresByUnit[unitID] = (moveDiagnostic.failuresByUnit[unitID] or 0) + 1
				Spring.Echo(string.format(
					"[AOE Move Diagnostic] sampled UnitMoveFailed frame=%d unit=%d team=%s occurrence=%d front={%s}",
					frame, unitID, sample.teamName, moveDiagnostic.failuresByUnit[unitID], snapshot.frontCommand
				))
			end
			state.moveFailed = moveFailed

			if previous then
				snapshot.deltaX = snapshot.x - previous.x
				snapshot.deltaZ = snapshot.z - previous.z
				local distance = math.sqrt(snapshot.deltaX ^ 2 + snapshot.deltaZ ^ 2)
				local previousDistance = math.sqrt((previous.deltaX or 0) ^ 2 + (previous.deltaZ or 0) ^ 2)

				if twoFramesAgo then
					local roundTripX = snapshot.x - twoFramesAgo.x
					local roundTripZ = snapshot.z - twoFramesAgo.z
					snapshot.roundTrip = math.sqrt(roundTripX ^ 2 + roundTripZ ^ 2)
				end

				local stoppedDisplacement =
					distance >= 0.04 and
					math.max(snapshot.speed, previous.speed) <= 0.05
				-- Only attribute displacement to continuous collision protection. A
				-- target death, retarget, or front-command transition can legitimately
				-- unlock and restart movement between the two Lua frame snapshots.
				local collisionProtectedInterval =
					previous.collisionLocked and
					snapshot.collisionLocked and
					previous.target == snapshot.target and
					previous.frontCommand == snapshot.frontCommand
				local targetDeathFrame = previous.targetUnitID and destroyedUnitFrames[previous.targetUnitID]
				if
					targetDeathFrame and
					targetDeathFrame >= previous.frame and
					targetDeathFrame <= frame and
					(previous.phase == "windup" or previous.phase == "recovery")
				then
					moveDiagnostic.targetDeathCases = moveDiagnostic.targetDeathCases + 1
					if snapshot.hasFightCommand then
						moveDiagnostic.targetDeathFightPreserved = moveDiagnostic.targetDeathFightPreserved + 1
					end
					Spring.Echo(string.format(
						"[AOE Attack Regression] %s target death phase=%s attacker=%d target=%d deathFrame=%d fightPreserved=%s front={%s}",
						snapshot.hasFightCommand and "PASS" or "FAIL", previous.phase, unitID,
						previous.targetUnitID, targetDeathFrame, tostring(snapshot.hasFightCommand), snapshot.frontCommand
					))
				end
				if collisionProtectedInterval then
					positionDiagnostic.collisionLockedFrames = positionDiagnostic.collisionLockedFrames + 1
					if stoppedDisplacement then
						positionDiagnostic.collisionLockedDisplacements = positionDiagnostic.collisionLockedDisplacements + 1
						positionDiagnostic.maxCollisionLockedDisplacement = math.max(
							positionDiagnostic.maxCollisionLockedDisplacement,
							distance
						)
					end
				end
				local shortReversal = false
				if distance >= 0.04 and distance <= 4.0 and previousDistance >= 0.04 and previousDistance <= 4.0 then
					local directionDot = snapshot.deltaX * (previous.deltaX or 0) + snapshot.deltaZ * (previous.deltaZ or 0)
					local directionCos = directionDot / (distance * previousDistance)
					shortReversal =
						directionCos <= -0.5 and
						(snapshot.roundTrip or math.huge) <= 0.5 and
						(snapshot.collisionLocked or previous.collisionLocked or snapshot.phase ~= "mobile" or snapshot.target ~= "none")
				end

				if
					stoppedDisplacement and
					collisionProtectedInterval and
					positionDiagnostic.protectedTriggerCount < positionDiagnostic.maxProtectedTriggerCount
				then
					triggerReason = "collision-locked-displacement"
					positionDiagnostic.protectedTriggerCount = positionDiagnostic.protectedTriggerCount + 1
				elseif frame >= state.cooldownUntil and positionDiagnostic.triggerCount < positionDiagnostic.maxTriggerCount then
					if stoppedDisplacement and snapshot.collisionLocked then
						triggerReason = "collision-lock-entry-displacement"
					elseif stoppedDisplacement and previous.collisionLocked then
						triggerReason = "collision-lock-exit-displacement"
					elseif shortReversal then
						triggerReason = "short-reversal"
					end
				end
			end

			history[#history + 1] = snapshot
			while #history > positionDiagnostic.historyFrames do
				table.remove(history, 1)
			end

			if triggerReason then
				if triggerReason ~= "collision-locked-displacement" then
					positionDiagnostic.triggerCount = positionDiagnostic.triggerCount + 1
				end
				state.cooldownUntil = frame + positionDiagnostic.cooldownFrames
				state.followUntil = frame + positionDiagnostic.followFrames
				Spring.Echo(string.format(
					"[AOE Position Diagnostic] trigger=%d/%d protectedTrigger=%d/%d reason=%s unit=%d team=%s frame=%d historyFrames=%d",
					positionDiagnostic.triggerCount, positionDiagnostic.maxTriggerCount,
					positionDiagnostic.protectedTriggerCount, positionDiagnostic.maxProtectedTriggerCount, triggerReason,
					unitID, sample.teamName, frame, #history
				))
				for historyIndex, historicalSnapshot in ipairs(history) do
					LogPositionSnapshot("history-" .. tostring(#history - historyIndex), unitID, sample.teamName, historicalSnapshot)
				end
			elseif state.followUntil >= frame then
				LogPositionSnapshot("follow", unitID, sample.teamName, snapshot)
			end
		end
	end
end

local function GetUnitMoveDiagnostic(unitID)
	local x, y, z = Spring.GetUnitPosition(unitID)
	if not x then
		return nil
	end

	local velocityX, _, velocityZ = Spring.GetUnitVelocity(unitID)
	local speed = math.sqrt((velocityX or 0) ^ 2 + (velocityZ or 0) ^ 2)
	local queueCount = Spring.GetUnitCommandCount(unitID) or 0
	local commands = Spring.GetUnitCommands(unitID, 3) or {}
	local expectedTarget = expectedFightTargets[unitID]
	local distanceToExpected = -1
	if expectedTarget then
		local dx = expectedTarget.x - x
		local dz = expectedTarget.z - z
		distanceToExpected = math.sqrt(dx * dx + dz * dz)
	end

	return {
		x = x,
		y = y,
		z = z,
		speed = speed,
		queueCount = queueCount,
		commands = commands,
		distanceToExpected = distanceToExpected,
	}
end

local function LogPostEliminationSnapshot(frame)
	local units = Spring.GetTeamUnits(moveDiagnostic.survivorTeamID)
	local stopped = 0
	local stalled = 0
	local queueEmpty = 0
	local stalledQueueEmpty = 0
	local fightFront = 0
	local attackFront = 0
	local failedSurvivors = 0
	local detailCount = 0
	local maxDetails = 16

	for _, unitID in ipairs(units) do
		local diagnostic = GetUnitMoveDiagnostic(unitID)
		if diagnostic then
			local frontCommand = diagnostic.commands[1]
			local isStopped = diagnostic.speed <= 0.01
			local isStalled = isStopped and diagnostic.distanceToExpected > stalledDistanceThreshold

			if isStopped then
				stopped = stopped + 1
			end
			if diagnostic.queueCount == 0 then
				queueEmpty = queueEmpty + 1
			end
			if frontCommand and frontCommand.id == CMD.FIGHT then
				fightFront = fightFront + 1
			elseif frontCommand and frontCommand.id == CMD.ATTACK then
				attackFront = attackFront + 1
			end
			if moveDiagnostic.failuresByUnit[unitID] then
				failedSurvivors = failedSurvivors + 1
			end

			if isStalled then
				stalled = stalled + 1
				if diagnostic.queueCount == 0 then
					stalledQueueEmpty = stalledQueueEmpty + 1
				end
				if detailCount < maxDetails then
					detailCount = detailCount + 1
					Spring.Echo(string.format(
						"[AOE Move Diagnostic] stalled frame=%d unit=%d team=%d pos=(%.1f,%.1f,%.1f) speed=%.4f expectedDistance=%.1f queue=%d front={%s} failures=%d",
						frame, unitID, moveDiagnostic.survivorTeamID,
						diagnostic.x, diagnostic.y, diagnostic.z, diagnostic.speed,
						diagnostic.distanceToExpected, diagnostic.queueCount,
						FormatCommand(frontCommand), moveDiagnostic.failuresByUnit[unitID] or 0
					))
				end
			end
		end
	end

	Spring.Echo(string.format(
		"[AOE Move Diagnostic] post-elimination frame=%d elapsed=%d survivor=%s alive=%d stopped=%d stalled=%d queueEmpty=%d stalledQueueEmpty=%d fightFront=%d attackFront=%d failedSurvivors=%d totalMoveFailures=%d corpseFeatures=%d detailLimit=%d",
		frame, frame - moveDiagnostic.eliminationFrame, moveDiagnostic.survivorName,
		#units, stopped, stalled, queueEmpty, stalledQueueEmpty, fightFront, attackFront,
		failedSurvivors, moveDiagnostic.totalFailures, #Spring.GetAllFeatures(), maxDetails
	))
end

local function UpdateEliminationDiagnostic(frame)
	-- This diagnostic supports large test formations, so avoid scanning both
	-- teams every simulation frame while waiting for an elimination.
	if frame % eliminationCheckPeriod ~= 0 then
		return
	end

	if not moveDiagnostic.eliminationFrame then
		local liveA = #Spring.GetTeamUnits(teams[1].teamID)
		local liveB = #Spring.GetTeamUnits(teams[2].teamID)
		if liveA == 0 and liveB > 0 then
			moveDiagnostic.eliminationFrame = frame
			moveDiagnostic.survivorTeamID = teams[2].teamID
			moveDiagnostic.survivorName = teams[2].name
			moveDiagnostic.eliminatedName = teams[1].name
		elseif liveB == 0 and liveA > 0 then
			moveDiagnostic.eliminationFrame = frame
			moveDiagnostic.survivorTeamID = teams[1].teamID
			moveDiagnostic.survivorName = teams[1].name
			moveDiagnostic.eliminatedName = teams[2].name
		end

		if moveDiagnostic.eliminationFrame then
			Spring.Echo(string.format(
				"[AOE Move Diagnostic] team eliminated frame=%d eliminated=%s survivor=%s totalMoveFailures=%d",
				frame, moveDiagnostic.eliminatedName, moveDiagnostic.survivorName, moveDiagnostic.totalFailures
			))
		end
	end

	if not moveDiagnostic.eliminationFrame then
		return
	end

	local elapsed = frame - moveDiagnostic.eliminationFrame
	for _, offset in ipairs(moveDiagnostic.snapshotOffsets) do
		if elapsed == offset and not moveDiagnostic.snapshotsLogged[offset] then
			moveDiagnostic.snapshotsLogged[offset] = true
			LogPostEliminationSnapshot(frame)
			break
		end
	end
end

local function GetCombatStatus(team)
	local units = Spring.GetTeamUnits(team.teamID)
	local damaged = 0
	local minimumHealth = math.huge
	for _, unitID in ipairs(units) do
		local health = Spring.GetUnitHealth(unitID)
		if health then
			minimumHealth = math.min(minimumHealth, health)
			if health < 100 then
				damaged = damaged + 1
			end
		end
	end
	return #units, damaged, (minimumHealth == math.huge) and 0 or minimumHealth
end

local function LogStatus(frame)
	local liveA, damagedA, minimumHealthA = GetCombatStatus(teams[1])
	local liveB, damagedB, minimumHealthB = GetCombatStatus(teams[2])
	local sampleUnitID = teams[1].units[1]
	local weaponRange = sampleUnitID and Spring.GetUnitWeaponState(sampleUnitID, 1, "range") or 0
	local reloadFrame = sampleUnitID and Spring.GetUnitWeaponState(sampleUnitID, 1, "reloadFrame") or 0
	Spring.Echo(string.format(
		"[AOE Gameplay Test] frame=%d liveA=%d damagedA=%d minHealthA=%.1f liveB=%d damagedB=%d minHealthB=%.1f corpseFeatures=%d projectiles=%d weaponRange=%.1f reloadFrame=%d",
		frame, liveA, damagedA, minimumHealthA, liveB, damagedB, minimumHealthB,
		#Spring.GetAllFeatures(), #Spring.GetAllProjectiles(), weaponRange or 0, reloadFrame or 0
	))
end

local function AuditAttackStartSpeed(frame)
	if not attackCannotMoveConfigured then
		return
	end

	for _, team in ipairs(teams) do
		for index = 1, math.min(64, #team.units) do
			local unitID = team.units[index]
			if not attackStartAudit.checked[unitID] and Spring.ValidUnitID(unitID) then
				local reloadFrame = Spring.GetUnitWeaponState(unitID, 1, "reloadFrame") or 0
				if reloadFrame > frame then
					local velocityX, _, velocityZ = Spring.GetUnitVelocity(unitID)
					local horizontalSpeed = math.sqrt((velocityX or 0) ^ 2 + (velocityZ or 0) ^ 2)
					attackStartAudit.checked[unitID] = true
					attackStartAudit.samples = attackStartAudit.samples + 1
					if horizontalSpeed > 0.011 then
						attackStartAudit.violations = attackStartAudit.violations + 1
						Spring.Echo(string.format(
							"[AOE Gameplay Test] attack-start speed violation unit=%d frame=%d speed=%.6f",
							unitID, frame, horizontalSpeed
						))
					end
				end
			end
		end
	end
end

local function SendAnchorPoint(x, y, z, label)
	SendToUnsynced("aoe_anchor_point", x, y, z, label)
end

local function SendAnchorLine(x1, y1, z1, x2, y2, z2)
	SendToUnsynced("aoe_anchor_line", x1, y1, z1, x2, y2, z2)
end

local function LogAnchorState(unitID, label)
	local baseX, baseY, baseZ, _, _, _, aimX, aimY, aimZ = Spring.GetUnitPosition(unitID, true, true)
	local muzzleX, muzzleY, muzzleZ, dirX, dirY, dirZ = Spring.GetUnitWeaponVectors(unitID, 1)
	Spring.Echo(string.format(
		"[AOE Anchor Test] %s unit=%d base=(%.2f,%.2f,%.2f) aim=(%.2f,%.2f,%.2f) muzzle=(%.2f,%.2f,%.2f) weaponDir=(%.3f,%.3f,%.3f)",
		label, unitID, baseX, baseY, baseZ, aimX, aimY, aimZ, muzzleX, muzzleY, muzzleZ, dirX, dirY, dirZ
	))
	SendAnchorPoint(baseX, baseY, baseZ, label .. " foot")
	SendAnchorPoint(aimX, aimY, aimZ, label .. " aim")
	SendAnchorPoint(muzzleX, muzzleY, muzzleZ, label .. " muzzle")
	SendAnchorLine(baseX, baseY, baseZ, muzzleX, muzzleY, muzzleZ)
	SendAnchorLine(muzzleX, muzzleY, muzzleZ, muzzleX + dirX * 48, muzzleY + dirY * 48, muzzleZ + dirZ * 48)
end

local function SpawnAnchorValidation()
	local centerX = Game.mapSizeX * 0.5
	local centerZ = Game.mapSizeZ * 0.5
	local targetID = Spring.CreateUnit("aoe_archer", centerX, Spring.GetGroundHeight(centerX, centerZ), centerZ, "south", 1)
	if not targetID then
		error("[AOE Anchor Test] failed to create target")
	end
	anchorTest.targetID = targetID
	Spring.GiveOrderToUnit(targetID, CMD.FIRE_STATE, {0}, {})

	for index, testCase in ipairs(anchorCases) do
		local distance = 360
		local x = centerX - testCase.x * distance
		local z = centerZ - testCase.z * distance
		local unitID = Spring.CreateUnit("aoe_archer", x, Spring.GetGroundHeight(x, z), z, "south", 0)
		if not unitID then
			error("[AOE Anchor Test] failed to create attacker " .. testCase.label)
		end
		-- Supply both front and right vectors so the test also covers diagonal headings.
		Spring.SetUnitDirection(unitID, testCase.x, 0, testCase.z, -testCase.z, 0, testCase.x)
		Spring.GiveOrderToUnit(unitID, CMD.FIRE_STATE, {0}, {})
		anchorTest.attackers[#anchorTest.attackers + 1] = { unitID = unitID, label = testCase.label }
		anchorTest.attackFrames[index] = 90 + (index - 1) * 120
	end

	Spring.Echo("[AOE Anchor Test] DAT weapon_offset=(0,0.5,1.5), converted muzzle_local=(0,31.5,30), aim_local=(0,21,0)")
	LogAnchorState(targetID, "target")
	for _, attacker in ipairs(anchorTest.attackers) do
		LogAnchorState(attacker.unitID, attacker.label)
	end
end

local function ResetCombatDiagnostics()
	attackStartAudit = { checked = {}, samples = 0, violations = 0 }
	expectedFightTargets = {}
	destroyedUnitFrames = {}
	moveDiagnostic = {
		totalFailures = 0,
		failuresByUnit = {},
		eliminationFrame = nil,
		survivorTeamID = nil,
		survivorName = nil,
		eliminatedName = nil,
		snapshotOffsets = { 0, 30, 150, 300, 600, 900 },
		snapshotsLogged = {},
		targetDeathCases = 0,
		targetDeathFightPreserved = 0,
	}
	positionDiagnostic = {
		units = {},
		states = {},
		triggerCount = 0,
		maxTriggerCount = 16,
		protectedTriggerCount = 0,
		maxProtectedTriggerCount = 16,
		historyFrames = 8,
		followFrames = 12,
		cooldownFrames = 60,
		collisionLockedFrames = 0,
		collisionLockedDisplacements = 0,
		maxCollisionLockedDisplacement = 0,
	}
	explicitMoveRegression = {
		cases = {},
		completed = 0,
		passed = 0,
		deadlineFrame = activeAttackMoveFrame + 1200,
	}
end

local function StartCombatRound(frame, isReset)
	combatRound = combatRound + 1
	activeAttackMoveFrame = frame + attackMoveStartFrame

	for _, team in ipairs(teams) do
		team.units = {}
		team.towerID = nil
	end

	ResetCombatDiagnostics()
	SpawnFormation(teams[1])
	SpawnFormation(teams[2])
	SpawnTeamTower(teams[1])
	SpawnTeamTower(teams[2])
	InitializePositionDiagnostic()
	InitializeExplicitMoveRegression()

	Spring.Echo(string.format(
		"[AOE Gameplay Test] round=%d %s; attackMoveFrame=%d",
		combatRound, isReset and "reset" or "initialized", activeAttackMoveFrame
	))
end

local function ResetArmorCombatRound()
	if not armorUpgradeTestEnabled then
		return
	end

	for projectileID in pairs(combatProjectileIDs) do
		Spring.DeleteProjectile(projectileID)
	end
	for featureID in pairs(combatFeatureIDs) do
		Spring.DestroyFeature(featureID)
	end
	combatProjectileIDs = {}
	combatFeatureIDs = {}
	for _, team in ipairs(teams) do
		for _, unitID in ipairs(team.units) do
			if Spring.ValidUnitID(unitID) then
				Spring.DestroyUnit(unitID, false, true, nil, true)
			end
		end
		if team.towerID and Spring.ValidUnitID(team.towerID) then
			Spring.DestroyUnit(team.towerID, false, true, nil, true)
		end
	end

	StartCombatRound(Spring.GetGameFrame(), true)
end

function gadget:GameStart()
	if buildingTest or meleeCalibration or meleeBattle or chukonuTest then
		return
	end

	local archerDef = UnitDefs[UnitDefNames.aoe_archer.id]
	local arrowDef = WeaponDefs[WeaponDefNames.aoe_arrow.id]
	Spring.Echo(string.format(
		"[AOE Gameplay Test] attackCannotMove=%s attackStartSpeedThreshold=%.3f attackRecoveryTime=%.3f range=%.1f sightDistance=%.1f turret=%s maxAngle=%.4f impactOnly=%s impulseFactor=%.1f impulseBoost=%.1f",
		tostring(archerDef.attackCannotMove), archerDef.attackStartSpeedThreshold, arrowDef.attackRecoveryTime,
		arrowDef.range, archerDef.losRadius, tostring(arrowDef.turret), arrowDef.maxAngle,
		tostring(arrowDef.impactOnly), arrowDef.damages.impulseFactor, arrowDef.damages.impulseBoost
	))

	if anchorCalibration then
		return
	end

	if anchorValidation then
		Script.SetWatchWeapon(WeaponDefNames.aoe_arrow.id, true)
		SpawnAnchorValidation()
		return
	end

	Spring.Echo(string.format(
		"[AOE Move Diagnostic] enabled eliminationCheckPeriod=%d snapshotOffsets=0,30,150,300,600,900 sampledMoveFailures=%d",
		eliminationCheckPeriod, positionDiagnosticSamplesPerTeam * 2
	))

	-- This is deliberately scoped to the local render test's player AllyTeam.
	-- It preserves normal enemy relations and command authority while bypassing
	-- LOS-based visual hiding for remote units, features, and projectiles.
	Spring.SetGlobalLos(0, globalLosForTeamA)
	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team A global LOS=%s",
		tostring(Spring.GetGlobalLos(0))
	))

	StartCombatRound(Spring.GetGameFrame(), false)
	Spring.Echo(string.format("[AOE Gameplay Test] Team A/B allied=%s", tostring(Spring.AreTeamsAllied(teams[1].teamID, teams[2].teamID))))
	Spring.Echo(string.format(
		"[AOE Gameplay Test] spacing=%.1f separation=%.1f attackMoveFrame=%d counterAttack=%s globalLos=%s",
		formationSpacing, formationSeparation, activeAttackMoveFrame, tostring(counterAttack), tostring(globalLosForTeamA)
	))
end

function gadget:GameFrame(frame)
	if armorUpgradeTestEnabled and frame == 60 and GG.AoeArmor ~= nil then
		GG.AoeArmor.ApplyTeamUpgrade(0, "fletching")
		GG.AoeArmor.ApplyTeamUpgrade(1, "padded_archer_armor")
		Spring.Echo("[AOE Armor Test] applied Team A fletching and Team B padded archer armor")
	end
	if castleRapidFireUpgradeTestEnabled and frame == 60 and GG.AoeArmor ~= nil then
		GG.AoeArmor.ApplyTeamUpgrade(0, "castle_rapid_fire")
		GG.AoeArmor.ApplyTeamUpgrade(1, "castle_rapid_fire")
		Spring.Echo("[AOE Castle Test] applied castle_rapid_fire (burst=10) to both teams")
	end

	if buildingTest or anchorCalibration or meleeCalibration or meleeBattle then
		return
	end

	if anchorValidation then
		for index, attacker in ipairs(anchorTest.attackers) do
			if frame == anchorTest.attackFrames[index] then
				LogAnchorState(attacker.unitID, attacker.label .. " pre-fire")
				Spring.GiveOrderToUnit(attacker.unitID, CMD.FIRE_STATE, {2}, {})
				Spring.GiveOrderToUnit(attacker.unitID, CMD.ATTACK, {anchorTest.targetID}, {})
				Spring.Echo(string.format("[AOE Anchor Test] issued native CMD.ATTACK attacker=%s frame=%d target=%d", attacker.label, frame, anchorTest.targetID))
			elseif frame == anchorTest.attackFrames[index] + 45 then
				Spring.GiveOrderToUnit(attacker.unitID, CMD.FIRE_STATE, {0}, {})
				Spring.GiveOrderToUnit(attacker.unitID, CMD.STOP, {}, {})
			end
		end
		if frame == 780 then
			Spring.SetUnitDirection(anchorTest.targetID, 1, 0, 0, 0, 0, 1)
			LogAnchorState(anchorTest.targetID, "target rotated east")
		end
		return
	end

	AuditAttackStartSpeed(frame)

	if frame == activeAttackMoveFrame then
		GiveAttackMove(teams[1], teams[2].center)
		if counterAttack then
			GiveAttackMove(teams[2], teams[1].center)
		end
	end

	if frame >= activeAttackMoveFrame then
		UpdatePositionDiagnostic(frame)
		UpdateExplicitMoveRegression(frame)
		UpdateEliminationDiagnostic(frame)
	end

	if frame > 0 and frame % statusLogPeriod == 0 then
		LogStatus(frame)
		Spring.Echo(string.format(
			"[AOE Gameplay Test] attack-start audit samples=%d violations=%d",
			attackStartAudit.samples, attackStartAudit.violations
		))
		Spring.Echo(string.format(
			"[AOE Attack Regression] target-death Fight preservation passed=%d/%d",
			moveDiagnostic.targetDeathFightPreserved, moveDiagnostic.targetDeathCases
		))
		Spring.Echo(string.format(
			"[AOE Position Diagnostic] collision-lock audit protectedFrames=%d displacementViolations=%d maxDisplacement=%.6f",
			positionDiagnostic.collisionLockedFrames,
			positionDiagnostic.collisionLockedDisplacements,
			positionDiagnostic.maxCollisionLockedDisplacement
		))
	end
end

function gadget:RecvLuaMsg(message, playerID)
	if message ~= ARMOR_RESET_MESSAGE or not armorUpgradeTestEnabled then
		return false
	end

	ResetArmorCombatRound()
	return true
end

function gadget:UnitDestroyed(unitID)
	destroyedUnitFrames[unitID] = Spring.GetGameFrame()
end

function gadget:FeatureCreated(featureID)
	if armorUpgradeTestEnabled then
		combatFeatureIDs[featureID] = true
	end
end

function gadget:FeatureDestroyed(featureID)
	combatFeatureIDs[featureID] = nil
end

function gadget:ProjectileCreated(projectileID, ownerID, weaponDefID)
	if armorUpgradeTestEnabled then
		combatProjectileIDs[projectileID] = true
	end
	if not anchorValidation or weaponDefID ~= WeaponDefNames.aoe_arrow.id then
		return
	end
	local x, y, z = Spring.GetProjectilePosition(projectileID)
	Spring.Echo(string.format("[AOE Anchor Test] projectile=%d owner=%d start=(%.2f,%.2f,%.2f)", projectileID, ownerID, x or 0, y or 0, z or 0))
	SendAnchorPoint(x, y, z, "projectile start")
end

function gadget:ProjectileDestroyed(projectileID)
	combatProjectileIDs[projectileID] = nil
end

function gadget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID)
	if not anchorValidation or unitID ~= anchorTest.targetID or weaponDefID ~= WeaponDefNames.aoe_arrow.id then
		return
	end
	local _, _, _, _, _, _, aimX, aimY, aimZ = Spring.GetUnitPosition(unitID, true, true)
	Spring.Echo(string.format("[AOE Anchor Test] target hit projectile=%d damage=%.2f targetAim=(%.2f,%.2f,%.2f)", projectileID or -1, damage, aimX, aimY, aimZ))
	SendAnchorPoint(aimX, aimY, aimZ, "target hit aim")
end
