#include "$/eye.set"
#include "$/mesh.set"

layout(location = 0) out vec3 outLocalPosition;
layout(location = 1) out vec4 outPosition; // w component is eye-depth
layout(location = 2) out vec2 outUv;
layout(location = 3) out vec3 outNormal;
layout(location = 4) out mat3 outTbn;

void main() {
    setupEye();
    setupMesh();

    outLocalPosition = inVertexPosition;
    vec4 position = mesh.matrix * vec4(inVertexPosition, 1);
    gl_Position = eye.projectionMatrix * eye.viewMatrix * position;

    vec3 n = normalize(inVertexNormal);
    vec3 t = normalize(inVertexTangent.xyz);
    t = normalize(t - n * dot(n, t)); // Orthogonalization
    vec3 b = normalize(cross(n, t) * inVertexTangent.w);

    outPosition.xyz = position.xyz;
    outTbn = mat3(mesh.matrix) * mat3(t, b, n);

    // @todo :NonUniformScaling There is currently a bug with non-uniform scaling,
    // as this will change the normal in an unexpected way.
    // We should probably send TRS independently to the push_constants,
    // and use the rotation matrix directly.
    outTbn[0] = normalize(outTbn[0]);
    outTbn[1] = normalize(outTbn[1]);
    outTbn[2] = normalize(outTbn[2]);

    outUv = inVertexUv;
    outNormal = inVertexNormal;
    outPosition.w = gl_Position.z / gl_Position.w;
}
