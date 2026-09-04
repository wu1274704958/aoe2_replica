/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Aoe2ProjectileGameplayRenderBridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "Aoe2UnitRenderer.h"
#include "Rendering/Env/Particles/ProjectileDrawer.h"
#include "Sim/Misc/GlobalConstants.h"
#include "Sim/Projectiles/Projectile.h"
#include "Sim/Projectiles/ProjectileHandler.h"
#include "Sim/Projectiles/WeaponProjectiles/WeaponProjectile.h"
#include "Sim/Weapons/WeaponDef.h"
#include "Sim/Weapons/WeaponDefHandler.h"
#include "System/Config/ConfigHandler.h"
#include "System/Config/ConfigVariable.h"
#include "System/EventClient.h"
#include "System/EventHandler.h"
#include "System/Log/ILog.h"
#include "System/StringUtil.h"

CONFIG(bool, Aoe2ProjectileGameplayBridge)
	.defaultValue(false)
	.headlessValue(false)
	.description("Drive AOE2 sprite projectile instances from native Recoil weapon projectiles");
CONFIG(bool, Aoe2ProjectileGameplayDiagnostics)
	.defaultValue(false)
	.description("Log AOE2 projectile render-bridge metrics once per second");

namespace {

constexpr std::uint32_t INVALID_ACTIVE_INDEX = ~std::uint32_t(0);
constexpr float MIN_HEADING_SPEED_SQ = 0.0001f;
constexpr float PI = 3.14159265358979323846f;

struct WeaponDefMapping {
	std::string resourceId;
	Aoe2AppearanceHandle appearance;
	float scale = 1.0f;
	float animationFps = 0.0f;
	std::uint32_t elevationFrameCount = 0;
	bool configured = false;
	bool usable = false;
};

struct ProjectileSlot {
	Aoe2InstanceHandle instance;
	std::uintptr_t projectileToken = 0;
	std::uint32_t activeIndex = INVALID_ACTIVE_INDEX;
	std::uint32_t mappingIndex = 0;
	float heading = 0.0f;

	bool IsActive() const { return activeIndex != INVALID_ACTIVE_INDEX; }
};

enum class LifecycleEventType : std::uint8_t {
	Created,
	Destroyed,
};

struct LifecycleEvent {
	LifecycleEventType type;
	std::uint32_t projectileId;
	std::uintptr_t projectileToken;
};

const std::string* FindParam(const WeaponDef& weaponDef, std::string_view name)
{
	const auto it = weaponDef.customParams.find(std::string(name));
	return (it != weaponDef.customParams.end()) ? &it->second : nullptr;
}

float ParseFloatParam(const WeaponDef& weaponDef, std::string_view name, float defaultValue, float minValue, float maxValue)
{
	const std::string* value = FindParam(weaponDef, name);
	if (value == nullptr)
		return defaultValue;

	bool failed = false;
	const float parsed = StringToFloat(*value, &failed);
	if (failed || !std::isfinite(parsed)) {
		LOG_L(L_WARNING, "[Aoe2ProjectileBridge] WeaponDef %s has invalid %s=%s; using %.3f",
			weaponDef.name.c_str(), std::string(name).c_str(), value->c_str(), defaultValue);
		return defaultValue;
	}
	return std::clamp(parsed, minValue, maxValue);
}

class Aoe2ProjectileGameplayBridgeImpl final : public CEventClient
{
public:
	Aoe2ProjectileGameplayBridgeImpl()
		: CEventClient("[Aoe2ProjectileGameplayRenderBridge]", 271831, false)
	{}

	bool Init();
	void Kill();
	void Update();
	bool ReplacesNativeProjectile(const CProjectile* projectile) const;
	int GetReadAllyTeam() const override { return AllAccessTeam; }

	bool WantsEvent(const std::string& eventName) override
	{
		return eventName == "RenderProjectileCreated" || eventName == "RenderProjectileDestroyed";
	}
	void RenderProjectileCreated(const CProjectile* projectile) override { QueueEvent(LifecycleEventType::Created, projectile); }
	void RenderProjectileDestroyed(const CProjectile* projectile) override { QueueEvent(LifecycleEventType::Destroyed, projectile); }

