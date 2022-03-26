MeshNode :: struct {
    primitives : [..]*Magma.Mesh;
    children : [..]s64; // Index based on `MeshComponent.nodes`.
    parent : s64 = -1;  // Negative index means no parent.

    // Local data, in parent space.
    transform : Chamber.trs;
    _matrix : Chamber.mat3x4;
}

MeshComponent :: struct {
    using component : Component;
    transform : *TransformComponent;

    nodes : [..]MeshNode;

    _nodesTransformsDirty : bool;
}

component_init :: (iMesh : *MeshComponent) {
    transform_on_world_transform_changed(iMesh.transform,
                                         xx (iMesh : *MeshComponent) { iMesh._nodesTransformsDirty = true; },
                                         iMesh);
}

component_cleanup :: (iMesh : *MeshComponent, resetMemory := true) {
    for *node : iMesh.nodes {
        // @todo Really improve what cleanup means...
        // Here, for instance, do we need to remove the primitives for the render engine?
        Basic.array_free(node.primitives);
        Basic.array_free(node.children);
    }
    Basic.array_free(iMesh.nodes);

    if resetMemory {
        <<iMesh = MeshComponent.{};
    }
}

component_update :: (iMesh : *MeshComponent, dt : float64) {
    if iMesh._nodesTransformsDirty {
        mesh_commit_nodes(iMesh, instantly = true);
    }
}

mesh_debug_print_nodes :: (iMesh : *MeshComponent) {
    Basic.print("(nodes:%)\n", iMesh.nodes.count);
    for *node : iMesh.nodes {
        if node.parent == -1 {
            _debug_print_nodes(iMesh.nodes, node);
        }
    }
}

mesh_commit_nodes :: (iMesh : *MeshComponent, instantly := false) {
    iMesh._nodesTransformsDirty = !instantly;

    if instantly {
        matrix := Chamber.make_matrix(iMesh.transform.worldTransform);
        for *node : iMesh.nodes {
            if node.parent == -1 {
                _update_node_transforms(iMesh.nodes, node, matrix);
            }
        }
    }
}

mesh_make_plane :: (iMesh : *MeshComponent,
                    extent := Chamber.uvec2.{1, 1}) {
    mesh := Magma.create_mesh(iMesh.entity.engine.scene);

    // Positions
    positions := Chamber.vec3.[
        // Bottom
        .{ 1., -1., 0.},
        .{-1., -1., 0.},
        .{-1.,  1., 0.},
        .{ 1.,  1., 0.},
        // Top
        .{ 1., -1., 0.},
        .{ 1.,  1., 0.},
        .{-1.,  1., 0.},
        .{-1., -1., 0.},
    ];
    for *position : positions {
        position.x *= extent.width / 2.;
        position.y *= extent.height / 2.;
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
    ];

    indices := u16.[
        0,  1,  2,  2,  3,  0,
        4,  5,  6,  6,  7,  4,
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

    // Node transform
    iNode := Basic.array_add(*iMesh.nodes);

    Basic.array_add(*iNode.primitives, mesh);
}

mesh_make_cube :: (iMesh : *MeshComponent,
                   extent := Chamber.uvec3.{1, 1, 1}) {
    mesh := Magma.create_mesh(iMesh.entity.engine.scene);

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
        position.x *= extent.x / 2.;
        position.y *= extent.y / 2.;
        position.z *= extent.z / 2.;
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

    // Node transform
    iNode := Basic.array_add(*iMesh.nodes);

    Basic.array_add(*iNode.primitives, mesh);
}

// Returns false on error.
mesh_load_glb :: (iMesh : *MeshComponent, filePath : string) -> bool {
    fileContent, readOk := File.read_entire_file(filePath);
    _CHECK(readOk, "Unable to read GLB file.");
    defer Basic.free(fileContent);

    glb := Chamber.glb_parse(fileContent);
    defer json_free(glb.json);

    cache : Cache;

    rootSceneIndex := cast(u64) glb.json["scene"].number;
    rootScene := glb.json["scenes"][rootSceneIndex];
    rootSceneNodes := rootScene["nodes"];

    // @note We create a root node to apply a transform on the whole object.
    // (In order to fix axes conventions from glTF.)
    Basic.array_resize(*iMesh.nodes, iMesh.nodes.count + 1);
    iRootNodeIndex := iMesh.nodes.count - 1;
    for nodeIndex : rootSceneNodes.array {
        iNodeIndex := _glb_load_node(iMesh, cast(u64) nodeIndex.number, glb, *cache, iRootNodeIndex);
        if iNodeIndex != -1 {
            Basic.array_add(*iMesh.nodes[iRootNodeIndex].children, iNodeIndex);
        }
    }

    uninit(*cache.bufferViewToTexture);
    uninit(*cache.material);

    // Going from glTF right-handed Y up, Z forward,
    // to ours right-handed Z up, X forward.
    // @todo Too bad this does not work...
    // glbFixTransform :: #run Chamber.make_trs(make_matrix_from_columns(.{0, 0, 1}, .{1, 0, 0}, .{0, 1, 0}));
    glbFixTransform :: #insert #run () -> string {
        transform := Chamber.make_trs(make_matrix_from_columns(.{0, 1, 0}, .{0, 0, 1}, .{1, 0, 0}));
        return Basic.sprint("Chamber.trs.{.%, .%, .%};", transform.translation.std, transform.rotation, transform.scaling.std);
    }();
    iMesh.nodes[iRootNodeIndex].transform = glbFixTransform;
    iMesh.nodes[iRootNodeIndex].parent = -1;

    mesh_commit_nodes(iMesh);

    return true;
}

