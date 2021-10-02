TransformComponent :: struct {
    using component : Component;

    using transform : Chamber.trf;
    worldTransform : Chamber.trf;

    worldTransformChangedCallbacks : [..]struct {
        function : WorldTransformChangedCallbackType;
        userData : *void;
    };

    WorldTransformChangedCallbackType :: #type (userData : *void);
}

component_init :: (iTransform : *TransformComponent) {
    // Nothing to do
}

component_cleanup :: (iTransform : *TransformComponent, resetMemory := true) {
    Basic.array_free(iTransform.worldTransformChangedCallbacks);

    if resetMemory {
        <<iTransform = TransformComponent.{};
    }
}

component_update :: (iTransform : *TransformComponent, dt : float64) {
    // Nothing to do
}

transform_set :: (iTransform : *TransformComponent, transform : Chamber.trf) {
    iTransform.transform = transform;
    _update_world_transform(iTransform);
}

transform_translate :: (iTransform : *TransformComponent, delta : Chamber.vec3) {
    if abs(delta.x) < 0.001 && abs(delta.y) < 0.001 && abs(delta.z) < 0.001 then return;

    iTransform.translation.std += delta;
    _update_world_transform(iTransform);
}

transform_rotate :: (iTransform : *TransformComponent, angle : float32, axis : Chamber.vec3) {
    if abs(angle) < 0.001 then return;

    rotationDelta : Chamber.quat = ---;
    set_from_axis_and_angle(*rotationDelta, axis, angle);
    iTransform.rotation = rotationDelta * iTransform.rotation;
    _update_world_transform(iTransform);
}

transform_scale :: (iTransform : *TransformComponent, scaleFactor : float32) {
    if abs(scaleFactor - 1.) < 0.001 then return;

    iTransform.factor *= scaleFactor;
    _update_world_transform(iTransform);
}

transform_origin_target :: (iTransform : *TransformComponent, origin : Chamber.vec3, target : Chamber.vec3, referenceUp := Chamber.vec3.{0, 0, 1}) {
    iTransform.translation = origin;
    // @todo @speed Could probably be optimized, no need to compute a temporary matrix here.
    iTransform.rotation = get_rotation(Chamber.orientation_matrix(origin, target, referenceUp));
    _update_world_transform(iTransform);
}

transform_on_world_transform_changed :: (iTransform : *TransformComponent, function : TransformComponent.WorldTransformChangedCallbackType, userData : *void) {
    Basic.array_add(*iTransform.worldTransformChangedCallbacks, .{});
    callback := Basic.peek_pointer(iTransform.worldTransformChangedCallbacks);
    callback.function = function;
    callback.userData = userData;
}

#scope_file

_update_world_transform :: (iTransform : *TransformComponent) {
    // @todo No entity parenting yet, so no difference between world and local transforms.
    iTransform.worldTransform = iTransform.transform;
    _call_world_transform_changed_callbacks(iTransform);
}

_call_world_transform_changed_callbacks :: (iTransform : *TransformComponent) {
    for callback : iTransform.worldTransformChangedCallbacks {
        callback.function(callback.userData);
    }
}

#import "Math";
