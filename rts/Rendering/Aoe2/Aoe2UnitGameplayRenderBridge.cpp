/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Aoe2UnitGameplayRenderBridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "Aoe2UnitRenderer.h"
#include "Rendering/GlobalRendering.h"
#include "Sim/Features/Feature.h"
#include "Sim/Features/FeatureDef.h"
#include "Sim/Features/FeatureHandler.h"
#include "Sim/Misc/GlobalConstants.h"
#include "Sim/Misc/GlobalSynced.h"
#include "Sim/Units/Unit.h"
#include "Sim/Units/UnitDef.h"
#include "Sim/Units/UnitDefHandler.h"
#include "Sim/Units/UnitHandler.h"
#include "System/Config/ConfigHandler.h"
#include "System/Config/ConfigVariable.h"
#include "System/EventClient.h"
#include "System/EventHandler.h"
#include "System/Log/ILog.h"
#include "System/StringUtil.h"

CONFIG(bool, Aoe2UnitGameplayBridge)
	.defaultValue(false)
	.headlessValue(false)
	.description("Drive AOE2 render instances from native Recoil Gameplay Units");
CONFIG(bool, Aoe2UnitGameplayDiagnostics)
	.defaultValue(false)
	.description("Log AOE2 Gameplay render-bridge metrics once per second");
CONFIG(float, Aoe2UnitIdleSpeedThreshold)
	.defaultValue(0.03f)
	.minimumValue(0.0f)
	.maximumValue(10.0f)
	.description("Horizontal speed at or below which an AOE2 Gameplay Unit becomes idle (elmos/frame)");
CONFIG(float, Aoe2UnitMoveSpeedThreshold)
	.defaultValue(0.08f)
	.minimumValue(0.0f)
	.maximumValue(10.0f)
	.description("Horizontal speed at or above which an AOE2 Gameplay Unit starts walking (elmos/frame)");

namespace {

constexpr float HEADING_TO_RADIANS = 3.14159265358979323846f / SPRING_MAX_HEADING;
constexpr std::uint32_t INVALID_ACTIVE_INDEX = ~std::uint32_t(0);

// A CUnit address is only an unsynced lifetime token; queued events never dereference it.

struct UnitDefMapping {
	std::string resourceId;
	Aoe2AppearanceHandle appearance;
	float scale = 1.0f;
	float groundOffset = 0.0f;
	float animationSpeed = 1.0f;
	std::uint8_t fixedPlayerColor = 1;
	bool useTeamColor = true;
	bool hideNativeModel = true;
	bool configured = false;
	bool usable = false;
};

struct UnitSlot {
	Aoe2InstanceHandle instance;
	std::uintptr_t unitToken = 0;
	std::uint32_t activeIndex = INVALID_ACTIVE_INDEX;
	float animationTime = 0.0f;
	int attackStartFrame = -1;
	std::uint32_t mappingIndex = 0;
	std::uint8_t playerColor = 0;
	bool walking = false;
	bool attacking = false;
	bool pendingDestroy = false;
	bool nativeModelVisible = false;

	bool IsActive() const { return activeIndex != INVALID_ACTIVE_INDEX; }
};

struct FeatureSlot {
	Aoe2InstanceHandle instance;
	std::uintptr_t featureToken = 0;
	std::uint32_t activeIndex = INVALID_ACTIVE_INDEX;
	std::uint32_t mappingIndex = 0;
	std::uint8_t playerColor = 1;
	bool nativeModelVisible = false;

	bool IsActive() const { return activeIndex != INVALID_ACTIVE_INDEX; }
};

enum class LifecycleEventType : std::uint8_t {
	UnitCreated,
	UnitDestroyed,
	FeatureCreated,
	FeatureDestroyed,
};

struct LifecycleEvent {
	LifecycleEventType type;
	std::uint32_t objectId;
	std::uintptr_t objectToken;
	std::int32_t sourceUnitId = -1;
	std::uintptr_t sourceUnitToken = 0;
};

const std::string* FindParam(const UnitDef& unitDef, std::string_view name)
{
	const auto it = unitDef.customParams.find(std::string(name));
	return (it != unitDef.customParams.end()) ? &it->second : nullptr;
}

float ParseFloatParam(const UnitDef& unitDef, std::string_view name, float defaultValue, float minValue, float maxValue)
{
	const std::string* value = FindParam(unitDef, name);
	if (value == nullptr)
		return defaultValue;

	bool failed = false;
	const float parsed = StringToFloat(*value, &failed);
	if (failed || !std::isfinite(parsed)) {
		LOG_L(L_WARNING, "[Aoe2GameplayBridge] UnitDef %s has invalid %s=%s; using %.3f",
			unitDef.name.c_str(), std::string(name).c_str(), value->c_str(), defaultValue);
		return defaultValue;
	}
	return std::clamp(parsed, minValue, maxValue);
}

bool ParseBoolParam(const UnitDef& unitDef, std::string_view name, bool defaultValue)
{
	const std::string* value = FindParam(unitDef, name);
	if (value == nullptr)
		return defaultValue;

	std::string lower = StringToLower(*value);
	if (lower == "1" || lower == "yes" || lower == "true" || lower == "on")
		return true;
	if (lower == "0" || lower == "no" || lower == "false" || lower == "off")
		return false;

	LOG_L(L_WARNING, "[Aoe2GameplayBridge] UnitDef %s has invalid %s=%s; using %s",
		unitDef.name.c_str(), std::string(name).c_str(), value->c_str(), defaultValue ? "true" : "false");
	return defaultValue;
}

std::uint8_t PlayerColorForUnit(const CUnit& unit, const UnitDefMapping& mapping)
{
	if (!mapping.useTeamColor)
		return mapping.fixedPlayerColor;
	return static_cast<std::uint8_t>(std::max(0, unit.team) % 8 + 1);
}

class Aoe2GameplayBridgeImpl final : public CEventClient
{
public:
	Aoe2GameplayBridgeImpl()
		: CEventClient("[Aoe2UnitGameplayRenderBridge]", 271829, false)
	{}

