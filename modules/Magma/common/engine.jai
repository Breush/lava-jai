#scope_module

#if VR_ENABLED {
    #load "openxr/vr.jai";
} else {
    #load "dummy/vr.jai";
}

/*
    An Engine is the heart of the rendering system.
    Multiple can exist at once, but they do not share data.

    @todo Complete description
*/

Engine :: struct {
    Options :: struct {
        FeatureFlag :: enum_flags {
            None;
            Window;     // Allows to use WindowTarget.
            Vr;         // Allows to use VR features. (Enables OpenXR integration.)
            RayTracing; // Allows to use RayTracingRenderer.
        }

        features : FeatureFlag = .Window;
    }

    options : Options;

    scenes : [..]*Scene;
    textures : [..]*Texture;
    targets : [..]*Target;

    vr : Vr;

    stats : struct {
        drawCalls : u32;
    }

    using engineImpl : EngineImpl;

    allocator : Allocator;
}

create_engine :: (options : Engine.Options = .{}) -> *Engine {
    engine := cast(*Engine) Basic.New(Engine);
    Basic.remember_allocators(engine);
    engine_init(engine, options);
    return engine;
}

destroy_engine :: (engine : *Engine, destroyResources := true) {
    if destroyResources {
        for scene : engine.scenes {
            destroy_scene(scene, destroyResources);
        }
        for target : engine.targets {
            destroy_target(target);
        }
        for texture : engine.textures {
            destroy_texture(texture);
        }
    }

    engine_cleanup(engine, resetMemory = false);

    // Cleanup ourselves
    if engine.allocator.proc != null {
        Basic.free(engine, engine.allocator);
    }
}

engine_init :: (engine : *Engine, options : Engine.Options) -> bool {
    engine.options = options;

    if VR_ENABLED && engine.options.features & .Vr {
        if !engine_vr_init(engine) {
            Basic.log("Unable to init engine with TargetFlags.Vr: VR is not available. Disabling VR capabilities.", flags=.WARNING);
        }
    }

    impl_engine_init(engine);
    return true;
}

engine_cleanup :: (engine : *Engine, resetMemory := true) {
    if engine.vr.enabled {
        engine_vr_cleanup(engine);
    }

    impl_engine_cleanup(engine);

    Basic.array_free(engine.scenes);
    Basic.array_free(engine.targets);
    Basic.array_free(engine.textures);

    if resetMemory {
        <<engine = Engine.{};
    }
}

engine_update :: (engine : *Engine) {
    for scene : engine.scenes {
        scene_update(scene);
    }

    for target : engine.targets {
        target_update(target);
    }
}

engine_draw :: (engine : *Engine) {
    engine.stats.drawCalls = 0;
    impl_engine_draw(engine);
}

engine_wait_idle :: (engine : *Engine) {
    impl_engine_wait_idle(engine);
}

engine_register :: (engine : *Engine, scene : *Scene) {
    Basic.array_add(*engine.scenes, scene);
}

engine_register :: (engine : *Engine, target : *Target) {
    Basic.array_add(*engine.targets, target);
    impl_engine_register(engine, target);
}

engine_register :: (engine : *Engine, texture : *Texture) {
    Basic.array_add(*engine.textures, texture);
}
