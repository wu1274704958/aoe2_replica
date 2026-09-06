/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Aoe2UnitRenderer.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

#include <simdjson.h>

#include "Game/Camera.h"
#include "Game/CameraHandler.h"
#include "Map/Ground.h"
#include "Map/ReadMap.h"
#include "Rendering/GL/myGL.h"
#include "Rendering/GlobalRendering.h"
#include "Rendering/Shaders/Shader.h"
#include "Rendering/Shaders/ShaderHandler.h"
#include "Rendering/Textures/Bitmap.h"
#include "Sim/Misc/GlobalConstants.h"
#include "System/Config/ConfigHandler.h"
#include "System/Config/ConfigVariable.h"
#include "System/Log/ILog.h"

CONFIG(bool, Aoe2UnitRendering)
	.defaultValue(false)
	.headlessValue(false)
	.description("Enable the experimental, unsynced AOE2 sprite unit renderer");
CONFIG(std::string, Aoe2UnitCachePath)
	.defaultValue("cont/aoe2de_cache")
	.description("Local AOE2 cache root; this content is not redistributed");
CONFIG(float, Aoe2UnitPixelsToWorld)
	.defaultValue(0.55f)
	.minimumValue(0.01f)
	.maximumValue(10.0f)
	.description("Conversion from cached sprite pixels to Recoil world units (AOE2 x2 cache baseline)");
CONFIG(float, Aoe2UnitMainCameraBias)
	.defaultValue(4.0f)
	.minimumValue(0.0f)
	.maximumValue(32.0f)
	.description("Temporary main-sprite offset toward the camera in world units");
CONFIG(int, Aoe2UnitTestCount)
	.defaultValue(0)
	.minimumValue(0)
	.maximumValue(100000)
	.description("Create an unsynced render-only AOE2 unit test grid");
CONFIG(std::string, Aoe2UnitTestId)
	.defaultValue("u_arc_archer")
	.description("AOE2 cache unit ID used by the render-only test grid");
CONFIG(bool, Aoe2UnitDiagnostics)
	.defaultValue(false)
	.description("Log AOE2 renderer frame metrics once per second");

namespace {

constexpr float PI = 3.14159265358979323846f;
constexpr float TWO_PI = PI * 2.0f;
constexpr std::uint32_t INVALID_INDEX = ~std::uint32_t(0);

struct Float4 {
	float x = 0.0f;
	float y = 0.0f;
	float z = 0.0f;
	float w = 0.0f;
};

struct WorldInstance {
	Float4 axisX;
	Float4 axisY;
	Float4 origin;
};

struct VisualInstance {
	Float4 uv;
	Float4 sizeAndFoot;
	std::uint32_t tintRgba8 = 0xFFFFFFFFu;
	std::uint32_t playerAndFlags = 1u;
};

static_assert(sizeof(WorldInstance) == 48);
static_assert(sizeof(VisualInstance) == 40);

struct Frame {
	Float4 uv;
	float width = 0.0f;
	float height = 0.0f;
	float footX = 0.0f;
	float footY = 0.0f;
	bool present = false;
};

struct Layer {
	std::filesystem::path imagePath;
	int atlasWidth = 0;
	int atlasHeight = 0;
	std::vector<Frame> frames;
	GLuint texture = 0;
	std::uint64_t textureBytes = 0;
	bool usable = false;
};

struct GpuBatch {
	GLuint vao = 0;
	GLuint worldVbo = 0;
	GLuint visualVbo = 0;
	std::size_t capacity = 0;
	std::vector<WorldInstance> world;
	std::vector<VisualInstance> visual;
	std::vector<WorldInstance> uploadedWorld;
	std::vector<VisualInstance> uploadedVisual;
};

struct Animation {
	std::string name;
	float fps = 30.0f;
	int directionCount = 0;
	int framesPerDirection = 0;
	Layer main;
	Layer shadow;
	Layer playerColor;
	GpuBatch mainBatch;
	GpuBatch shadowBatch;
};

struct Appearance {
	std::string id;
	std::uint32_t generation = 1;
	std::array<Animation, 4> animations;
	std::array<bool, 4> loaded{false, false, false, false};
	int attackReleaseFrame = 0;
};

struct Instance {
	std::uint32_t generation = 1;
	bool alive = false;
	bool visible = true;
	bool testControlled = false;
	std::uint32_t appearanceIndex = INVALID_INDEX;
	float3 position;
	float3 testOrigin;
	float heading = 0.0f;
	float scale = 1.0f;
	float animationTime = 0.0f;
	float playbackSpeed = 1.0f;
	float testPhase = 0.0f;
	Aoe2UnitAnimationSlot animation = Aoe2UnitAnimationSlot::IdleA;
	std::uint8_t playerColor = 1;
	std::uint32_t tintRgba8 = 0xFFFFFFFFu;
};

constexpr std::string_view VERTEX_SHADER = R"GLSL(
#version 330 core
uniform mat4 uViewProj;
layout(location = 0) in vec3 vposition;
layout(location = 1) in vec4 vaxisX;
layout(location = 2) in vec4 vaxisY;
layout(location = 3) in vec4 vorigin;
layout(location = 4) in vec4 vuv;
layout(location = 5) in vec4 vgeometry;
layout(location = 6) in uvec2 vmaterial;
out vec2 oUv;
out vec4 oColor;
flat out uint oPlayer;
vec4 unpackRgba8(uint value) {
	return vec4(float(value & 255u), float((value >> 8u) & 255u),
		float((value >> 16u) & 255u), float((value >> 24u) & 255u)) / 255.0;
}
void main() {
	vec2 local = vec2(
		vposition.x * vgeometry.x + vgeometry.x * 0.5 - vgeometry.z,
		vposition.y * vgeometry.y + vgeometry.w - vgeometry.y * 0.5);
	gl_Position = uViewProj * (vorigin + vaxisX * local.x + vaxisY * local.y);
	vec2 p0 = vuv.xy;
	vec2 p1 = vuv.xy + vuv.zw;
	if (gl_VertexID == 0) oUv = vec2(p1.x, p0.y);
	else if (gl_VertexID == 1) oUv = p0;
	else if (gl_VertexID == 2) oUv = vec2(p0.x, p1.y);
	else oUv = p1;
	oColor = unpackRgba8(vmaterial.x);
	oPlayer = clamp(vmaterial.y & 15u, 1u, 8u);
}
)GLSL";

constexpr std::string_view MAIN_FRAGMENT_SHADER = R"GLSL(
#version 330 core
in vec2 oUv;
in vec4 oColor;
flat in uint oPlayer;
out vec4 fragColor;
uniform sampler2D diffuseTex;
uniform sampler2D playerColorTex;
uniform sampler2D playerPalette;
void main() {
	vec4 base = texture(diffuseTex, oUv);
	if (base.a < 0.01) discard;
	int encodedIndex = int(texture(playerColorTex, oUv).r * 255.0 + 0.5);
	if (encodedIndex != 0) {
		int player = clamp(int(oPlayer), 1, 8) - 1;
		vec3 teamBase = texelFetch(playerPalette, ivec2(0, player), 0).rgb;
		float diffuseLuma = dot(base.rgb, vec3(0.2126, 0.7152, 0.0722));
		float shade = clamp(diffuseLuma * 1.6, 0.22, 1.15);
		base.rgb = clamp(teamBase * shade, 0.0, 1.0);
	}
	fragColor = base * oColor;
}
)GLSL";

constexpr std::string_view SHADOW_FRAGMENT_SHADER = R"GLSL(
#version 330 core
in vec2 oUv;
in vec4 oColor;
out vec4 fragColor;
uniform sampler2D diffuseTex;
void main() {
	float strength = texture(diffuseTex, oUv).r;
	if (strength < 0.01) discard;
	fragColor = vec4(0.0, 0.0, 0.0, strength * 0.62 * oColor.a);
}
)GLSL";