	bool Init();
	void Kill();
	void Prepare();
	void Update();
	void SetNativeModelVisible(const CUnit* unit, bool visible);
	bool ReplacesNativeModel(const CUnit* unit) const;
	void SetNativeModelVisible(const CFeature* feature, bool visible);
	bool ReplacesNativeModel(const CFeature* feature) const;
	int GetReadAllyTeam() const override { return AllAccessTeam; }

	bool WantsEvent(const std::string& eventName) override
	{
		return eventName == "RenderUnitCreated" || eventName == "RenderUnitDestroyed" ||
			eventName == "RenderFeatureCreated" || eventName == "RenderFeatureDestroyed";
	}

	void RenderUnitCreated(const CUnit* unit, int cloaked) override { QueueUnitEvent(LifecycleEventType::UnitCreated, unit); }
	void RenderUnitDestroyed(const CUnit* unit) override { QueueUnitEvent(LifecycleEventType::UnitDestroyed, unit); }
	void RenderFeatureCreated(const CFeature* feature) override { QueueFeatureEvent(LifecycleEventType::FeatureCreated, feature); }
	void RenderFeatureDestroyed(const CFeature* feature) override { QueueFeatureEvent(LifecycleEventType::FeatureDestroyed, feature); }

	Aoe2UnitGameplayBridgeDiagnostics diagnostics;

private:
	void ParseMappings();
	void PrepareAppearances();
	void Enable();
	void Disable();
	void QueueUnitEvent(LifecycleEventType type, const CUnit* unit);
	void QueueFeatureEvent(LifecycleEventType type, const CFeature* feature);
	void ProcessEvents();
	bool AddUnit(const CUnit* unit, std::uintptr_t token);
	bool AddFeature(const CFeature* feature, const LifecycleEvent& event);
	void MarkUnitDestroyed(std::uint32_t unitId, std::uintptr_t token);
	void RemoveUnitSlot(std::uint32_t unitId, bool destroyInstance = true);
	void RemoveFeature(std::uint32_t featureId, std::uintptr_t token);
	void RemoveFeatureSlot(std::uint32_t featureId, bool destroyInstance = true);
	void UpdateUnit(std::uint32_t unitId, CUnit* unit, float deltaSeconds);
	void UpdateFeature(std::uint32_t featureId, CFeature* feature);

