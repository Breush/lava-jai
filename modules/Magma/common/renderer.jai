#scope_module

/*
    A renderer is capable of rendering an image.
    Usually, they are Cameras or PostProcesses and
    inputs of PostProcesses and Targets.
*/
Renderer :: struct {
    Kind :: enum {
        Unknown :: 0;
        Camera;
    }

    engine : *Engine;

    kind : Kind;
    extent : Chamber.uvec2;

    using rendererImpl : RendererImpl;
}

renderer_cleanup :: (renderer : *Renderer) {
    impl_renderer_cleanup(renderer);

    if renderer.kind == Renderer.Kind.Camera {
        _camera_cleanup(cast(*Camera) renderer);
    }
}

/*
    A camera is a eye within a scene.

    It is defined with different properties,
    but everything can be summed up into two matrices:
        - The view matrix, which is the position/orientation of the camera
          in world-space.
        - The projection matrix, which is usually a perspective matrix transforming
          local coordinates into Normalized Device Coordinates.

    It is a renderer, which can be bound to a Target or a PostProcess.
*/
Camera :: struct {
    using renderer : Renderer;
    using cameraImpl : CameraImpl;

    allocator : Allocator;
    allocator_data : *void;
}

// Allocate, init and register a new camera.
create_camera :: (engine : *Engine, extent : Chamber.uvec2) -> *Camera {
    camera := cast(*Camera) Basic.New(Camera);
    camera.kind = Renderer.Kind.Camera;
    Basic.remember_allocators(camera);
    camera_init(camera, engine, extent);
    engine_register(engine, camera);
    return camera;
}

camera_init :: (camera : *Camera, engine : *Engine, extent : Chamber.uvec2) {
    _renderer_init(camera, engine, extent);
    impl_camera_init(camera);
}

#scope_file

_renderer_init :: (renderer : *Renderer, engine : *Engine, extent : Chamber.uvec2) {
    renderer.engine = engine;
    renderer.extent = extent;
}

_camera_cleanup :: (camera : *Camera) {
    impl_camera_cleanup(camera);

    // Reset memory
    <<camera = .{};
}
