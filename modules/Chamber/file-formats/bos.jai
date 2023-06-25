/*
 * BOS: Breust's Object Serialization
 *
 * A binary file format to store associative and composed information.
 * Kind of a binary JSON format in the idea, but strongly typed
 * and hopefully much more simpler.
 *
 * Everything is meant to be little-endian,
 * strings are UTF-8 (prefixed with size) - they are
 * not zero-terminated.
 */

// The file is structured as such:
// Header (12 bytes):
// | MagicNumber (4 bytes)
// | Version (4 bytes) (file format version)
// | TypeTableLengthInBytes (4 bytes)
// Type entry (multiple times):
// | Type (4 bytes)
// | if TypeKind == .Struct:
// |   MemberCount (4 bytes)
// |   DebugName (4 bytes size + string)
// |   Member (multiple times):
// |   | Type (4 bytes)
// |   | DebugName (4 bytes size + string)
// | else TypeKind == .Array:
// |   ElementType (4 bytes)
// | else TypeKind == .Map:
// |   KeyType (4 bytes)
// |   ValueType (4 bytes)
// Content:
// | DataVersion (4 bytes)
// | Type (4 bytes)
// | Data depending on type


// ## Terminology
//
// Type: Either a numeric type, a string type, an array type
//       or a user-defined type in the type table.
// Numeric type: Can represent a numeric value.
// String type: Can represent a string.
// Array type: Can represent an array of elements.
//

Bytes :: #type string;

BosHeader :: struct {
    magic : [4]u8;
    version : u32;
    typeTableLengthInBytes : u32;
}

// A type needs to be masked with 0xFF before checking
// against the enum below.
// The top 24 bits are either flags or the offset in the type table.
BosType :: enum u32 {
    Unknown :: 0;

    Struct :: #char "S";
    Array :: #char "A";
    Map :: #char "M";

    String :: #char "s";

    NumericSignedInt8 :: #char "g";
    NumericSignedInt16 :: #char "h";
    NumericSignedInt32 :: #char "i";
    NumericSignedInt64 :: #char "j";
    NumericUnsignedInt8 :: #char "G";
    NumericUnsignedInt16 :: #char "H";
    NumericUnsignedInt32 :: #char "I";
    NumericUnsignedInt64 :: #char "J";
    NumericFloat32 :: #char "f";
    NumericFloat64 :: #char "d";
}

BosSerializationOptions :: struct {
    noHeaderEnabled : bool;
    typeTableEnabled : bool;
}

// If version is 0xFFFFFFFF, no version comparison will occur.
// If version mismatch with the stored one in bytes, false is returned without touching the object.
bos_deserialize_as :: (object : *$T, bytes : Bytes, version : u32) -> (success : bool) {
    header := cast(*BosHeader) bytes.data;
    if bytes.count < size_of(BosHeader) ||
       memcmp(header.magic.data, "BOS\0".data, 4) != 0 ||
       header.version != 1 {
        log("Invalid BOS header or version.", flags = .WARNING);
        return false;
    }

    Basic.advance(*bytes, size_of(BosHeader));
    Basic.advance(*bytes, header.typeTableLengthInBytes);

    dataVersion := bos_deserialize_raw_numeric(*bytes, u32);
    if version != 0xFFFFFFFF && dataVersion != version {
        return false;
    }

    typeEntry := << cast(*BosType) bytes.data;
    typeKind := typeEntry & 0xFF;
    typeInfo := type_info(T);
    Basic.assert(typeKind == bos_identify_type(typeInfo));
    Basic.advance(*bytes, size_of(BosType));

    bos_deserialize(cast(*u8) object, typeInfo, *bytes);
    return true;
}

