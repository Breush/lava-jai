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

    vertices : [..]VertexInput;
    indices : [..]u16;
    instance : InstanceInput;

    verticesDirty : bool;
    indicesDirty : bool;
    instanceDirty : bool;

    using transform : Chamber.trs;

    using meshImpl : MeshImpl;

    allocator : Allocator;
    allocator_data : *void;
}

VertexInput :: struct {
    position : Chamber.vec3;
    normal : Chamber.vec3;
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

destroy_mesh :: (mesh : *Mesh) {
    mesh_cleanup(mesh, resetMemory = false);

    if mesh.allocator != null {
        Basic.free(mesh, mesh.allocator, mesh.allocator_data);
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
        <<mesh = Mesh.{};
    }
}

// Called by scene_update.
mesh_update :: (mesh : *Mesh) {
    impl_mesh_update(mesh);

    mesh.verticesDirty = false;
    mesh.indicesDirty = false;
    mesh.instanceDirty = false;
}

mesh_commit_vertices :: (mesh : *Mesh) {
    mesh.verticesDirty = true;
}

mesh_commit_indices :: (mesh : *Mesh) {
    mesh.indicesDirty = true;
}

mesh_commit_instance :: (mesh : *Mesh, $copyTrs := true) {
    #if copyTrs {
        mesh.instance.matrix = Chamber.make_mat3x4(mesh.transform);
    } else {
        mesh.transform = Chamber.make_trs(mesh.instance.matrix);
    }

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
        v0.normal.std = normalize(cross(v1.position.std - v2.position.std, v1.position.std - v0.position.std));
        v1.normal = v0.normal;
        v2.normal = v0.normal;

        i += 3;
    }
}

mesh_translate :: (mesh : *Mesh, delta : Chamber.vec3) {
    mesh.translation.std += delta;

    mesh_commit_instance(mesh);
}

#scope_file

#import "Math"; // For operators
