#scope_module

/*
    An Engine is the heart of the rendering system.
    Multiple can exist at once, but they do not share data.

    @todo Complete description
*/

Engine :: struct {
    Options :: struct {
        TargetFlags :: enum_flags {
            None :: 0;
            Window :: 1;
        }

        targetFlags : TargetFlags = .Window;
    }

    options : Options;

    scenes : [..]*Scene;
    targets : [..]*Target;

    using engineImpl : EngineImpl;

    allocator : Allocator;
    allocator_data : *void;
}

create_engine :: (options : Engine.Options = .{}) -> *Engine {
    engine := cast(*Engine) Basic.New(Engine);
    Basic.remember_allocators(engine);
    engine_init(engine);
    return engine;
}

destroy_engine :: (engine : *Engine, destroyResources := true) {
    if destroyResources {
        for scene : engine.scenes {
            destroy_scene(scene, true);
        }
        for target : engine.targets {
            destroy_target(target);
        }
    }

    engine_cleanup(engine);

    // Cleanup ourselves
    if engine.allocator != null {
        Basic.free(engine, engine.allocator, engine.allocator_data);
    }
}

engine_init :: (engine : *Engine, _options : Engine.Options = .{}) {
    engine.options = _options;
    impl_engine_init(engine);
}

engine_cleanup :: (engine : *Engine) {
    impl_engine_cleanup(engine);

    Basic.array_free(engine.scenes);
    Basic.array_free(engine.targets);

    // Reset memory
    <<engine = Engine.{};
}

engine_update :: (engine : *Engine) {
    for scene : engine.scenes {
        scene_update(scene);
    }
}

engine_draw :: (engine : *Engine) {
    impl_engine_draw(engine);
}

engine_register :: (engine : *Engine, target : *Target) {
    Basic.array_add(*engine.targets, target);
    impl_engine_register(engine, target);
}

engine_register :: (engine : *Engine, scene : *Scene) {
    Basic.array_add(*engine.scenes, scene);
    impl_engine_register(engine, scene);
}
