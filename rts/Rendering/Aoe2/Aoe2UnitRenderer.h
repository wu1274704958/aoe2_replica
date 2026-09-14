/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include "System/float3.h"

enum class Aoe2UnitAnimationSlot : std::uint8_t {
	IdleA,
	WalkA,
	AttackA,
	DeathA,
	Built,
	Construction,
	BuildingAttack,
	Destruction,
	Rubble,
	Count,
};

constexpr std::size_t AOE2_ANIMATION_SLOT_COUNT = static_cast<std::size_t>(Aoe2UnitAnimationSlot::Count);

enum class Aoe2AnimationSamplingMode : std::uint8_t {
	Timeline,
	PitchPose,
	TimeLoop,
	TimeOnce,
};

struct Aoe2UnitAnimationInfo {
	float durationSeconds = 0.0f;
	float releaseTimeSeconds = 0.0f;
	float fps = 0.0f;
	std::uint32_t frameCount = 0;
	bool loop = false;
	Aoe2AnimationSamplingMode samplingMode = Aoe2AnimationSamplingMode::Timeline;
};

struct Aoe2AppearanceRenderBounds {
	// Conservative sphere radius around the sprite foot, in Recoil world units.
	float radius = 0.0f;
};

struct Aoe2EffectAppearanceInfo {
	float durationSeconds = 0.0f;
	float scale = 1.0f;
	float alpha = 1.0f;
};

struct Aoe2AppearanceHandle {
	std::uint32_t index = 0;
	std::uint32_t generation = 0;

	explicit operator bool() const { return generation != 0; }
};

struct Aoe2InstanceHandle {
	std::uint32_t index = 0;
	std::uint32_t generation = 0;

	explicit operator bool() const { return generation != 0; }
};

struct Aoe2UnitInstanceDesc {
	Aoe2AppearanceHandle appearance;
	float3 position;
	float headingRadians = 0.0f;
	float scale = 1.0f;
	Aoe2UnitAnimationSlot animation = Aoe2UnitAnimationSlot::IdleA;
	float animationTime = 0.0f;
	float playbackSpeed = 1.0f;
	std::uint8_t playerColor = 1;
	std::uint32_t tintRgba8 = 0xFFFFFFFFu;
	bool visible = true;
	// Keep overlapping billboard sprites in a stable foot-depth order. Projectile
	// instances disable this because their continuous flight depth is meaningful.
	bool stableDepthOrdering = true;
};

struct Aoe2UnitRenderDiagnostics {
	std::uint32_t liveInstances = 0;
	std::uint32_t visibleInstances = 0;
	std::uint32_t batches = 0;
	std::uint32_t drawCalls = 0;
	std::uint64_t uploadedBytes = 0;
	std::uint64_t textureBytes = 0;
	double cpuUpdateMs = 0.0;
	double cpuDrawMs = 0.0;
	double gpuDrawMs = 0.0;
};

/**
 * Experimental unsynced AOE2 sprite renderer.
 *
 * Gameplay owns all instance state and drives this API. The renderer never
 * reads CUnit, pathfinding, group, or simulation state.
 */
class CAoe2UnitRenderer
{
public:
	static void InitStatic();
	static void KillStatic();
	static void UpdateStatic();
	static void DrawStatic();
	static bool IsAvailable();

	static Aoe2AppearanceHandle PreloadAppearance(const std::string& unitId);
	// Loads an exported schema-4 building cache entry into the shared sprite batches.
	static Aoe2AppearanceHandle PreloadBuildingAppearance(const std::string& buildingId);
	// Loads an exported graphics cache entry into the shared sprite batches.
	static Aoe2AppearanceHandle PreloadGraphicsAppearance(const std::string& graphicsId);
	// Loads an exported one-shot effect cache entry into a non-depth-writing batch.
	static Aoe2AppearanceHandle PreloadEffectAppearance(const std::string& effectId);
	static bool GetAnimationInfo(Aoe2AppearanceHandle appearance, Aoe2UnitAnimationSlot animation, Aoe2UnitAnimationInfo& info);
	static bool GetEffectAppearanceInfo(Aoe2AppearanceHandle appearance, Aoe2EffectAppearanceInfo& info);
	static bool GetAppearanceRenderBounds(Aoe2AppearanceHandle appearance, Aoe2AppearanceRenderBounds& bounds);
	// Reserves handle storage up front for bridges with a fixed instance budget.
	static void ReserveAdditionalInstances(std::size_t additionalInstances);
	static Aoe2InstanceHandle CreateInstance(const Aoe2UnitInstanceDesc& desc);
	static bool DestroyInstance(Aoe2InstanceHandle handle);
	static bool SetTransform(Aoe2InstanceHandle handle, const float3& position, float headingRadians, float scale);
	static bool SetAnimation(Aoe2InstanceHandle handle, Aoe2UnitAnimationSlot animation, float playbackTime, float playbackSpeed);
	static bool SetPlayerColor(Aoe2InstanceHandle handle, std::uint8_t playerColor);
	static bool SetTint(Aoe2InstanceHandle handle, std::uint32_t tintRgba8);
	static bool SetVisible(Aoe2InstanceHandle handle, bool visible);
	static Aoe2UnitRenderDiagnostics GetDiagnostics();
};
