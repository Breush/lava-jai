File :: #import "File";

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
    window_target_init_pre_register(scene, engine, windowHandle);
    engine_register(engine, scene);
    window_target_init_post_register(scene);
    return scene;
}

#scope_file