	Aoe2ProjectileGameplayBridgeDiagnostics diagnostics;

private:
	void ParseMappings();
	void PrepareAppearances();
	void Enable();
	void Disable();
	void QueueEvent(LifecycleEventType type, const CProjectile* projectile);
	void ProcessEvents();
	bool AddProjectile(const CProjectile* projectile, std::uintptr_t token);
	void RemoveProjectile(std::uint32_t projectileId, std::uintptr_t token = 0);
	void UpdateProjectile(std::uint32_t projectileId, CProjectile* projectile);
	bool IsMappedProjectile(const CProjectile* projectile, std::uint32_t* mappingIndex = nullptr) const;
	static float PitchFrameTime(const CProjectile& projectile, const WeaponDefMapping& mapping);

	std::vector<WeaponDefMapping> mappings;
	std::vector<ProjectileSlot> slots;
	std::vector<std::uint32_t> activeProjectileIds;
	std::mutex eventMutex;
	std::vector<LifecycleEvent> queuedEvents;
	std::vector<LifecycleEvent> processingEvents;
	std::atomic_bool enabled{false};
	bool appearancesPrepared = false;
	bool registered = false;
	std::chrono::steady_clock::time_point lastDiagnostics = std::chrono::steady_clock::now();
};

std::unique_ptr<Aoe2ProjectileGameplayBridgeImpl> bridge;

bool Aoe2ProjectileGameplayBridgeImpl::Init()
{
	if (!CAoe2UnitRenderer::IsAvailable())
		return false;

	slots.resize(MAX_PROJECTILES);
	// Projectile bursts can create and destroy many instances in one render
	// update. Reserve fixed-capacity bookkeeping so the hot lifecycle path has
	// no allocation or string lookup work.
	activeProjectileIds.reserve(MAX_PROJECTILES);
	queuedEvents.reserve(MAX_PROJECTILES);
	processingEvents.reserve(MAX_PROJECTILES);
	ParseMappings();
	eventHandler.AddClient(this);
	registered = true;
	if (configHandler->GetBool("Aoe2ProjectileGameplayBridge"))
		Enable();
	return true;
}

void Aoe2ProjectileGameplayBridgeImpl::ParseMappings()
{
	mappings.resize(weaponDefHandler->NumWeaponDefs());
	for (const WeaponDef& weaponDef : weaponDefHandler->GetWeaponDefsVec()) {
		if (weaponDef.id < 0 || static_cast<std::size_t>(weaponDef.id) >= mappings.size())
			continue;
		const std::string* resourceId = FindParam(weaponDef, "aoe2_projectile_id");
		if (resourceId == nullptr || resourceId->empty())
			continue;

		auto& mapping = mappings[weaponDef.id];
		mapping.resourceId = *resourceId;
		mapping.scale = ParseFloatParam(weaponDef, "aoe2_projectile_scale", 1.0f, 0.01f, 16.0f);
		mapping.configured = true;
		++diagnostics.mappedWeaponDefs;
	}
}

void Aoe2ProjectileGameplayBridgeImpl::PrepareAppearances()
{
	if (appearancesPrepared)
		return;
	appearancesPrepared = true;
	for (std::size_t weaponDefId = 0; weaponDefId < mappings.size(); ++weaponDefId) {
		auto& mapping = mappings[weaponDefId];
		if (!mapping.configured)
			continue;
		mapping.appearance = CAoe2UnitRenderer::PreloadGraphicsAppearance(mapping.resourceId);
		mapping.usable = static_cast<bool>(mapping.appearance);
		Aoe2UnitAnimationInfo animationInfo;
		mapping.usable = mapping.usable && CAoe2UnitRenderer::GetAnimationInfo(
			mapping.appearance, Aoe2UnitAnimationSlot::IdleA, animationInfo);
		if (mapping.usable) {
			mapping.animationFps = animationInfo.fps;
			mapping.elevationFrameCount = animationInfo.frameCount;
			mapping.usable = mapping.animationFps > 0.0f && mapping.elevationFrameCount > 0;
		}
		if (!mapping.usable) {
			LOG_L(L_WARNING, "[Aoe2ProjectileBridge] AOE2 resource %s for WeaponDef %u is unavailable; keeping native projectile rendering",
				mapping.resourceId.c_str(), static_cast<unsigned>(weaponDefId));
		}
	}
}

float Aoe2ProjectileGameplayBridgeImpl::PitchFrameTime(const CProjectile& projectile, const WeaponDefMapping& mapping)
{
	if (mapping.elevationFrameCount <= 1 || mapping.animationFps <= 0.0f)
		return 0.0f;

	const float horizontalSpeed = std::sqrt(projectile.speed.x * projectile.speed.x + projectile.speed.z * projectile.speed.z);
	const float pitchRadians = std::atan2(projectile.speed.y, horizontalSpeed);
	// p_arrow stores its elevation poses from up (frame 0) through level flight
	// to down (last frame). This is state sampling, never time animation.
	const float frame = std::clamp(
		(0.5f - pitchRadians / PI) * (mapping.elevationFrameCount - 1),
		0.0f,
		static_cast<float>(mapping.elevationFrameCount - 1)
	);
	return std::round(frame) / mapping.animationFps;
}

void Aoe2ProjectileGameplayBridgeImpl::Enable()
{
	if (enabled.exchange(true, std::memory_order_release))
		return;
	PrepareAppearances();
	for (const CProjectile* projectile : projectileHandler.GetActiveProjectiles(true)) {
		if (projectile != nullptr)
			AddProjectile(projectile, reinterpret_cast<std::uintptr_t>(projectile));
	}
	LOG_L(L_INFO, "[Aoe2ProjectileBridge] enabled (mappedWeaponDefs=%u, liveInstances=%u)",
		diagnostics.mappedWeaponDefs, diagnostics.liveInstances);
}

void Aoe2ProjectileGameplayBridgeImpl::Disable()
{
	if (!enabled.exchange(false, std::memory_order_acq_rel))
		return;
	{
		std::scoped_lock lock(eventMutex);
		queuedEvents.clear();
	}
	while (!activeProjectileIds.empty())
		RemoveProjectile(activeProjectileIds.back());
	diagnostics.liveInstances = 0;
	diagnostics.visibleInstances = 0;
	LOG_L(L_INFO, "[Aoe2ProjectileBridge] disabled; native projectile rendering restored");
}

void Aoe2ProjectileGameplayBridgeImpl::Kill()
{
	Disable();
	if (registered) {
		eventHandler.RemoveClient(this);
		registered = false;
	}
}

void Aoe2ProjectileGameplayBridgeImpl::QueueEvent(LifecycleEventType type, const CProjectile* projectile)
{
	if (projectile == nullptr || projectile->id < 0 || !enabled.load(std::memory_order_acquire))
		return;
	std::scoped_lock lock(eventMutex);
	queuedEvents.push_back({type, static_cast<std::uint32_t>(projectile->id), reinterpret_cast<std::uintptr_t>(projectile)});
}

bool Aoe2ProjectileGameplayBridgeImpl::IsMappedProjectile(const CProjectile* projectile, std::uint32_t* mappingIndex) const
{
	const auto* weaponProjectile = dynamic_cast<const CWeaponProjectile*>(projectile);
	if (weaponProjectile == nullptr || weaponProjectile->GetWeaponDef() == nullptr)
		return false;
	const int weaponDefId = weaponProjectile->GetWeaponDef()->id;
	if (weaponDefId < 0 || static_cast<std::size_t>(weaponDefId) >= mappings.size() || !mappings[weaponDefId].usable)
		return false;
	if (mappingIndex != nullptr)
		*mappingIndex = static_cast<std::uint32_t>(weaponDefId);
	return true;
}

bool Aoe2ProjectileGameplayBridgeImpl::AddProjectile(const CProjectile* projectile, std::uintptr_t token)
{
	if (projectile == nullptr || projectile->id < 0 || static_cast<std::size_t>(projectile->id) >= slots.size())
		return false;
	std::uint32_t mappingIndex = 0;
	if (!IsMappedProjectile(projectile, &mappingIndex))
		return false;

	auto& slot = slots[projectile->id];
	if (slot.IsActive()) {
		if (slot.projectileToken == token)
			return true;
		RemoveProjectile(static_cast<std::uint32_t>(projectile->id));
	}
	const auto& mapping = mappings[mappingIndex];
	float heading = 0.0f;
	const float horizontalSpeedSq = projectile->speed.x * projectile->speed.x + projectile->speed.z * projectile->speed.z;
	if (horizontalSpeedSq > MIN_HEADING_SPEED_SQ)
		heading = std::atan2(projectile->speed.x, projectile->speed.z);

	Aoe2UnitInstanceDesc desc;
	desc.appearance = mapping.appearance;
	desc.position = projectile->drawPos;
	desc.headingRadians = heading;
	desc.scale = mapping.scale;
	desc.animation = Aoe2UnitAnimationSlot::IdleA;
	desc.animationTime = 0.0f;
	desc.playbackSpeed = 0.0f;
	desc.visible = false;
	const Aoe2InstanceHandle instance = CAoe2UnitRenderer::CreateInstance(desc);
	if (!instance)
		return false;

	slot = {};
	slot.instance = instance;
	slot.projectileToken = token;
	slot.activeIndex = static_cast<std::uint32_t>(activeProjectileIds.size());
	slot.mappingIndex = mappingIndex;
	slot.heading = heading;
	activeProjectileIds.push_back(static_cast<std::uint32_t>(projectile->id));
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeProjectileIds.size());
	return true;
}

