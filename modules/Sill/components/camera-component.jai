CameraComponent :: struct {
    using #as component : Component;
    transform : *TransformComponent;

    eye : *Magma.Eye;
}

component_init :: (iCamera : *CameraComponent) {
    transform_on_world_transform_changed(iCamera.transform,
                                         (committed : bool, iCamera : *CameraComponent) { _camera_update_from_transform(iCamera); },
                                         iCamera);

    iCamera.eye = Magma.renderer_get_eye(iCamera.entity.engine.renderer, 0);
    _camera_update_from_transform(iCamera);
}

component_cleanup :: (iCamera : *CameraComponent, resetMemory := true) {
    // Nothing to do
}

component_update :: (iCamera : *CameraComponent, dt : float64) {
    // Nothing to do
}

#scope_file

_camera_update_from_transform :: (iCamera : *CameraComponent) {
    worldTransform := iCamera.transform.worldTransform;
    worldTransform.factor = 1.;
    orientationMatrix := Chamber.make_matrix(worldTransform, Chamber.mat4);
    iCamera.eye.viewMatrix = Chamber.inverse_and_prepare_for_projection(orientationMatrix);
    Magma.eye_commit(iCamera.eye);
}