std::size_t AnimationIndex(Aoe2UnitAnimationSlot slot)
{
	return static_cast<std::size_t>(slot);
}

bool AnimationLoops(Aoe2UnitAnimationSlot slot)
{
	return slot == Aoe2UnitAnimationSlot::IdleA || slot == Aoe2UnitAnimationSlot::WalkA;
}

std::size_t NextCapacity(std::size_t requested)
{
	std::size_t result = 256;
	while (result < requested)
		result += result / 2;
	return result;
}

std::string GetString(simdjson::dom::element element)
{
	return std::string(element.get_string().value());
}

bool IsUsableLayer(const std::string& status)
{
	return status == "complete" || status == "partial";
}

Layer ParseLayer(
	simdjson::dom::object layerObject,
	const std::filesystem::path& configPath,
	int directionCount,
	int framesPerDirection
)
{
	Layer layer;
	const int expectedFrames = directionCount * framesPerDirection;
	const std::string status = GetString(layerObject["status"]);
	if (!IsUsableLayer(status))
		return layer;

	layer.atlasWidth = static_cast<int>(layerObject["atlas_w"].get_int64().value());
	layer.atlasHeight = static_cast<int>(layerObject["atlas_h"].get_int64().value());
	if (layer.atlasWidth <= 0 || layer.atlasHeight <= 0)
		throw std::runtime_error("invalid atlas dimensions");
	layer.imagePath = configPath.parent_path() / GetString(layerObject["image"]);
	layer.frames.reserve(expectedFrames);

	simdjson::dom::array frames;
	if (const auto error = layerObject["frames"].get_array().get(frames); error != simdjson::SUCCESS)
		throw std::runtime_error("layer frames are missing or invalid: " + std::string(simdjson::error_message(error)));
	for (const auto frameElement : frames) {
		const auto frameObject = frameElement.get_object().value();
		Frame frame;
		const int direction = static_cast<int>(frameObject["direction"].get_int64().value());
		const int frameNumber = static_cast<int>(frameObject["frame"].get_int64().value());
		const int expectedDirection = static_cast<int>(layer.frames.size()) / framesPerDirection;
		const int expectedFrame = static_cast<int>(layer.frames.size()) % framesPerDirection;
		if (direction != expectedDirection || frameNumber != expectedFrame)
			throw std::runtime_error("layer frames are not direction-major");
		frame.present = frameObject["present"].get_bool().value();
		const int x = static_cast<int>(frameObject["x"].get_int64().value());
		const int y = static_cast<int>(frameObject["y"].get_int64().value());
		frame.width = static_cast<float>(frameObject["w"].get_int64().value());
		frame.height = static_cast<float>(frameObject["h"].get_int64().value());
		const auto foot = frameObject["foot"].get_object().value();
		if (GetString(foot["space"]) != "frame_pixels_top_left")
			throw std::runtime_error("unsupported foot coordinate space");
		frame.footX = static_cast<float>(foot["x"].get_double().value());
		frame.footY = static_cast<float>(foot["y"].get_double().value());
		if (x < 0 || y < 0 || frame.width <= 0.0f || frame.height <= 0.0f ||
			x + frame.width > layer.atlasWidth || y + frame.height > layer.atlasHeight)
			throw std::runtime_error("frame rectangle is outside atlas");
		frame.uv = {
			static_cast<float>(x) / layer.atlasWidth,
			static_cast<float>(y) / layer.atlasHeight,
			frame.width / layer.atlasWidth,
			frame.height / layer.atlasHeight,
		};
		layer.frames.push_back(frame);
	}

	if (static_cast<int>(layer.frames.size()) != expectedFrames)
		throw std::runtime_error("layer frame count mismatch");
	layer.usable = true;
	return layer;
}

void ResolveMissingFrames(Layer& layer, int directionCount, int framesPerDirection)
{
	if (!layer.usable)
		return;

	for (int direction = 0; direction < directionCount; ++direction) {
		for (int frame = 0; frame < framesPerDirection; ++frame) {
			const int index = direction * framesPerDirection + frame;
			if (layer.frames[index].present)
				continue;
			for (int distance = 1; distance < framesPerDirection; ++distance) {
				const int previous = direction * framesPerDirection + (frame - distance + framesPerDirection) % framesPerDirection;
				const int next = direction * framesPerDirection + (frame + distance) % framesPerDirection;
				if (layer.frames[previous].present) {
					layer.frames[index] = layer.frames[previous];
					break;
				}
				if (layer.frames[next].present) {
					layer.frames[index] = layer.frames[next];
					break;
				}
			}
			if (!layer.frames[index].present)
				throw std::runtime_error("direction contains no present frame");
		}
	}
}

enum class TextureEncoding {
	Rgba,
	ShadowR8,
	PlayerColorR8,
};

GLuint LoadTexture(
	const std::filesystem::path& path,
	bool linear,
	TextureEncoding encoding,
	std::uint64_t& textureBytes,
	int expectedWidth = 0,
	int expectedHeight = 0
)
{
	CBitmap source;
	if (!source.Load(path.string(), 1.0f, 4, GL_UNSIGNED_BYTE, false))
		throw std::runtime_error("failed to load texture: " + path.string());
	if ((expectedWidth > 0 && source.xsize != expectedWidth) ||
		(expectedHeight > 0 && source.ysize != expectedHeight))
		throw std::runtime_error("unexpected texture dimensions: " + path.string());

	CBitmap packed;
	const CBitmap* upload = &source;
	if (encoding != TextureEncoding::Rgba) {
		packed.Alloc(source.xsize, source.ysize, 1, GL_UNSIGNED_BYTE);
		const auto* sourcePixels = source.GetRawMem();
		auto* packedPixels = packed.GetRawMem();
		const std::size_t pixelCount = static_cast<std::size_t>(source.xsize) * source.ysize;
		for (std::size_t i = 0; i < pixelCount; ++i) {
			if (encoding == TextureEncoding::ShadowR8) {
				packedPixels[i] = sourcePixels[i * 4];
			} else {
				// Exported masks use 0 for non-team-color pixels and 1..128 for
				// original SLD player-color indices 0..127. Preserve that compact
				// encoding exactly; do not quantize it back to the legacy 8 shades.
				packedPixels[i] = sourcePixels[i * 4];
			}
		}
		upload = &packed;
	}

	GL::TextureCreationParams params;
	params.reqNumLevels = 1;
	params.linearTextureFilter = linear;
	params.linearMipMapFilter = linear;
	params.minFilter = linear ? GL_LINEAR : GL_NEAREST;
	params.magFilter = linear ? GL_LINEAR : GL_NEAREST;
	params.wrapModes = std::array<int32_t, 3>{GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE};
	GLint oldUnpackAlignment = 4;
	glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldUnpackAlignment);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	const GLuint texture = upload->CreateTexture(params);
	glPixelStorei(GL_UNPACK_ALIGNMENT, oldUnpackAlignment);
	textureBytes = upload->GetMemSize();
	return texture;
}

GLuint CreateZeroMaskTexture(std::uint64_t& textureBytes)
{
	constexpr std::uint8_t zero = 0;
	GLuint texture = 0;
	glGenTextures(1, &texture);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 1, 1, 0, GL_RED, GL_UNSIGNED_BYTE, &zero);
	glBindTexture(GL_TEXTURE_2D, 0);
	textureBytes = 1;
	return texture;
}

void DeleteLayerTexture(Layer& layer)
{
	if (layer.texture != 0)
		glDeleteTextures(1, &layer.texture);
	layer.texture = 0;
}

void DeleteBatch(GpuBatch& batch)
{
	if (batch.visualVbo != 0) glDeleteBuffers(1, &batch.visualVbo);
	if (batch.worldVbo != 0) glDeleteBuffers(1, &batch.worldVbo);
	if (batch.vao != 0) glDeleteVertexArrays(1, &batch.vao);
	batch = {};
}