	std::vector<UnitDefMapping> mappings;
	std::vector<UnitSlot> slots;
	std::vector<std::uint32_t> activeUnitIds;
	std::vector<FeatureSlot> featureSlots;
	std::vector<std::uint32_t> activeFeatureIds;
	std::mutex eventMutex;
	std::vector<LifecycleEvent> queuedEvents;
	std::vector<LifecycleEvent> processingEvents;
	std::atomic_bool enabled{false};
	bool appearancesPrepared = false;
	bool registered = false;
	float idleSpeedThreshold = 0.03f;
	float moveSpeedThreshold = 0.08f;
	std::chrono::steady_clock::time_point lastDiagnostics = std::chrono::steady_clock::now();
};

std::unique_ptr<Aoe2GameplayBridgeImpl> bridge;

bool Aoe2GameplayBridgeImpl::Init()
{
	if (!CAoe2UnitRenderer::IsAvailable())
		return false;

	slots.resize(unitHandler.MaxUnits());
	featureSlots.resize(MAX_FEATURES);
	activeUnitIds.reserve(unitHandler.GetActiveUnits().size());
	activeFeatureIds.reserve(featureHandler.GetActiveFeatureIDs().size());
	queuedEvents.reserve(128);
	processingEvents.reserve(128);
	idleSpeedThreshold = configHandler->GetFloat("Aoe2UnitIdleSpeedThreshold");
	moveSpeedThreshold = std::max(idleSpeedThreshold, configHandler->GetFloat("Aoe2UnitMoveSpeedThreshold"));
	ParseMappings();
	eventHandler.AddClient(this);
	registered = true;

	if (configHandler->GetBool("Aoe2UnitGameplayBridge"))
		Enable();
	return true;
}

void Aoe2GameplayBridgeImpl::ParseMappings()
{
	mappings.resize(unitDefHandler->NumUnitDefs() + 1);
	for (const UnitDef& unitDef : unitDefHandler->GetUnitDefsVec()) {
		if (unitDef.id <= 0 || static_cast<std::size_t>(unitDef.id) >= mappings.size())
			continue;

		const std::string* resourceId = FindParam(unitDef, "aoe2_unit_id");
		if (resourceId == nullptr || resourceId->empty())
			continue;

		auto& mapping = mappings[unitDef.id];
		mapping.resourceId = *resourceId;
		mapping.scale = ParseFloatParam(unitDef, "aoe2_scale", 1.0f, 0.01f, 16.0f);
		mapping.groundOffset = ParseFloatParam(unitDef, "aoe2_ground_offset", 0.0f, -128.0f, 128.0f);
		mapping.animationSpeed = ParseFloatParam(unitDef, "aoe2_animation_speed", 1.0f, 0.05f, 8.0f);
		mapping.hideNativeModel = ParseBoolParam(unitDef, "aoe2_hide_native_model", true);
		mapping.configured = true;

		if (unitDef.NumWeapons() > 1) {
			LOG_L(L_WARNING,
				"[Aoe2GameplayBridge] UnitDef %s has %u weapons; multi-weapon AOE2 animation is unsupported and only weapon 1 drives AttackA",
				unitDef.name.c_str(), unitDef.NumWeapons());
		}

		if (const std::string* color = FindParam(unitDef, "aoe2_player_color"); color != nullptr) {
			std::string lower = StringToLower(*color);
			if (lower != "team") {
				bool failed = false;
				const int fixedColor = StringToInt(*color, &failed);
				if (!failed && fixedColor >= 1 && fixedColor <= 8) {
					mapping.useTeamColor = false;
					mapping.fixedPlayerColor = static_cast<std::uint8_t>(fixedColor);
				} else {
					LOG_L(L_WARNING, "[Aoe2GameplayBridge] UnitDef %s has invalid aoe2_player_color=%s; using team",
						unitDef.name.c_str(), color->c_str());
				}
			}
		}
		++diagnostics.mappedUnitDefs;
	}
}

void Aoe2GameplayBridgeImpl::PrepareAppearances()
{
	if (appearancesPrepared)
		return;
	appearancesPrepared = true;

	for (std::size_t unitDefId = 1; unitDefId < mappings.size(); ++unitDefId) {
		auto& mapping = mappings[unitDefId];
		if (!mapping.configured)
			continue;
		mapping.appearance = CAoe2UnitRenderer::PreloadAppearance(mapping.resourceId);
		mapping.usable = static_cast<bool>(mapping.appearance);
		if (!mapping.usable) {
			LOG_L(L_WARNING, "[Aoe2GameplayBridge] AOE2 resource %s for UnitDef %u is unavailable; keeping native model",
				mapping.resourceId.c_str(), static_cast<unsigned>(unitDefId));
		}
	}
}

void Aoe2GameplayBridgeImpl::Enable()
{
	if (enabled.exchange(true, std::memory_order_release))
		return;
	PrepareAppearances();
	for (const CUnit* unit : unitHandler.GetActiveUnits()) {
		if (unit != nullptr)
			AddUnit(unit, reinterpret_cast<std::uintptr_t>(unit));
	}
	for (const int featureId : featureHandler.GetActiveFeatureIDs()) {
		const CFeature* feature = featureHandler.GetFeature(featureId);
		if (feature == nullptr)
			continue;
		const LifecycleEvent event{
			LifecycleEventType::FeatureCreated,
			static_cast<std::uint32_t>(featureId),
			reinterpret_cast<std::uintptr_t>(feature),
			feature->renderSourceUnitId,
			feature->renderSourceUnitToken,
		};
		AddFeature(feature, event);
	}
	LOG_L(L_INFO, "[Aoe2GameplayBridge] enabled (mappedUnitDefs=%u, liveInstances=%u)",
		diagnostics.mappedUnitDefs, diagnostics.liveInstances);
}

void Aoe2GameplayBridgeImpl::Disable()
{
	if (!enabled.exchange(false, std::memory_order_acq_rel))
		return;

	{
		std::scoped_lock lock(eventMutex);
		queuedEvents.clear();
	}
	while (!activeUnitIds.empty())
		RemoveUnitSlot(activeUnitIds.back());
	while (!activeFeatureIds.empty())
		RemoveFeatureSlot(activeFeatureIds.back());
	diagnostics.liveInstances = 0;
	diagnostics.visibleInstances = 0;
	LOG_L(L_INFO, "[Aoe2GameplayBridge] disabled; native Unit models restored");
}

void Aoe2GameplayBridgeImpl::Kill()
{
	Disable();
	if (registered) {
		eventHandler.RemoveClient(this);
		registered = false;
	}
}

void Aoe2GameplayBridgeImpl::QueueUnitEvent(LifecycleEventType type, const CUnit* unit)
{
	if (unit == nullptr || unit->id < 0 || !enabled.load(std::memory_order_acquire))
		return;
	std::scoped_lock lock(eventMutex);
	queuedEvents.push_back({type, static_cast<std::uint32_t>(unit->id), reinterpret_cast<std::uintptr_t>(unit)});
}

void Aoe2GameplayBridgeImpl::QueueFeatureEvent(LifecycleEventType type, const CFeature* feature)
{
	if (feature == nullptr || feature->id < 0 || !enabled.load(std::memory_order_acquire))
		return;
	std::scoped_lock lock(eventMutex);
	queuedEvents.push_back({
		type,
		static_cast<std::uint32_t>(feature->id),
		reinterpret_cast<std::uintptr_t>(feature),
		feature->renderSourceUnitId,
		feature->renderSourceUnitToken,
	});
}

void Aoe2GameplayBridgeImpl::ProcessEvents()
{
	{
		std::scoped_lock lock(eventMutex);
		queuedEvents.swap(processingEvents);
	}

	for (const LifecycleEvent& event : processingEvents) {
		switch (event.type) {
			case LifecycleEventType::UnitDestroyed: {
				MarkUnitDestroyed(event.objectId, event.objectToken);
			} break;
			case LifecycleEventType::UnitCreated: {
				const CUnit* unit = unitHandler.GetUnit(event.objectId);
				if (unit != nullptr && reinterpret_cast<std::uintptr_t>(unit) == event.objectToken)
					AddUnit(unit, event.objectToken);
			} break;
			case LifecycleEventType::FeatureCreated: {
				const CFeature* feature = featureHandler.GetFeature(event.objectId);
				if (feature != nullptr && reinterpret_cast<std::uintptr_t>(feature) == event.objectToken)
					AddFeature(feature, event);
			} break;
			case LifecycleEventType::FeatureDestroyed: {
				RemoveFeature(event.objectId, event.objectToken);
			} break;
		}
	}
	processingEvents.clear();

	for (std::size_t i = 0; i < activeUnitIds.size();) {
		const std::uint32_t unitId = activeUnitIds[i];
		if (!slots[unitId].pendingDestroy) {
			++i;
			continue;
		}
		RemoveUnitSlot(unitId);
	}
}

bool Aoe2GameplayBridgeImpl::AddUnit(const CUnit* unit, std::uintptr_t token)
{
	if (unit == nullptr || unit->id < 0 || static_cast<std::size_t>(unit->id) >= slots.size() || unit->unitDef == nullptr)
		return false;
	if (unit->unitDef->id <= 0 || static_cast<std::size_t>(unit->unitDef->id) >= mappings.size())
		return false;

	auto& mapping = mappings[unit->unitDef->id];
	if (!mapping.usable)
		return false;

	auto& slot = slots[unit->id];
	if (slot.IsActive()) {
		if (slot.unitToken == token)
			return true;
		RemoveUnitSlot(static_cast<std::uint32_t>(unit->id));
	}

	Aoe2UnitInstanceDesc desc;
	desc.appearance = mapping.appearance;
	desc.position = unit->drawPos;
	desc.position.y += mapping.groundOffset;
	desc.headingRadians = static_cast<float>(unit->heading) * HEADING_TO_RADIANS;
	desc.scale = mapping.scale;
	desc.animation = Aoe2UnitAnimationSlot::IdleA;
	desc.animationTime = 0.0f;
	desc.playbackSpeed = 0.0f;
	desc.playerColor = PlayerColorForUnit(*unit, mapping);
	desc.visible = false;
	const Aoe2InstanceHandle instance = CAoe2UnitRenderer::CreateInstance(desc);
	if (!instance)
		return false;

	slot = {};
	slot.instance = instance;
	slot.unitToken = token;
	slot.activeIndex = static_cast<std::uint32_t>(activeUnitIds.size());
	slot.mappingIndex = static_cast<std::uint32_t>(unit->unitDef->id);
	slot.playerColor = desc.playerColor;
	activeUnitIds.push_back(static_cast<std::uint32_t>(unit->id));
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeUnitIds.size() + activeFeatureIds.size());
	return true;
}

