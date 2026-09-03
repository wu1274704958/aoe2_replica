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

if not gadgetHandler:IsSyncedCode() then
	return false
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
local globalLosForTeamA = ReadBooleanOption("aoe_global_los", true)
local statusLogPeriod = 150
local attackStartAudit = { checked = {}, samples = 0, violations = 0 }

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

local function SpawnFormation(team)
	local dimensions = team.dimensions
	for index = 1, team.count do
		local column = (index - 1) % dimensions.columns
		local row = math.floor((index - 1) / dimensions.columns)
		local x = team.center.x - dimensions.width * 0.5 + column * formationSpacing
		local z = team.center.z - dimensions.depth * 0.5 + row * formationSpacing
		local unitID = Spring.CreateUnit("aoe_archer", x, Spring.GetGroundHeight(x, z), z, team.facing, team.teamID)
		if unitID then
			team.units[#team.units + 1] = unitID
		end
	end

	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team %s created=%d/%d center=(%.1f, %.1f) grid=%dx%d",
		team.name, #team.units, team.count, team.center.x, team.center.z,
		dimensions.columns, dimensions.rows
	))
end

local function GiveAttackMove(team, target)
	local targetY = Spring.GetGroundHeight(target.x, target.z)
	local issued = Spring.GiveOrderToUnitArrayGroup(team.units, CMD.FIGHT, {target.x, targetY, target.z}, {})
	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team %s issued native group-locked CMD.FIGHT to (%.1f, %.1f) members=%d accepted=%s at frame %d",
		team.name, target.x, target.z, #team.units, tostring(issued), Spring.GetGameFrame()
	))
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

function gadget:GameStart()
	local archerDef = UnitDefs[UnitDefNames.aoe_archer.id]
	local arrowDef = WeaponDefs[WeaponDefNames.aoe_arrow.id]
	Spring.Echo(string.format(
		"[AOE Gameplay Test] attackCannotMove=%s attackStartSpeedThreshold=%.3f attackRecoveryTime=%.3f",
		tostring(archerDef.attackCannotMove), archerDef.attackStartSpeedThreshold, arrowDef.attackRecoveryTime
	))

	-- This is deliberately scoped to the local render test's player AllyTeam.
	-- It preserves normal enemy relations and command authority while bypassing
	-- LOS-based visual hiding for remote units, features, and projectiles.
	Spring.SetGlobalLos(0, globalLosForTeamA)
	Spring.Echo(string.format(
		"[AOE Gameplay Test] Team A global LOS=%s",
		tostring(Spring.GetGlobalLos(0))
	))

	SpawnFormation(teams[1])
	SpawnFormation(teams[2])
	Spring.Echo(string.format("[AOE Gameplay Test] Team A/B allied=%s", tostring(Spring.AreTeamsAllied(teams[1].teamID, teams[2].teamID))))
	Spring.Echo(string.format(
		"[AOE Gameplay Test] spacing=%.1f separation=%.1f attackMoveFrame=%d counterAttack=%s globalLos=%s",
		formationSpacing, formationSeparation, attackMoveStartFrame, tostring(counterAttack), tostring(globalLosForTeamA)
	))
end

function gadget:GameFrame(frame)
	AuditAttackStartSpeed(frame)

	if frame == attackMoveStartFrame then
		GiveAttackMove(teams[1], teams[2].center)
		if counterAttack then
			GiveAttackMove(teams[2], teams[1].center)
		end
	end

	if frame > 0 and frame % statusLogPeriod == 0 then
		LogStatus(frame)
		Spring.Echo(string.format(
			"[AOE Gameplay Test] attack-start audit samples=%d violations=%d",
			attackStartAudit.samples, attackStartAudit.violations
		))
	end
end
