/*
 * A shader is defining the pipeline for materials.
 */

Shader :: struct {
    renderer : *Renderer;
    id : string;

    materials : [..]*Material;
    uniformsFrame : *Chamber.UniformsFrame;
    options : ShaderOptions;

    using shaderImpl : ShaderImpl;

    allocator : Allocator;
}

ShaderOptions :: struct {
    depthWriteEnabled := true;
    alphaBlendingEnabled := false;
}

// Allocate, init and register a new shader.
create_shader :: (renderer : *Renderer, id : string, options : ShaderOptions = .{}) -> *Shader {
    shader := cast(*Shader) Basic.New(Shader);
    Basic.remember_allocators(shader);
    shader_init(shader, renderer, id, options);
    renderer_register(renderer, shader);
    return shader;
}

destroy_shader :: (shader : *Shader, destroyResources : bool) {
    if destroyResources {
        for material : shader.materials {
            destroy_material(material);
        }
    }

    shader_cleanup(shader, resetMemory = false);

    if shader.allocator.proc != null {
        Basic.free(shader, shader.allocator);
    }
}

shader_init :: (shader : *Shader, renderer : *Renderer, id : string, options : ShaderOptions = .{}) {
    shader.renderer = renderer;
    shader.id = id;
    shader.options = options;
    impl_shader_init(shader);
}

shader_cleanup :: (shader : *Shader, resetMemory := true) {
    impl_shader_cleanup(shader);

    Basic.array_free(shader.materials);

    if resetMemory {
        <<shader = Shader.{};
    }
}

shader_update :: (shader : *Shader) {
    for material : shader.materials {
        material_update(material);
    }
}

shader_register :: (shader : *Shader, material : *Material) {
    Basic.array_add(*shader.materials, material);
}