#scope_file

_update_node_transforms :: (nodes : []MeshNode, node : *MeshNode, parentMatrix : Chamber.mat3x4) {
    node._matrix = Chamber.make_matrix(node.transform);
    matrix := parentMatrix * node._matrix;

    for primitive : node.primitives {
        primitive.instance.matrix = matrix;
        Magma.mesh_commit_instance(primitive, false);
    }

    for child : node.children {
        _update_node_transforms(nodes, *nodes[child], matrix);
    }
}

_debug_print_nodes :: (nodes : []MeshNode, node : *MeshNode, indentLevel := 0) {
    for i : 0 .. indentLevel - 1 {
        Basic.print("--");
    }
    Basic.print("> (primitives:%) (children:%) (transform:%)\n", node.primitives.count, node.children.count, node.transform);

    for child : node.children {
        _debug_print_nodes(nodes, *nodes[child], indentLevel + 1);
    }
}

// ----- GLB loading

Cache :: struct {
    bufferViewToTexture : Table(u64, *Magma.Texture);
    material : Table(u64, *Magma.Material);
}

_glb_load_node :: (iMesh : *MeshComponent, nodeIndex : u64, glb : Glb, cache : *Cache, iParentNodeIndex : s64) -> s64 {
    node := glb.json["nodes"][nodeIndex];

    children := node["children"];
    nodeMesh := node["mesh"];

    _CHECK(children.type != .INVALID || nodeMesh.type != .INVALID, -1, "GLB node is empty and has no children. It has been removed.");

    // Node transform
    iNode := Basic.array_add(*iMesh.nodes);
    iNodeIndex := iMesh.nodes.count - 1;
    iNode.transform = Chamber.glb_get_transform(node);
    iNode.parent = iParentNodeIndex;

    // Load geometry if any
    if nodeMesh.type == .NUMBER {
        meshIndex := cast(u64) nodeMesh.number;
        _glb_load_mesh(iMesh, meshIndex, glb, cache);
    }

    if children.type == .ARRAY {
        for child : children.array {
            iChildNodeIndex := _glb_load_node(iMesh, cast(u64) child.number, glb, cache, iNodeIndex);
            if iChildNodeIndex != -1 {
                // @note Can't use iNode here directly as it's pointer might be invalidated
                // by new nodes.
                Basic.array_add(*iMesh.nodes[iNodeIndex].children, iChildNodeIndex);
            }
        }
    }

    return iNodeIndex;
}

