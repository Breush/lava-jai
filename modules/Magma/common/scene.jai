#scope_module

Scene :: struct {
    engine : *Engine;

    meshes : [..]*Mesh;
    renderers : [..]*Renderer;

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

destroy_scene :: (scene : *Scene, destroyResources : bool) {
    if destroyResources {
        for mesh : scene.meshes {
            mesh_cleanup(mesh);
        }
        for renderer : scene.renderers {
            renderer_cleanup(renderer);
        }
    }

    scene_cleanup(scene);

    // @todo :AutoUnregister There should be some scene_unregister() call
    // that is optionally called.

    // Cleanup ourselves
    if scene.allocator != null {
        Basic.free(scene, scene.allocator, scene.allocator_data);
    }
}

scene_init :: (scene : *Scene, engine : *Engine) {
    scene.engine = engine;
    impl_scene_init(scene);
}

scene_cleanup :: (scene : *Scene) {
    Basic.array_free(scene.renderers);

    // Reset memory
    <<scene = Scene.{};
}

scene_register :: (scene : *Scene, mesh : *Mesh) {
    Basic.array_add(*scene.meshes, mesh);
}

scene_register :: (scene : *Scene, renderer : *Renderer) {
    Basic.array_add(*scene.renderers, renderer);
    impl_scene_register(scene, renderer);
}

// Called by engine_update
scene_update :: (scene : *Scene) {
    for mesh : scene.meshes {
        mesh_update(mesh);
    }
}
