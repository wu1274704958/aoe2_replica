local FixedTestCamera = {}

local FOV_DEGREES = 5
local REFERENCE_FOV_DEGREES = 45
local REFERENCE_HEIGHT = 1000
local CAMERA_ANGLE = math.pi * 0.25
local FEATURE_DISTANCE_MARGIN = 512

local function ReadBoolean(value)
	value = tostring(value or "false"):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function ApplyFeatureDistanceOverlay(cameraHeight)
	local halfMapWidth = Game.mapSizeX * 0.5
	local halfMapHeight = Game.mapSizeZ * 0.5
	local halfMapDiagonal = math.sqrt(halfMapWidth * halfMapWidth + halfMapHeight * halfMapHeight)
	local requiredDistance = math.ceil(cameraHeight + halfMapDiagonal + FEATURE_DISTANCE_MARGIN)
	local featureDrawDistance = math.max(
		requiredDistance,
		Spring.GetConfigFloat("FeatureDrawDistance", 6000))
	local featureFadeDistance = math.max(
		requiredDistance,
		Spring.GetConfigFloat("FeatureFadeDistance", 4500))

	-- These in-memory overlays are scoped to this engine run. They keep the
	-- fixed test camera from hiding AOE corpse-host Features without
	-- changing the user's persistent settings or normal game defaults.
	Spring.SetConfigFloat("FeatureDrawDistance", featureDrawDistance, true)
	Spring.SetConfigFloat("FeatureFadeDistance", featureFadeDistance, true)

	return featureDrawDistance, featureFadeDistance
end

function FixedTestCamera.Apply()
	local modOptions = Spring.GetModOptions()
	local orthographic = ReadBoolean(modOptions.aoe_orthographic_test_camera)
	local referenceHalfFov = math.rad(REFERENCE_FOV_DEGREES * 0.5)
	local testHalfFov = math.rad(FOV_DEGREES * 0.5)
	local orthoHeight = 2 * REFERENCE_HEIGHT * math.tan(referenceHalfFov)
	local testHeight = orthographic
		and REFERENCE_HEIGHT
		or REFERENCE_HEIGHT * math.tan(referenceHalfFov) / math.tan(testHalfFov)
	local cameraFov = orthographic and REFERENCE_FOV_DEGREES or FOV_DEGREES
	local centerX = Game.mapSizeX * 0.5
	local centerZ = Game.mapSizeZ * 0.5
	local featureDrawDistance, featureFadeDistance = ApplyFeatureDistanceOverlay(testHeight)

	Spring.SetConfigFloat("OverheadFOV", cameraFov, true)
	Spring.SetConfigFloat("OverheadTiltSpeed", 0, true)
	local applied = Spring.SetCameraState({
		mode = 1,
		fov = cameraFov,
		projection = orthographic and 1 or 0,
		orthoHeight = orthoHeight,
		px = centerX,
		py = Spring.GetGroundHeight(centerX, centerZ),
		pz = centerZ,
		height = testHeight,
		angle = CAMERA_ANGLE,
		flipped = false,
	}, 0)
	local appliedState = Spring.GetCameraState()
	local appliedProjection = appliedState.projection == 1 and "orthographic" or "perspective"
	local appliedOrthoHeight = tonumber(appliedState.orthoHeight) or 0

	return applied, cameraFov, testHeight, math.deg(CAMERA_ANGLE), featureDrawDistance, featureFadeDistance,
		appliedProjection, appliedOrthoHeight
end

return FixedTestCamera