_glb_load_mesh :: (iMesh : *MeshComponent, meshIndex : u64, glb : Glb, cache : *Cache) {
    iNode := Basic.peek_pointer(iMesh.nodes);

    mesh := glb.json["meshes"][meshIndex];

    primitives := mesh["primitives"];

    for primitive : primitives.array {
        iPrimitive := Magma.create_mesh(iMesh.entity.engine.scene);
        Basic.array_add(*iNode.primitives, iPrimitive);

        // Extracting primitive attributes from JSON and BIN
        primitiveAttributes := primitive["attributes"];
        positionsAccessorIndex := cast(u64) primitiveAttributes["POSITION"].number;
        positions := glb_get_accessor(glb, positionsAccessorIndex, Chamber.vec3);

        normals : []Chamber.vec3;
        if primitiveAttributes["NORMAL"].type == .NUMBER {
            normalsAccessorIndex := cast(u64) primitiveAttributes["NORMAL"].number;
            normals = glb_get_accessor(glb, normalsAccessorIndex, Chamber.vec3);
        }

        tangents : []Chamber.vec4;
        if primitiveAttributes["TANGENT"].type == .NUMBER {
            tangentsAccessorIndex := cast(u64) primitiveAttributes["TANGENT"].number;
            tangents = glb_get_accessor(glb, tangentsAccessorIndex, Chamber.vec4);
        }

        uvs : []Chamber.vec2;
        if primitiveAttributes["TEXCOORD_0"].type == .NUMBER {
            uvsAccessorIndex := cast(u64) primitiveAttributes["TEXCOORD_0"].number;
            uvs = glb_get_accessor(glb, uvsAccessorIndex, Chamber.vec2);
        }

        if primitive["material"].type != .INVALID {
            materialIndex := cast(u64) primitive["material"].number;
            _glb_set_material(iMesh, iPrimitive, materialIndex, glb, cache);
        }

        indices : []u16;
        indicesAccessorIndex := cast(u64) primitive["indices"].number;
        indicesComponentType := cast(u64) glb.json["accessors"][indicesAccessorIndex]["componentType"].number;
        if indicesComponentType == 5123 {
            indices = glb_get_accessor(glb, indicesAccessorIndex, u16);
        } else {
            Basic.log("Unsupported GLB indices component type.", flags=.ERROR);
            continue;
        }

        // Constructing the primitive mesh itself
        Basic.array_resize(*iPrimitive.vertices, positions.count);
        for *vertex, i : iPrimitive.vertices {
            vertex.position = positions[i];
            if normals.count != 0 {
                vertex.normal = normals[i];
            }
            if tangents.count != 0 {
                vertex.tangent = tangents[i];
            } else {
                // @todo Autocompute tangents if we don't have them.
                vertex.tangent = .{1, 0, 0, 1};
            }
            if uvs.count != 0 {
                vertex.uv = uvs[i];
            }
        }

        if normals.count == 0 {
            Magma.mesh_compute_flat_normals(iPrimitive);
        }

        Basic.array_resize(*iPrimitive.indices, indices.count);
        memcpy(iPrimitive.indices.data, indices.data, size_of(u16) * indices.count);

        Magma.mesh_commit_vertices(iPrimitive);
        Magma.mesh_commit_indices(iPrimitive);
    }
}

