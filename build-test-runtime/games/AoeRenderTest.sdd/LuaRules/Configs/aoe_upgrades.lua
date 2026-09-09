-- Experimental AOE2-style technology definitions.  The engine owns numeric
-- damage application; this table only maps completed technologies to unit and
-- weapon upgrade tags.
return {
	fletching = {
		weaponTags = { "archer" },
		damage = { pierce = 1 },
	},
	padded_archer_armor = {
		unitTags = { "archer" },
		armor = { pierce = 1 },
	},
	forging = {
		weaponTags = { "cavalry" },
		damage = { melee = 1 },
	},
	scale_barding_armor = {
		unitTags = { "cavalry" },
		armor = { melee = 1, pierce = 1 },
	},
	castle_rapid_fire = {
		-- Absolute per-unit weapon-state override. The base Castle starts with
		-- burst=5; completing this technology upgrades its single native weapon
		-- to a 10-arrow temporal burst without adding a second AOE AttackA.
		weaponTags = { "castle" },
		weaponState = { burst = 10 },
	},
}
