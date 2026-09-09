function gadget:GetInfo()
	return {
		name = "AOE Test Terrain",
		desc = "Applies a local AOE2DE terrain texture through the native SMF square-texture API",
		author = "OpenAI Codex",
		license = "GPL v2 or later",
		layer = -10,
		enabled = true,
	}
end

if gadgetHandler:IsSyncedCode() then
	return
end

local function ReadBooleanOption(name, defaultValue)
	local value = Spring.GetModOptions()[name]
	if value == nil then
		return defaultValue
	end

	value = tostring(value):lower()
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

if not ReadBooleanOption("aoe_test_terrain", false) then
	return
end

-- Local development asset copied from the user's AoE2DE installation. It is
-- deliberately not versioned or redistributed with this test mod.
local TERRAIN_TEXTURE = "bitmaps/aoe2de_g_des.dds"
-- SMF ground squares are 128 map squares (8 world units each).
local GROUND_SQUARE_WORLD_SIZE = 1024
local GROUND_AMBIENT_COLOR = { 0.75, 0.75, 0.75 }
local GROUND_DIFFUSE_COLOR = { 0.75, 0.75, 0.75 }

function gadget:Initialize()
	-- The generated blank map defaults both ground-light terms to 0.5, which
	-- makes the otherwise bright AoE terrain texture appear substantially too
	-- dark. This is an unsynced, test-only native map-light override.
	Spring.SetSunLighting({
		groundAmbientColor = GROUND_AMBIENT_COLOR,
		groundDiffuseColor = GROUND_DIFFUSE_COLOR,
	})

	-- TextureInfo resolves and retains the named VFS texture before it is handed
	-- to Spring.SetMapSquareTexture. The latter is Recoil's native SMF texture
	-- override path; only rendering changes, never synced terrain state.
	local textureInfo = gl.TextureInfo(TERRAIN_TEXTURE)
	if textureInfo == nil then
		Spring.Echo("[AOE Test Terrain] failed to load " .. TERRAIN_TEXTURE)
		return
	end

	if textureInfo.xsize ~= textureInfo.ysize then
		Spring.Echo(string.format(
			"[AOE Test Terrain] texture must be square, got %dx%d: %s",
			textureInfo.xsize, textureInfo.ysize, TERRAIN_TEXTURE
		))
		return
	end

	local squareCountX = math.floor(Game.mapSizeX / GROUND_SQUARE_WORLD_SIZE)
	local squareCountZ = math.floor(Game.mapSizeZ / GROUND_SQUARE_WORLD_SIZE)
	local applied = 0

	for z = 0, squareCountZ - 1 do
		for x = 0, squareCountX - 1 do
			if Spring.SetMapSquareTexture(x, z, TERRAIN_TEXTURE) then
				applied = applied + 1
			end
		end
	end

	Spring.Echo(string.format(
		"[AOE Test Terrain] applied %s (%dx%d) to %d/%d ground squares; ambient=%.2f diffuse=%.2f",
		TERRAIN_TEXTURE, textureInfo.xsize, textureInfo.ysize,
		applied, squareCountX * squareCountZ,
		GROUND_AMBIENT_COLOR[1], GROUND_DIFFUSE_COLOR[1]
	))
end