class Aoe2RendererImpl
{
public:
	bool Init();
	void Kill();
	void Update();
	void Draw();

	Aoe2AppearanceHandle Preload(const std::string& unitId);
	Aoe2AppearanceHandle PreloadGraphics(const std::string& graphicsId);
	Aoe2InstanceHandle Create(const Aoe2UnitInstanceDesc& desc);
	bool Destroy(Aoe2InstanceHandle handle);
	Instance* Get(Aoe2InstanceHandle handle);

	void CreateTestGrid();
	void RebuildBatches();
	void SetupBatch(GpuBatch& batch);
	void UploadBatch(GpuBatch& batch);
	void DrawBatch(const Animation& animation, GpuBatch& batch, bool shadow);
	Animation LoadAnimation(const std::filesystem::path& configPath, const std::string& expectedName, bool requirePlayerColor = true);
	Shader::IProgramObject* CreateShader(const char* name, std::string_view fragmentShader);
	int DirectionForHeading(float heading, int directionCount) const;
	void PollGpuQueries();
	int BeginGpuQuery();
	void EndGpuQuery(int slot);

	std::filesystem::path cacheRoot;
	float pixelsToWorld = 1.0f;
	float mainCameraBias = 0.0f;
	std::vector<std::unique_ptr<Appearance>> appearances;
	std::vector<Instance> instances;
	std::vector<std::uint32_t> freeInstances;
	std::vector<Aoe2InstanceHandle> testHandles;
	std::vector<Aoe2UnitInstanceDesc> destroyedTestInstances;
	Shader::IProgramObject* mainShader = nullptr;
	Shader::IProgramObject* shadowShader = nullptr;
	GLuint playerColorPaletteTexture = 0;
	std::uint64_t playerColorPaletteTextureBytes = 0;
	GLuint quadVbo = 0;
	GLuint quadEbo = 0;
	std::array<GLuint, 4> gpuQueries{};
	std::array<bool, 4> gpuQueryPending{};
	std::size_t gpuQueryWrite = 0;
	Aoe2UnitRenderDiagnostics diagnostics;
	std::chrono::steady_clock::time_point lastDiagnostics = std::chrono::steady_clock::now();
	float testElapsed = 0.0f;
	int testLifecyclePhase = 0;
	bool diagnosticsEnabled = false;
	bool testCameraConfigured = false;
};

std::unique_ptr<Aoe2RendererImpl> renderer;

Shader::IProgramObject* Aoe2RendererImpl::CreateShader(const char* name, std::string_view fragmentShader)
{
	auto* program = shaderHandler->CreateProgramObject("[Aoe2UnitRenderer]", name);
	program->AttachShaderObject(shaderHandler->CreateShaderObject(std::string(VERTEX_SHADER), "", GL_VERTEX_SHADER));
	program->AttachShaderObject(shaderHandler->CreateShaderObject(std::string(fragmentShader), "", GL_FRAGMENT_SHADER));
	program->Link();
	program->Enable();
	program->SetUniform("diffuseTex", 0);
	if (std::string_view(name) == "Main") {
		program->SetUniform("playerColorTex", 1);
		program->SetUniform("playerPalette", 2);
	}
	program->Disable();
	program->Validate();
	return program->IsValid() ? program : nullptr;
}

bool Aoe2RendererImpl::Init()
{
	if (!GLAD_GL_VERSION_3_3 || !GLAD_GL_ARB_instanced_arrays) {
		LOG_L(L_WARNING, "[Aoe2UnitRenderer] OpenGL 3.3 instancing is unavailable; renderer disabled");
		return false;
	}

	cacheRoot = configHandler->GetString("Aoe2UnitCachePath");
	if (!cacheRoot.is_absolute() && !std::filesystem::exists(cacheRoot)) {
		const auto fromBuildDirectory = std::filesystem::current_path().parent_path() / cacheRoot;
		const auto fromSourceDirectory = std::filesystem::path(__FILE__).parent_path()
			.parent_path().parent_path().parent_path() / cacheRoot;
		if (std::filesystem::exists(fromBuildDirectory))
			cacheRoot = fromBuildDirectory;
		else if (std::filesystem::exists(fromSourceDirectory))
			cacheRoot = fromSourceDirectory;
	}
	cacheRoot = cacheRoot.lexically_normal();
	pixelsToWorld = configHandler->GetFloat("Aoe2UnitPixelsToWorld");
	mainCameraBias = configHandler->GetFloat("Aoe2UnitMainCameraBias");
	diagnosticsEnabled = configHandler->GetBool("Aoe2UnitDiagnostics");
	if (!std::filesystem::exists(cacheRoot)) {
		LOG_L(L_WARNING, "[Aoe2UnitRenderer] cache root does not exist: %s", cacheRoot.string().c_str());
		return false;
	}
	try {
		playerColorPaletteTexture = LoadTexture(
			cacheRoot / "playercolor_palette.png", false, TextureEncoding::Rgba,
			playerColorPaletteTextureBytes, 128, 8);
		diagnostics.textureBytes += playerColorPaletteTextureBytes;
	} catch (const std::exception& error) {
		LOG_L(L_ERROR, "[Aoe2UnitRenderer] failed to load player-color palette: %s", error.what());
		return false;
	}

	static constexpr float quadVertices[] = {
		 0.5f,  0.5f, 0.0f,
		-0.5f,  0.5f, 0.0f,
		-0.5f, -0.5f, 0.0f,
		 0.5f, -0.5f, 0.0f,
	};
	static constexpr std::uint32_t quadIndices[] = {0, 1, 2, 0, 2, 3};
	glGenBuffers(1, &quadVbo);
	glBindBuffer(GL_ARRAY_BUFFER, quadVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(quadVertices), quadVertices, GL_STATIC_DRAW);
	glGenBuffers(1, &quadEbo);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, quadEbo);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(quadIndices), quadIndices, GL_STATIC_DRAW);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

	mainShader = CreateShader("Main", MAIN_FRAGMENT_SHADER);
	shadowShader = CreateShader("Shadow", SHADOW_FRAGMENT_SHADER);
	if (mainShader == nullptr || shadowShader == nullptr) {
		LOG_L(L_ERROR, "[Aoe2UnitRenderer] shader compilation failed; renderer disabled");
		return false;
	}

	CreateTestGrid();
	LOG_L(L_INFO, "[Aoe2UnitRenderer] initialized (cache=%s, testInstances=%u, mainCameraBias=%.2f)",
		cacheRoot.string().c_str(), static_cast<unsigned>(testHandles.size()), mainCameraBias);
	return true;
}

void Aoe2RendererImpl::Kill()
{
	for (auto& appearancePtr : appearances) {
		if (appearancePtr == nullptr)
			continue;
		for (auto& animation : appearancePtr->animations) {
			DeleteBatch(animation.mainBatch);
			DeleteBatch(animation.shadowBatch);
			DeleteLayerTexture(animation.main);
			DeleteLayerTexture(animation.shadow);
			DeleteLayerTexture(animation.playerColor);
		}
	}
	if (quadEbo != 0) glDeleteBuffers(1, &quadEbo);
	if (quadVbo != 0) glDeleteBuffers(1, &quadVbo);
	if (gpuQueries[0] != 0) glDeleteQueries(static_cast<GLsizei>(gpuQueries.size()), gpuQueries.data());
	if (playerColorPaletteTexture != 0) glDeleteTextures(1, &playerColorPaletteTexture);
	playerColorPaletteTexture = 0;
	shaderHandler->ReleaseProgramObjects("[Aoe2UnitRenderer]");
	mainShader = nullptr;
	shadowShader = nullptr;
}

