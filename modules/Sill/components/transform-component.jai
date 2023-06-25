TransformComponent :: struct {
    using #as component : Component;

    using transform : Chamber.trf;
    worldTransform : Chamber.trf;

    worldTransformChangedCallbacks : [..]struct {
        function : WorldTransformChangedCallbackType;
        userData : *void;
    };

    // committed means that the user specifically said the transform is finished
    // modifying, so no need to cache.
    WorldTransformChangedCallbackType :: #type (committed : bool, userData : *void);
}

component_init :: (iTransform : *TransformComponent) {
    // Nothing to do
}

component_cleanup :: (iTransform : *TransformComponent, resetMemory := true) {
    Basic.array_free(iTransform.worldTransformChangedCallbacks);

    if resetMemory {
        iTransform.* = .{};
    }
}

component_update :: (iTransform : *TransformComponent, dt : float64) {
    // @todo We're missing updates here, but for now it is not impactful,
    // and does not worth the performance hit. (i.e. just commit the transform when you modify the parent)
    // if iTransform.entity.parentChanged {
    //     _update_world_transform(iTransform);
    // }
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

transform_commit :: (iTransform : *TransformComponent) {
    _update_world_transform(iTransform, committed = true);
}

transform_origin_target :: (iTransform : *TransformComponent, origin : Chamber.vec3, target : Chamber.vec3, referenceUp := Chamber.vec3.{0, 0, 1}) {
    iTransform.translation = origin;
    // @todo @speed Could probably be optimized, no need to compute a temporary matrix here.
    iTransform.rotation = get_rotation(Chamber.orientation_matrix(origin, target, referenceUp));
    _update_world_transform(iTransform);
}

transform_on_world_transform_changed :: (iTransform : *TransformComponent, function : (committed : bool, userData : *$T), userData : *T = null) {
    callback := Basic.array_add(*iTransform.worldTransformChangedCallbacks);
    callback.function = cast(TransformComponent.WorldTransformChangedCallbackType) function;
    callback.userData = userData;
}

#scope_file

_update_world_transform :: (iTransform : *TransformComponent, committed := false) {
    if iTransform.entity.parent != null {
        // @note The world transform updates are done instantly, so it should be up-to-date.
        iParentTransform := entity_get_component(iTransform.entity.parent, TransformComponent);
        if iParentTransform != null {
            iTransform.worldTransform = Chamber.multiply(iParentTransform.worldTransform, iTransform.transform);
        } else {
            iTransform.worldTransform = iTransform.transform;
        }
    } else {
        iTransform.worldTransform = iTransform.transform;
    }

    // Update children position
    for child : iTransform.entity.children {
        _update_world_transform(entity_get_component(child, TransformComponent), committed);
    }

    // Call callbacks
    for callback : iTransform.worldTransformChangedCallbacks {
        callback.function(committed, callback.userData);
    }
}

#import "Math";