bool Aoe2GameplayBridgeImpl::AddFeature(const CFeature* feature, const LifecycleEvent& event)
{
	if (feature == nullptr || feature->id < 0 || static_cast<std::size_t>(feature->id) >= featureSlots.size() ||
		feature->def == nullptr)
		return false;
	const auto corpseParam = feature->def->customParams.find("aoe2_corpse");
	if (corpseParam == feature->def->customParams.end())
		return false;
	const std::string corpseValue = StringToLower(corpseParam->second);
	if (corpseValue != "1" && corpseValue != "true" && corpseValue != "yes")
		return false;

	auto& featureSlot = featureSlots[feature->id];
	if (featureSlot.IsActive())
		return featureSlot.featureToken == event.objectToken;

	Aoe2InstanceHandle instance;
	std::uint32_t mappingIndex = 0;
	std::uint8_t playerColor = static_cast<std::uint8_t>(std::max(0, feature->team) % 8 + 1);
	if (event.sourceUnitId >= 0 && static_cast<std::size_t>(event.sourceUnitId) < slots.size()) {
		auto& sourceSlot = slots[event.sourceUnitId];
		if (sourceSlot.IsActive() && sourceSlot.unitToken == event.sourceUnitToken) {
			instance = sourceSlot.instance;
			mappingIndex = sourceSlot.mappingIndex;
			playerColor = sourceSlot.playerColor;
			RemoveUnitSlot(static_cast<std::uint32_t>(event.sourceUnitId), false);
		}
	}

	if (!instance) {
		const auto resourceParam = feature->def->customParams.find("aoe2_unit_id");
		if (resourceParam == feature->def->customParams.end())
			return false;
		for (std::size_t i = 1; i < mappings.size(); ++i) {
			if (mappings[i].usable && mappings[i].resourceId == resourceParam->second) {
				mappingIndex = static_cast<std::uint32_t>(i);
				break;
			}
		}
		if (mappingIndex == 0) {
			UnitDefMapping featureMapping;
			featureMapping.resourceId = resourceParam->second;
			featureMapping.configured = true;
			featureMapping.hideNativeModel = true;
			const auto parseFloat = [feature](const char* name, float defaultValue, float minValue, float maxValue) {
				const auto it = feature->def->customParams.find(name);
				if (it == feature->def->customParams.end())
					return defaultValue;
				bool failed = false;
				const float value = StringToFloat(it->second, &failed);
				return (failed || !std::isfinite(value)) ? defaultValue : std::clamp(value, minValue, maxValue);
			};
			featureMapping.scale = parseFloat("aoe2_scale", 1.0f, 0.01f, 16.0f);
			featureMapping.groundOffset = parseFloat("aoe2_ground_offset", 0.0f, -128.0f, 128.0f);
			featureMapping.animationSpeed = parseFloat("aoe2_animation_speed", 1.0f, 0.05f, 8.0f);
			featureMapping.appearance = CAoe2UnitRenderer::PreloadAppearance(featureMapping.resourceId);
			featureMapping.usable = static_cast<bool>(featureMapping.appearance);
			if (!featureMapping.usable)
				return false;
			mappingIndex = static_cast<std::uint32_t>(mappings.size());
			mappings.push_back(std::move(featureMapping));
		}

		const auto& mapping = mappings[mappingIndex];
		Aoe2UnitInstanceDesc desc;
		desc.appearance = mapping.appearance;
		desc.position = feature->drawPos;
		desc.position.y += mapping.groundOffset;
		desc.headingRadians = static_cast<float>(feature->heading) * HEADING_TO_RADIANS;
		desc.scale = mapping.scale;
		desc.animation = Aoe2UnitAnimationSlot::DeathA;
		desc.playerColor = playerColor;
		desc.visible = false;
		instance = CAoe2UnitRenderer::CreateInstance(desc);
		if (!instance)
			return false;
	}

	featureSlot = {};
	featureSlot.instance = instance;
	featureSlot.featureToken = event.objectToken;
	featureSlot.activeIndex = static_cast<std::uint32_t>(activeFeatureIds.size());
	featureSlot.mappingIndex = mappingIndex;
	featureSlot.playerColor = playerColor;
	activeFeatureIds.push_back(static_cast<std::uint32_t>(feature->id));
	CAoe2UnitRenderer::SetAnimation(instance, Aoe2UnitAnimationSlot::DeathA, 0.0f, 0.0f);
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeUnitIds.size() + activeFeatureIds.size());
	if (configHandler->GetBool("Aoe2UnitGameplayDiagnostics")) {
		LOG_L(L_INFO,
			"[Aoe2GameplayBridge] corpse feature=%d sourceUnit=%d decay=[%d,%d] transferred=%d",
			feature->id, event.sourceUnitId, feature->aoe2DecayStartFrame, feature->aoe2DecayEndFrame,
			event.sourceUnitId >= 0);
	}
	return true;
}

