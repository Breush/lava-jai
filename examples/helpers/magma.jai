Chamber :: #import "Chamber";
Magma :: #import "Magma";

magma_helper_make_cube :: (scene : *Magma.Scene, sideLength : float) -> *Magma.Mesh {
    mesh := Magma.create_mesh(scene);

    // Positions
    positions := Chamber.vec3.[
        // Bottom
        .{ 1., -1., -1.},
        .{-1., -1., -1.},
        .{-1.,  1., -1.},
        .{ 1.,  1., -1.},
        // Top
        .{ 1., -1.,  1.},
        .{ 1.,  1.,  1.},
        .{-1.,  1.,  1.},
        .{-1., -1.,  1.},
        // Left
        .{ 1.,  1.,  1.},
        .{ 1.,  1., -1.},
        .{-1.,  1., -1.},
        .{-1.,  1.,  1.},
        // Right
        .{-1., -1.,  1.},
        .{-1., -1., -1.},
        .{ 1., -1., -1.},
        .{ 1., -1.,  1.},
        // Front
        .{ 1., -1.,  1.},
        .{ 1., -1., -1.},
        .{ 1.,  1., -1.},
        .{ 1.,  1.,  1.},
        // Back
        .{-1.,  1.,  1.},
        .{-1.,  1., -1.},
        .{-1., -1., -1.},
        .{-1., -1.,  1.},
    ];
    for *position : positions {
        position.std *= (sideLength / 2.);
    }

    normals := Chamber.vec3.[
        // Bottom
        .{ 0.,  0., -1.},
        .{ 0.,  0., -1.},
        .{ 0.,  0., -1.},
        .{ 0.,  0., -1.},
        // Top
        .{ 0.,  0.,  1.},
        .{ 0.,  0.,  1.},
        .{ 0.,  0.,  1.},
        .{ 0.,  0.,  1.},
        // Left
        .{ 0.,  1.,  0.},
        .{ 0.,  1.,  0.},
        .{ 0.,  1.,  0.},
        .{ 0.,  1.,  0.},
        // Right
        .{ 0., -1.,  0.},
        .{ 0., -1.,  0.},
        .{ 0., -1.,  0.},
        .{ 0., -1.,  0.},
        // Front
        .{ 1.,  0.,  0.},
        .{ 1.,  0.,  0.},
        .{ 1.,  0.,  0.},
        .{ 1.,  0.,  0.},
        // Back
        .{-1.,  0.,  0.},
        .{-1.,  0.,  0.},
        .{-1.,  0.,  0.},
        .{-1.,  0.,  0.},
    ];

    indices := u16.[
        0,  1,  2,  2,  3,  0,
        4,  5,  6,  6,  7,  4,
        8,  9,  10, 10, 11, 8,
        12, 13, 14, 14, 15, 12,
        16, 17, 18, 18, 19, 16,
        20, 21, 22, 22, 23, 20,
    ];

    Basic.array_resize(*mesh.vertices, positions.count);
    for *vertex, i : mesh.vertices {
        vertex.position = positions[i];
        vertex.normal = normals[i];
    }

    Basic.array_resize(*mesh.indices, indices.count);
    memcpy(mesh.indices.data, indices.data, size_of(u16) * indices.count);

    Magma.mesh_commit_vertices(mesh);
    Magma.mesh_commit_indices(mesh);

    return mesh;
}

magma_helper_make_pyramid :: (scene : *Magma.Scene, sideLength : float) -> *Magma.Mesh {
    mesh := Magma.create_mesh(scene);

    // Positions
    positions := Chamber.vec3.[
        // Bottom
        .{ 1., -1., -1.},
        .{-1., -1., -1.},
        .{-1.,  1., -1.},
        .{ 1.,  1., -1.},
        // Left
        .{ 0.,  0.,  1.},
        .{ 1.,  1., -1.},
        .{-1.,  1., -1.},
        // Right
        .{ 0.,  0.,  1.},
        .{-1., -1., -1.},
        .{ 1., -1., -1.},
        // Front
        .{ 0.,  0,  1.},
        .{ 1., -1., -1.},
        .{ 1.,  1., -1.},
        // Back
        .{ 0.,  0.,  1.},
        .{-1.,  1., -1.},
        .{-1., -1., -1.},
    ];
    for *position : positions {
        position.std *= (sideLength / 2.);
    }

    indices := u16.[
        0,  1,  2,  2,  3,  0,
        4,  5,  6,
        7,  8,  9,
        10, 11, 12,
        13, 14, 15,
    ];

    Basic.array_resize(*mesh.vertices, positions.count);
    for *vertex, i : mesh.vertices {
        vertex.position = positions[i];
    }

    Basic.array_resize(*mesh.indices, indices.count);
    memcpy(mesh.indices.data, indices.data, size_of(u16) * indices.count);

    Magma.mesh_compute_flat_normals(mesh);
    Magma.mesh_commit_vertices(mesh);
    Magma.mesh_commit_indices(mesh);

    return mesh;
}

#scope_file

#import "Math";
