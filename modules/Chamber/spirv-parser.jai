Spv :: struct {
    header : SpvHeader;
    uniformsFrame : UniformsFrame;
}

SpvHeader :: struct {
    magic : u32;
    version : u32;
    generatorMagic : u32;
    bound : u32;
    _reserved : u32;
}

UniformFrameKind :: enum {
    Unknown :: 0;
    Texture;
    Block;
    BlockField;
}

UniformsFrame :: Table(string, struct {
    kind : UniformFrameKind;
    set : u32;
    binding : u32;
    union {
        block : struct {
            size : u32;
        }
        blockField : struct {
            parentName : string;
            offset : u32;
        }
    }
});

spirv_parse :: (fileContent : string, $parseUniforms := false) -> Spv {
    spv : Spv;

    spvCode : []u32;
    spvCode.data = cast(*u32) fileContent.data;
    spvCode.count = fileContent.count / size_of(u32);
    spv.header = << cast(*SpvHeader) spvCode.data;
    _CHECK(spv.header.magic == 0x07230203, Spv.{}, "Shader file is not a SPIR-V.");

    spvCode.data += 5;
    spvCode.count -= 5;

    // Extract uniforms definitions (name/set/binding) from the SPV.
    // @note This requires OpName to exist, so the SPV should keep these debug symbols.
    #if parseUniforms {
        Member :: struct {
            index : u32;
            offset : u32;
            name : string;
        };

        idToName : Table(u32, string);
        typePointerToType : Table(u32, u32);
        typeInfos : Table(u32, struct {
            size : u32;
            members : [..]Member;
        });
        defer {
            for typeInfo : typeInfos {
                Basic.array_free(typeInfo.members);
            }
            uninit(*typeInfos);
            uninit(*typePointerToType);
            uninit(*idToName);
        }

        while spvCode.count > 0 {
            wordCountOpCode := spvCode[0];
            wordCount := wordCountOpCode >> 16;
            opCode := cast(SpvOpCode) wordCountOpCode & 0xFF;

            if opCode == .OpName {
                target := spvCode[1];
                name := Basic.to_string(cast(*u8) *spvCode[2]);
                table_add(*idToName, target, name);

            } else if opCode == .OpMemberName {
                type := spvCode[1];

                member : Member;
                member.index = spvCode[2];
                member.name = Basic.to_string(cast(*u8) *spvCode[3]);

                typeInfo := table_find_or_add(*typeInfos, type);
                Basic.array_add(*typeInfo.members, member);

            } else if opCode == .OpTypeInt || opCode == .OpTypeFloat {
                result := spvCode[1];
                width := spvCode[2] / 8; // Converting bits to bytes

                typeInfo := table_find_or_add(*typeInfos, result);
                typeInfo.size = width;

            } else if opCode == .OpTypeVector || opCode == .OpTypeMatrix {
                result := spvCode[1];
                componentType := spvCode[2];
                componentCount := spvCode[3];

                componentTypeInfo, ok := table_find(typeInfos, componentType);

                typeInfo := table_find_or_add(*typeInfos, result);
                typeInfo.size = componentCount * componentTypeInfo.size;

            } else if opCode == .OpTypeStruct {
                result := spvCode[1];
                lastMemberType := spvCode[wordCount - 1];

                typeInfo := table_find_pointer(typeInfos, result);
                lastMemberTypeInfo := table_find_pointer(typeInfos, lastMemberType);

                // @todo We are relying on the fact that members are added in
                // order in this array. Hopefully, that's true whatever SPV compiler in used.
                lastMember := typeInfo.members[typeInfo.members.count - 1];

                typeInfo.size = lastMember.offset + lastMemberTypeInfo.size;

            } else if opCode == .OpTypePointer {
                result := spvCode[1];
                storageClass := cast(SpvStorageClass) spvCode[2];
                type := spvCode[3];

                if storageClass == .Uniform {
                    table_add(*typePointerToType, result, type);
                }

            } else if opCode == .OpFunction {
                // Breaking on first OpFunction, it's no more the header.
                break;

            } else if opCode == .OpVariable {
                typePointer := spvCode[1];
                result := spvCode[2];
                storageClass := cast(SpvStorageClass) spvCode[3];

                // More info about a uniform
                if storageClass == .Uniform {
                    name, ok := table_find(idToName, result);
                    uniformFrame, uniformName := table_find_entry(spv.uniformsFrame, name);
                    if uniformFrame != null {
                        uniformFrame.kind = .Block;
                        type := table_find_pointer(typePointerToType, typePointer);
                        if type != null {
                            typeInfo, ok := table_find(typeInfos, <<type);
                            for *member : typeInfo.members {
                                memberName := Basic.copy_string(member.name);
                                uniformFrame := table_add(*spv.uniformsFrame, memberName, .{});
                                uniformFrame.kind = .BlockField;
                                uniformFrame.blockField.parentName = <<uniformName;
                                uniformFrame.blockField.offset = member.offset;
                            }
                            uniformFrame.block.size = typeInfo.size;
                        }
                    }
                } else if storageClass == .UniformConstant {
                    name, ok := table_find(idToName, result);
                    uniformFrame := table_find_pointer(spv.uniformsFrame, name);
                    if uniformFrame != null {
                        uniformFrame.kind = .Texture;
                    }
                }

            } else if opCode == .OpDecorate {
                target := spvCode[1];
                decoration := cast(SpvDecoration) spvCode[2];
                literal := spvCode[3];

                if decoration == .Binding ||
                   decoration == .DescriptorSet {
                    name, ok := table_find(idToName, target);
                    uniformFrame := table_find_pointer(spv.uniformsFrame, name);
                    if uniformFrame == null {
                        name = Basic.copy_string(name); // Needed, original shaderCode will be wiped out.
                        uniformFrame = table_add(*spv.uniformsFrame, name, .{});
                    }

                    if decoration == .Binding {
                        uniformFrame.binding = literal;
                    } else if decoration == SpvDecoration.DescriptorSet {
                        uniformFrame.set = literal;
                    }
                }

            } else if opCode == .OpMemberDecorate {
                structureType := spvCode[1];
                index := spvCode[2];
                decoration := cast(SpvDecoration) spvCode[3];

                if decoration == .Offset {
                    offset := spvCode[4];

                    typeInfo, ok := table_find(typeInfos, structureType);
                    for *member : typeInfo.members {
                        if member.index == index {
                            member.offset = offset;
                            break;
                        }
                    }
                }
            }

            if wordCount == 0 {
                break;
            }

            spvCode.data += wordCount;
            spvCode.count -= wordCount;
        }
    }

    return spv;
}

#scope_file

SpvOpCode :: enum u32 {
    OpName :: 5;
    OpMemberName :: 6;
    OpTypeInt :: 21;
    OpTypeFloat :: 22;
    OpTypeVector :: 23;
    OpTypeMatrix :: 24;
    OpTypeStruct :: 30;
    OpTypePointer :: 32;
    OpFunction :: 54;
    OpVariable :: 59;
    OpDecorate :: 71;
    OpMemberDecorate :: 72;
}

SpvStorageClass :: enum u32 {
    UniformConstant :: 0;
    Uniform :: 2;
}

SpvDecoration :: enum u32 {
    Binding :: 33;
    DescriptorSet :: 34;
    Offset :: 35;
}

#scope_file

#import "Hash_Table";
