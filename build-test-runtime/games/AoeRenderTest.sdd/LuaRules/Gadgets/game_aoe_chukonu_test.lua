function gadget:GetInfo()
	return {
		name = "AOE Chu Ko Nu Salvo Test",
		desc = "Acceptance test for per-shot aoeSalvoDamage profiles on the Chu Ko Nu",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = 2,
		enabled = true,
	}
end

-- DAT 73 fires three arrows per attack cycle: the first carries the unit attack
-- (8 pierce plus the spearman bonus) and the two follow-up bolts are fixed at
-- 3 pierce. The follow-up value cannot be read back from Lua because
-- `aoeSalvoDamage` is an engine-side table, so it is repeated here as the
-- specification under test.
local ATTACKER_NAME = "aoe_chukonu"
local TARGET_NAME = "aoe_archer"
local WEAPON_NAME = "aoe_chukonu_arrow"
local UPGRADE_ID = "fletching"
local PROFILE_FOLLOWUP_ATTACK = { pierce = 3 }

local SPAWN_FRAME = 30
local ATTACK1_FRAME = 90
local STOP1_FRAME = 170
local EVAL1_FRAME = 180
local UPGRADE_FRAME = 200
local ATTACK2_FRAME = 230
local STOP2_FRAME = 310
local EVAL2_FRAME = 320
local END_FRAME = 340

-- Centre distance between attacker and target. The weapon range is 240, so the
-- pair starts inside range and the volley has a visible flight time.
local ENGAGEMENT_DISTANCE = 180

local options = Spring.GetModOptions()

local function ReadBoolean(name, defaultValue)
	local value = options[name]
	if value == nil then
		return defaultValue
	end
	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

if not ReadBoolean("aoe_chukonu_test", false) then
	return
end

if not gadgetHandler:IsSyncedCode() then
	return
end

-- Mirrors CalculateAoeArmorDamage() in Sim/Misc/DamageArray.cpp: only classes
-- declared by both the attack and target contribute. Missing target classes
-- are ignored, and the total floors at one.
-- Mirrors AddAoeArmorEntries() in the same file: a technology appends its
-- deltas, and normalization sums entries that name the same class.
local function MergeAttack(baseAttack, delta)
	local merged = {}
	for className, value in pairs(baseAttack or {}) do
		merged[className] = value
	end
	for className, value in pairs(delta or {}) do
		merged[className] = (merged[className] or 0) + value
	end
	return merged
end

local function ComputeAoeDamage(attackEntries, armorEntries)
	local total = 0
	for className, attackValue in pairs(attackEntries or {}) do
		local armorValue = armorEntries and armorEntries[className]
		if armorValue ~= nil then
			total = total + math.max(0, attackValue - armorValue)
		end
	end
	return math.max(1, total)
end

local test = {
	weaponDefID = nil,
	attackerID = nil,
	targetID = nil,
	hits = {},
	volleys = {},
	summaryLogged = false,
}

local function SpawnPair()
	local targetX = Game.mapSizeX * 0.5
	local targetZ = Game.mapSizeZ * 0.5
	test.targetID = Spring.CreateUnit(TARGET_NAME, targetX, Spring.GetGroundHeight(targetX, targetZ), targetZ, "south", 1)
	if not test.targetID then
		error("[AOE Chu Ko Nu Test] failed to create target")
	end
	-- Hold fire so the target never retaliates and cannot pollute the hit log.
	Spring.GiveOrderToUnit(test.targetID, CMD.FIRE_STATE, {0}, {})

	-- Neutralise the Recoil flanking damage bonus on the target. Its default
	-- band is [0.9, 1.9] and a stationary target converges to the 0.9 minimum,
	-- which would scale every profile value by a factor unrelated to the salvo
	-- damage table under test. Setting min == max pins the bonus at 1.0.
	Spring.SetUnitFlanking(test.targetID, "minDamage", 1.0)
	Spring.SetUnitFlanking(test.targetID, "maxDamage", 1.0)

	local attackerX = targetX - ENGAGEMENT_DISTANCE
	test.attackerID = Spring.CreateUnit(ATTACKER_NAME, attackerX, Spring.GetGroundHeight(attackerX, targetZ), targetZ, "east", 0)
	if not test.attackerID then
		error("[AOE Chu Ko Nu Test] failed to create attacker")
	end

	Spring.Echo(string.format(
		"[AOE Chu Ko Nu Test] spawned attacker=%d target=%d distance=%d",
		test.attackerID, test.targetID, ENGAGEMENT_DISTANCE
	))