void Aoe2ProjectileGameplayBridgeImpl::RemoveProjectile(std::uint32_t projectileId, std::uintptr_t token)
{
	if (projectileId >= slots.size())
		return;
	auto& slot = slots[projectileId];
	if (!slot.IsActive() || (token != 0 && slot.projectileToken != token))
		return;
	CAoe2UnitRenderer::DestroyInstance(slot.instance);
	const std::uint32_t activeIndex = slot.activeIndex;
	const std::uint32_t movedProjectileId = activeProjectileIds.back();
	activeProjectileIds[activeIndex] = movedProjectileId;
	activeProjectileIds.pop_back();
	if (activeIndex < activeProjectileIds.size())
		slots[movedProjectileId].activeIndex = activeIndex;
	slot = {};
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeProjectileIds.size());
}

void Aoe2ProjectileGameplayBridgeImpl::ProcessEvents()
{
	{
		std::scoped_lock lock(eventMutex);
		queuedEvents.swap(processingEvents);
	}
	for (const LifecycleEvent& event : processingEvents) {
		if (event.type == LifecycleEventType::Destroyed) {
			RemoveProjectile(event.projectileId, event.projectileToken);
			continue;
		}
		CProjectile* projectile = projectileHandler.GetProjectileBySyncedID(event.projectileId);
		if (projectile != nullptr && reinterpret_cast<std::uintptr_t>(projectile) == event.projectileToken)
			AddProjectile(projectile, event.projectileToken);
	}
	processingEvents.clear();
}