Animation Aoe2RendererImpl::LoadAnimation(const std::filesystem::path& configPath, const std::string& expectedName, bool requirePlayerColor)
{
	simdjson::dom::parser parser;
	simdjson::dom::element document;
	if (const auto error = parser.load(configPath.string()).get(document); error != simdjson::SUCCESS)
		throw std::runtime_error("failed to parse animation config: " + std::string(simdjson::error_message(error)));
	Animation animation;
	animation.name = GetString(document["name"]);
	if (animation.name != expectedName)
		throw std::runtime_error("animation name mismatch");
	animation.fps = static_cast<float>(document["fps"].get_double().value());
	animation.directionCount = static_cast<int>(document["direction_count"].get_int64().value());
	animation.framesPerDirection = static_cast<int>(document["frames_per_direction"].get_int64().value());
	if (!(animation.fps > 0.0f) || animation.directionCount <= 0 || animation.framesPerDirection <= 0)
		throw std::runtime_error("invalid animation dimensions");
	if (GetString(document["frame_order"]) != "direction_major")
		throw std::runtime_error("unsupported frame order");
	simdjson::dom::object layers;
	if (const auto error = document["layers"].get_object().get(layers); error != simdjson::SUCCESS)
		throw std::runtime_error("animation layers are missing or invalid: " + std::string(simdjson::error_message(error)));
	simdjson::dom::object mainLayer;
	simdjson::dom::object shadowLayer;
	simdjson::dom::object playerColorLayer;
	if (const auto error = layers["main"].get_object().get(mainLayer); error != simdjson::SUCCESS)
		throw std::runtime_error("main layer is missing or invalid: " + std::string(simdjson::error_message(error)));
	if (const auto error = layers["shadow"].get_object().get(shadowLayer); error != simdjson::SUCCESS)
		throw std::runtime_error("shadow layer is missing or invalid: " + std::string(simdjson::error_message(error)));
	if (const auto error = layers["player_color"].get_object().get(playerColorLayer); error != simdjson::SUCCESS)
		throw std::runtime_error("player-color layer is missing or invalid: " + std::string(simdjson::error_message(error)));
	animation.main = ParseLayer(mainLayer, configPath, animation.directionCount, animation.framesPerDirection);
	animation.shadow = ParseLayer(shadowLayer, configPath, animation.directionCount, animation.framesPerDirection);
	animation.playerColor = ParseLayer(playerColorLayer, configPath, animation.directionCount, animation.framesPerDirection);
	if (!animation.main.usable)
		throw std::runtime_error("main layer is unavailable");
	if (requirePlayerColor) {
		if (!animation.playerColor.usable)
			throw std::runtime_error("player-color layer is unavailable");
		if (animation.playerColor.atlasWidth != animation.main.atlasWidth ||
			animation.playerColor.atlasHeight != animation.main.atlasHeight ||
			animation.playerColor.frames.size() != animation.main.frames.size())
			throw std::runtime_error("player-color atlas layout differs from main");
		for (std::size_t i = 0; i < animation.main.frames.size(); ++i) {
			const auto& mainFrame = animation.main.frames[i];
			const auto& playerFrame = animation.playerColor.frames[i];
			if (mainFrame.uv.x != playerFrame.uv.x || mainFrame.uv.y != playerFrame.uv.y ||
				mainFrame.uv.z != playerFrame.uv.z || mainFrame.uv.w != playerFrame.uv.w ||
				mainFrame.footX != playerFrame.footX || mainFrame.footY != playerFrame.footY)
				throw std::runtime_error("player-color frame layout differs from main");
		}
	}
	ResolveMissingFrames(animation.main, animation.directionCount, animation.framesPerDirection);
	ResolveMissingFrames(animation.shadow, animation.directionCount, animation.framesPerDirection);
	if (requirePlayerColor)
		ResolveMissingFrames(animation.playerColor, animation.directionCount, animation.framesPerDirection);
	animation.main.texture = LoadTexture(animation.main.imagePath, true, TextureEncoding::Rgba, animation.main.textureBytes);
	if (requirePlayerColor) {
		animation.playerColor.texture = LoadTexture(
			animation.playerColor.imagePath, false, TextureEncoding::PlayerColorR8, animation.playerColor.textureBytes);
	} else {
		animation.playerColor.texture = CreateZeroMaskTexture(animation.playerColor.textureBytes);
	}
	if (animation.shadow.usable)
		animation.shadow.texture = LoadTexture(
			animation.shadow.imagePath, true, TextureEncoding::ShadowR8, animation.shadow.textureBytes);
	return animation;
}

Aoe2AppearanceHandle Aoe2RendererImpl::Preload(const std::string& unitId)
{
	for (std::size_t i = 0; i < appearances.size(); ++i) {
		if (appearances[i] != nullptr && appearances[i]->id == "units/" + unitId)
			return {static_cast<std::uint32_t>(i), appearances[i]->generation};
	}

	std::unique_ptr<Appearance> appearance;
	try {
		const auto manifestPath = cacheRoot / "units" / unitId / "manifest.json";
		simdjson::dom::parser parser;
		simdjson::dom::element document;
		if (const auto error = parser.load(manifestPath.string()).get(document); error != simdjson::SUCCESS)
			throw std::runtime_error("failed to parse unit manifest: " + std::string(simdjson::error_message(error)));
		const int schemaVersion = static_cast<int>(document["schema_version"].get_int64().value());
		const std::string kind = GetString(document["kind"]);
		if ((schemaVersion != 2 && schemaVersion != 3) || kind != "aoe2de_unit" || GetString(document["id"]) != unitId)
			throw std::runtime_error("unsupported unit manifest");
		if (GetString(document["export_settings"]["player_color"]["format"]) != "r8_palette_index_plus_one")
			throw std::runtime_error("unsupported player-color format");
		simdjson::dom::object manifestAnimations;
		if (const auto error = document["animations"].get_object().get(manifestAnimations); error != simdjson::SUCCESS)
			throw std::runtime_error("manifest animations are missing or invalid: " + std::string(simdjson::error_message(error)));
		appearance = std::make_unique<Appearance>();
		appearance->id = "units/" + unitId;
		std::int64_t attackReleaseFrame = 0;
		if (document["dat"]["combat"]["frame_delay"].get_int64().get(attackReleaseFrame) == simdjson::SUCCESS)
			appearance->attackReleaseFrame = static_cast<int>(std::max<std::int64_t>(0, attackReleaseFrame));
		static constexpr std::array<std::string_view, 4> animationNames = {
			"idleA", "walkA", "attackA", "deathA",
		};
		for (std::size_t i = 0; i < appearance->animations.size(); ++i) {
			const std::string name(animationNames[i]);
			simdjson::dom::object entry;
			if (const auto error = manifestAnimations[name].get_object().get(entry); error != simdjson::SUCCESS)
				throw std::runtime_error(name + " manifest entry is missing or invalid: " + std::string(simdjson::error_message(error)));
			if (GetString(entry["status"]) != "exported")
				throw std::runtime_error(name + " is not exported");
			const auto configPath = manifestPath.parent_path() / GetString(entry["config"]);
			appearance->animations[i] = LoadAnimation(configPath, name);
			appearance->loaded[i] = true;
		}
		for (const auto& animation : appearance->animations) {
			diagnostics.textureBytes += animation.main.textureBytes;
			diagnostics.textureBytes += animation.shadow.textureBytes;
			diagnostics.textureBytes += animation.playerColor.textureBytes;
		}
		const auto index = static_cast<std::uint32_t>(appearances.size());
		appearances.push_back(std::move(appearance));
		return {index, appearances.back()->generation};
	} catch (const std::exception& error) {
		if (appearance != nullptr) {
			for (auto& animation : appearance->animations) {
				DeleteLayerTexture(animation.main);
				DeleteLayerTexture(animation.shadow);
				DeleteLayerTexture(animation.playerColor);
			}
		}
		LOG_L(L_ERROR, "[Aoe2UnitRenderer] failed to preload unit %s: %s", unitId.c_str(), error.what());
		return {};
	}
}