end

local function BeginVolley()
	Spring.GiveOrderToUnit(test.attackerID, CMD.FIRE_STATE, {2}, {})
	Spring.GiveOrderToUnit(test.attackerID, CMD.ATTACK, {test.targetID}, {})
	Spring.Echo(string.format("[AOE Chu Ko Nu Test] issued CMD.ATTACK attacker=%d target=%d frame=%d",
		test.attackerID, test.targetID, Spring.GetGameFrame()))
end

local function EndVolley()
	Spring.GiveOrderToUnit(test.attackerID, CMD.STOP, {}, {})
	Spring.GiveOrderToUnit(test.attackerID, CMD.FIRE_STATE, {0}, {})
end

local function CollectVolley(fromFrame, toFrame)
	local hits = {}
	for index, hit in ipairs(test.hits) do
		if hit.frame >= fromFrame and hit.frame <= toFrame then
			hits[#hits + 1] = hit
		end
	end
	return hits
end

local function FormatHits(hits)
	local parts = {}
	for index, hit in ipairs(hits) do
		parts[#parts + 1] = string.format("%d:%.2f@f%d", index, hit.damage, hit.frame)
	end
	return table.concat(parts, " ")
end

local function EvaluateVolley(label, hits, expectedMain, expectedFollowUp)
	local problems = {}
	if #hits ~= 3 then
		problems[#problems + 1] = string.format("hitCount=%d(expected 3)", #hits)
	end
	if (hits[1] or {}).damage ~= expectedMain then
		problems[#problems + 1] = string.format("shot1=%.2f(expected %.2f)", (hits[1] or {}).damage or -1, expectedMain)
	end
	for index = 2, 3 do
		if (hits[index] or {}).damage ~= expectedFollowUp then
			problems[#problems + 1] = string.format("shot%d=%.2f(expected %.2f)", index, (hits[index] or {}).damage or -1, expectedFollowUp)
		end
	end

	local passed = #problems == 0
	Spring.Echo(string.format(
		"[AOE Chu Ko Nu Test] %s volley=%s hits=[%s] expected=[%.2f,%.2f,%.2f] issues=%s",
		passed and "PASS" or "FAIL", label, FormatHits(hits),
		expectedMain, expectedFollowUp, expectedFollowUp,
		passed and "none" or table.concat(problems, ",")
	))
	test.volleys[#test.volleys + 1] = { label = label, passed = passed, hits = #hits }
	return passed
end

function gadget:GameStart()
	test.weaponDefID = WeaponDefNames[WEAPON_NAME] and WeaponDefNames[WEAPON_NAME].id
	if not test.weaponDefID then
		error("[AOE Chu Ko Nu Test] weapon def not found: " .. WEAPON_NAME)
	end

	local targetDefID = UnitDefNames[TARGET_NAME] and UnitDefNames[TARGET_NAME].id
	local attackerDefID = UnitDefNames[ATTACKER_NAME] and UnitDefNames[ATTACKER_NAME].id
	if not targetDefID or not attackerDefID then
		error("[AOE Chu Ko Nu Test] unit def not found")
	end

	-- Watch the weapon so projectile spawns are reported alongside the hits.
	Script.SetWatchWeapon(test.weaponDefID, true)

	-- Read the applied technology so the post-upgrade expectation follows
	-- config changes instead of a hard-coded delta.
	local upgrade = VFS.Include("LuaRules/Configs/aoe_upgrades.lua")[UPGRADE_ID]
	local upgradePierce = (upgrade and upgrade.damage and upgrade.damage.pierce) or 0
	test.upgradeAttack = { pierce = upgradePierce }

	test.baseAttack = WeaponDefs[test.weaponDefID].aoeDamage
	test.armor = UnitDefs[targetDefID].aoeArmor
	test.expectedMain = ComputeAoeDamage(test.baseAttack, test.armor)
	test.expectedFollowUp = ComputeAoeDamage(PROFILE_FOLLOWUP_ATTACK, test.armor)

	Spring.Echo(string.format(
		"[AOE Chu Ko Nu Test] setup weapon=%s burst=%d burstRate=%.3f windup=%.3f reloadTime=%.3f range=%.1f target=%s expectedMain=%.2f expectedFollowUp=%.2f",
		WEAPON_NAME, WeaponDefs[test.weaponDefID].salvoSize, WeaponDefs[test.weaponDefID].salvoDelay,
		WeaponDefs[test.weaponDefID].windup, WeaponDefs[test.weaponDefID].reload,
		WeaponDefs[test.weaponDefID].range, TARGET_NAME, test.expectedMain, test.expectedFollowUp
	))
end

function gadget:GameFrame(frame)
	if frame == SPAWN_FRAME then
		SpawnPair()
		return
	end

	if frame == ATTACK1_FRAME then
		BeginVolley()
		return
	end
	if frame == STOP1_FRAME then
		EndVolley()
		return
	end
	if frame == EVAL1_FRAME then
		EvaluateVolley("base", CollectVolley(ATTACK1_FRAME, STOP1_FRAME), test.expectedMain, test.expectedFollowUp)
		return
	end

	if frame == UPGRADE_FRAME then
		if GG.AoeArmor == nil or not GG.AoeArmor.ApplyTeamUpgrade(0, UPGRADE_ID) then
			Spring.Echo(string.format("[AOE Chu Ko Nu Test] FAIL could not apply upgrade=%s", UPGRADE_ID))
		end
		-- Only the first bolt inherits the upgraded attack; the follow-up bolts
		-- keep the fixed profile, so expectedFollowUp is deliberately unchanged.
		test.expectedMain = ComputeAoeDamage(MergeAttack(test.baseAttack, test.upgradeAttack), test.armor)
		Spring.Echo(string.format(
			"[AOE Chu Ko Nu Test] upgrade=%s pierce+%d expectedMain=%.2f expectedFollowUp=%.2f",
			UPGRADE_ID, test.upgradeAttack.pierce, test.expectedMain, test.expectedFollowUp
		))
		return
	end

	if frame == ATTACK2_FRAME then
		BeginVolley()
		return
	end
	if frame == STOP2_FRAME then
		EndVolley()
		return
	end
	if frame == EVAL2_FRAME then
		EvaluateVolley(
			"after-" .. UPGRADE_ID,
			CollectVolley(ATTACK2_FRAME, STOP2_FRAME),
			test.expectedMain, test.expectedFollowUp
		)
		return
	end

	if frame == END_FRAME and not test.summaryLogged then
		test.summaryLogged = true
		local passed = 0
		local labels = {}
		for _, volley in ipairs(test.volleys) do
			if volley.passed then
				passed = passed + 1
			end
			labels[#labels + 1] = string.format("%s=%s(hits=%d)", volley.label, volley.passed and "PASS" or "FAIL", volley.hits)
		end
		Spring.Echo(string.format(
			"[AOE Chu Ko Nu Test] summary %s volleys=%s health=%.2f",
			passed == #test.volleys and "PASS" or "FAIL",
			table.concat(labels, " "),
			Spring.GetUnitHealth(test.targetID) or -1
		))
	end
end

function gadget:ProjectileCreated(projectileID, ownerID, weaponDefID)
	if ownerID ~= test.attackerID or weaponDefID ~= test.weaponDefID then
		return
	end
	Spring.Echo(string.format("[AOE Chu Ko Nu Test] projectile=%d spawned frame=%d", projectileID, Spring.GetGameFrame()))
end

function gadget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID)
	if unitID ~= test.targetID or weaponDefID ~= test.weaponDefID then
		return
	end
	test.hits[#test.hits + 1] = {
		damage = damage,
		frame = Spring.GetGameFrame(),
		projectileID = projectileID,
	}
	Spring.Echo(string.format(
		"[AOE Chu Ko Nu Test] hit projectile=%d damage=%.2f frame=%d",
		projectileID or -1, damage, Spring.GetGameFrame()
	))
end
