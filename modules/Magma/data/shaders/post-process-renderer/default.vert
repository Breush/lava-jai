// Our fullscreen pass uses only one triangle instead of two.
// Idea from Real-Time Rendering - Fourth Edition - page 514.

vec2 positions[3] = vec2[](
    vec2(-1, -1),
    vec2(-1, 3),
    vec2(3, -1)
);

vec2 uvs[3] = vec2[](
    vec2(0, 0),
    vec2(0, 2),
    vec2(2, 0)
);

layout(location = 0) out vec2 outUv;

void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0, 1);
    outUv = uvs[gl_VertexIndex];
}
