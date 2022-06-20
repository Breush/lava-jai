Ray :: struct {
    origin : vec3;
    direction : vec3; // Always normalized.
}

PickPrecision :: enum {
    Collider;           // Fast.
    MeshBoundingSphere; // Fast but imprecise.
    MeshFirstHit;       // Slow but somewhat precise.
    MeshClosestHit;     // Very slow but precise.
}

// Outputs the parametrization of the intersection of the ray with the triangle.
// Returns 0.0 when not intersecting.
// @note We're using algorithm from Real-Time Rendering Fourth Edition - page 965,
// which projects the ray into the barycentric coordinates system of the triangle to test.
ray_intersect_triangle :: inline (ray : Ray, p0 : vec3, p1 : vec3, p2 : vec3) -> float {
    e01 := p1 - p0;
    e02 := p2 - p0;

    // Ignore triangles with opposite normals
    c := Math.cross(e01, e02);
    if (Math.dot(c, ray.direction) > 0.0) return 0.0;

    // Ray might be parallel to triangle
    q := Math.cross(ray.direction, e02);
    a := Math.dot(e01, q);
    if (a > -0.0001 && a < 0.0001) return 0.0;

    f := 1.0 / a;
    s := ray.origin - p0;
    u := f * Math.dot(s, q);
    if (u < 0.0) return 0.0;

    r := Math.cross(s, e01);
    v := f * Math.dot(ray.direction, r);
    if (v < 0.0 || u + v > 1.0) return 0.0;

    t := f * Math.dot(e02, r);
    if (t < 0.0) return 0.0;

    return t;
}

// Outputs the parametrization of the intersection of the ray with the sphere.
// Returns 0.0 when not intersecting.
ray_intersect_sphere :: inline (ray : Ray, sphere : Sphere) -> float {
    originToCenter := sphere.center - ray.origin;
    originDistanceToCenter := Math.length(originToCenter);
    tCenter := Math.dot(ray.direction, originToCenter);

    factor := 1.0;
    if originDistanceToCenter <= sphere.radius {
        // Special case: origin is inside the sphere, we're sure to intersect!
        factor = -1.0;
    }
    else if tCenter <= 0.0 {
        // Origin is outside the sphere,
        // therefore we cannot intersect if we are looking in opposite direction of the center.
        return 0.0;
    }

    centerProjection := ray.origin + ray.direction * tCenter;
    centerDistanceToProjection := Math.length(sphere.center - centerProjection);
    if centerDistanceToProjection > sphere.radius then return 0.0;

    return tCenter + factor * Math.sqrt(sphere.radius * sphere.radius - centerDistanceToProjection * centerDistanceToProjection);
}

// Outputs the parametrization of the intersection of the ray with the axis-aligned box.
// Returns 0.0 when not intersecting.
ray_intersect_aab :: inline (ray : Ray, boxCenter : $T1/interface vec3Interface, boxExtent : $T2/interface vec3Interface) -> float {
    tMin := -50000.0;
    tMax :=  50000.0;

    t0 := (boxCenter.x - boxExtent.x / 2.0 - ray.origin.x) / ray.direction.x;
    t1 := (boxCenter.x + boxExtent.x / 2.0 - ray.origin.x) / ray.direction.x;
    if t0 > t1 then t0, t1 = t1, t0;
    tMin = Basic.max(tMin, t0);
    tMax = Basic.min(tMax, t1);
    if tMin > tMax then return 0.0;

    t0 = (boxCenter.y - boxExtent.y / 2.0 - ray.origin.y) / ray.direction.y;
    t1 = (boxCenter.y + boxExtent.y / 2.0 - ray.origin.y) / ray.direction.y;
    if t0 > t1 then t0, t1 = t1, t0;
    tMin = Basic.max(tMin, t0);
    tMax = Basic.min(tMax, t1);
    if tMin > tMax then return 0.0;

    t0 = (boxCenter.z - boxExtent.z / 2.0 - ray.origin.z) / ray.direction.z;
    t1 = (boxCenter.z + boxExtent.z / 2.0 - ray.origin.z) / ray.direction.z;
    if t0 > t1 then t0, t1 = t1, t0;
    tMin = Basic.max(tMin, t0);
    tMax = Basic.min(tMax, t1);
    if tMin > tMax then return 0.0;

    if tMin <= 0.0 then return 0.0;
    return tMin;
}