bos_deserialize :: (objectBytes : *u8, typeInfo : *Type_Info, bytes : *Bytes) {
    if typeInfo.type == .BOOL {
        << cast(*bool) objectBytes = bos_deserialize_raw_numeric(bytes, bool);
    } else if typeInfo.type == .INTEGER {
        if typeInfo.runtime_size == 1 then << cast(*u8) objectBytes = bos_deserialize_raw_numeric(bytes, u8);
        else if typeInfo.runtime_size == 2 then << cast(*u16) objectBytes = bos_deserialize_raw_numeric(bytes, u16);
        else if typeInfo.runtime_size == 4 then << cast(*u32) objectBytes = bos_deserialize_raw_numeric(bytes, u32);
        else if typeInfo.runtime_size == 8 then << cast(*u64) objectBytes = bos_deserialize_raw_numeric(bytes, u64);
    } else if typeInfo.type == .FLOAT {
        if typeInfo.runtime_size == 4 then << cast(*float32) objectBytes = bos_deserialize_raw_numeric(bytes, float32);
        else if typeInfo.runtime_size == 8 then << cast(*float64) objectBytes = bos_deserialize_raw_numeric(bytes, float64);
    } else if typeInfo.type == .ENUM {
        targetTypeInfo := cast(*Type_Info_Enum) typeInfo;
        bos_deserialize(objectBytes, targetTypeInfo.internal_type, bytes);
    } else if typeInfo.type == .STRING {
        objectString := cast(*string) objectBytes;
        << objectString = Basic.sprint("%", bos_deserialize_string(bytes));
    } else if typeInfo.type == .ARRAY {
        targetTypeInfo := cast(*Type_Info_Array) typeInfo;
        // @todo Handle flatness, if elements are known flats.
        if targetTypeInfo.array_type == .RESIZABLE {
            arrayLength := bos_deserialize_raw_numeric(bytes, u32);
            objectArray := cast(*[..]u8) objectBytes;
            elementSize := targetTypeInfo.element_type.runtime_size;
            Basic.array_resize(objectArray, arrayLength * elementSize);
            objectArray.count = arrayLength;
            objectArray.allocated = arrayLength;
            for elementIndex : 0 .. cast,no_check(s32) arrayLength - 1 {
                bos_deserialize(objectArray.data + elementIndex * elementSize, targetTypeInfo.element_type, bytes);
            }
        } else if targetTypeInfo.array_type == .FIXED {
            arrayLength := targetTypeInfo.array_count;
            elementSize := targetTypeInfo.element_type.runtime_size;
            for elementIndex : 0 .. cast,no_check(s32) arrayLength - 1 {
                bos_deserialize(objectBytes + elementIndex * elementSize, targetTypeInfo.element_type, bytes);
            }
        } else {
            Basic.log_error("Unsupported array type: %.", targetTypeInfo.array_type);
        }
    } else if typeInfo.type == .STRUCT {
        targetTypeInfo := cast(*Type_Info_Struct) typeInfo;
        // Handling Hash_Table.Table specifically
        if targetTypeInfo.polymorph_source_struct != null && targetTypeInfo.name == "Table" {
            count := bos_deserialize_raw_numeric(bytes, u32);
            countMember := targetTypeInfo.members[0];
            slotsFilledMember := targetTypeInfo.members[2];
            << cast(*s64) (objectBytes + countMember.offset_in_bytes) = cast(s64) count;
            << cast(*s64) (objectBytes + slotsFilledMember.offset_in_bytes) = cast(s64) count;

            allocated := bos_deserialize_raw_numeric(bytes, u32);
            allocatedMember := targetTypeInfo.members[1];
            << cast(*s64) (objectBytes + allocatedMember.offset_in_bytes) = cast(s64) allocated;

            entryMember := targetTypeInfo.members[4];
            entryTypeInfo := << cast(**Type_Info_Struct) (targetTypeInfo.constant_storage.data + entryMember.offset_into_constant_storage);
            entrySize := entryTypeInfo.runtime_size;

            entriesMember := targetTypeInfo.members[5];
            entriesArray := cast(*[]u8) (objectBytes + entriesMember.offset_in_bytes);
            Basic.array_resize(entriesArray, allocated * entrySize);
            entriesArray.count = allocated;

            for i : 0 .. cast(s32) count - 1 {
                entryIndex := bos_deserialize_raw_numeric(bytes, u32);
                bos_deserialize(entriesArray.data + entryIndex * entrySize, entryTypeInfo, bytes);
            }
        } else {
            // @todo Handle flatness.
            currentMaxOffset := -1;
            for *member : targetTypeInfo.members {
                if member.flags & .CONSTANT then continue;
                if member.notes.count != 0 && member.notes[0] == "NoSerialize" then continue;
                if currentMaxOffset >= member.offset_in_bytes then continue;
                currentMaxOffset = member.offset_in_bytes;
                bos_deserialize(objectBytes + member.offset_in_bytes, member.type, bytes);
            }
        }
    } else {
        Basic.log_error("Unsupported type kind: %.", typeInfo.type);
    }
}

