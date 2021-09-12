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
    // Nothing to do
    if iMesh._nodesTransformsDirty {
        iMesh._nodesTransformsDirty = false;
        matrix := Chamber.make_mat3x4(iMesh.transform.worldTransform);
        for *node : iMesh.nodes {
            if node.parent == -1 {
                _update_node_transforms(iMesh.nodes, node, matrix);
            }
        }
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

mesh_commit_nodes :: (iMesh : *MeshComponent) {
    iMesh._nodesTransformsDirty = true;
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
        return Basic.sprint("Chamber.trs.{.%, .%, .%};", transform.translation, transform.rotation, transform.scaling);
    }();
    iMesh.nodes[iRootNodeIndex].transform = glbFixTransform;
    iMesh.nodes[iRootNodeIndex].parent = -1;

    mesh_commit_nodes(iMesh);

    return true;
}

#scope_file

_update_node_transforms :: (nodes : []MeshNode, node : *MeshNode, parentMatrix : Chamber.mat3x4) {
    node._matrix = Chamber.make_mat3x4(node.transform);
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

    Basic.array_resize(*iMesh.nodes, iMesh.nodes.count + 1);

    // Node transform
    iNodeIndex := iMesh.nodes.count - 1;
    iMesh.nodes[iNodeIndex].transform = Chamber.glb_get_transform(node);
    iMesh.nodes[iNodeIndex].parent = iParentNodeIndex;

    // Load geometry if any
    if nodeMesh.type == .NUMBER {
        meshIndex := cast(u64) nodeMesh.number;
        _glb_load_mesh(iMesh, meshIndex, glb, cache);
    }

    if children.type == .ARRAY {
        for child : children.array {
            iChildNodeIndex := _glb_load_node(iMesh, cast(u64) child.number, glb, cache, iNodeIndex);
            if iChildNodeIndex != -1 {
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
            Chamber.debug("Unsupported GLB indices component type.");
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

    material := glb.json["materials"][materialIndex];

    iShader := Magma.renderer_find_shader(iMesh.entity.engine.renderer, "roughness-metallic");
    if iShader == null {
        iShader = Magma.create_shader(iMesh.entity.engine.renderer, "roughness-metallic");
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
        _glb_set_texture(iMaterial, "albedoMap", pbrMetallicRoughness["baseColorTexture"], glb, cache);
        _glb_set_texture(iMaterial, "roughnessMetallicMap", pbrMetallicRoughness["metallicRoughnessTexture"], glb, cache);
    }

    iPrimitive.material = iMaterial;
    table_add(*cache.material, materialIndex, iMaterial);
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
