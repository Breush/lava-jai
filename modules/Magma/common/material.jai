Material :: struct {
    shader : *Shader;

    name : string;

    using materialImpl : MaterialImpl;

    allocator : Allocator;
    allocator_data : *void;

    uniforms : Table(string, Uniform);

    UniformKind :: Chamber.UniformFrameKind;

    UniformBlock :: struct {
        buffer : [..]u8;
        using uniformBlockImpl : MaterialImpl.UniformBlockImpl;
    }

    UniformBlockField :: struct {
        parentName : string;
        offset : u32;
        size : u32;
    }

    Uniform :: struct {
        kind : UniformKind;
        binding : u32;
        union {
            texture : *Texture;
            block : UniformBlock;
            blockField : UniformBlockField;
        }
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

    if material.allocator != null {
        Basic.free(material, material.allocator, material.allocator_data);
    }
}

material_init :: (material : *Material, shader : *Shader) {
    material.shader = shader;

    for *uniformFrame, uniformName : shader.uniformsFrame {
        if uniformFrame.set == MATERIAL_DESCRIPTOR_SET_INDEX {
            Basic.assert(uniformFrame.kind != .Unknown);

            uniform : Material.Uniform;
            uniform.kind = uniformFrame.kind;
            uniform.binding = uniformFrame.binding;

            if uniformFrame.kind == .Block {
                Basic.array_resize(*uniform.block.buffer, uniformFrame.block.size);
            } else if uniformFrame.kind == .BlockField {
                uniform.blockField.offset = uniformFrame.blockField.offset;
                uniform.blockField.parentName = uniformFrame.blockField.parentName;
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

    uninit(*material.uniforms);

    if resetMemory {
        <<material = Material.{};
    }
}

material_set :: (material : *Material, uniformName : string, texture : *Texture) {
    uniform := table_find_pointer(material.uniforms, uniformName);
    Basic.assert(uniform != null && uniform.kind == .Texture);

    uniform.texture = texture;
    impl_material_uniform_commit(material, uniform);
}

material_set :: (material : *Material, uniformName : string, value : bool) {
    uniform := table_find_pointer(<<material.shader.uniformsFrame, uniformName);
    Basic.assert(uniform != null && uniform.kind == .BlockField);

    parentUniform := table_find_pointer(material.uniforms, uniform.blockField.parentName);

    <<cast(*u32) (parentUniform.block.buffer.data + uniform.blockField.offset) = cast(u32) value;
    impl_material_uniform_commit(material, parentUniform);
}

material_set :: (material : *Material, uniformName : string, value : $T) {
    uniform := table_find_pointer(<<material.shader.uniformsFrame, uniformName);
    Basic.assert(uniform != null && uniform.kind == .BlockField);

    parentUniform := table_find_pointer(material.uniforms, uniform.blockField.parentName);

    <<cast(*T) (parentUniform.block.buffer.data + uniform.blockField.offset) = value;
    impl_material_uniform_commit(material, parentUniform);
}

#scope_file

#import "Hash_Table";