_glb_set_material :: (iMesh : *MeshComponent, iPrimitive : *Magma.Mesh, materialIndex : u64, glb : Glb, cache : *Cache) {
    cachedMaterial := table_find_pointer(cache.material, materialIndex);
    if cachedMaterial != null {
        iPrimitive.material = <<cachedMaterial;
        return;
    }

    // @todo Currently not making materials if the renderer is a raytracer.
    if iMesh.entity.engine.renderer.kind == .RayTracingRenderer {
        return;
    }

    material := glb.json["materials"][materialIndex];

    iShader := Magma.renderer_find_shader(iMesh.entity.engine.renderer, "$/forward-renderer/materials/roughness-metallic");
    if iShader == null {
        iShader = Magma.create_shader(iMesh.entity.engine.renderer, "$/forward-renderer/materials/roughness-metallic");
    }

    iMaterial := Magma.create_material(iShader);

    if material["normalTexture"].type != .INVALID {
        _glb_set_texture(iMaterial, "normalMap", material["normalTexture"], glb, cache);
        Magma.material_set(iMaterial, "normalMapEnabled", true);
    }

    _glb_set_texture(iMaterial, "occlusionMap", material["occlusionTexture"], glb, cache);

    if material["emissiveTexture"].type != .INVALID {
        _glb_set_texture(iMaterial, "emissiveMap", material["emissiveTexture"], glb, cache);
        Magma.material_set(iMaterial, "emissiveMapEnabled", true);
    }

    if material["pbrMetallicRoughness"].type != .INVALID {
        pbrMetallicRoughness := material["pbrMetallicRoughness"];
        _glb_set_attribute(iMaterial, "albedo", pbrMetallicRoughness["baseColorFactor"]);
        _glb_set_texture(iMaterial, "albedoMap", pbrMetallicRoughness["baseColorTexture"], glb, cache);
        _glb_set_texture(iMaterial, "roughnessMetallicMap", pbrMetallicRoughness["metallicRoughnessTexture"], glb, cache);

        // @todo Ok, we're just cheating here, the default values should be decided within the shader.
        if pbrMetallicRoughness["baseColorFactor"].type == .INVALID {
            Magma.material_set(iMaterial, "albedo", Chamber.vec4.{1, 1, 1, 1});
        }
    }

    iPrimitive.material = iMaterial;
    table_add(*cache.material, materialIndex, iMaterial);
}

_glb_set_attribute :: (iMaterial : *Magma.Material, uniformName : string, valueRef : JsonValue) {
    if valueRef.type == .INVALID then return;

    if valueRef.type == .ARRAY && valueRef.array.count == 4 {
        color : Chamber.vec4;
        color.r = cast(float32) valueRef.array[0].number;
        color.g = cast(float32) valueRef.array[1].number;
        color.b = cast(float32) valueRef.array[2].number;
        color.a = cast(float32) valueRef.array[3].number;
        Magma.material_set(iMaterial, "albedo", color);
    }
}

_glb_set_texture :: (iMaterial : *Magma.Material, uniformName : string, textureRef : JsonValue, glb : Glb, cache : *Cache) {
    if textureRef.type == .INVALID then return;

    textureIndex := cast(u64) textureRef["index"].number;
    texture := glb.json["textures"][textureIndex];

    imageIndex := cast(u64) texture["source"].number;
    image := glb.json["images"][imageIndex];
    bufferViewIndex := cast(u64) image["bufferView"].number;

    // @todo We could load textures asynchronously using a Thread_Group
    // @todo Engine-wise texture cache (based on pixels hash).
    cachedTexture := table_find_pointer(cache.bufferViewToTexture, bufferViewIndex);
    if cachedTexture != null {
        Magma.material_set(iMaterial, uniformName, <<cachedTexture);
        return;
    }

    bufferView := Chamber.glb_get_buffer_view(glb, bufferViewIndex);

    extent : Chamber.uvec2;
    pixelsRaw := stbi_load_from_memory(bufferView.data, xx bufferView.count, xx *extent.width, xx *extent.height, null, 4);

    pixels : []u8;
    pixels.data = pixelsRaw;
    pixels.count = extent.width * extent.height * 4;

    iTexture := Magma.create_texture(iMaterial.shader.renderer.scene.engine);
    Magma.texture_load_from_memory(iTexture, pixels, extent);
    stbi_image_free(pixelsRaw);

    Magma.material_set(iMaterial, uniformName, iTexture);
    table_add(*cache.bufferViewToTexture, bufferViewIndex, iTexture);
}

#scope_file

#import "Math";
#import "stb_image";
#import "Chamber";
#import "Hash_Table";
