local modOptions = Spring.GetModOptions()
local attackCannotMoveValue = tostring(modOptions.aoe_attack_cannot_move or "true"):lower()
local attackCannotMove =
	attackCannotMoveValue == "1" or
	attackCannotMoveValue == "true" or
	attackCannotMoveValue == "yes" or
	attackCannotMoveValue == "on"

return {
	UnitDefs = {
			aoe_archer = {
			name = "AOE Gameplay Archer",
			description = "Native Recoil Gameplay Unit with an AOE2 render appearance",
			objectName = "fir_tree_smallest.s3o",
			script = "aoe_archer.lua",
			category = "LAND",
			footprintX = 2,
			footprintZ = 2,
			collisionVolumeType = "CylY",
			collisionVolumeScales = "24 60 24",
			maxDamage = 100,
			buildCostMetal = 1,
			buildTime = 1,
			power = 1,
			mass = 50,
			canMove = true,
			canGuard = true,
			canPatrol = true,
				canStop = true,
				canAttack = true,
				canFireControl = true,
				corpse = "aoe_archer_dead",
			movementClass = "AOE2_TEST_UNIT",
			speed = 90,
			maxAcc = 0.15,
			maxDec = 0.30,
			turnRate = 1200,
			turnInPlace = true,
			stopToAttack = true,
			attackCannotMove = attackCannotMove,
			attackStartSpeedThreshold = 0.3,
			upright = true,
			sightDistance = 500,
				customParams = {
				aoe2_unit_id = "u_arc_archer",
				aoe2_scale = "1.0",
				aoe2_ground_offset = "0.0",
				aoe2_player_color = "team",
				aoe2_hide_native_model = "true",
				aoe2_animation_speed = "1.0",
				-- AOE DAT weapon_offset=(0, 0.5, 1.5). The base conversion
				-- (right=x*60, up=z*30, forward=y*60) gives (0, 45, 30).
				-- Manual all-direction calibration adds an archer-specific
				-- (0, 10.5, 0) correction. Keep that correction explicit until
				-- another ranged unit validates a reusable vertical rule.
				aoe2_aim_local = "0 30 0",
				aoe2_weapon1_muzzle_local = "0 55.5 30",
				aoe2_weapon1_forward_local = "0 0 1",
				},
				weapons = {
					{ name = "AOE_ARROW" },
				},
			},
		},
	FeatureDefs = {
		aoe_archer_dead = {
			description = "AOE archer corpse gameplay host",
			object = "fir_tree_smallest.s3o",
			blocking = true,
			reclaimable = true,
			resurrectable = 0,
			smokeTime = 0,
			health = 100,
			metal = 1,
			footprintX = 2,
			footprintZ = 2,
			customParams = {
				aoe2_corpse = "true",
				aoe2_unit_id = "u_arc_archer",
				aoe2_death_frames = "30",
				aoe2_corpse_hold_frames = "120",
				aoe2_corpse_fade_frames = "60",
			},
		},
	},
	WeaponDefs = {
		aoe_arrow = {
			name = "Native test arrow",
			weaponType = "Cannon",
			areaOfEffect = 8,
			impactOnly = true,
			impulseFactor = 0,
			impulseBoost = 0,
			range = 550,
			reloadtime = 2,
			windup = 0.5,
			attackRecoveryTime = 0.5,
			accuracy = 0,
			sprayAngle = 0,
			targetMoveError = 0,
			weaponVelocity = 400,
			gravityAffected = true,
			-- Require the unit chassis (and therefore the directional sprite) to
			-- face the target before firing. 1820 legacy angle units is about 10°.
			turret = false,
			tolerance = 1820,
			damage = { default = 5 },
			customParams = {
				aoe2_projectile_id = "p_arrow",
				aoe2_projectile_scale = "1.0",
			},
		},
	},
	ArmorDefs = {},
	MoveDefs = {
		{
			name = "AOE2_TEST_UNIT",
			footprintX = 2,
			footprintZ = 2,
			maxSlope = 36,
			maxWaterDepth = 12,
			crushStrength = 10,
		},
	},
}
