#version 460
#extension GL_EXT_ray_tracing : require

#define AO_RAY_COUNT 1
#define AO_RAY_DISTANCE 0.5
#define AO_STABILIZATION_FRAMES 1000
#define AO_COMPOSITION_POWER 0.95

// @todo Generate the AO in a separate pass and compose it,
// so that it can be filtered dynamically. (And have a different size.)

struct hitPayload {
    vec3 hitValue;
    float aoIntensity;
    bool miss;
};

// ------------------
// ----- RAYGEN -----

#if defined(RAYGEN)

#include "../eye.set"

#include "../debug.glsl"

layout(location = 0) rayPayloadEXT hitPayload prd;

layout(set = 0, binding = 0, rgba8) uniform image2D outputImage;
layout(set = 0, binding = 1, r8) uniform image2D aoImage;
layout(set = 1, binding = 0) uniform accelerationStructureEXT topLevelAS;

void main()
{
    setupEye();

    const vec2 pixelCenter = vec2(gl_LaunchIDEXT.xy) + vec2(0.5);
    const vec2 inUV = pixelCenter/vec2(gl_LaunchSizeEXT.xy);
    vec2 d = inUV * 2.0 - 1.0;

    // @todo Precomputed inverses.
    vec4 origin = inverse(eye.viewMatrix) * vec4(0, 0, 0, 1);
    vec4 target = inverse(eye.projectionMatrix) * vec4(d.x, d.y, 1, 1);
    vec4 direction = inverse(eye.viewMatrix) * vec4(normalize(target.xyz), 0);

    float tMin = 0.001;
    float tMax = 10000.0;

    uint stableFrames = (pushConstant.frame - eye.lastChangeFrame);
    bool aoNeeded = (stableFrames <= AO_STABILIZATION_FRAMES);

    if (aoNeeded) {
        prd.aoIntensity = 0;
    } else {
        stableFrames = AO_STABILIZATION_FRAMES;
        prd.aoIntensity = 1; // Disables AO in ClosestHit shader.
    }

    prd.hitValue = vec3(0, 0, 0);
    traceRayEXT(topLevelAS, gl_RayFlagsOpaqueEXT, 0xFF /* cullMask */,
                0 /* sbtRecordOffset */, 0 /* sbtRecordStride */,
                0 /* miss index */,
                origin.xyz,     tMin,
                direction.xyz,  tMax,
                0 /* payload location */
    );

    if (prd.aoIntensity == 0 && prd.miss) {
        prd.aoIntensity = 1.0;
    }

    float finalAo = imageLoad(aoImage, ivec2(gl_LaunchIDEXT.xy)).r;
    if (aoNeeded) {
        finalAo = (prd.aoIntensity + stableFrames * finalAo) / (stableFrames + 1); // Iterative mean.
        imageStore(aoImage, ivec2(gl_LaunchIDEXT.xy), vec4(finalAo));
    }

    // Debugging the number of stable frames.
    debug_set_screen_and_origin_coords(gl_LaunchIDEXT.xy, vec2(gl_LaunchSizeEXT.x, gl_LaunchSizeEXT.y * 0.98));
    debug_int(stableFrames);

    vec3 aoColor = vec3(mix(1.0, finalAo, AO_COMPOSITION_POWER));
    vec3 debugColor = debug_get_color();
    imageStore(outputImage, ivec2(gl_LaunchIDEXT.xy), vec4(prd.hitValue * aoColor * debugColor, 1.0));
}

// -----------------------
// ----- CLOSEST_HIT -----

#elif defined(CLOSEST_HIT)

#include "../eye.set"
#include "../random.glsl"
#include "../algebra.glsl"

#extension GL_EXT_scalar_block_layout : enable // For vec3 and such to not be extra aligned
#extension GL_EXT_shader_16bit_storage : enable // For u16vec3, used as indices' type

