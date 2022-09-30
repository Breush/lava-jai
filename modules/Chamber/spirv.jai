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
            maxSize : u32;
        }
    }
});

ShaderKind :: enum {
    Vertex;
    Fragment;
    Raygen;
    Miss;
    ClosestHit;
}

DollarFile :: struct {
    id : string;
    data : string;
}

// dollarPath is the path to use if any included shader files refer to "$/something.glsl"
spirv_compile_from_glsl :: (glslFile : string, shaderKind : ShaderKind, macroDefinition : string, dollarFiles : []DollarFile, optimized : bool) -> []u8 {
    spvCode : [..]u8;

    _, glslFileContent := _get_entire_shader_file(glslFile, ".", dollarFiles);
    defer if glslFile[0] != #char "$" then Basic.free(glslFileContent);

    shadercShaderKind : Shaderc.ShaderKind;
    if shaderKind == .Vertex {
        shadercShaderKind = .VertexShader;
    } else if shaderKind == .Fragment {
        shadercShaderKind = .FragmentShader;
    } else if shaderKind == .Raygen {
        shadercShaderKind = .RaygenShader;
    } else if shaderKind == .Miss {
        shadercShaderKind = .MissShader;
    } else if shaderKind == .ClosestHit {
        shadercShaderKind = .ClosesthitShader;
    }

    userData : ShadercUserData;
    userData.dollarFiles = dollarFiles;

    // :ContextBug We need to reference the first
    // field of the context, otherwise this does not work (for some unknown reason).
    // This is the workaround provided by Jon.
    #assert(type_info(Context_Base).members[0].name == "thread_index");
    userData.ctx = xx *context.thread_index;
    compiler := Shaderc.compiler_initialize();
    compileOptions := Shaderc.compile_options_initialize();
    Shaderc.compile_options_set_optimization_level(compileOptions, ifx optimized then Shaderc.OptimizationLevel.Performance else .Zero);
    Shaderc.compile_options_set_source_language(compileOptions, .Glsl);
    Shaderc.compile_options_add_macro_definition(compileOptions, macroDefinition.data, xx macroDefinition.count, null, 0);
    Shaderc.compile_options_set_include_callbacks(compileOptions, _include_resolver, _include_result_releaser, *userData);
    Shaderc.compile_options_set_target_spirv(compileOptions, ._1_4); // @note SPIR-V 1.4 required for ray-tracing extensions
    Shaderc.compile_options_set_target_env(compileOptions, .Vulkan, cast(u32) Shaderc.EnvVersion.Vulkan1_2);
    compilationResult := Shaderc.compile_into_spv(compiler, glslFileContent.data, xx glslFileContent.count, shadercShaderKind,
                                                  glslFile.data, "main", compileOptions);
    defer Shaderc.result_release(compilationResult);

    status := Shaderc.result_get_compilation_status(compilationResult);
    if status != .Success {
        Basic.print("Error: %\n", Basic.to_string(Shaderc.result_get_error_message(compilationResult)));
        return spvCode;
    }

    spvCodeView : []u8;
    spvCodeView.data = Shaderc.result_get_bytes(compilationResult);
    spvCodeView.count = xx Shaderc.result_get_length(compilationResult);

    // Making a copy of the code, as it will be wiped out by Shaderc.result_release
    Basic.array_copy(*spvCode, spvCodeView);
    return spvCode;
}

