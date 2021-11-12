#include "../eye.set"

layout(location = 0) in vec4 position; // w component is eye-depth
layout(location = 1) in vec2 uv;
layout(location = 2) in mat3 tbn;

layout(location = 0) out vec4 outColor;

#define MATERIAL_DESCRIPTOR_SET_INDEX 0