#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require // For working with int16_t, used as indices's type
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require // For uint64_t, used as buffer address
#extension GL_EXT_buffer_reference2 : require

hitAttributeEXT vec2 attribs;

layout(location = 0) rayPayloadInEXT hitPayload prd;

// Type definitions of buffers.
struct Vertex {
    vec3 position;
    vec3 normal;
    vec4 tangent;
    vec2 uv;
};
layout(buffer_reference, scalar) buffer Vertices { Vertex v[]; }; // Positions of an object
layout(buffer_reference, scalar) buffer Indices { u16vec3 i[]; }; // Triangle indices
struct ObjectDescription {
    uint64_t vertexAddress;
    uint64_t indexAddress;
};

layout(set = 1, binding = 0) uniform accelerationStructureEXT topLevelAS;
layout(set = 1, binding = 1, scalar) buffer ObjectDescriptions { ObjectDescription i[]; } objectDescriptions;

void main()
{
    // @note Our custom index is refering to the object description, so instances are invisible to us.
    ObjectDescription objectDescription = objectDescriptions.i[gl_InstanceCustomIndexEXT];
    Indices indices = Indices(objectDescription.indexAddress);
    Vertices vertices = Vertices(objectDescription.vertexAddress);

    uvec3 index = uvec3(indices.i[gl_PrimitiveID]);
    Vertex v0 = vertices.v[index.x];
    Vertex v1 = vertices.v[index.y];
    Vertex v2 = vertices.v[index.z];

    const vec3 barycentrics = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    const vec3 pos = v0.position * barycentrics.x + v1.position * barycentrics.y + v2.position * barycentrics.z;
    const vec3 worldPos = vec3(gl_ObjectToWorldEXT * vec4(pos, 1.0));

    const vec3 nrm = v0.normal * barycentrics.x + v1.normal * barycentrics.y + v2.normal * barycentrics.z;
    const vec3 worldNrm = normalize(gl_ObjectToWorldEXT * vec4(nrm, 0.0));

    // @todo Of course, get light from descriptor.
    vec3 lightDirection = vec3(0.5, 0.5, 0.5);
    float dotNL = max(dot(worldNrm, lightDirection), 0.0);

    vec3 hitValue = max(vec3(0.2), vec3(dotNL));
    prd.hitValue = hitValue;

    // ----- AO

    // Don't compute AO if not needed.
    if (prd.aoIntensity > 0) {
        return;
    }

    mat3 transformToFrameMatrix = reorientZOrientedDirectionMatrix(worldNrm);
    for (int rayIndex = 0; rayIndex < AO_RAY_COUNT; ++rayIndex) {
        float x0 = random(vec4(gl_LaunchIDEXT.xy, pushConstant.frame, AO_RAY_COUNT * rayIndex));
        float x1 = random(vec4(gl_LaunchIDEXT.xy, pushConstant.frame, AO_RAY_COUNT * rayIndex + 1));
        vec3 dir = sampleZOrientedDirection(x0, x1);
        dir = transformToFrameMatrix * dir;

        prd.miss = false;
        traceRayEXT(topLevelAS, gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT, 0xFF /* cullMask */,
                    0 /* sbtRecordOffset */, 0 /* sbtRecordStride */,
                    0 /* miss index */,
                    worldPos.xyz + 0.01 * worldNrm.xyz, 0.01,
                    dir.xyz, AO_RAY_DISTANCE,
                    0 /* payload location */
        );

        prd.aoIntensity += prd.miss ? 1 : 0;
    }

    prd.aoIntensity /= AO_RAY_COUNT;
}

// ----------------
// ----- MISS -----

#elif defined(MISS)

layout(location = 0) rayPayloadInEXT hitPayload prd;

void main()
{
    if ((gl_IncomingRayFlagsEXT & gl_RayFlagsSkipClosestHitShaderEXT) == 0) {
        prd.hitValue = vec3(0.0, 0.1, 0.3);
    }
    prd.miss = true;
}

#endif