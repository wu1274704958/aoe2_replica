/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "SolidObjectDef.h"

#include <cmath>
#include "Lua/LuaParser.h"
#include "Rendering/Models/IModelParser.h"
#include "Rendering/Models/3DModel.hpp"
#include "Sim/Misc/CollisionVolume.h"
#include "System/EventHandler.h"
#include "System/Log/ILog.h"
#include "System/SpringMath.h"
#include "System/StringUtil.h"

#include "System/Misc/TracyDefs.h"

SolidObjectDecalDef::SolidObjectDecalDef()
	: useGroundDecal(false)
	, groundDecalType(-1)
	, groundDecalSizeX(-1)
	, groundDecalSizeY(-1)
	, groundDecalDecaySpeed(0.0f)

	, leaveTrackDecals(false)
	//, trackDecalType(-1)
	, trackDecalWidth(0.0f)
	, trackDecalOffset(0.0f)
	, trackDecalStrength(0.0f)
	, trackDecalStretch(0.0f)
{}

void SolidObjectDecalDef::Parse(const LuaTable& table) {
	groundDecalTypeName = table.GetString("groundDecalType", table.GetString("buildingGroundDecalType", ""));
	trackDecalTypeName = table.GetString("trackType", "StdTank");

	useGroundDecal        = table.GetBool("useGroundDecal", table.GetBool("useBuildingGroundDecal", false));
	groundDecalType       = -1;
	groundDecalSizeX      = table.GetInt("groundDecalSizeX", table.GetInt("buildingGroundDecalSizeX", 4));
	groundDecalSizeY      = table.GetInt("groundDecalSizeY", table.GetInt("buildingGroundDecalSizeY", 4));
	groundDecalDecaySpeed = table.GetFloat("groundDecalDecaySpeed", table.GetFloat("buildingGroundDecalDecaySpeed", 0.1f));

	leaveTrackDecals   = table.GetBool("leaveTracks", false);
	//trackDecalType     = -1;
	trackDecalWidth    = table.GetFloat("trackWidth",   32.0f);
	trackDecalOffset   = table.GetFloat("trackOffset",   0.0f);
	trackDecalStrength = table.GetFloat("trackStrength", 0.0f);
	trackDecalStretch  = table.GetFloat("trackStretch",  1.0f);
}

SolidObjectDef::SolidObjectDef()
	: id(-1)

	, xsize(0)
	, zsize(0)

	, cost(0.0f)
	, health(0.0f)
	, mass(0.0f)
	, crushResistance(0.0f)

	, collidable(false)
	, selectable(true)
	, upright(false)
	, reclaimable(true)

	, model(nullptr)
{
}

void SolidObjectDef::PreloadModel() const
{
	RECOIL_DETAILED_TRACY_ZONE;
	if (model != nullptr)
		return;
	if (modelName.empty())
		return;

	modelLoader.PreloadModel(modelName);
}

S3DModel* SolidObjectDef::LoadModel() const
{
	RECOIL_DETAILED_TRACY_ZONE;
	if (model != nullptr)
		return model;
	if (UsesAoeLogicalModel())
		return (model = modelLoader.GetDummyModel());
	if (modelName.empty())
		return nullptr;

	return (model = modelLoader.LoadModel(modelName));
}

bool SolidObjectDef::UsesAoeLogicalModel() const
{
#if defined(ENABLE_AOE2_UNIT_RENDERER)
	if (!modelName.empty())
		return false;

	const bool hasAppearance = customParams.contains("aoe2_unit_id") || customParams.contains("aoe2_building_id");
	if (!hasAppearance)
		return false;

	if (const auto it = customParams.find("aoe2_corpse"); it != customParams.end()) {
		const std::string value = StringToLower(it->second);
		if (value == "1" || value == "true" || value == "yes" || value == "on")
			return true;
	}

	if (const auto it = customParams.find("aoe2_hide_native_model"); it != customParams.end()) {
		const std::string value = StringToLower(it->second);
		return value == "1" || value == "true" || value == "yes" || value == "on";
	}
#endif
	return false;
}

void SolidObjectDef::ApplyAoeCollisionYaw()
{
#if defined(ENABLE_AOE2_UNIT_RENDERER)
	if (collisionVolume.GetVolumeType() != CollisionVolume::COLVOL_TYPE_AOE_BOX &&
		selectionVolume.GetVolumeType() != CollisionVolume::COLVOL_TYPE_AOE_BOX)
		return;

	float yawDegrees = 0.0f;
	if (const auto it = customParams.find("aoe2_collision_yaw_degrees"); it != customParams.end()) {
		bool failed = false;
		yawDegrees = StringToFloat(it->second, &failed);
		if (failed || !std::isfinite(yawDegrees)) {
			LOG_L(L_WARNING, "SolidObjectDef %s has invalid aoe2_collision_yaw_degrees=%s; using 0",
				name.c_str(), it->second.c_str());
			yawDegrees = 0.0f;
		}
	}

	const float yawRadians = std::remainder(yawDegrees, 360.0f) * math::DEG_TO_RAD;
	if (collisionVolume.GetVolumeType() == CollisionVolume::COLVOL_TYPE_AOE_BOX)
		collisionVolume.SetLocalYaw(yawRadians);
	if (selectionVolume.GetVolumeType() == CollisionVolume::COLVOL_TYPE_AOE_BOX)
		selectionVolume.SetLocalYaw(yawRadians);
#endif
}

