function gadget:GetInfo()
	return {
		name = "AOE Armor Upgrades",
		desc = "Applies configured AOE2-style class attack and armor upgrades",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = -10,
		enabled = Spring.AddUnitAoeArmor ~= nil and Spring.AddUnitAoeWeaponDamage ~= nil,
	}
end

if not gadgetHandler:IsSyncedCode() then
	return
end

local upgrades = VFS.Include("LuaRules/Configs/aoe_upgrades.lua")
local activeUpgrades = {}

local function HasAnyTag(actualTags, requiredTags)
	if requiredTags == nil or #requiredTags == 0 then
		return false
	end

	local lookup = {}
	for _, tag in ipairs(actualTags or {}) do
		lookup[tag] = true
	end
	for _, tag in ipairs(requiredTags) do
		if lookup[tag] then
			return true
		end
	end
	return false
end

local function ApplyUpgradeToUnit(unitID, unitDefID, upgrade)
	local unitDef = UnitDefs[unitDefID]
	if unitDef == nil then
		return
	end

	if upgrade.armor ~= nil and HasAnyTag(unitDef.aoeUpgradeTags, upgrade.unitTags) then
		Spring.AddUnitAoeArmor(unitID, upgrade.armor)
	end

	if upgrade.damage == nil then
		return
	end

	for weaponNum, unitWeapon in ipairs(unitDef.weapons or {}) do
		local weaponDef = WeaponDefs[unitWeapon.weaponDef]
		if weaponDef ~= nil and HasAnyTag(weaponDef.aoeUpgradeTags, upgrade.weaponTags) then
			Spring.AddUnitAoeWeaponDamage(unitID, weaponNum, upgrade.damage)
		end
	end
end

local function ApplyActiveUpgradesToUnit(unitID, unitDefID, teamID)
	local teamUpgrades = activeUpgrades[teamID]
	if teamUpgrades == nil then
		return
	end

	for _, upgradeID in ipairs(teamUpgrades.ids) do
		ApplyUpgradeToUnit(unitID, unitDefID, upgrades[upgradeID])
	end
end

GG.AoeArmor = GG.AoeArmor or {}

function GG.AoeArmor.ApplyTeamUpgrade(teamID, upgradeID)
	local upgrade = upgrades[upgradeID]
	if upgrade == nil then
		Spring.Echo(string.format("[AOE Armor] unknown upgrade '%s'", tostring(upgradeID)))
		return false
	end

	local teamUpgrades = activeUpgrades[teamID]
	if teamUpgrades == nil then
		teamUpgrades = { ids = {}, lookup = {} }
		activeUpgrades[teamID] = teamUpgrades
	end
	if teamUpgrades.lookup[upgradeID] then
		return false
	end

	teamUpgrades.lookup[upgradeID] = true
	teamUpgrades.ids[#teamUpgrades.ids + 1] = upgradeID
	for _, unitID in ipairs(Spring.GetTeamUnits(teamID)) do
		ApplyUpgradeToUnit(unitID, Spring.GetUnitDefID(unitID), upgrade)
	end

	Spring.Echo(string.format("[AOE Armor] team=%d applied=%s", teamID, upgradeID))
	return true
end

function gadget:UnitCreated(unitID, unitDefID, unitTeam)
	ApplyActiveUpgradesToUnit(unitID, unitDefID, unitTeam)
end

function gadget:Shutdown()
	if GG.AoeArmor ~= nil then
		GG.AoeArmor.ApplyTeamUpgrade = nil
	end
end
