#scope_module

Scene :: struct {
    engine : *Engine;

    meshes : [..]*Mesh;
    renderers : [..]*Renderer;
    // @note Just a tool to let us find it while sorting the meshes in forward-renderer.
    // If closures get supported in the language, this can be removed.
    currentRendererMaterialFallback : *Material;

    using sceneImpl : SceneImpl;

    allocator : Allocator;
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
            destroy_mesh(mesh, unregister = false);
        }
        for renderer : scene.renderers {
            destroy_renderer(renderer, destroyResources);
        }
    }

    scene_cleanup(scene, resetMemory = false);

    // @todo :AutoUnregister There should be some scene_unregister() call
    // that is optionally called.

    if scene.allocator.proc != null {
        Basic.free(scene, scene.allocator);
    }
}

scene_init :: (scene : *Scene, engine : *Engine) {
    scene.engine = engine;
    impl_scene_init(scene);
}

scene_cleanup :: (scene : *Scene, resetMemory := true) {
    impl_scene_cleanup(scene);

    Basic.array_free(scene.renderers);
    Basic.array_free(scene.meshes);

    if resetMemory {
        <<scene = Scene.{};
    }
}

scene_register :: (scene : *Scene, mesh : *Mesh) {
    Basic.array_add(*scene.meshes, mesh);
}

scene_unregister :: (scene : *Scene, mesh : *Mesh) {
    Basic.array_unordered_remove_by_value(*scene.meshes, mesh, stop_after_first = true);
}

scene_register :: (scene : *Scene, renderer : *Renderer) {
    Basic.array_add(*scene.renderers, renderer);
    impl_scene_register(scene, renderer);
}

// Called by engine_update
scene_update :: (scene : *Scene) {
    impl_scene_update(scene);

    for renderer : scene.renderers {
        renderer_update(renderer);
    }

    for mesh : scene.meshes {
        mesh_update(mesh);
    }
}
