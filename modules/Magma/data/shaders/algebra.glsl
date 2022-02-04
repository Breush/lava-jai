
mat3 makeRotationMatrix(float angle, vec3 axis) {
    float c = cos(angle);
    float s = sin(angle);
    float t = 1.0 - c;
    vec3 tAxis = normalize(axis);
    return mat3(
        tAxis.x * tAxis.x * t + c,
        tAxis.x * tAxis.y * t - tAxis.z * s,
        tAxis.x * tAxis.z * t + tAxis.y * s,
        tAxis.x * tAxis.y * t + tAxis.z * s,
        tAxis.y * tAxis.y * t + c,
        tAxis.y * tAxis.z * t - tAxis.x * s,
        tAxis.x * tAxis.z * t - tAxis.y * s,
        tAxis.y * tAxis.z * t + tAxis.x * s,
        tAxis.z * tAxis.z * t + c
    );
}

mat3 reorientZOrientedDirectionMatrix(vec3 targetDirection) {
    if (targetDirection.x == 0 && targetDirection.y == 0 && targetDirection.z == 1) {
        return mat3(1, 0, 0, 0, 1, 0, 0, 0, 1);
    } else if (targetDirection.x == 0 && targetDirection.y == 0 && targetDirection.z == -1) {
        return mat3(1, 0, 0, 0, 1, 0, 0, 0, -1);
    }

    float angle = acos(dot(targetDirection, vec3(0, 0, 1)));
    vec3 axis = cross(targetDirection, vec3(0, 0, 1));
    return makeRotationMatrix(angle, axis);
}