Aoe2AppearanceHandle Aoe2RendererImpl::PreloadGraphics(const std::string& graphicsId)
{
	const std::string cacheId = "graphics/" + graphicsId;
	for (std::size_t i = 0; i < appearances.size(); ++i) {
		if (appearances[i] != nullptr && appearances[i]->id == cacheId)
			return {static_cast<std::uint32_t>(i), appearances[i]->generation};
	}

	std::unique_ptr<Appearance> appearance;
	try {
		const auto manifestPath = cacheRoot / "graphics" / graphicsId / "manifest.json";
		simdjson::dom::parser parser;
		simdjson::dom::element document;
		if (const auto error = parser.load(manifestPath.string()).get(document); error != simdjson::SUCCESS)
			throw std::runtime_error("failed to parse graphics manifest: " + std::string(simdjson::error_message(error)));
		if (document["schema_version"].get_int64().value() != 2 ||
			GetString(document["kind"]) != "aoe2de_graphics" || GetString(document["id"]) != graphicsId)
			throw std::runtime_error("unsupported graphics manifest");

		simdjson::dom::array discoveredAnimations;
		if (const auto error = document["discovered_animations"].get_array().get(discoveredAnimations); error != simdjson::SUCCESS || discoveredAnimations.size() == 0)
			throw std::runtime_error("graphics manifest has no discovered animation");
		std::string animationName;
		for (const auto animationElement : discoveredAnimations) {
			animationName = GetString(animationElement);
			break;
		}
		simdjson::dom::object animations;
		if (const auto error = document["animations"].get_object().get(animations); error != simdjson::SUCCESS)
			throw std::runtime_error("graphics manifest animations are missing or invalid: " + std::string(simdjson::error_message(error)));
		simdjson::dom::object entry;
		if (const auto error = animations[animationName].get_object().get(entry); error != simdjson::SUCCESS || GetString(entry["status"]) != "exported")
			throw std::runtime_error("graphics animation is unavailable");

		appearance = std::make_unique<Appearance>();
		appearance->id = cacheId;
		appearance->animations[AnimationIndex(Aoe2UnitAnimationSlot::IdleA)] = LoadAnimation(
			manifestPath.parent_path() / GetString(entry["config"]), animationName, false);
		appearance->loaded[AnimationIndex(Aoe2UnitAnimationSlot::IdleA)] = true;
		const auto& animation = appearance->animations[AnimationIndex(Aoe2UnitAnimationSlot::IdleA)];
		diagnostics.textureBytes += animation.main.textureBytes + animation.shadow.textureBytes + animation.playerColor.textureBytes;
		const auto index = static_cast<std::uint32_t>(appearances.size());
		appearances.push_back(std::move(appearance));
		return {index, appearances.back()->generation};
	} catch (const std::exception& error) {
		if (appearance != nullptr) {
			for (auto& animation : appearance->animations) {
				DeleteLayerTexture(animation.main);
				DeleteLayerTexture(animation.shadow);
				DeleteLayerTexture(animation.playerColor);
			}
		}
		LOG_L(L_ERROR, "[Aoe2UnitRenderer] failed to preload graphics %s: %s", graphicsId.c_str(), error.what());
		return {};
	}
}

Aoe2InstanceHandle Aoe2RendererImpl::Create(const Aoe2UnitInstanceDesc& desc)
{
	if (!desc.appearance || desc.appearance.index >= appearances.size() ||
		appearances[desc.appearance.index] == nullptr ||
		appearances[desc.appearance.index]->generation != desc.appearance.generation ||
		AnimationIndex(desc.animation) >= appearances[desc.appearance.index]->animations.size())
		return {};

	std::uint32_t index = 0;
	if (!freeInstances.empty()) {
		index = freeInstances.back();
		freeInstances.pop_back();
	} else {
		index = static_cast<std::uint32_t>(instances.size());
		instances.emplace_back();
	}
	auto& instance = instances[index];
	const std::uint32_t generation = std::max(1u, instance.generation);
	instance = {};
	instance.generation = generation;
	instance.alive = true;
	instance.visible = desc.visible;
	instance.appearanceIndex = desc.appearance.index;
	instance.position = desc.position;
	instance.heading = desc.headingRadians;
	instance.scale = std::max(0.01f, desc.scale);
	instance.animation = desc.animation;
	instance.animationTime = std::max(0.0f, desc.animationTime);
	instance.playbackSpeed = desc.playbackSpeed;
	instance.playerColor = std::clamp<std::uint8_t>(desc.playerColor, 1, 8);
	instance.tintRgba8 = desc.tintRgba8;
	return {index, generation};
}

Instance* Aoe2RendererImpl::Get(Aoe2InstanceHandle handle)
{
	if (!handle || handle.index >= instances.size())
		return nullptr;
	auto& instance = instances[handle.index];
	return (instance.alive && instance.generation == handle.generation) ? &instance : nullptr;
}

bool Aoe2RendererImpl::Destroy(Aoe2InstanceHandle handle)
{
	auto* instance = Get(handle);
	if (instance == nullptr)
		return false;
	instance->alive = false;
	instance->generation = (instance->generation == ~0u) ? 1u : instance->generation + 1u;
	freeInstances.push_back(handle.index);
	return true;
}

void Aoe2RendererImpl::CreateTestGrid()
{
	const int count = configHandler->GetInt("Aoe2UnitTestCount");
	if (count <= 0)
		return;
	const auto appearance = Preload(configHandler->GetString("Aoe2UnitTestId"));
	if (!appearance)
		return;

	const int columns = std::max(1, static_cast<int>(std::ceil(std::sqrt(static_cast<float>(count)))));
	const int rows = (count + columns - 1) / columns;
	const float spacing = 96.0f;
	const float centerX = mapDims.mapx * SQUARE_SIZE * 0.5f;
	const float centerZ = mapDims.mapy * SQUARE_SIZE * 0.5f;
	testHandles.reserve(count);
	for (int i = 0; i < count; ++i) {
		const float x = centerX + (i % columns - (columns - 1) * 0.5f) * spacing;
		const float z = centerZ + (i / columns - (rows - 1) * 0.5f) * spacing;
		Aoe2UnitInstanceDesc desc;
		desc.appearance = appearance;
		desc.position = {x, CGround::GetHeightReal(x, z, false) + 1.0f, z};
		desc.headingRadians = (i % 16) * TWO_PI / 16.0f;
		desc.animation = ((i & 1) == 0) ? Aoe2UnitAnimationSlot::IdleA : Aoe2UnitAnimationSlot::WalkA;
		desc.animationTime = (i % 31) * 0.037f;
		desc.playerColor = static_cast<std::uint8_t>(i % 8 + 1);
		const auto handle = Create(desc);
		if (auto* instance = Get(handle)) {
			instance->testControlled = ((i & 3) == 1);
			instance->testOrigin = instance->position;
			instance->testPhase = (i % 29) * 0.21f;
		}
		testHandles.push_back(handle);
	}
}

int Aoe2RendererImpl::DirectionForHeading(float heading, int directionCount) const
{
	const float3 facing{std::sin(heading), 0.0f, std::cos(heading)};
	const float screenX = facing.dot(camera->GetRight());
	const float screenY = facing.dot(camera->GetUp());
	float clockwiseAngle = std::atan2(-screenY, screenX);
	if (clockwiseAngle < 0.0f)
		clockwiseAngle += TWO_PI;
	return static_cast<int>(std::floor(clockwiseAngle * directionCount / TWO_PI + 0.5f)) % directionCount;
}

