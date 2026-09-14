function script.Create()
end

function script.StartMoving()
end

function script.StopMoving()
end

function script.AimWeapon()
	return true
end

function script.Shot()
	local x, y, z, directionX, directionY, directionZ = Spring.GetUnitWeaponVectors(unitID, 1)
	if x ~= nil then
		Spring.SpawnCEG("AOE_BOMBARD_MUZZLE", x, y, z, directionX, directionY, directionZ)
	end
end

function script.Killed()
	return 1
end