float SolidObjectDef::GetModelRadius() const
{
	RECOIL_DETAILED_TRACY_ZONE;
	return ((LoadModel() != nullptr)? model->GetDrawRadius(): 0.0f);
}


void SolidObjectDef::ParseCollisionVolume(const LuaTable& odTable)
{
	RECOIL_DETAILED_TRACY_ZONE;
	const LuaTable& cvTable = odTable.SubTable("collisionVolume");
	const std::string& cvType = odTable.GetString("collisionVolumeType", "");

	#if defined(ENABLE_AOE2_UNIT_RENDERER)
	if (!cvTable.IsValid() && cvType == "AoeBox") {
		collisionVolume.InitShape(
			odTable.GetFloat3("collisionVolumeScales", ZeroVector),
			odTable.GetFloat3("collisionVolumeOffsets", ZeroVector),
			CollisionVolume::COLVOL_TYPE_AOE_BOX,
			CollisionVolume::COLVOL_HITTEST_CONT,
			CollisionVolume::COLVOL_AXIS_Z
		);
		return;
	}
	#endif

	if (cvTable.IsValid()) {
		collisionVolume = CollisionVolume(
			cvTable.GetInt("type", 's'),
			cvTable.GetInt("axis", 'z'),
			cvTable.GetFloat3("scales" , ZeroVector),
			cvTable.GetFloat3("offsets", ZeroVector)
		);
	} else {
		collisionVolume = CollisionVolume(
			((cvType.empty())? 's': cvType.front()),
			((cvType.empty())? 'z': cvType.back ()),
			odTable.GetFloat3("collisionVolumeScales" , ZeroVector),
			odTable.GetFloat3("collisionVolumeOffsets", ZeroVector)
		);
	}

	// if this unit wants per-piece volumes, make
	// its main collision volume deferent and let
	// it ignore hits
	collisionVolume.SetDefaultToPieceTree(odTable.GetBool("usePieceCollisionVolumes", false));
	collisionVolume.SetDefaultToFootPrint(odTable.GetBool("useFootPrintCollisionVolume", false));
	collisionVolume.SetIgnoreHits(collisionVolume.DefaultToPieceTree());
}

void SolidObjectDef::ParseSelectionVolume(const LuaTable& odTable)
{
	RECOIL_DETAILED_TRACY_ZONE;
	const LuaTable& svTable = odTable.SubTable("selectionVolume");
	const std::string& svType = odTable.GetString("selectionVolumeType", odTable.GetString("collisionVolumeType", ""));

	#if defined(ENABLE_AOE2_UNIT_RENDERER)
	if (!svTable.IsValid() && svType == "AoeBox") {
		selectionVolume.InitShape(
			odTable.GetFloat3("selectionVolumeScales", odTable.GetFloat3("collisionVolumeScales", ZeroVector)),
			odTable.GetFloat3("selectionVolumeOffsets", odTable.GetFloat3("collisionVolumeOffsets", ZeroVector)),
			CollisionVolume::COLVOL_TYPE_AOE_BOX,
			CollisionVolume::COLVOL_HITTEST_CONT,
			CollisionVolume::COLVOL_AXIS_Z
		);
		return;
	}
	#endif

	if (svTable.IsValid()) {
		selectionVolume = CollisionVolume(
			svTable.GetInt("type", 's'),
			svTable.GetInt("axis", 'z'),
			svTable.GetFloat3("scales" , ZeroVector),
			svTable.GetFloat3("offsets", ZeroVector)
		);
	} else {
		selectionVolume = CollisionVolume(
			((svType.empty())? 's': svType.front()),
			((svType.empty())? 'z': svType.back ()),
			odTable.GetFloat3("selectionVolumeScales" , odTable.GetFloat3("collisionVolumeScales" , ZeroVector)),
			odTable.GetFloat3("selectionVolumeOffsets", odTable.GetFloat3("collisionVolumeOffsets", ZeroVector))
		);
	}

	selectionVolume.SetDefaultToPieceTree(odTable.GetBool("usePieceSelectionVolumes", false));
	selectionVolume.SetDefaultToFootPrint(odTable.GetBool("useFootPrintSelectionVolume", false));
	selectionVolume.SetIgnoreHits(selectionVolume.DefaultToPieceTree());
}
