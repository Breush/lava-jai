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
    }

    scene : *Scene;
    kind : Kind;

    using rendererImpl : RendererImpl;
}

renderer_cleanup :: (renderer : *Renderer) {
    impl_renderer_cleanup(renderer);

    if renderer.kind == Renderer.Kind.ForwardRenderer {
        _forward_renderer_cleanup(cast(*ForwardRenderer) renderer);
    }
}

renderer_make_orbit_camera :: (renderer : *Renderer, eyeIndex : u32 = 0) -> OrbitCamera {
    orbitCamera : OrbitCamera;
    orbit_camera_init(*orbitCamera, renderer_get_eye(renderer, eyeIndex));
    return orbitCamera;
}

renderer_get_eye :: (renderer : *Renderer, eyeIndex : u32) -> *Eye {
    if renderer.kind == .ForwardRenderer then return forward_renderer_get_eye(cast(*ForwardRenderer) renderer, eyeIndex);
    return null;
}

/*
    A forward renderer draw meshes the simple way.

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

    allocator : Allocator;
    allocator_data : *void;
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

#scope_file

_renderer_init :: (renderer : *Renderer, scene : *Scene) {
    renderer.scene = scene;
}

_forward_renderer_cleanup :: (forwardRenderer : *ForwardRenderer) {
    impl_forward_renderer_cleanup(forwardRenderer);

    // Reset memory
    <<forwardRenderer = .{};
}