void Aoe2GameplayBridgeImpl::MarkUnitDestroyed(std::uint32_t unitId, std::uintptr_t token)
{
	if (unitId >= slots.size())
		return;
	auto& slot = slots[unitId];
	if (slot.IsActive() && slot.unitToken == token)
		slot.pendingDestroy = true;
}

void Aoe2GameplayBridgeImpl::RemoveUnitSlot(std::uint32_t unitId, bool destroyInstance)
{
	auto& slot = slots[unitId];
	if (!slot.IsActive())
		return;
	if (destroyInstance)
		CAoe2UnitRenderer::DestroyInstance(slot.instance);

	const std::uint32_t activeIndex = slot.activeIndex;
	const std::uint32_t movedUnitId = activeUnitIds.back();
	activeUnitIds[activeIndex] = movedUnitId;
	activeUnitIds.pop_back();
	if (activeIndex < activeUnitIds.size())
		slots[movedUnitId].activeIndex = activeIndex;
	slot = {};
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeUnitIds.size() + activeFeatureIds.size());
}

void Aoe2GameplayBridgeImpl::RemoveFeature(std::uint32_t featureId, std::uintptr_t token)
{
	if (featureId >= featureSlots.size())
		return;
	const auto& slot = featureSlots[featureId];
	if (slot.IsActive() && slot.featureToken == token)
		RemoveFeatureSlot(featureId);
}

