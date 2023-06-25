#scope_module

/*
    An index-based mesh.

    Once created, one can modify the vertices and indices
    arrays. Then, one should call mesh_commit_vertices()
    and mesh_commit_indices() so that the data is transfered
    to the graphic card.
*/
Mesh :: struct {
    scene : *Scene;

    disabled : MeshDisabledFlags;

    vertices : [..]VertexInput;
    indices : [..]u16;
    instance : InstanceInput;
    material : *Material;

    verticesDirty : bool;
    indicesDirty : bool;
    instanceDirty : bool;

    geometryAabb : Chamber.AxisAlignedBox; // The axis-aligned bounding box if transform is identity.
    boundingSphere : Chamber.Sphere; // The world-space bounding sphere.

    using transform : Chamber.trs;

    using meshImpl : MeshImpl;

    allocator : Allocator;
}

MeshDisabledFlags :: enum_flags u8 {
    None            :: 0x0;
    User            :: 0x1;
    Application     :: 0x2;
    Internal        :: 0x4; // Reserved, unused.
    GameEngine      :: 0x8; // Used in Sill.
}

VertexInput :: struct {
    position : Chamber.vec3;
    normal : Chamber.vec3;
    tangent : Chamber.vec4;
    uv : Chamber.vec2;
}

InstanceInput :: struct {
    matrix : Chamber.mat3x4;
}

// Allocate, init and register a new mesh.
create_mesh :: (scene : *Scene) -> *Mesh {
    mesh := cast(*Mesh) Basic.New(Mesh);
    Basic.remember_allocators(mesh);
    mesh_init(mesh, scene);
    scene_register(scene, mesh);
    return mesh;
}

destroy_mesh :: (mesh : *Mesh, unregister := true) {
    mesh_cleanup(mesh, resetMemory = false);

    if unregister {
        scene_unregister(mesh.scene, mesh);
    }

    if mesh.allocator.proc != null {
        Basic.free(mesh, mesh.allocator);
    }
}

mesh_init :: (mesh : *Mesh, scene : *Scene) {
    mesh.scene = scene;
    impl_mesh_init(mesh);
    mesh_commit_instance(mesh);
}

mesh_cleanup :: (mesh : *Mesh, resetMemory := true) {
    impl_mesh_cleanup(mesh);

    Basic.array_free(mesh.vertices);
    Basic.array_free(mesh.indices);

    if resetMemory {
        mesh.* = .{};
    }
}

// Called by scene_update.
mesh_update :: (mesh : *Mesh) {
    if mesh.disabled then return;

    impl_mesh_update(mesh);
}

mesh_commit_vertices :: (mesh : *Mesh) {
    _update_geometry_aabb(mesh);
    _update_bounding_sphere(mesh);
    mesh.verticesDirty = true;
}

mesh_commit_indices :: (mesh : *Mesh) {
    mesh.indicesDirty = true;
}

mesh_commit_instance :: (mesh : *Mesh, $copyTrs := true) {
    #if copyTrs {
        mesh.instance.matrix = Chamber.make_matrix(mesh.transform);
    } else {
        meshTransform := Chamber.make_trs(mesh.instance.matrix);
        if memcmp(*meshTransform, *mesh.transform, size_of(Chamber.trs)) == 0 then return;
        mesh.transform = meshTransform;
    }

    _update_bounding_sphere(mesh);
    mesh.instanceDirty = true;
}

mesh_compute_flat_normals :: (mesh : *Mesh) {
    i := 0;
    while i < mesh.indices.count {
        i0 := mesh.indices[i];
        i1 := mesh.indices[i + 1];
        i2 := mesh.indices[i + 2];
        v0 := *mesh.vertices[i0];
        v1 := mesh.vertices[i1];
        v2 := mesh.vertices[i2];
        v0.normal.std = normalize(cross(v1.position - v2.position, v1.position - v0.position));
        v1.normal = v0.normal;
        v2.normal = v0.normal;

        i += 3;
    }
}

mesh_translate :: (mesh : *Mesh, delta : Chamber.vec3) {
    mesh.translation.std += delta;

    mesh_commit_instance(mesh);
}

// Returns 0 if the mesh is not intersected.
mesh_distance_from :: (mesh : *Mesh, ray : Chamber.Ray, pickPrecision : Chamber.PickPrecision) -> float {
    if mesh.disabled then return 0.0;
    if pickPrecision != .MeshBoundingSphere &&
       pickPrecision != .MeshFirstHit &&
       pickPrecision != .MeshClosestHit {
        return 0.0;
    }

    distance := Chamber.ray_intersect_sphere(ray, mesh.boundingSphere);
    if distance == 0.0 then return 0.0;
    if pickPrecision == .MeshBoundingSphere then return distance;

    // Reset because we're not sure of hitting geometry.
    distance = 0.0;

    i := 0;
    while i < mesh.indices.count {
        p0 := Chamber.multiply(mesh.transform, mesh.vertices[mesh.indices[i + 0]].position);
        p1 := Chamber.multiply(mesh.transform, mesh.vertices[mesh.indices[i + 1]].position);
        p2 := Chamber.multiply(mesh.transform, mesh.vertices[mesh.indices[i + 2]].position);

        t := Chamber.ray_intersect_triangle(ray, p0, p1, p2);
        if t > 0.0 && (distance == 0.0 || t < distance) {
            distance = t;
            if pickPrecision == .MeshFirstHit then break;
        }

        i += 3;
    }

    return distance;
}

#scope_file

_update_geometry_aabb :: (mesh : *Mesh) {
    if mesh.vertices.count == 0 {
        mesh.geometryAabb.center = .{};
        mesh.geometryAabb.extent = .{};
        return;
    }

    minRange := mesh.vertices[0].position;
    maxRange := minRange;
    for *vertex : mesh.vertices {
        if vertex.position.x > maxRange.x then maxRange.x = vertex.position.x;
        if vertex.position.x < minRange.x then minRange.x = vertex.position.x;
        if vertex.position.y > maxRange.y then maxRange.y = vertex.position.y;
        if vertex.position.y < minRange.y then minRange.y = vertex.position.y;
        if vertex.position.z > maxRange.z then maxRange.z = vertex.position.z;
        if vertex.position.z < minRange.z then minRange.z = vertex.position.z;
    }
    mesh.geometryAabb.center.std = (minRange + maxRange) / 2.;
    mesh.geometryAabb.extent.std = maxRange - minRange;
}

_update_bounding_sphere :: (mesh : *Mesh) {
    mesh.boundingSphere.center = Chamber.multiply(mesh.transform, mesh.geometryAabb.center);
    mesh.boundingSphere.radius = Math.length((mesh.transform.scaling * mesh.geometryAabb.extent) / 2.);
}