bos_deserialize_raw_numeric :: (bytes : *Bytes, $T : Type) -> T {
    value := << cast(*T) bytes.data;
    Basic.advance(bytes, size_of(T));

    return value;
}

bos_deserialize_string :: (bytes : *Bytes) -> string {
    str : string;
    str.count = bos_deserialize_raw_numeric(bytes, u32);
    str.data = bytes.data;
    Basic.advance(bytes, str.count);

    return str;
}

bos_serialize :: (object : $T, version : u32, options := BosSerializationOptions.{}) -> (bytes : Bytes) {
    sb : Basic.String_Builder;
    defer Basic.reset(*sb);

    if !options.noHeaderEnabled {
        header := BosHeader.{
            magic = .[#char "B", #char "O", #char "S", 0],
            version = 1,
        };
        Basic.append(*sb, cast(*u8) *header, size_of(BosHeader));
    }

    contentSb : Basic.String_Builder;
    defer Basic.reset(*contentSb);

    typeInfo := type_info(T);
    rootType := bos_identify_type(typeInfo);
    if options.typeTableEnabled {
        knownTypesMap : Hash.Table(*Type_Info, BosType);
        defer Hash.deinit(*knownTypesMap);
        rootType = bos_serialize_type(*sb, typeInfo, *knownTypesMap, options);
    }
    bos_serialize_raw_numeric(*contentSb, version);
    bos_serialize_raw_type(*contentSb, rootType);
    bos_serialize(*contentSb, cast(*u8) *object, typeInfo);

    typeTableLengthInBytes := Basic.builder_string_length(*sb) - size_of(BosHeader);

    // @todo One can probably do way better than this double copy...
    Basic.append(*sb, Basic.builder_to_string(*contentSb, Basic.temp));
    s := Basic.builder_to_string(*sb);

    // Setting the type table length
    << cast(*u32) (s.data + 8) = cast(u32) typeTableLengthInBytes;

    tmp : []u8;
    tmp.data = s.data;
    tmp.count = s.count;
    return cast(Bytes) s;
}

bos_serialize :: (sb : *Basic.String_Builder, objectBytes : *u8, typeInfo : *Type_Info) {
    if typeInfo.type == .BOOL {
        bos_serialize_raw_numeric(sb, << cast(*bool) objectBytes);
    } else if typeInfo.type == .INTEGER {
        if typeInfo.runtime_size == 1 then bos_serialize_raw_numeric(sb, << cast(*u8) objectBytes);
        else if typeInfo.runtime_size == 2 then bos_serialize_raw_numeric(sb, << cast(*u16) objectBytes);
        else if typeInfo.runtime_size == 4 then bos_serialize_raw_numeric(sb, << cast(*u32) objectBytes);
        else if typeInfo.runtime_size == 8 then bos_serialize_raw_numeric(sb, << cast(*u64) objectBytes);
    } else if typeInfo.type == .FLOAT {
        if typeInfo.runtime_size == 4 then bos_serialize_raw_numeric(sb, << cast(*float32) objectBytes);
        else if typeInfo.runtime_size == 8 then bos_serialize_raw_numeric(sb, << cast(*float64) objectBytes);
    } else if typeInfo.type == .ENUM {
        targetTypeInfo := cast(*Type_Info_Enum) typeInfo;
        bos_serialize(sb, objectBytes, targetTypeInfo.internal_type);
    } else if typeInfo.type == .STRING {
        bos_serialize_raw_string(sb, << cast(*string) objectBytes);
    } else if typeInfo.type == .ARRAY {
        targetTypeInfo := cast(*Type_Info_Array) typeInfo;
        if targetTypeInfo.array_type == .RESIZABLE || targetTypeInfo.array_type == .VIEW {
            objectArray := << cast(*[]u8) objectBytes;
            bos_serialize_raw_numeric(sb, cast(u32) objectArray.count);
            for i : 0 .. objectArray.count - 1 {
                bos_serialize(sb, objectArray.data + i * targetTypeInfo.element_type.runtime_size, targetTypeInfo.element_type);
            }
        } else if targetTypeInfo.array_type == .FIXED {
            for i : 0 .. targetTypeInfo.array_count - 1 {
                bos_serialize(sb, objectBytes + i * targetTypeInfo.element_type.runtime_size, targetTypeInfo.element_type);
            }
        } else {
            Basic.log_error("Unsupported array type: %.", targetTypeInfo.array_type);
        }
    } else if typeInfo.type == .STRUCT {
        targetTypeInfo := cast(*Type_Info_Struct) typeInfo;

        // Handling Hash_Table.Table specifically
        if targetTypeInfo.polymorph_source_struct != null && targetTypeInfo.name == "Table" {
            countMember := targetTypeInfo.members[0];
            Basic.assert(countMember.name == "count" && countMember.type == type_info(s64));
            count := << cast(*s64) (objectBytes + countMember.offset_in_bytes);
            bos_serialize_raw_numeric(sb, cast(u32) count);

            allocatedMember := targetTypeInfo.members[1];
            Basic.assert(allocatedMember.name == "allocated" && allocatedMember.type == type_info(s64));
            allocated := << cast(*s64) (objectBytes + allocatedMember.offset_in_bytes);
            bos_serialize_raw_numeric(sb, cast(u32) allocated);

            entryMember := targetTypeInfo.members[4];
            Basic.assert(entryMember.name == "Entry" && entryMember.type.type == .TYPE);
            entryTypeInfo := << cast(**Type_Info_Struct) (targetTypeInfo.constant_storage.data + entryMember.offset_into_constant_storage);
            entrySize := entryTypeInfo.runtime_size;

            entriesMember := targetTypeInfo.members[5];
            Basic.assert(entriesMember.name == "entries" && entriesMember.type.type == .ARRAY);
            entries := << cast(*[]u8) (objectBytes + entriesMember.offset_in_bytes);

            entryHashMember := *entryTypeInfo.members[0];

            for i : 0 .. entries.count - 1 {
                entryBytes := entries.data + i * entrySize;
                hash := << cast(*u32) (entryBytes + entryHashMember.offset_in_bytes);
                if hash < Hash.FIRST_VALID_HASH then continue;
                bos_serialize_raw_numeric(sb, cast(u32) i);
                bos_serialize(sb, entryBytes, entryTypeInfo);
            }
        } else {
            // To handle #place and unions
            currentMaxOffset := -1;
            for *member : targetTypeInfo.members {
                if member.flags & .CONSTANT then continue;
                if member.notes.count != 0 && member.notes[0] == "NoSerialize" then continue;
                if currentMaxOffset >= member.offset_in_bytes then continue;
                currentMaxOffset = member.offset_in_bytes;

                bos_serialize(sb, objectBytes + member.offset_in_bytes, member.type);
            }
        }
    } else {
        Basic.log_error("Unsupported type info: %.", typeInfo.type);
    }
}

bos_serialize_type :: (sb : *Basic.String_Builder, typeInfo : *Type_Info, knownTypesMap : *Hash.Table(*Type_Info, BosType), options : BosSerializationOptions) -> BosType {
    knownType := Hash.table_find_pointer(knownTypesMap, typeInfo);
    if knownType != null then return knownType.*;

    type : BosType;
    if typeInfo.type == .BOOL {
        type = .NumericUnsignedInt8;
    } else if typeInfo.type == .INTEGER {
        targetTypeInfo := cast(*Type_Info_Integer) typeInfo;
        if typeInfo.runtime_size == 1 {
            type = ifx targetTypeInfo.signed then BosType.NumericSignedInt8 else .NumericUnsignedInt8;
        } else if typeInfo.runtime_size == 2 {
            type = ifx targetTypeInfo.signed then BosType.NumericSignedInt16 else .NumericUnsignedInt16;
        } else if typeInfo.runtime_size == 4 {
            type = ifx targetTypeInfo.signed then BosType.NumericSignedInt32 else .NumericUnsignedInt32;
        } else if typeInfo.runtime_size == 8 {
            type = ifx targetTypeInfo.signed then BosType.NumericSignedInt64 else .NumericUnsignedInt64;
        } else {
            Basic.log_error("Unsupported integer size: %.", typeInfo.runtime_size);
            Basic.assert(false);
        }
    } else if typeInfo.type == .FLOAT {
        type = .NumericFloat32;
    } else if typeInfo.type == .ENUM {
        targetTypeInfo := cast(*Type_Info_Enum) typeInfo;
        type = bos_serialize_type(sb, targetTypeInfo.internal_type, knownTypesMap, options);
    } else if typeInfo.type == .STRING {
        type = .String;
    } else if typeInfo.type == .ARRAY {
        // Ensure that the element's type is fully serialized first.
        targetTypeInfo := cast(*Type_Info_Array) typeInfo;
        arrayElementType := bos_serialize_type(sb, targetTypeInfo.element_type, knownTypesMap, options);

        type = .Array;
        type |= (cast(BosType) Basic.builder_string_length(sb) - size_of(BosHeader)) << 24;

        typeEntry := BosType.Array;
        Basic.append(sb, cast(*u8) *typeEntry, size_of(BosType));
        bos_serialize_raw_type(sb, arrayElementType);
    } else if typeInfo.type == .STRUCT {
        targetTypeInfo := cast(*Type_Info_Struct) typeInfo;

        // Handling Hash_Table.Table specifically
        if targetTypeInfo.polymorph_source_struct != null && targetTypeInfo.name == "Table" {
            Basic.assert(targetTypeInfo.specified_parameters.count >= 2);
            keyParameter := targetTypeInfo.specified_parameters[0];
            valueParameter := targetTypeInfo.specified_parameters[1];
            Basic.assert(keyParameter.name == "Key_Type");
            keyTypeInfo := << cast(**Type_Info) (targetTypeInfo.constant_storage.data + keyParameter.offset_into_constant_storage);
            valueTypeInfo := << cast(**Type_Info) (targetTypeInfo.constant_storage.data + valueParameter.offset_into_constant_storage);

            // Ensure that key/value types are fully serialized first.
            keyType := bos_serialize_type(sb, keyTypeInfo, knownTypesMap, options);
            valueType := bos_serialize_type(sb, valueTypeInfo, knownTypesMap, options);

            type = .Map;
            type |= (cast(BosType) Basic.builder_string_length(sb) - size_of(BosHeader)) << 24;

            typeEntry := BosType.Map;
            Basic.append(sb, cast(*u8) *typeEntry, size_of(BosType));
            bos_serialize_raw_type(sb, keyType);
            bos_serialize_raw_type(sb, valueType);
        } else {
            // Ensure that all depending types are fully serialized in type table first.
            currentMaxOffset := -1;
            for *member : targetTypeInfo.members {
                if member.flags & .CONSTANT then continue;
                if currentMaxOffset >= member.offset_in_bytes then continue;
                currentMaxOffset = member.offset_in_bytes;
                bos_serialize_type(sb, member.type, knownTypesMap, options);
            }

            type = .Struct;
            type |= (cast(BosType) Basic.builder_string_length(sb) - size_of(BosHeader)) << 24;

            typeEntry := BosType.Struct;
            memberCount := cast(u32) targetTypeInfo.members.count;
            Basic.append(sb, cast(*u8) *typeEntry, size_of(BosType));
            bos_serialize_raw_numeric(sb, memberCount);
            bos_serialize_raw_string(sb, targetTypeInfo.name);

            if typeEntry & 0x0000_0100 == 0 {
                currentMaxOffset := -1;
                for *member : targetTypeInfo.members {
                    if member.flags & .CONSTANT then continue;
                    if currentMaxOffset >= member.offset_in_bytes then continue;
                    currentMaxOffset = member.offset_in_bytes;
                    memberType := bos_serialize_type(sb, member.type, knownTypesMap, options);
                    bos_serialize_raw_type(sb, memberType);
                    bos_serialize_raw_string(sb, member.name);
                }
            }
        }
    } else {
        Basic.log_error("Unsupported type info: %.", typeInfo.type);
        Basic.assert(false);
    }

    Hash.table_add(knownTypesMap, typeInfo, type);
    return type;
}

bos_serialize_raw_string :: (sb : *Basic.String_Builder, str : string, sized := true) {
    bos_serialize_raw_numeric(sb, cast(u32) str.count);
    Basic.append(sb, str.data, str.count);
}

bos_serialize_raw_type :: (sb : *Basic.String_Builder, type : BosType) {
    Basic.append(sb, cast(*u8) *type, size_of(BosType));
}

bos_serialize_raw_numeric :: (sb : *Basic.String_Builder, value : $T) {
    Basic.assert(type_info(T).runtime_size <= 8);
    Basic.append(sb, cast(*u8) *value, size_of(T));
}

bos_identify_type :: (typeInfo : *Type_Info) -> BosType {
    if typeInfo.type == .BOOL {
        return .NumericUnsignedInt8;
    } else if typeInfo.type == .INTEGER {
        targetTypeInfo := cast(*Type_Info_Integer) typeInfo;
        if typeInfo.runtime_size == 1 {
            return ifx targetTypeInfo.signed then BosType.NumericSignedInt8 else .NumericUnsignedInt8;
        } else if typeInfo.runtime_size == 2 {
            return ifx targetTypeInfo.signed then BosType.NumericSignedInt16 else .NumericUnsignedInt16;
        } else if typeInfo.runtime_size == 4 {
            return ifx targetTypeInfo.signed then BosType.NumericSignedInt32 else .NumericUnsignedInt32;
        } else if typeInfo.runtime_size == 8 {
            return ifx targetTypeInfo.signed then BosType.NumericSignedInt64 else .NumericUnsignedInt64;
        }
    } else if typeInfo.type == .FLOAT {
        return .NumericFloat32;
    } else if typeInfo.type == .ENUM {
        targetTypeInfo := cast(*Type_Info_Enum) typeInfo;
        return bos_identify_type(targetTypeInfo.internal_type);
    } else if typeInfo.type == .STRING {
        return .String;
    } else if typeInfo.type == .ARRAY {
        return .Array;
    } else if typeInfo.type == .STRUCT {
        targetTypeInfo := cast(*Type_Info_Struct) typeInfo;
        return ifx targetTypeInfo.polymorph_source_struct != null && targetTypeInfo.name == "Table" then BosType.Map else .Struct;
    }

    Basic.log_error("Unsupported type info: %.", typeInfo.type);
    Basic.assert(false);
    return .Unknown;
}

bos_demo :: () {
    Point :: struct {
        x, y, z : float;
    }

    Mesh :: struct {
        name : string;
        vertices : [..]Point;
        indices : [..]u32;
    }

    mesh : Mesh;
    mesh.name = "My mesh";
    Basic.array_copy(*mesh.vertices, .[.{0,0,0}, .{1,0,0}, .{1,1,0}, .{0,1,0}]);
    Basic.array_copy(*mesh.indices, .[0, 1, 2, 0, 2, 3]);

    // Type table is needed for sharing the file outside of the application,
    // as it therefore can be used to deserialize the data.
    serializedMesh := bos_serialize(mesh, .{ typeTableEnabled = true });

    // Full deserialize
    deserializedMesh : Mesh;
    bos_deserialize_as(*deserializedMesh, serializedMesh);
}