void Aoe2GameplayBridgeImpl::RemoveFeatureSlot(std::uint32_t featureId, bool destroyInstance)
{
	auto& slot = featureSlots[featureId];
	if (!slot.IsActive())
		return;
	if (destroyInstance)
		CAoe2UnitRenderer::DestroyInstance(slot.instance);

	const std::uint32_t activeIndex = slot.activeIndex;
	const std::uint32_t movedFeatureId = activeFeatureIds.back();
	activeFeatureIds[activeIndex] = movedFeatureId;
	activeFeatureIds.pop_back();
	if (activeIndex < activeFeatureIds.size())
		featureSlots[movedFeatureId].activeIndex = activeIndex;
	slot = {};
	diagnostics.liveInstances = static_cast<std::uint32_t>(activeUnitIds.size() + activeFeatureIds.size());
}

void Aoe2GameplayBridgeImpl::UpdateUnit(std::uint32_t unitId, CUnit* unit, float deltaSeconds)
{
	auto& slot = slots[unitId];
	const auto& mapping = mappings[unit->unitDef->id];
	const float horizontalSpeed = std::sqrt(unit->speed.x * unit->speed.x + unit->speed.z * unit->speed.z);
	const bool wasWalking = slot.walking;
	if (slot.walking) {
		if (horizontalSpeed <= idleSpeedThreshold)
			slot.walking = false;
	} else if (horizontalSpeed >= moveSpeedThreshold) {
		slot.walking = true;
	}
	const bool gameplayAttacking = unit->IsAttackAnimationActive();
	const int gameplayAttackStartFrame = unit->GetAttackMotionStartFrame();
	const bool newAttack = gameplayAttacking && (
		!slot.attacking ||
		slot.attackStartFrame != gameplayAttackStartFrame
	);
	if (newAttack) {
		slot.attackStartFrame = gameplayAttackStartFrame;
		slot.animationTime = 0.0f;
	}
	if (!gameplayAttacking && slot.attacking) {
		slot.attackStartFrame = -1;
		slot.animationTime = 0.0f;
	}
	slot.attacking = gameplayAttacking;

	if (wasWalking != slot.walking && !slot.attacking)
		slot.animationTime = 0.0f;

	float playbackRate = mapping.animationSpeed;
	if (slot.walking && !slot.attacking) {
		const float referenceSpeed = std::max(0.01f, unit->unitDef->speed * INV_GAME_SPEED);
		playbackRate *= std::clamp(horizontalSpeed / referenceSpeed, 0.5f, 2.0f);
	}
	if (slot.attacking) {
		slot.animationTime = std::max(
			0.0f,
			(static_cast<float>(gs->frameNum - slot.attackStartFrame) + globalRendering->timeOffset) *
				INV_GAME_SPEED * mapping.animationSpeed
		);
		Aoe2UnitAnimationInfo attackInfo;
		if (CAoe2UnitRenderer::GetAnimationInfo(mapping.appearance, Aoe2UnitAnimationSlot::AttackA, attackInfo))
			slot.animationTime = std::min(slot.animationTime, attackInfo.durationSeconds);
	} else {
		slot.animationTime = std::max(0.0f, slot.animationTime + deltaSeconds * playbackRate);
	}

	float3 position = unit->drawPos;
	position.y += mapping.groundOffset;
	CAoe2UnitRenderer::SetTransform(
		slot.instance,
		position,
		static_cast<float>(unit->heading) * HEADING_TO_RADIANS,
		mapping.scale
	);
	CAoe2UnitRenderer::SetAnimation(
		slot.instance,
		slot.attacking ? Aoe2UnitAnimationSlot::AttackA :
			(slot.walking ? Aoe2UnitAnimationSlot::WalkA : Aoe2UnitAnimationSlot::IdleA),
		slot.animationTime,
		0.0f
	);
	const std::uint8_t playerColor = PlayerColorForUnit(*unit, mapping);
	if (playerColor != slot.playerColor) {
		CAoe2UnitRenderer::SetPlayerColor(slot.instance, playerColor);
		slot.playerColor = playerColor;
	}
	CAoe2UnitRenderer::SetVisible(slot.instance, slot.nativeModelVisible);
}