spirv_parse :: (fileContent : []u8, $parseUniforms := false) -> Spv {
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

                componentTypeInfo, ok := table_find(*typeInfos, componentType);

                typeInfo := table_find_or_add(*typeInfos, result);
                typeInfo.size = componentCount * componentTypeInfo.size;

            } else if opCode == .OpTypeStruct {
                result := spvCode[1];
                lastMemberType := spvCode[wordCount - 1];

                typeInfo := table_find_pointer(*typeInfos, result);
                lastMemberTypeInfo := table_find_pointer(*typeInfos, lastMemberType);

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
                    name, ok := table_find(*idToName, result);
                    uniformFrame, uniformName := table_find_entry(spv.uniformsFrame, name);
                    if uniformFrame != null {
                        uniformFrame.kind = .Block;
                        type := table_find_pointer(*typePointerToType, typePointer);
                        if type != null {
                            typeInfo, ok := table_find(*typeInfos, <<type);

                            uniformFrame.block.size = typeInfo.size;
                            nextOffset := typeInfo.size;
                            for <*member : typeInfo.members {
                                memberName := Basic.copy_string(member.name);
                                uniformFrame := table_add(*spv.uniformsFrame, memberName, .{});
                                uniformFrame.kind = .BlockField;
                                uniformFrame.blockField.parentName = <<uniformName;
                                uniformFrame.blockField.offset = member.offset;
                                uniformFrame.blockField.maxSize = (nextOffset - member.offset);
                                nextOffset = member.offset;
                            }
                        }
                    }
                } else if storageClass == .UniformConstant {
                    name, ok := table_find(*idToName, result);
                    uniformFrame := table_find_pointer(*spv.uniformsFrame, name);
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
                    name, ok := table_find(*idToName, target);
                    if !ok then Basic.log("Unable to find variable name in SPIR-V. Have decorations been stripped?", flags=.ERROR);
                    uniformFrame := table_find_pointer(*spv.uniformsFrame, name);
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

                    typeInfo, ok := table_find(*typeInfos, structureType);
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

ShadercUserData :: struct {
    // @note We are limiting the number of includes to 16 for now,
    // but as described in the speed tag below, it would be better to
    // just store their content once and for all.
    includeResults : [16]Shaderc.IncludeResult;
    includeResultsCount : u32;
    dollarFiles : []DollarFile;
    ctx : *Context;
}

// @todo @speed Looks like shaderc is re-asking for the same files
// multiple times. We could store them in a persistent way
// and feed shaderc accordingly. (Need to reduce paths too.)
_include_resolver :: (_userData : *void, requestedSource : *u8, type : s64,
                      requestingSource : *u8, includeDepth : u64) -> *Shaderc.IncludeResult #c_call {
    userData := cast(*ShadercUserData) _userData;
    includeResult : *Shaderc.IncludeResult;

    // :ContextBug We need to recreate a variable here,
    // otherwise the wrong context will be popped.
    ctx := << userData.ctx;
    push_context ctx {
        requestedSourceString := Basic.to_string(requestedSource);
        requestingSourceString := Basic.to_string(requestingSource);
        _, requestingPath := Compiler.get_basename_and_path(requestingSourceString);

        shaderPath, shaderCode := _get_entire_shader_file(requestedSourceString, requestingPath, userData.dollarFiles);

        includeResult = *userData.includeResults[userData.includeResultsCount];
        userData.includeResultsCount += 1;

        includeResult.sourceName = shaderPath.data;
        includeResult.sourceNameLength = xx shaderPath.count;
        includeResult.content = shaderCode.data;
        includeResult.contentLength = xx shaderCode.count;
    }
    return includeResult;
}

_include_result_releaser :: (_userData : *void, includeResult : *Shaderc.IncludeResult) #c_call {
    ctx : Context;
    push_context ctx {
        if includeResult.sourceName[0] != #char "$" {
            Basic.free(includeResult.content);
            Basic.free(includeResult.sourceName);
        }
    }
}

_get_entire_shader_file :: (filename : string, requestingPath : string, dollarFiles : []DollarFile) -> ( shaderPath : string, shaderCode : string ) {
    path, code : string;

    if filename[0] == #char "$" {
        for file : dollarFiles {
            if file.id == filename {
                path = file.id;
                code = file.data;
                break;
            }
        }
    } else {
        readOk : bool;
        path = Basic.tprint("%/%", requestingPath, filename);
        code, readOk = File.read_entire_file(path);
    }

    if code.count == 0 {
        Basic.log("Unable to get shader file: % from %", filename, requestingPath, flags = .ERROR);
    }

    return path, code;
}

#scope_file

Compiler :: #import "Compiler"; // For get_basename_and_path
Shaderc :: #import "Shaderc";
File :: #import "File";
#import "Hash_Table";
