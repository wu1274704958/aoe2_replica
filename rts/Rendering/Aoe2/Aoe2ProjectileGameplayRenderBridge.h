/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include <cstdint>

class CProjectile;

struct Aoe2ProjectileGameplayBridgeDiagnostics {
	std::uint32_t mappedWeaponDefs = 0;
	std::uint32_t mappedEffectWeaponDefs = 0;
	std::uint32_t liveInstances = 0;
	std::uint32_t visibleInstances = 0;
	std::uint32_t liveEffects = 0;
	std::uint32_t visibleEffects = 0;
	std::uint64_t spawnedEffects = 0;
	std::uint64_t droppedEffects = 0;
	double cpuUpdateMs = 0.0;
};

/**
 * Unsynced adapter from native weapon projectiles to shared AOE2 sprite
 * instances. It observes render lifecycle events and never changes projectile
 * simulation, collision, damage, or lifetime.
 */
class CAoe2ProjectileGameplayRenderBridge
{
public:
	static void InitStatic();
	static void KillStatic();
	static void UpdateStatic();

	// Used by the native projectile drawer to avoid rendering a mapped
	// projectile twice while this optional bridge is enabled.
	static bool ReplacesNativeProjectile(const CProjectile* projectile);
	static Aoe2ProjectileGameplayBridgeDiagnostics GetDiagnostics();
};