void Aoe2RendererImpl::RebuildBatches()
{
	for (auto& appearancePtr : appearances) {
		if (appearancePtr == nullptr)
			continue;
		for (auto& animation : appearancePtr->animations) {
			animation.mainBatch.world.clear();
			animation.mainBatch.visual.clear();
			animation.shadowBatch.world.clear();
			animation.shadowBatch.visual.clear();
		}
	}

	diagnostics.liveInstances = 0;
	diagnostics.visibleInstances = 0;
	for (const auto& instance : instances) {
		if (!instance.alive)
			continue;
		++diagnostics.liveInstances;
		if (!instance.visible || instance.appearanceIndex >= appearances.size() ||
			!camera->InView(instance.position, 128.0f * instance.scale))
			continue;
		auto& appearance = *appearances[instance.appearanceIndex];
		auto& animation = appearance.animations[AnimationIndex(instance.animation)];
		if (animation.main.texture == 0)
			continue;
		++diagnostics.visibleInstances;
		const int direction = DirectionForHeading(instance.heading, animation.directionCount);
		const int sampledFrame = static_cast<int>(std::floor(instance.animationTime * animation.fps));
		const int frameNumber = AnimationLoops(instance.animation)
			? sampledFrame % animation.framesPerDirection
			: std::min(sampledFrame, animation.framesPerDirection - 1);
		const int frameIndex = direction * animation.framesPerDirection + frameNumber;
		const float scale = instance.scale * pixelsToWorld;
		const float3 axisX = camera->GetRight() * scale;
		const float3 axisY = camera->GetUp() * scale;
		const WorldInstance shadowWorld{
			{axisX.x, axisX.y, axisX.z, 0.0f},
			{axisY.x, axisY.y, axisY.z, 0.0f},
			{instance.position.x, instance.position.y, instance.position.z, 1.0f},
		};
		const float3 mainPosition = instance.position - camera->GetDir() * mainCameraBias;
		const WorldInstance mainWorld{
			{axisX.x, axisX.y, axisX.z, 0.0f},
			{axisY.x, axisY.y, axisY.z, 0.0f},
			{mainPosition.x, mainPosition.y, mainPosition.z, 1.0f},
		};
		const auto makeVisual = [&](const Frame& frame) {
			return VisualInstance{
				frame.uv,
				{frame.width, frame.height, frame.footX, frame.footY},
				instance.tintRgba8,
				static_cast<std::uint32_t>(instance.playerColor),
			};
		};
		animation.mainBatch.world.push_back(mainWorld);
		animation.mainBatch.visual.push_back(makeVisual(animation.main.frames[frameIndex]));
		if (animation.shadow.texture != 0) {
			animation.shadowBatch.world.push_back(shadowWorld);
			animation.shadowBatch.visual.push_back(makeVisual(animation.shadow.frames[frameIndex]));
		}
	}
}

void Aoe2RendererImpl::Update()
{
	const auto started = std::chrono::steady_clock::now();
	// Keep this lightweight renderer-only setting live so the anchor calibration
	// scene can tune sprite scale without restarting or touching synced state.
	pixelsToWorld = configHandler->GetFloat("Aoe2UnitPixelsToWorld");
	const float deltaSeconds = std::clamp(globalRendering->lastFrameTime * 0.001f, 0.0f, 0.1f);
	testElapsed += deltaSeconds;
	if (!testHandles.empty() && !testCameraConfigured && camHandler != nullptr &&
		camHandler->GetControllers()[CCameraHandler::CAMERA_MODE_OVERHEAD] != nullptr) {
		const float centerX = mapDims.mapx * SQUARE_SIZE * 0.5f;
		const float centerZ = mapDims.mapy * SQUARE_SIZE * 0.5f;
		camHandler->SetCameraMode(CCameraHandler::CAMERA_MODE_OVERHEAD);
		auto& testCamera = camHandler->GetCurrentController();
		testCamera.SetRot({PI - PI * 0.25f, 0.0f, 0.0f});
		testCamera.SetPos({centerX, CGround::GetHeightReal(centerX, centerZ, false), centerZ});
		testCameraConfigured = true;
	}
	for (auto& instance : instances) {
		if (!instance.alive)
			continue;
		instance.animationTime = std::max(0.0f, instance.animationTime + deltaSeconds * instance.playbackSpeed);
		if (instance.testControlled) {
			instance.position.x = instance.testOrigin.x + std::sin(testElapsed * 0.8f + instance.testPhase) * 24.0f;
			instance.position.z = instance.testOrigin.z + std::cos(testElapsed * 0.8f + instance.testPhase) * 12.0f;
			instance.position.y = CGround::GetHeightReal(instance.position.x, instance.position.z, false) + 1.0f;
			instance.heading = testElapsed * 0.8f + instance.testPhase;
		}
	}
	if (!testHandles.empty()) {
		const int animationPhase = static_cast<int>(testElapsed / 5.0f) & 1;
		for (std::size_t i = 0; i < testHandles.size(); ++i) {
			if (auto* instance = Get(testHandles[i]))
				instance->animation = (((static_cast<int>(i) + animationPhase) & 1) == 0)
					? Aoe2UnitAnimationSlot::IdleA : Aoe2UnitAnimationSlot::WalkA;
		}

		const float lifecycleTime = std::fmod(testElapsed, 15.0f);
		const std::size_t lifecycleCount = std::max<std::size_t>(1, testHandles.size() / 10);
		if (lifecycleTime >= 10.0f && testLifecyclePhase == 0) {
			destroyedTestInstances.clear();
			destroyedTestInstances.reserve(lifecycleCount);
			for (std::size_t i = 0; i < lifecycleCount; ++i) {
				if (auto* instance = Get(testHandles[i])) {
					Aoe2UnitInstanceDesc desc;
					desc.appearance = {instance->appearanceIndex, appearances[instance->appearanceIndex]->generation};
					desc.position = instance->position;
					desc.headingRadians = instance->heading;
					desc.scale = instance->scale;
					desc.animation = instance->animation;
					desc.animationTime = instance->animationTime;
					desc.playbackSpeed = instance->playbackSpeed;
					desc.playerColor = instance->playerColor;
					desc.tintRgba8 = instance->tintRgba8;
					destroyedTestInstances.push_back(desc);
					Destroy(testHandles[i]);
				}
			}
			testLifecyclePhase = 1;
		} else if (lifecycleTime >= 12.0f && testLifecyclePhase == 1) {
			for (std::size_t i = 0; i < destroyedTestInstances.size(); ++i) {
				testHandles[i] = Create(destroyedTestInstances[i]);
				if (auto* instance = Get(testHandles[i])) {
					instance->testOrigin = instance->position;
					instance->testPhase = (i % 29) * 0.21f;
					instance->testControlled = ((i & 3) == 1);
				}
			}
			destroyedTestInstances.clear();
			testLifecyclePhase = 2;
		} else if (lifecycleTime < 2.0f && testLifecyclePhase == 2) {
			testLifecyclePhase = 0;
		}
	}
	RebuildBatches();
	diagnostics.cpuUpdateMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();

	const auto now = std::chrono::steady_clock::now();
	if (diagnosticsEnabled && now - lastDiagnostics >= std::chrono::seconds(1)) {
		const float fps = (globalRendering->lastFrameTime > 0.0f) ? 1000.0f / globalRendering->lastFrameTime : 0.0f;
		LOG_L(L_INFO, "[Aoe2UnitRenderer] instances=%u visible=%u batches=%u draws=%u upload=%lluB textures=%.1fMiB CPU(update/draw)=%.3f/%.3fms GPU=%.3fms FPS=%.1f",
			diagnostics.liveInstances, diagnostics.visibleInstances, diagnostics.batches, diagnostics.drawCalls,
			static_cast<unsigned long long>(diagnostics.uploadedBytes), diagnostics.textureBytes / (1024.0 * 1024.0), diagnostics.cpuUpdateMs,
			diagnostics.cpuDrawMs, diagnostics.gpuDrawMs, fps);
		lastDiagnostics = now;
	}
}

