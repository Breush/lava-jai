#scope_module

/*
    A renderer is capable of rendering an image or more.

    Usually, they are things like ForwardRenderer or PostProcesses and
    inputs of PostProcesses and Targets.
*/
Renderer :: struct {
    Kind :: enum {
        Unknown :: 0;
        ForwardRenderer;
        RayTracingRenderer;
        PostProcessRenderer;
    }

    scene : *Scene;
    kind : Kind;

    shaders : [..]*Shader;

    using rendererImpl : RendererImpl;

    allocator : Allocator;
}

destroy_renderer :: (renderer : *Renderer, destroyResources : bool) {
    if destroyResources {
        for shader : renderer.shaders {
            destroy_shader(shader, destroyResources);
        }
    }

    renderer_cleanup(renderer, resetMemory = false);

    if renderer.allocator.proc != null {
        Basic.free(renderer, renderer.allocator);
    }
}

renderer_cleanup :: (renderer : *Renderer, resetMemory := true) {
    impl_renderer_cleanup(renderer);

    Basic.array_free(renderer.shaders);

    if renderer.kind == .ForwardRenderer {
        _forward_renderer_cleanup(cast(*ForwardRenderer) renderer, resetMemory);
    } else if renderer.kind == .PostProcessRenderer {
        _post_process_renderer_cleanup(cast(*PostProcessRenderer) renderer, resetMemory);
    } else if renderer.kind == .RayTracingRenderer {
        _ray_tracing_renderer_cleanup(cast(*RayTracingRenderer) renderer, resetMemory);
    } else {
        Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    }
}

renderer_make_orbit_camera :: (renderer : *Renderer, eyeIndex : u32 = 0) -> OrbitCamera {
    orbitCamera : OrbitCamera;
    orbit_camera_init(*orbitCamera, renderer_get_eye(renderer, eyeIndex));
    return orbitCamera;
}

renderer_find_shader :: (renderer : *Renderer, id : string) -> *Shader {
    for shader : renderer.shaders {
        if shader.id == id {
            return shader;
        }
    }
    return null;
}

renderer_get_eye :: (renderer : *Renderer, eyeIndex : u32) -> *Eye {
    if renderer.kind == .ForwardRenderer then return forward_renderer_get_eye(cast(*ForwardRenderer) renderer, eyeIndex);
    if renderer.kind == .RayTracingRenderer then return ray_tracing_renderer_get_eye(cast(*RayTracingRenderer) renderer, eyeIndex);
    if renderer.kind == .PostProcessRenderer then return renderer_get_eye((cast(*PostProcessRenderer) renderer).rendererOutput.renderer, eyeIndex);
    Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    return null;
}

renderer_get_extent :: (renderer : *Renderer, outputIndex : u32) -> Chamber.uvec2 {
    if renderer.kind == .ForwardRenderer then return forward_renderer_get_extent(cast(*ForwardRenderer) renderer, outputIndex);
    if renderer.kind == .RayTracingRenderer then return ray_tracing_renderer_get_extent(cast(*RayTracingRenderer) renderer, outputIndex);
    if renderer.kind == .PostProcessRenderer then return post_process_renderer_get_extent(cast(*PostProcessRenderer) renderer, outputIndex);
    Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    return .{};
}

renderer_get_material_descriptor_set_index :: (renderer : *Renderer) -> u32 {
    if renderer.kind == .ForwardRenderer {
        return ForwardRenderer.MATERIAL_DESCRIPTOR_SET_INDEX;
    } else if renderer.kind == .PostProcessRenderer {
        return PostProcessRenderer.MATERIAL_DESCRIPTOR_SET_INDEX;
    }
    Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    return 0xFFFF_FFFF;
}

renderer_get_output :: (renderer : *Renderer, outputIndex : u8 = 0) -> RendererOutput {
    output : RendererOutput;
    output.renderer = renderer;
    output.index = outputIndex;
    return output;
}

renderer_register :: (renderer : *Renderer, shader : *Shader) {
    Basic.array_add(*renderer.shaders, shader);
}

// ----- Renderer output

RendererOutput :: struct {
    renderer : *Renderer;
    index : u8;
}

renderer_output_get_extent :: (output : RendererOutput) -> Chamber.uvec2 {
    if output.renderer.kind == .ForwardRenderer {
        return impl_forward_renderer_get_output_extent(cast(*ForwardRenderer) output.renderer, output.index);
    } else if output.renderer.kind == .RayTracingRenderer {
        return impl_ray_tracing_renderer_get_output_extent(cast(*RayTracingRenderer) output.renderer, output.index);
    } else if output.renderer.kind == .PostProcessRenderer {
        return impl_post_process_renderer_get_output_extent(cast(*PostProcessRenderer) output.renderer, output.index);
    }

    Basic.log("Unhandled renderer kind: %.", output.renderer, flags=.ERROR);
    return .{};
}

// ----- Forward

/*
    A forward renderer draws meshes the simple way.

    It is usually fast enough except if you have multiple
    dynamic lights or complex lighting shaders.

    The main difference with DeferredRenderer is that we might
    uselessly compute lighting of a fragment that might be hidden behind
    another one.
    But the cost of a DeferredRenderer is memory, and that is something
    that we cannot afford in VR environment for instance.
*/
ForwardRenderer :: struct {
    using renderer : Renderer;
    using forwardRendererImpl : ForwardRendererImpl;

    eye : Eye;

    MATERIAL_DESCRIPTOR_SET_INDEX :: 0;
}

