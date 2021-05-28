#scope_module

// @note We don't have _scene_draw here
// because renderers decide how to draw things directly.

impl_scene_init :: (scene : *Scene) {

}

impl_scene_register :: (scene : *Scene, renderer : *Renderer) {
    if scene.engine.device != null {
        _renderer_post_init(renderer);
    }
}

_scene_post_init :: (scene : *Scene) {
    for renderer : scene.renderers {
        _renderer_post_init(renderer);
    }
    for mesh : scene.meshes {
        _mesh_post_init(mesh);
    }
}

