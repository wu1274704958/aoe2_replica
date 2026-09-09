/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include <cstdint>

class CUnit;
class CFeature;
class float3;

struct Aoe2UnitGameplayBridgeDiagnostics {
	std::uint32_t mappedUnitDefs = 0;
	std::uint32_t liveInstances = 0;
	std::uint32_t visibleInstances = 0;
	double cpuUpdateMs = 0.0;
};

/**
 * Unsynced adapter from native Gameplay Units to AOE2 render instances.
 *
 * Lifecycle events only enqueue unit identity data. Renderer resources and
 * instance handles are owned and updated from WorldDrawer's render update.
 */
class CAoe2UnitGameplayRenderBridge
{
public:
	static void InitStatic();
	static void KillStatic();
	static void PrepareStatic();
	static void UpdateStatic();

	// Called by UnitDrawer after it has applied the native LOS/icon/view rules.
	static void SetNativeModelVisible(const CUnit* unit, bool visible);
	static bool ReplacesNativeModel(const CUnit* unit);
	static bool GetNativeCullBounds(const CUnit* unit, float3& center, float& radius);
	static void SetNativeModelVisible(const CFeature* feature, bool visible);
	static bool ReplacesNativeModel(const CFeature* feature);
	static bool GetNativeCullBounds(const CFeature* feature, float3& center, float& radius);
	static Aoe2UnitGameplayBridgeDiagnostics GetDiagnostics();
};