void Aoe2RendererImpl::SetupBatch(GpuBatch& batch)
{
	if (batch.vao != 0)
		return;
	glGenVertexArrays(1, &batch.vao);
	glGenBuffers(1, &batch.worldVbo);
	glGenBuffers(1, &batch.visualVbo);
	glBindVertexArray(batch.vao);
	glBindBuffer(GL_ARRAY_BUFFER, quadVbo);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
	glVertexAttribDivisor(0, 0);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, quadEbo);
	glBindBuffer(GL_ARRAY_BUFFER, batch.worldVbo);
	for (GLuint attribute = 1; attribute <= 3; ++attribute) {
		glEnableVertexAttribArray(attribute);
		glVertexAttribPointer(attribute, 4, GL_FLOAT, GL_FALSE, sizeof(WorldInstance),
			reinterpret_cast<void*>(static_cast<std::size_t>(attribute - 1) * sizeof(Float4)));
		glVertexAttribDivisor(attribute, 1);
	}
	glBindBuffer(GL_ARRAY_BUFFER, batch.visualVbo);
	glEnableVertexAttribArray(4);
	glVertexAttribPointer(4, 4, GL_FLOAT, GL_FALSE, sizeof(VisualInstance), reinterpret_cast<void*>(offsetof(VisualInstance, uv)));
	glVertexAttribDivisor(4, 1);
	glEnableVertexAttribArray(5);
	glVertexAttribPointer(5, 4, GL_FLOAT, GL_FALSE, sizeof(VisualInstance), reinterpret_cast<void*>(offsetof(VisualInstance, sizeAndFoot)));
	glVertexAttribDivisor(5, 1);
	glEnableVertexAttribArray(6);
	glVertexAttribIPointer(6, 2, GL_UNSIGNED_INT, sizeof(VisualInstance), reinterpret_cast<void*>(offsetof(VisualInstance, tintRgba8)));
	glVertexAttribDivisor(6, 1);
	glBindVertexArray(0);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
}

void Aoe2RendererImpl::UploadBatch(GpuBatch& batch)
{
	if (batch.world.empty())
		return;
	SetupBatch(batch);
	const bool grow = batch.world.size() > batch.capacity;
	if (grow)
		batch.capacity = NextCapacity(batch.world.size());

	const auto uploadStream = [this, grow, capacity = batch.capacity]<typename T>(
		GLuint vbo,
		const std::vector<T>& current,
		std::vector<T>& uploaded
	) {
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		if (grow)
			glBufferData(GL_ARRAY_BUFFER, capacity * sizeof(T), nullptr, GL_DYNAMIC_DRAW);

		bool fullUpload = grow || uploaded.size() != current.size();
		std::array<std::pair<std::size_t, std::size_t>, 9> dirtyRanges{};
		std::size_t rangeCount = 0;
		std::size_t dirtyCount = 0;
		if (!fullUpload) {
			std::size_t index = 0;
			while (index < current.size()) {
				if (std::memcmp(&current[index], &uploaded[index], sizeof(T)) == 0) {
					++index;
					continue;
				}
				const std::size_t first = index;
				while (index < current.size() && std::memcmp(&current[index], &uploaded[index], sizeof(T)) != 0)
					++index;
				dirtyCount += index - first;
				if (rangeCount < dirtyRanges.size())
					dirtyRanges[rangeCount] = {first, index - first};
				++rangeCount;
			}
			fullUpload = rangeCount > 8 || dirtyCount * 4 >= current.size() * 3;
		}

		if (fullUpload && !current.empty()) {
			const std::size_t bytes = current.size() * sizeof(T);
			glBufferSubData(GL_ARRAY_BUFFER, 0, bytes, current.data());
			diagnostics.uploadedBytes += bytes;
		} else {
			for (std::size_t rangeIndex = 0; rangeIndex < rangeCount; ++rangeIndex) {
				const auto [first, count] = dirtyRanges[rangeIndex];
				const std::size_t bytes = count * sizeof(T);
				glBufferSubData(GL_ARRAY_BUFFER, first * sizeof(T), bytes, current.data() + first);
				diagnostics.uploadedBytes += bytes;
			}
		}
		if (fullUpload || dirtyCount != 0)
			uploaded = current;
	};

	uploadStream(batch.worldVbo, batch.world, batch.uploadedWorld);
	uploadStream(batch.visualVbo, batch.visual, batch.uploadedVisual);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
}

void Aoe2RendererImpl::DrawBatch(const Animation& animation, GpuBatch& batch, bool shadow)
{
	if (batch.world.empty())
		return;
	UploadBatch(batch);
	auto* shader = shadow ? shadowShader : mainShader;
	auto token = shader->EnableScoped();
	shader->SetUniformMatrix4x4("uViewProj", false, camera->GetViewProjectionMatrix().m);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, shadow ? animation.shadow.texture : animation.main.texture);
	if (!shadow) {
		glActiveTexture(GL_TEXTURE1);
		glBindTexture(GL_TEXTURE_2D, animation.playerColor.texture);
		glActiveTexture(GL_TEXTURE0);
	}
	glBindVertexArray(batch.vao);
	glDrawElementsInstanced(GL_TRIANGLES, 6, GL_UNSIGNED_INT, nullptr, static_cast<GLsizei>(batch.world.size()));
	glBindVertexArray(0);
	++diagnostics.drawCalls;
	++diagnostics.batches;
}

void Aoe2RendererImpl::PollGpuQueries()
{
	if (gpuQueries[0] == 0)
		glGenQueries(static_cast<GLsizei>(gpuQueries.size()), gpuQueries.data());
	for (std::size_t i = 0; i < gpuQueries.size(); ++i) {
		if (!gpuQueryPending[i])
			continue;
		GLint available = GL_FALSE;
		glGetQueryObjectiv(gpuQueries[i], GL_QUERY_RESULT_AVAILABLE, &available);
		if (available == GL_TRUE) {
			GLuint64 nanoseconds = 0;
			glGetQueryObjectui64v(gpuQueries[i], GL_QUERY_RESULT, &nanoseconds);
			diagnostics.gpuDrawMs = static_cast<double>(nanoseconds) / 1000000.0;
			gpuQueryPending[i] = false;
		}
	}
}

int Aoe2RendererImpl::BeginGpuQuery()
{
	PollGpuQueries();
	for (std::size_t offset = 0; offset < gpuQueries.size(); ++offset) {
		const std::size_t slot = (gpuQueryWrite + offset) % gpuQueries.size();
		if (gpuQueryPending[slot])
			continue;
		glBeginQuery(GL_TIME_ELAPSED, gpuQueries[slot]);
		gpuQueryWrite = (slot + 1) % gpuQueries.size();
		return static_cast<int>(slot);
	}
	return -1;
}

void Aoe2RendererImpl::EndGpuQuery(int slot)
{
	if (slot < 0)
		return;
	glEndQuery(GL_TIME_ELAPSED);
	gpuQueryPending[slot] = true;
}

