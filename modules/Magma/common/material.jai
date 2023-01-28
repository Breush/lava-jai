Material :: struct {
    shader : *Shader;

    name : string;

    using materialImpl : MaterialImpl;

    allocator : Allocator;

    uniforms : Table(string, Uniform);

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
        // :PushDescriptors
        dirties : [2]bool;
    }

    // :PushDescriptors
    inFlightDescriptorSetIndex : u32;
    anyUniformDirty : bool;
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
        Basic.free(material, material.allocator);
    }
}

material_init :: (material : *Material, shader : *Shader) {
    material.shader = shader;
    material.descriptorSetIndex = renderer_get_material_descriptor_set_index(material.shader.renderer);

    for *uniformFrame, uniformName : shader.uniformsFrame {
        if uniformFrame.set == material.descriptorSetIndex {
            Basic.assert(uniformFrame.kind != .Unknown);

            uniform : Material.Uniform;
            uniform.kind = uniformFrame.kind;
            uniform.binding = uniformFrame.binding;

            if uniformFrame.kind == .Block {
                Basic.array_resize(*uniform.block.buffer, uniformFrame.block.size);
            } else if uniformFrame.kind == .BlockField {
                uniform.blockField.offset = uniformFrame.blockField.offset;
                uniform.blockField.parentName = uniformFrame.blockField.parentName;
                uniform.blockField.maxSize = uniformFrame.blockField.maxSize;
            }

            table_add(*material.uniforms, uniformName, uniform);
        }
    }

    impl_material_init(material);
}

material_cleanup :: (material : *Material, resetMemory := true) {
    impl_material_cleanup(material);

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            Basic.array_free(uniform.block.buffer);
        }
    }

    deinit(*material.uniforms);

    if resetMemory {
        <<material = Material.{};
    }
}

material_update :: (material : *Material) {
    // :PushDescriptors If any uniform is dirty, advance to next offset.
    if !material.anyUniformDirty then return;

    material.inFlightDescriptorSetIndex = (material.inFlightDescriptorSetIndex + 1) % 2;

    for *uniform : material.uniforms {
        if !uniform.dirties[material.inFlightDescriptorSetIndex] then continue;
        impl_material_uniform_commit(material, uniform);
        uniform.dirties[material.inFlightDescriptorSetIndex] = false;
    }

    material.anyUniformDirty = false;
}

material_fallback :: (material : *Material, uniformName : string, fallback : *Texture) {
    uniform := table_find_pointer(*material.uniforms, uniformName);
    Basic.assert(uniform != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    Basic.assert(uniform.kind == .Texture, "Shader's '%' uniform named '%' is not a texture.", material.shader.id, uniformName);

    uniform.texture.fallback = fallback;
    uniform.dirties[0] = true;
    uniform.dirties[1] = true;
    material.anyUniformDirty = true;
}

material_set :: (material : *Material, uniformName : string, texture : *Texture) {
    uniform := table_find_pointer(*material.uniforms, uniformName);
    Basic.assert(uniform != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    Basic.assert(uniform.kind == .Texture, "Shader's '%' uniform named '%' is not a texture.", material.shader.id, uniformName);

    if uniform.texture.value == texture then return;
    uniform.texture.value = texture;
    uniform.dirties[0] = true;
    uniform.dirties[1] = true;
    material.anyUniformDirty = true;
}

material_set_color :: (material : *Material, uniformName : string, srgColor : Chamber.vec3) {
    uniform := table_find_pointer(material.shader.uniformsFrame, uniformName);
    Basic.assert(uniform != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(Chamber.vec3) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a value of type 'Chamber.vec3' (source too big).", material.shader.id, uniformName);

    parentUniform := table_find_pointer(*material.uniforms, uniform.blockField.parentName);

    color := srgb_to_linear(srgColor);
    if <<cast(*Vector3) (parentUniform.block.buffer.data + uniform.blockField.offset) == color then return;
    <<cast(*Vector3) (parentUniform.block.buffer.data + uniform.blockField.offset) = color;

    parentUniform.dirties[0] = true;
    parentUniform.dirties[1] = true;
    material.anyUniformDirty = true;
}

material_set_color :: (material : *Material, uniformName : string, srgColor : Chamber.vec4) {
    uniform := table_find_pointer(material.shader.uniformsFrame, uniformName);
    Basic.assert(uniform != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(Chamber.vec4) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a value of type 'Chamber.vec4' (source too big).", material.shader.id, uniformName);

    parentUniform := table_find_pointer(*material.uniforms, uniform.blockField.parentName);

    color := srgb_to_linear(srgColor);
    if <<cast(*Vector4) (parentUniform.block.buffer.data + uniform.blockField.offset) == color then return;
    <<cast(*Vector4) (parentUniform.block.buffer.data + uniform.blockField.offset) = color;

    parentUniform.dirties[0] = true;
    parentUniform.dirties[1] = true;
    material.anyUniformDirty = true;
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
    uniform := table_find_pointer(material.shader.uniformsFrame, uniformName);
    Basic.assert(uniform != null, "Shader '%' has no uniform named '%'.", material.shader.id, uniformName);
    Basic.assert(uniform.kind == .BlockField, "Shader's '%' uniform named '%' is not a block field.", material.shader.id, uniformName);
    Basic.assert(size_of(EffectiveT) <= uniform.blockField.maxSize, "Shader's '%' uniform named '%' can not be filled with a object of type '%' (source too big).", material.shader.id, uniformName, T);

    parentUniform := table_find_pointer(*material.uniforms, uniform.blockField.parentName);

    if <<cast(*EffectiveT) (parentUniform.block.buffer.data + uniform.blockField.offset) == cast(EffectiveT) value then return;
    <<cast(*EffectiveT) (parentUniform.block.buffer.data + uniform.blockField.offset) = cast(EffectiveT) value;

    parentUniform.dirties[0] = true;
    parentUniform.dirties[1] = true;
    material.anyUniformDirty = true;
}

#scope_file

#import "Hash_Table";
