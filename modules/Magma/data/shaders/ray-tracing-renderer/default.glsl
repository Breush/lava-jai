#version 460
#extension GL_EXT_ray_tracing : require

struct hitPayload {
    vec3 hitValue;
};

// ------------------
// ----- RAYGEN -----

#if defined(RAYGEN)

#include "../eye.set"

layout(location = 0) rayPayloadEXT hitPayload prd;

layout(set = 0, binding = 0, rgba8) uniform image2D outputImage;
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

    prd.hitValue = vec3(0, 0, 0);

    traceRayEXT(topLevelAS, gl_RayFlagsOpaqueEXT, 0xFF /* cullMask */,
                0 /* sbtRecordOffset */, 0 /* sbtRecordStride */,
                0 /* miss index */,
                origin.xyz,     tMin,
                direction.xyz,  tMax,
                0 /* payload location */
    );

    imageStore(outputImage, ivec2(gl_LaunchIDEXT.xy), vec4(prd.hitValue, 1.0));
}

// -----------------------
// ----- CLOSEST_HIT -----

#elif defined(CLOSEST_HIT)

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
    const vec3 worldNrm = normalize(vec3(nrm * gl_WorldToObjectEXT));

    // @todo Of course, get light from descriptor.
    vec3 lightDirection = vec3(0.5, 0.5, 0.5);
    float dotNL = max(dot(worldNrm, lightDirection), 0.0);

    prd.hitValue = vec3(dotNL);
}

// ----------------
// ----- MISS -----

#elif defined(MISS)

layout(location = 0) rayPayloadInEXT hitPayload prd;

void main()
{
    prd.hitValue = vec3(0.0, 0.1, 0.3);
}

#endif