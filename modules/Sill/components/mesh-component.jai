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

    nodes : [..]MeshNode;
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
    identity := matrix4x3_identity();

    for *node : iMesh.nodes {
        if node.parent == -1 {
            _update_node_transforms(iMesh.nodes, node, identity);
        }
    }
}

// Returns false on error.
mesh_load_glb :: (iMesh : *MeshComponent, filePath : string) -> bool {
    glbFullContent, readOk := File.read_entire_file(filePath);
    _CHECK(readOk, "Unable to read GLB file.");
    defer Basic.free(glbFullContent);
    glbContent := glbFullContent;

    // Parse header
    glb : Glb;
    glb.header = cast(*GlbHeader) glbContent.data;
    _CHECK(glb.header.magic == 0x46546C67, "Not a GLB file.");
    Basic.advance(*glbContent, size_of(GlbHeader));

    // Parse JSON chunk
    jsonChunkHeader := cast(*GlbChunkHeader) glbContent.data;
    _CHECK(jsonChunkHeader.type == 0x4E4F534A, "GLB file: no JSON chunk.");
    Basic.advance(*glbContent, size_of(GlbChunkHeader));

    glb.json.data = glbContent.data;
    glb.json.count = jsonChunkHeader.length;
    Basic.advance(*glbContent, jsonChunkHeader.length);

    // Parse bin chunk
    binChunkHeader := cast(*GlbChunkHeader) glbContent.data;
    _CHECK(binChunkHeader.type == 0x004E4942, "GLB file: no BIN chunk.");
    Basic.advance(*glbContent, size_of(GlbChunkHeader));

    glb.bin.data = glbContent.data;
    glb.bin.count = binChunkHeader.length;

    // Parse JSON itself
    json := json_parse_string(glb.json);
    defer json_free(json);

    rootSceneIndex := cast(u64) json["scene"].number;
    rootScene := json["scenes"][rootSceneIndex];
    rootSceneNodes := rootScene["nodes"];

    // @note We create a root node to apply a transform on the whole object.
    // (In order to fix axes conventions from glTF.)
    Basic.array_resize(*iMesh.nodes, iMesh.nodes.count + 1);
    iRootNodeIndex := iMesh.nodes.count - 1;
    for nodeIndex : rootSceneNodes.array {
        iNodeIndex := _glb_load_node(iMesh, cast(u64) nodeIndex.number, glb, json, iRootNodeIndex);
        if iNodeIndex != -1 {
            Basic.array_add(*iMesh.nodes[iRootNodeIndex].children, iNodeIndex);
        }
    }

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

// @todo We might have an issue due to endianess.
GlbHeader :: struct {
    magic : u32;
    version : u32;
    length : u32;
}

GlbChunkHeader :: struct {
    length : u32;
    type : u32;
}

Glb :: struct {
    header : *GlbHeader;
    json : string;
    bin : []u8;
}

_glb_load_node :: (iMesh : *MeshComponent, nodeIndex : u64, glb : Glb, json : JsonValue, iParentNodeIndex : s64) -> s64 {
    node := json["nodes"][nodeIndex];

    children := node["children"];
    nodeMesh := node["mesh"];

    _CHECK(children.type != .INVALID || nodeMesh.type != .INVALID, -1, "GLB node is empty and has no children. It has been removed.");

    Basic.array_resize(*iMesh.nodes, iMesh.nodes.count + 1);

    // Node transform
    iNodeIndex := iMesh.nodes.count - 1;
    iMesh.nodes[iNodeIndex].transform = _glb_get_transform(node);
    iMesh.nodes[iNodeIndex].parent = iParentNodeIndex;

    // Load geometry if any
    if nodeMesh.type == .NUMBER {
        meshIndex := cast(u64) nodeMesh.number;
        _glb_load_mesh(iMesh, meshIndex, glb, json);
    }

    if children.type == .ARRAY {
        for child : children.array {
            iChildNodeIndex := _glb_load_node(iMesh, cast(u64) child.number, glb, json, iNodeIndex);
            if iChildNodeIndex != -1 {
                Basic.array_add(*iMesh.nodes[iNodeIndex].children, iChildNodeIndex);
            }
        }
    }

    return iNodeIndex;
}

_glb_load_mesh :: (iMesh : *MeshComponent, meshIndex : u64, glb : Glb, json : JsonValue) {
    iNode := Basic.peek_pointer(iMesh.nodes);

    mesh := json["meshes"][meshIndex];

    primitives := mesh["primitives"];

    for primitive : primitives.array {
        // Extracting primitive attributes from JSON and BIN
        primitiveAttributes := primitive["attributes"];
        positionsAccessorIndex := cast(u64) primitiveAttributes["POSITION"].number;
        positions := _glb_access(positionsAccessorIndex, glb, json, Chamber.vec3);

        normals : []Chamber.vec3;
        if primitiveAttributes["NORMAL"].type == .NUMBER {
            normalsAccessorIndex := cast(u64) primitiveAttributes["NORMAL"].number;
            normals = _glb_access(normalsAccessorIndex, glb, json, Chamber.vec3);
        }

        indices : []u16;
        indicesAccessorIndex := cast(u64) primitive["indices"].number;
        indicesComponentType := cast(u64) json["accessors"][indicesAccessorIndex]["componentType"].number;
        if indicesComponentType == 5123 {
            indices = _glb_access(indicesAccessorIndex, glb, json, u16);
        } else {
            Chamber.debug("Unsupported GLB indices component type.");
            continue;
        }

        // Constructing the primitive mesh itself
        iPrimitive := Magma.create_mesh(iMesh.entity.engine.scene);
        Basic.array_add(*iNode.primitives, iPrimitive);

        Basic.array_resize(*iPrimitive.vertices, positions.count);
        for *vertex, i : iPrimitive.vertices {
            vertex.position = positions[i];
            if normals.count != 0 {
                vertex.normal = normals[i];
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

_glb_get_transform :: (json : JsonValue) -> Chamber.trs {
    transform : Chamber.trs;

    matrix := json["matrix"];
    if matrix.type == .ARRAY {
        // @note As per glsl convention, the matrix is listed column-major,
        // but we store it as row-major.
        m : Chamber.mat4;
        m.coef[0][0] = cast(float32) matrix.array[0].number;
        m.coef[1][0] = cast(float32) matrix.array[1].number;
        m.coef[2][0] = cast(float32) matrix.array[2].number;
        m.coef[3][0] = cast(float32) matrix.array[3].number;
        m.coef[0][1] = cast(float32) matrix.array[4].number;
        m.coef[1][1] = cast(float32) matrix.array[5].number;
        m.coef[2][1] = cast(float32) matrix.array[6].number;
        m.coef[3][1] = cast(float32) matrix.array[7].number;
        m.coef[0][2] = cast(float32) matrix.array[8].number;
        m.coef[1][2] = cast(float32) matrix.array[9].number;
        m.coef[2][2] = cast(float32) matrix.array[10].number;
        m.coef[3][2] = cast(float32) matrix.array[11].number;
        m.coef[0][3] = cast(float32) matrix.array[12].number;
        m.coef[1][3] = cast(float32) matrix.array[13].number;
        m.coef[2][3] = cast(float32) matrix.array[14].number;
        m.coef[3][3] = cast(float32) matrix.array[15].number;
        transform = Chamber.make_trs(m);
    } else {
        translation := json["translation"];
        rotation := json["rotation"];
        scale := json["scale"];

        if translation.type == .ARRAY {
            transform.translation.x = cast(float32) translation[0].number;
            transform.translation.y = cast(float32) translation[1].number;
            transform.translation.z = cast(float32) translation[2].number;
        }

        if rotation.type == .ARRAY {
            transform.rotation.x = cast(float32) rotation[0].number;
            transform.rotation.y = cast(float32) rotation[1].number;
            transform.rotation.z = cast(float32) rotation[2].number;
            transform.rotation.w = cast(float32) rotation[3].number;
        }

        if scale.type == .ARRAY {
            transform.scaling.x = cast(float32) scale[0].number;
            transform.scaling.y = cast(float32) scale[1].number;
            transform.scaling.z = cast(float32) scale[2].number;
        }
    }

    return transform;
}

_glb_access :: (accessorIndex : u64, glb : Glb, json : JsonValue, $T : Type) -> []T {
    accessor := json["accessors"][accessorIndex];
    count := cast(s64) accessor["count"].number;
    accessorByteOffset : u64 = 0;
    if accessor["byteOffset"].type == .NUMBER {
        accessorByteOffset = cast(u64) accessor["byteOffset"].number;
    }

    bufferViewIndex := cast(u64) accessor["bufferView"].number;
    bufferView := json["bufferViews"][bufferViewIndex];
    byteOffset : u64 = 0;
    if bufferView["byteOffset"].type == .NUMBER {
        byteOffset = cast(u64) bufferView["byteOffset"].number;
    }
    byteStride : u64 = 0;
    if bufferView["byteStride"].type == .NUMBER {
        byteStride = cast(u64) bufferView["byteStride"].number;
        _CHECK(byteStride == size_of(T), T.[], "GLB byteStride is not supported yet.");
    }

    result : []T;
    result.data = cast(*T) (glb.bin.data + accessorByteOffset + byteOffset);
    result.count = count;

    return result;
}

#import "Math";
#import "Chamber";