void Aoe2GameplayBridgeImpl::UpdateFeature(std::uint32_t featureId, CFeature* feature)
{
	auto& slot = featureSlots[featureId];
	const auto& mapping = mappings[slot.mappingIndex];
	const float renderFrame = static_cast<float>(gs->frameNum) + globalRendering->timeOffset;
	const float deathTime = std::max(0.0f, (renderFrame - feature->creationFrame) * INV_GAME_SPEED * mapping.animationSpeed);
	Aoe2UnitAnimationInfo deathInfo;
	CAoe2UnitRenderer::GetAnimationInfo(mapping.appearance, Aoe2UnitAnimationSlot::DeathA, deathInfo);

	float fade = 1.0f;
	if (feature->aoe2DecayStartFrame >= 0 && renderFrame > feature->aoe2DecayStartFrame) {
		const float fadeFrames = std::max(1, feature->aoe2DecayEndFrame - feature->aoe2DecayStartFrame);
		fade = std::clamp(1.0f - (renderFrame - feature->aoe2DecayStartFrame) / fadeFrames, 0.0f, 1.0f);
	}
	fade *= std::clamp(feature->reclaimLeft, 0.0f, 1.0f);
	const std::uint8_t alpha = static_cast<std::uint8_t>(std::lround(
		255.0f * fade * std::clamp(feature->drawAlpha, 0.0f, 1.0f)));
	float3 position = feature->drawPos;
	position.y += mapping.groundOffset;
	CAoe2UnitRenderer::SetTransform(
		slot.instance,
		position,
		static_cast<float>(feature->heading) * HEADING_TO_RADIANS,
		mapping.scale
	);
	CAoe2UnitRenderer::SetAnimation(
		slot.instance,
		Aoe2UnitAnimationSlot::DeathA,
		std::min(deathTime, deathInfo.durationSeconds),
		0.0f
	);
	CAoe2UnitRenderer::SetTint(slot.instance, 0x00FFFFFFu | (static_cast<std::uint32_t>(alpha) << 24u));
	CAoe2UnitRenderer::SetVisible(slot.instance, slot.nativeModelVisible && alpha != 0);
}

void Aoe2GameplayBridgeImpl::Prepare()
{
	const bool requested = configHandler->GetBool("Aoe2UnitGameplayBridge") && CAoe2UnitRenderer::IsAvailable();
	if (requested && !enabled.load(std::memory_order_acquire))
		Enable();
	else if (!requested && enabled.load(std::memory_order_acquire))
		Disable();
	if (enabled.load(std::memory_order_acquire))
		ProcessEvents();
}

void Aoe2GameplayBridgeImpl::Update()
{
	const auto started = std::chrono::steady_clock::now();

	if (enabled.load(std::memory_order_acquire)) {
		const float deltaSeconds = std::clamp(globalRendering->lastFrameTime * 0.001f, 0.0f, 0.1f);
		diagnostics.visibleInstances = 0;
		for (std::size_t i = 0; i < activeUnitIds.size();) {
			const std::uint32_t unitId = activeUnitIds[i];
			const auto token = slots[unitId].unitToken;
			CUnit* unit = unitHandler.GetUnit(unitId);
			if (unit == nullptr || reinterpret_cast<std::uintptr_t>(unit) != token || unit->unitDef == nullptr) {
				RemoveUnitSlot(unitId);
				continue;
			}
			UpdateUnit(unitId, unit, deltaSeconds);
			diagnostics.visibleInstances += slots[unitId].nativeModelVisible;
			++i;
		}
		for (std::size_t i = 0; i < activeFeatureIds.size();) {
			const std::uint32_t featureId = activeFeatureIds[i];
			const auto token = featureSlots[featureId].featureToken;
			CFeature* feature = featureHandler.GetFeature(featureId);
			if (feature == nullptr || reinterpret_cast<std::uintptr_t>(feature) != token) {
				RemoveFeatureSlot(featureId);
				continue;
			}
			UpdateFeature(featureId, feature);
			diagnostics.visibleInstances += featureSlots[featureId].nativeModelVisible;
			++i;
		}
	}

	diagnostics.cpuUpdateMs = std::chrono::duration<double, std::milli>(
		std::chrono::steady_clock::now() - started).count();
	const auto now = std::chrono::steady_clock::now();
	if (configHandler->GetBool("Aoe2UnitGameplayDiagnostics") && now - lastDiagnostics >= std::chrono::seconds(1)) {
		LOG_L(L_INFO, "[Aoe2GameplayBridge] enabled=%d mappedDefs=%u live=%u (units=%u features=%u) visible=%u CPU=%.3fms",
			enabled.load(std::memory_order_relaxed), diagnostics.mappedUnitDefs,
			diagnostics.liveInstances, static_cast<unsigned>(activeUnitIds.size()),
			static_cast<unsigned>(activeFeatureIds.size()), diagnostics.visibleInstances, diagnostics.cpuUpdateMs);
		lastDiagnostics = now;
	}
}