void Aoe2ProjectileGameplayBridgeImpl::UpdateProjectile(std::uint32_t projectileId, CProjectile* projectile)
{
	auto& slot = slots[projectileId];
	const auto& mapping = mappings[slot.mappingIndex];
	const float horizontalSpeedSq = projectile->speed.x * projectile->speed.x + projectile->speed.z * projectile->speed.z;
	if (horizontalSpeedSq > MIN_HEADING_SPEED_SQ)
		slot.heading = std::atan2(projectile->speed.x, projectile->speed.z);
	CAoe2UnitRenderer::SetTransform(slot.instance, projectile->drawPos, slot.heading, mapping.scale);
	CAoe2UnitRenderer::SetAnimation(
		slot.instance,
		Aoe2UnitAnimationSlot::IdleA,
		PitchFrameTime(*projectile, mapping),
		0.0f
	);
	CAoe2UnitRenderer::SetVisible(slot.instance, CProjectileDrawer::CanDrawProjectile(projectile, projectile->GetAllyteamID()));
}

void Aoe2ProjectileGameplayBridgeImpl::Update()
{
	const auto started = std::chrono::steady_clock::now();
	const bool requested = configHandler->GetBool("Aoe2ProjectileGameplayBridge") && CAoe2UnitRenderer::IsAvailable();
	if (requested && !enabled.load(std::memory_order_acquire))
		Enable();
	else if (!requested && enabled.load(std::memory_order_acquire))
		Disable();
	if (enabled.load(std::memory_order_acquire)) {
		ProcessEvents();
		diagnostics.visibleInstances = 0;
		for (std::size_t i = 0; i < activeProjectileIds.size();) {
			const std::uint32_t projectileId = activeProjectileIds[i];
			const auto token = slots[projectileId].projectileToken;
			CProjectile* projectile = projectileHandler.GetProjectileBySyncedID(projectileId);
			if (projectile == nullptr || reinterpret_cast<std::uintptr_t>(projectile) != token) {
				RemoveProjectile(projectileId);
				continue;
			}
			UpdateProjectile(projectileId, projectile);
			diagnostics.visibleInstances += CProjectileDrawer::CanDrawProjectile(projectile, projectile->GetAllyteamID());
			++i;
		}
	}
	diagnostics.cpuUpdateMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
	const auto now = std::chrono::steady_clock::now();
	if (configHandler->GetBool("Aoe2ProjectileGameplayDiagnostics") && now - lastDiagnostics >= std::chrono::seconds(1)) {
		LOG_L(L_INFO, "[Aoe2ProjectileBridge] enabled=%d mappedDefs=%u live=%u visible=%u CPU=%.3fms",
			enabled.load(std::memory_order_relaxed), diagnostics.mappedWeaponDefs, diagnostics.liveInstances,
			diagnostics.visibleInstances, diagnostics.cpuUpdateMs);
		lastDiagnostics = now;
	}
}

