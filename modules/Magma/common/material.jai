Material :: struct {
    shader : *Shader;

    name : string;

    using materialImpl : MaterialImpl;

    allocator : Allocator;

    uniforms : [..]Uniform;

    UniformKind :: Chamber.UniformFrameKind;

    UniformBlock :: struct {
        buffer : [..]u8;
        using uniformBlockImpl : MaterialImpl.UniformBlockImpl;
    }

    UniformBlockField :: struct {
        parentName : string;
        offset : u32;
        maxSize : u32;
    }

    Uniform :: struct {
        kind : UniformKind;
        binding : u32;
        union {
            texture : struct {
                value : *Texture;       // Can be null.
                fallback : *Texture;    // Never null.
            }
            block : UniformBlock;
            blockField : UniformBlockField;
        }
        dirty : bool;
    }
}

// Allocate, init and register a new material.
create_material :: (shader : *Shader) -> *Material {
    material := cast(*Material) Basic.New(Material);
    Basic.remember_allocators(material);
    material_init(material, shader);
    shader_register(shader, material);
    return material;
}

destroy_material :: (material : *Material) {
    material_cleanup(material, resetMemory = false);

    if material.allocator.proc != null {
        Basic.free(material,, material.allocator);
    }
}

material_init :: (material : *Material, shader : *Shader) {
    material.shader = shader;
    material.descriptorSetIndex = renderer_get_material_descriptor_set_index(material.shader.renderer);

    Basic.array_resize(*material.uniforms, shader.uniformsFrame.count);
    for *uniformFrame, uniformName : shader.uniformsFrame {
        if uniformFrame.set == material.descriptorSetIndex {
            Basic.assert(uniformFrame.kind != .Unknown);

            uniformIndex := table_find_pointer(*shader.uniformsNameToIndex, uniformName);
            uniform := *material.uniforms[uniformIndex.*];
            uniform.kind = uniformFrame.kind;
            uniform.binding = uniformFrame.binding;

            if uniformFrame.kind == .Block {
                Basic.array_resize(*uniform.block.buffer, uniformFrame.block.size);
            } else if uniformFrame.kind == .BlockField {
                uniform.blockField.offset = uniformFrame.blockField.offset;
                uniform.blockField.parentName = Basic.copy_string(uniformFrame.blockField.parentName);
                uniform.blockField.maxSize = uniformFrame.blockField.maxSize;
            }
        }
    }

    impl_material_init(material);
}

material_cleanup :: (material : *Material, resetMemory := true) {
    impl_material_cleanup(material);

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            Basic.array_free(uniform.block.buffer);
        } else if uniform.kind == .BlockField {
            Basic.free(uniform.blockField.parentName);
        }
    }

    Basic.array_free(material.uniforms);

    if resetMemory {
        material.* = .{};
    }
}

material_update :: (material : *Material) {
    for *uniform : material.uniforms {
        if !uniform.dirty then continue;
        impl_material_uniform_commit(material, uniform);
        uniform.dirty = false;
    }
}

material_fallback :: (material : *Material, uniformName : string, fallback : *Texture) {
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .Texture, "Shader's '%' uniform named '%' is not a texture.", material.shader.id, uniformName);

    uniform.texture.fallback = fallback;
    uniform.dirty = true;
}

material_get_texture :: (material : *Material, uniformName : string) -> *Texture {
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .Texture, "Shader's '%' uniform named '%' is not a texture.", material.shader.id, uniformName);
    return uniform.texture.value;
}

material_set :: (material : *Material, uniformName : string, texture : *Texture) {
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .Texture, "Shader's '%' uniform named '%' is not a texture.", material.shader.id, uniformName);

    if uniform.texture.value == texture then return;
    uniform.texture.value = texture;
    uniform.dirty = true;
}

material_set_color :: (material : *Material, uniformName : string, srgColor : Chamber.vec3) {
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(Chamber.vec3) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a value of type 'Chamber.vec3' (source too big).", material.shader.id, uniformName);

    parentUniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniform.blockField.parentName);
    parentUniform := *material.uniforms[parentUniformIndex.*];

    color := srgb_to_linear(srgColor);
    if <<cast(*Vector3) (parentUniform.block.buffer.data + uniform.blockField.offset) == color then return;
    <<cast(*Vector3) (parentUniform.block.buffer.data + uniform.blockField.offset) = color;

    parentUniform.dirty = true;
}

material_set_color :: (material : *Material, uniformName : string, srgColor : Chamber.vec4) {
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(Chamber.vec4) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a value of type 'Chamber.vec4' (source too big).", material.shader.id, uniformName);

    parentUniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniform.blockField.parentName);
    parentUniform := *material.uniforms[parentUniformIndex.*];

    color := srgb_to_linear(srgColor);
    if <<cast(*Vector4) (parentUniform.block.buffer.data + uniform.blockField.offset) == color then return;
    <<cast(*Vector4) (parentUniform.block.buffer.data + uniform.blockField.offset) = color;

    parentUniform.dirty = true;
}

material_set :: (material : *Material, uniformName : string, value : $T, $EffectiveT : Type = void)
#modify {
    if T == float64 then EffectiveT = float32;
    if T == u64 then EffectiveT = u32;
    if T == s64 then EffectiveT = s32;
    else if T == bool then EffectiveT = u32;
    else EffectiveT = T;
    return true;
}
{
    uniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniformName);
    Basic.assert(uniformIndex != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    uniform := *material.uniforms[uniformIndex.*];
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(EffectiveT) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a object of type '%' (source too big).", material.shader.id, uniformName, T);

    parentUniformIndex := table_find_pointer(*material.shader.uniformsNameToIndex, uniform.blockField.parentName);
    parentUniform := *material.uniforms[parentUniformIndex.*];

    if <<cast(*EffectiveT) (parentUniform.block.buffer.data + uniform.blockField.offset) == cast(EffectiveT) value then return;
    <<cast(*EffectiveT) (parentUniform.block.buffer.data + uniform.blockField.offset) = cast(EffectiveT) value;

    parentUniform.dirty = true;
}

#scope_file

#import "Hash_Table";
#import "Srgb";
