Glb :: struct {
    header : *GlbHeader;
    jsonChunk : string;
    binChunk : []u8;
    json : JsonValue;
}

// @todo We might have an issue due to endianess.
GlbHeader :: struct {
    magic : u32;
    version : u32;
    length : u32;
}

// @note The json field of the returned value needs to be freed
// with json_free.
glb_parse :: (fileContent : string) -> Glb {
    glbCode := fileContent;

    // Parse header
    glb : Glb;
    glb.header = cast(*GlbHeader) glbCode.data;
    _CHECK(glb.header.magic == 0x46546C67, Glb.{}, "Not a GLB file.");
    Basic.advance(*glbCode, size_of(GlbHeader));

    // Parse JSON chunk
    jsonChunkHeader := cast(*GlbChunkHeader) glbCode.data;
    _CHECK(jsonChunkHeader.type == 0x4E4F534A, Glb.{}, "GLB file: no JSON chunk.");
    Basic.advance(*glbCode, size_of(GlbChunkHeader));

    glb.jsonChunk.data = glbCode.data;
    glb.jsonChunk.count = jsonChunkHeader.length;
    Basic.advance(*glbCode, jsonChunkHeader.length);

    // Parse bin chunk
    binChunkHeader := cast(*GlbChunkHeader) glbCode.data;
    _CHECK(binChunkHeader.type == 0x004E4942, Glb.{}, "GLB file: no BIN chunk.");
    Basic.advance(*glbCode, size_of(GlbChunkHeader));

    glb.binChunk.data = glbCode.data;
    glb.binChunk.count = binChunkHeader.length;

    // Parse JSON itself
    glb.json = json_parse_string(glb.jsonChunk);

    return glb;
}

// Get the buffer view content behind an accessor.
glb_get_accessor :: (glb : Glb, accessorIndex : u64, $T : Type) -> []T {
    accessor := glb.json["accessors"][accessorIndex];
    count := cast(s64) accessor["count"].number;
    byteOffset : u64 = 0;
    if accessor["byteOffset"].type == .NUMBER {
        byteOffset = cast(u64) accessor["byteOffset"].number;
    }

    bufferViewIndex := cast(u64) accessor["bufferView"].number;
    bufferViewResult := glb_get_buffer_view(glb, bufferViewIndex, size_of(T));

    result : []T;
    result.data = cast(*T) (bufferViewResult.data + byteOffset);
    result.count = bufferViewResult.count / size_of(T);

    return result;
}

// Get a specific buffer view content.
glb_get_buffer_view :: (glb : Glb, bufferViewIndex : u64, expectedByteStride : u64 = 1) -> []u8 {
    bufferView := glb.json["bufferViews"][bufferViewIndex];
    byteLength := cast(s64) bufferView["byteLength"].number;
    byteOffset : u64 = 0;
    if bufferView["byteOffset"].type == .NUMBER {
        byteOffset = cast(u64) bufferView["byteOffset"].number;
    }
    byteStride : u64 = 0;
    if bufferView["byteStride"].type == .NUMBER {
        byteStride = cast(u64) bufferView["byteStride"].number;
        _CHECK(byteStride != expectedByteStride, u8.[], "GLB byteStride is not supported yet.");
    }

    result : []u8;
    result.data = glb.binChunk.data + byteOffset;
    result.count = byteLength;

    return result;
}

// Extracts transform from a glb node.
glb_get_transform :: (node : JsonValue) -> trs {
    transform : trs;

    matrix := node["matrix"];
    if matrix.type == .ARRAY {
        // @note As per glsl convention, the matrix is listed column-major,
        // but we store it as row-major.
        m : mat4;
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
        transform = make_trs(m);
    } else {
        translation := node["translation"];
        rotation := node["rotation"];
        scale := node["scale"];

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

#scope_file

GlbChunkHeader :: struct {
    length : u32;
    type : u32;
}