void Aoe2GameplayBridgeImpl::SetNativeModelVisible(const CUnit* unit, bool visible)
{
	if (unit == nullptr || unit->id < 0 || static_cast<std::size_t>(unit->id) >= slots.size())
		return;
	auto& slot = slots[unit->id];
	if (slot.IsActive() && slot.unitToken == reinterpret_cast<std::uintptr_t>(unit))
		slot.nativeModelVisible = visible;
}

bool Aoe2GameplayBridgeImpl::ReplacesNativeModel(const CUnit* unit) const
{
	if (!enabled.load(std::memory_order_acquire) || unit == nullptr || unit->id < 0 ||
		static_cast<std::size_t>(unit->id) >= slots.size() || unit->unitDef == nullptr)
		return false;
	const auto& slot = slots[unit->id];
	if (!slot.IsActive() || slot.unitToken != reinterpret_cast<std::uintptr_t>(unit) ||
		unit->unitDef->id <= 0 || static_cast<std::size_t>(unit->unitDef->id) >= mappings.size())
		return false;
	return mappings[unit->unitDef->id].hideNativeModel;
}

void Aoe2GameplayBridgeImpl::SetNativeModelVisible(const CFeature* feature, bool visible)
{
	if (feature == nullptr || feature->id < 0 || static_cast<std::size_t>(feature->id) >= featureSlots.size())
		return;
	auto& slot = featureSlots[feature->id];
	if (slot.IsActive() && slot.featureToken == reinterpret_cast<std::uintptr_t>(feature))
		slot.nativeModelVisible = visible;
}

bool Aoe2GameplayBridgeImpl::ReplacesNativeModel(const CFeature* feature) const
{
	if (!enabled.load(std::memory_order_acquire) || feature == nullptr || feature->id < 0 ||
		static_cast<std::size_t>(feature->id) >= featureSlots.size())
		return false;
	const auto& slot = featureSlots[feature->id];
	return slot.IsActive() && slot.featureToken == reinterpret_cast<std::uintptr_t>(feature) &&
		slot.mappingIndex < mappings.size() && mappings[slot.mappingIndex].hideNativeModel;
}

} // namespace

void CAoe2UnitGameplayRenderBridge::InitStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr || !CAoe2UnitRenderer::IsAvailable())
		return;
	auto candidate = std::make_unique<Aoe2GameplayBridgeImpl>();
	if (candidate->Init())
		bridge = std::move(candidate);
#endif
}

void CAoe2UnitGameplayRenderBridge::KillStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->Kill();
	bridge.reset();
#endif
}

void CAoe2UnitGameplayRenderBridge::PrepareStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->Prepare();
#endif
}

void CAoe2UnitGameplayRenderBridge::UpdateStatic()
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->Update();
#endif
}

void CAoe2UnitGameplayRenderBridge::SetNativeModelVisible(const CUnit* unit, bool visible)
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->SetNativeModelVisible(unit, visible);
#endif
}

bool CAoe2UnitGameplayRenderBridge::ReplacesNativeModel(const CUnit* unit)
{
#ifndef HEADLESS
	return bridge != nullptr && bridge->ReplacesNativeModel(unit);
#else
	return false;
#endif
}

void CAoe2UnitGameplayRenderBridge::SetNativeModelVisible(const CFeature* feature, bool visible)
{
#ifndef HEADLESS
	if (bridge != nullptr)
		bridge->SetNativeModelVisible(feature, visible);
#endif
}

bool CAoe2UnitGameplayRenderBridge::ReplacesNativeModel(const CFeature* feature)
{
#ifndef HEADLESS
	return bridge != nullptr && bridge->ReplacesNativeModel(feature);
#else
	return false;
#endif
}

Aoe2UnitGameplayBridgeDiagnostics CAoe2UnitGameplayRenderBridge::GetDiagnostics()
{
#ifndef HEADLESS
	return (bridge != nullptr) ? bridge->diagnostics : Aoe2UnitGameplayBridgeDiagnostics{};
#else
	return {};
#endif
}
