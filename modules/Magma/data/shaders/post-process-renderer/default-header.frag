layout(location = 0) in vec2 uv;

layout(location = 0) out vec4 outColor;

#define SOURCE_DESCRIPTOR_SET_INDEX 0
#define MATERIAL_DESCRIPTOR_SET_INDEX 1

layout(set = SOURCE_DESCRIPTOR_SET_INDEX, binding = 0) uniform sampler2D source;
