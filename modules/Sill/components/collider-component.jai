ColliderComponent :: struct {
    using component : Component;
    transform : *TransformComponent;

    boxShapes : [..]BoxShape;

    _shapesTransformsDirty := true;

    BoxShape :: struct {
        transform : Chamber.trf;
        extent : Chamber.vec3;

        worldTransform : Chamber.trf; @ReadOnly
    }
}

component_init :: (iCollider : *ColliderComponent) {
    transform_on_world_transform_changed(iCollider.transform,
                                         xx (iCollider : *ColliderComponent) { iCollider._shapesTransformsDirty = true; },
                                         iCollider);
}

component_cleanup :: (iCollider : *ColliderComponent, resetMemory := true) {
    Basic.array_free(iCollider.boxShapes);

    if resetMemory {
        <<iCollider = .{};
    }
}

component_update :: (iCollider : *ColliderComponent, dt : float64) {
    if iCollider._shapesTransformsDirty {
        collider_commit_shapes(iCollider, instantly = true);
    }
}

collider_commit_shapes :: (iCollider : *ColliderComponent, instantly := false) {
    iCollider._shapesTransformsDirty = !instantly;

    if instantly {
        for *boxShape : iCollider.boxShapes {
            boxShape.worldTransform = iCollider.transform.worldTransform * boxShape.transform;
        }
    }
}

collider_distance_from :: (iCollider : *ColliderComponent, ray : Chamber.Ray) -> float {
    distance := 0.0;

    for *boxShape : iCollider.boxShapes {
        // @fixme Need to really transform the ray into the box's local space,
        // and not just use the translation.
        distance = ray_intersect_aab(ray, boxShape.worldTransform.translation, boxShape.worldTransform.factor * boxShape.extent);
    }

    return distance;
}
