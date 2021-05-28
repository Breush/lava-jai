#version 450
#extension GL_ARB_separate_shader_objects : enable

// @fixme Currently to be compiled with:
// glslc --target-env=vulkan1.2 phong.frag -o phong.frag.spv && glslc --target-env=vulkan1.2 phong.vert -o phong.vert.spv

// @todo Allow better include names.
#include "../../modules/Magma/data/shaders/eye.set"
#include "../../modules/Magma/data/shaders/mesh.set"

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec3 outNormal;
layout(location = 2) out float outDepth;

void main() {
    setupEye();
    setupMesh();

    vec4 position = mesh.matrix * vec4(inVertexPosition, 1);
    outPosition = position.xyz;
    gl_Position = eye.projectionMatrix * eye.viewMatrix * position;

    outNormal = inVertexNormal;
    outDepth = gl_Position.z / gl_Position.w;
}