bool Aoe2ProjectileGameplayBridgeImpl::ReplacesNativeProjectile(const CProjectile* projectile) const
{
	if (!enabled.load(std::memory_order_acquire) || projectile == nullptr || projectile->id < 0 ||
		static_cast<std::size_t>(projectile->id) >= slots.size())
		return false;
	const auto& slot = slots[projectile->id];
	return slot.IsActive() && slot.projectileToken == reinterpret_cast<std::uintptr_t>(projectile);
}

} // namespace

void CAoe2ProjectileGameplayRenderBridge::InitStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr || !CAoe2UnitRenderer::IsAvailable())
		return;
	auto candidate = std::make_unique<Aoe2ProjectileGameplayBridgeImpl>();
	if (candidate->Init())
		bridge = std::move(candidate);
#endif
}

void CAoe2ProjectileGameplayRenderBridge::KillStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->Kill();
	bridge.reset();
#endif
}

void CAoe2ProjectileGameplayRenderBridge::UpdateStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->Update();
#endif
}

bool CAoe2ProjectileGameplayRenderBridge::ReplacesNativeProjectile(const CProjectile* projectile)
{
#ifndef HEADLESS
	return bridge != nullptr && bridge->ReplacesNativeProjectile(projectile);
#else
	return false;
#endif
}

Aoe2ProjectileGameplayBridgeDiagnostics CAoe2ProjectileGameplayRenderBridge::GetDiagnostics()
{
#ifndef HEADLESS
	return (bridge != nullptr) ? bridge->diagnostics : Aoe2ProjectileGameplayBridgeDiagnostics{};
#else
	return {};
#endif
}