void Aoe2RendererImpl::Draw()
{
	const auto started = std::chrono::steady_clock::now();
	diagnostics.drawCalls = 0;
	diagnostics.batches = 0;
	diagnostics.uploadedBytes = 0;
	const int querySlot = diagnosticsEnabled ? BeginGpuQuery() : -1;

	const GLboolean blendWasEnabled = glIsEnabled(GL_BLEND);
	const GLboolean depthWasEnabled = glIsEnabled(GL_DEPTH_TEST);
	const GLboolean cullWasEnabled = glIsEnabled(GL_CULL_FACE);
	GLboolean oldDepthMask = GL_TRUE;
	GLint oldDepthFunc = GL_LESS;
	GLint oldBlendSrc = GL_ONE;
	GLint oldBlendDst = GL_ZERO;
	GLint oldBlendSrcAlpha = GL_ONE;
	GLint oldBlendDstAlpha = GL_ZERO;
	GLint oldBlendEquationRgb = GL_FUNC_ADD;
	GLint oldBlendEquationAlpha = GL_FUNC_ADD;
	GLint oldActiveTexture = GL_TEXTURE0;
	GLint oldProgram = 0;
	GLint oldVao = 0;
	GLint oldTexture0 = 0;
	GLint oldTexture1 = 0;
	GLint oldTexture2 = 0;
	glGetBooleanv(GL_DEPTH_WRITEMASK, &oldDepthMask);
	glGetIntegerv(GL_DEPTH_FUNC, &oldDepthFunc);
	glGetIntegerv(GL_BLEND_SRC_RGB, &oldBlendSrc);
	glGetIntegerv(GL_BLEND_DST_RGB, &oldBlendDst);
	glGetIntegerv(GL_BLEND_SRC_ALPHA, &oldBlendSrcAlpha);
	glGetIntegerv(GL_BLEND_DST_ALPHA, &oldBlendDstAlpha);
	glGetIntegerv(GL_BLEND_EQUATION_RGB, &oldBlendEquationRgb);
	glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &oldBlendEquationAlpha);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &oldActiveTexture);
	glGetIntegerv(GL_CURRENT_PROGRAM, &oldProgram);
	glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &oldVao);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTexture0);
	glActiveTexture(GL_TEXTURE1);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTexture1);
	glActiveTexture(GL_TEXTURE2);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTexture2);
	glBindTexture(GL_TEXTURE_2D, playerColorPaletteTexture);
	glActiveTexture(GL_TEXTURE0);

	glEnable(GL_BLEND);
	glEnable(GL_DEPTH_TEST);
	glDisable(GL_CULL_FACE);
	glDepthFunc(GL_LEQUAL);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glDepthMask(GL_FALSE);
	for (auto& appearancePtr : appearances) {
		if (appearancePtr == nullptr) continue;
		for (auto& animation : appearancePtr->animations)
			DrawBatch(animation, animation.shadowBatch, true);
	}

	glDepthMask(GL_TRUE);
	for (auto& appearancePtr : appearances) {
		if (appearancePtr == nullptr) continue;
		for (auto& animation : appearancePtr->animations)
			DrawBatch(animation, animation.mainBatch, false);
	}

	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, oldTexture2);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, oldTexture1);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, oldTexture0);
	glActiveTexture(oldActiveTexture);
	glUseProgram(oldProgram);
	glBindVertexArray(oldVao);
	glDepthMask(oldDepthMask);
	glDepthFunc(oldDepthFunc);
	glBlendFuncSeparate(oldBlendSrc, oldBlendDst, oldBlendSrcAlpha, oldBlendDstAlpha);
	glBlendEquationSeparate(oldBlendEquationRgb, oldBlendEquationAlpha);
	if (!blendWasEnabled) glDisable(GL_BLEND);
	if (!depthWasEnabled) glDisable(GL_DEPTH_TEST);
	if (cullWasEnabled) glEnable(GL_CULL_FACE);
	EndGpuQuery(querySlot);
	diagnostics.cpuDrawMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
}

} // namespace

void CAoe2UnitRenderer::InitStatic()
{
#ifndef HEADLESS
	if (!configHandler->GetBool("Aoe2UnitRendering") || renderer != nullptr)
		return;
	auto candidate = std::make_unique<Aoe2RendererImpl>();
	if (candidate->Init())
		renderer = std::move(candidate);
	else
		candidate->Kill();
#endif
}

void CAoe2UnitRenderer::KillStatic()
{
#ifndef HEADLESS
	if (renderer != nullptr)
		renderer->Kill();
	renderer.reset();
#endif
}

void CAoe2UnitRenderer::UpdateStatic()
{
#ifndef HEADLESS
	if (renderer != nullptr)
		renderer->Update();
#endif
}

void CAoe2UnitRenderer::DrawStatic()
{
#ifndef HEADLESS
	if (renderer != nullptr)
		renderer->Draw();
#endif
}

bool CAoe2UnitRenderer::IsAvailable()
{
	return renderer != nullptr;
}

Aoe2AppearanceHandle CAoe2UnitRenderer::PreloadAppearance(const std::string& unitId)
{
	return (renderer != nullptr) ? renderer->Preload(unitId) : Aoe2AppearanceHandle{};
}

Aoe2AppearanceHandle CAoe2UnitRenderer::PreloadGraphicsAppearance(const std::string& graphicsId)
{
	return (renderer != nullptr) ? renderer->PreloadGraphics(graphicsId) : Aoe2AppearanceHandle{};
}

bool CAoe2UnitRenderer::GetAnimationInfo(
	Aoe2AppearanceHandle appearance,
	Aoe2UnitAnimationSlot animationSlot,
	Aoe2UnitAnimationInfo& info
)
{
	if (renderer == nullptr || !appearance || appearance.index >= renderer->appearances.size())
		return false;
	const auto& appearancePtr = renderer->appearances[appearance.index];
	const std::size_t index = AnimationIndex(animationSlot);
	if (appearancePtr == nullptr || appearancePtr->generation != appearance.generation ||
		index >= appearancePtr->animations.size() || !appearancePtr->loaded[index])
		return false;

	const auto& animation = appearancePtr->animations[index];
	info.fps = animation.fps;
	info.frameCount = static_cast<std::uint32_t>(animation.framesPerDirection);
	info.durationSeconds = animation.framesPerDirection / animation.fps;
	info.loop = AnimationLoops(animationSlot);
	info.releaseTimeSeconds = (animationSlot == Aoe2UnitAnimationSlot::AttackA)
		? std::clamp(appearancePtr->attackReleaseFrame / animation.fps, 0.0f, info.durationSeconds)
		: 0.0f;
	return true;
}

Aoe2InstanceHandle CAoe2UnitRenderer::CreateInstance(const Aoe2UnitInstanceDesc& desc)
{
	return (renderer != nullptr) ? renderer->Create(desc) : Aoe2InstanceHandle{};
}

bool CAoe2UnitRenderer::DestroyInstance(Aoe2InstanceHandle handle)
{
	return renderer != nullptr && renderer->Destroy(handle);
}

bool CAoe2UnitRenderer::SetTransform(Aoe2InstanceHandle handle, const float3& position, float headingRadians, float scale)
{
	auto* instance = (renderer != nullptr) ? renderer->Get(handle) : nullptr;
	if (instance == nullptr) return false;
	instance->position = position;
	instance->heading = headingRadians;
	instance->scale = std::max(0.01f, scale);
	return true;
}

bool CAoe2UnitRenderer::SetAnimation(Aoe2InstanceHandle handle, Aoe2UnitAnimationSlot animation, float playbackTime, float playbackSpeed)
{
	auto* instance = (renderer != nullptr) ? renderer->Get(handle) : nullptr;
	if (instance == nullptr || AnimationIndex(animation) > AnimationIndex(Aoe2UnitAnimationSlot::DeathA)) return false;
	instance->animation = animation;
	instance->animationTime = std::max(0.0f, playbackTime);
	instance->playbackSpeed = playbackSpeed;
	return true;
}

bool CAoe2UnitRenderer::SetPlayerColor(Aoe2InstanceHandle handle, std::uint8_t playerColor)
{
	auto* instance = (renderer != nullptr) ? renderer->Get(handle) : nullptr;
	if (instance == nullptr) return false;
	instance->playerColor = std::clamp<std::uint8_t>(playerColor, 1, 8);
	return true;
}

bool CAoe2UnitRenderer::SetTint(Aoe2InstanceHandle handle, std::uint32_t tintRgba8)
{
	auto* instance = (renderer != nullptr) ? renderer->Get(handle) : nullptr;
	if (instance == nullptr) return false;
	instance->tintRgba8 = tintRgba8;
	return true;
}

bool CAoe2UnitRenderer::SetVisible(Aoe2InstanceHandle handle, bool visible)
{
	auto* instance = (renderer != nullptr) ? renderer->Get(handle) : nullptr;
	if (instance == nullptr) return false;
	instance->visible = visible;
	return true;
}

Aoe2UnitRenderDiagnostics CAoe2UnitRenderer::GetDiagnostics()
{
	return (renderer != nullptr) ? renderer->diagnostics : Aoe2UnitRenderDiagnostics{};
}