// Allocate, init and register a new forward renderer.
create_forward_renderer :: (scene : *Scene, extent : Chamber.uvec2) -> *ForwardRenderer {
    forwardRenderer := cast(*ForwardRenderer) Basic.New(ForwardRenderer);
    forwardRenderer.kind = Renderer.Kind.ForwardRenderer;
    Basic.remember_allocators(forwardRenderer);
    forward_renderer_init(forwardRenderer, scene, extent);
    scene_register(scene, forwardRenderer);
    return forwardRenderer;
}

forward_renderer_init :: (forwardRenderer : *ForwardRenderer, scene : *Scene, extent : Chamber.uvec2) {
    _renderer_init(forwardRenderer, scene);
    eye_init(*forwardRenderer.eye, extent);

    impl_forward_renderer_init(forwardRenderer);
}

forward_renderer_get_eye :: (forwardRenderer : *ForwardRenderer, eyeIndex : u32) -> *Eye {
    if eyeIndex == 0 then return *forwardRenderer.eye;
    return null;
}

forward_renderer_get_extent :: (forwardRenderer : *ForwardRenderer, eyeIndex : u32) -> Chamber.uvec2 {
    if eyeIndex == 0 then return forwardRenderer.eye.extent;
    return .{};
}

forward_renderer_extent :: (forwardRenderer : *ForwardRenderer, extent : Chamber.uvec2) {
    forwardRenderer.eye.extent = extent;
    impl_forward_renderer_update_from_eye(forwardRenderer);
}

// ----- Ray tracing

RayTracingRenderer :: struct {
    using renderer : Renderer;
    using rayTracingRendererImpl : RayTracingRendererImpl;

    eye : Eye;
}

create_ray_tracing_renderer :: (scene : *Scene, extent : Chamber.uvec2) -> *RayTracingRenderer {
    rayTracingRenderer := cast(*RayTracingRenderer) Basic.New(RayTracingRenderer);
    rayTracingRenderer.kind = Renderer.Kind.RayTracingRenderer;
    Basic.remember_allocators(rayTracingRenderer);
    ray_tracing_renderer_init(rayTracingRenderer, scene, extent);
    scene_register(scene, rayTracingRenderer);
    return rayTracingRenderer;
}

ray_tracing_renderer_init :: (rayTracingRenderer : *RayTracingRenderer, scene : *Scene, extent : Chamber.uvec2) {
    _renderer_init(rayTracingRenderer, scene);
    eye_init(*rayTracingRenderer.eye, extent);

    impl_ray_tracing_renderer_init(rayTracingRenderer);
}

ray_tracing_renderer_get_eye :: (rayTracingRenderer : *RayTracingRenderer, eyeIndex : u32) -> *Eye {
    if eyeIndex == 0 then return *rayTracingRenderer.eye;
    return null;
}

ray_tracing_renderer_get_extent :: (rayTracingRenderer : *RayTracingRenderer, eyeIndex : u32) -> Chamber.uvec2 {
    if eyeIndex == 0 then return rayTracingRenderer.eye.extent;
    return .{};
}

// ----- Post process

/*
    A post-process renderer takes an input (called source)
    and tweak it using a specific "material" that implements
    image-based post-processing.

    Once you created a PostProcessRenderer with a specific source,
    you'll have to create a shader on it and materials.
    All materials registered will be called once
    on a fullscreen image with "source" being the bound rendererOutput
    at the creation of the post-process renderer.
*/
PostProcessRenderer :: struct {
    using renderer : Renderer;
    using postProcessRendererImpl : PostProcessRendererImpl;

    rendererOutput : RendererOutput;

    SOURCE_DESCRIPTOR_SET_INDEX :: 0;
    MATERIAL_DESCRIPTOR_SET_INDEX :: 1;
}

// Allocate, init and register a new post process.
create_post_process_renderer :: (scene : *Scene, rendererOutput : RendererOutput) -> *PostProcessRenderer {
    postProcessRenderer := cast(*PostProcessRenderer) Basic.New(PostProcessRenderer);
    postProcessRenderer.kind = Renderer.Kind.PostProcessRenderer;
    Basic.remember_allocators(postProcessRenderer);
    post_process_renderer_init(postProcessRenderer, scene, rendererOutput);
    // @todo We probably don't really to register to a scene.
    // But this is forced due to us being a renderer.
    scene_register(scene, postProcessRenderer);
    return postProcessRenderer;
}

post_process_renderer_init :: (postProcessRenderer : *PostProcessRenderer, scene : *Scene, rendererOutput : RendererOutput) {
    _renderer_init(postProcessRenderer, scene);
    postProcessRenderer.rendererOutput = rendererOutput;
}

post_process_renderer_get_extent :: (postProcessRenderer : *PostProcessRenderer, eyeIndex : u32) -> Chamber.uvec2 {
    if eyeIndex == 0 then return renderer_output_get_extent(postProcessRenderer.rendererOutput);
    return .{};
}

#scope_file

_renderer_init :: (renderer : *Renderer, scene : *Scene) {
    renderer.scene = scene;
}

_forward_renderer_cleanup :: (forwardRenderer : *ForwardRenderer, resetMemory : bool) {
    impl_forward_renderer_cleanup(forwardRenderer);

    if resetMemory {
        <<forwardRenderer = .{};
    }
}

_ray_tracing_renderer_cleanup :: (rayTracingRenderer : *RayTracingRenderer, resetMemory : bool) {
    impl_ray_tracing_renderer_cleanup(rayTracingRenderer);

    if resetMemory {
        <<rayTracingRenderer = .{};
    }
}

_post_process_renderer_cleanup :: (postProcessRenderer : *PostProcessRenderer, resetMemory : bool) {
    impl_post_process_renderer_cleanup(postProcessRenderer);

    if resetMemory {
        <<postProcessRenderer = .{};
    }
}
