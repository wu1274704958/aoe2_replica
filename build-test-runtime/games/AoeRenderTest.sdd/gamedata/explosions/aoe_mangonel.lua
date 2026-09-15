return {
	-- AOE2 impact_dust is rendered by Aoe2ProjectileGameplayRenderBridge.
	-- Keep the native CEG empty so Recoil retains Gameplay explosion and sound
	-- semantics without drawing a second overlapping impact visual.
	["aoe_mangonel_impact"] = {},
}
