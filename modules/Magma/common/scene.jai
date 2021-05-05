#scope_module

Scene :: struct {
    // Empty for now

    allocator : Allocator;
    allocator_data : *void;
}

// Allocate, init and register a new scene.
create_scene :: (engine : *Engine) -> *Scene {
    scene := cast(*Scene) Basic.New(Scene);
    Basic.remember_allocators(scene);
    scene_init(scene, engine);
    engine_register(engine, scene);
    return scene;
}

#scope_file
