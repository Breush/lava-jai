#scope_module

SceneImpl :: struct {
    instancesBuckets : [..]InstancesBucket;

    InstancesBucket :: struct {
        bufferHolder : BufferHolder;
        inputs : [128]InstanceInput;
        freedCount : s32;
        nextIndex : s32;
        dirty : bool;
    }

    InstanceRef :: struct {
        bucketIndex : s32;
        inputIndex : s32;
    }
}

// @note We don't have _scene_draw here
// because renderers decide how to draw things directly.

impl_scene_init :: (scene : *Scene) {
}

impl_scene_cleanup :: (scene : *Scene) {
    for *bucket : scene.instancesBuckets {
        _buffer_holder_cleanup(*bucket.bufferHolder);
    }

    Basic.array_free(scene.instancesBuckets);
}

impl_scene_register :: (scene : *Scene, renderer : *Renderer) {
    if scene.engine.device != null {
        _renderer_post_init(renderer);
    }
}

impl_scene_update :: (scene : *Scene) -> bool {
    for mesh : scene.meshes {
        if !mesh.disabled && mesh.instanceDirty {
            scene.instancesBuckets[mesh.sharedInstanceRef.bucketIndex].inputs[mesh.sharedInstanceRef.inputIndex] = mesh.instance;
            scene.instancesBuckets[mesh.sharedInstanceRef.bucketIndex].dirty = true;
        }
    }

    if !_rebuild_instances_buffer(scene) then return false;

    return true;
}

_scene_post_init :: (scene : *Scene) {
    for renderer : scene.renderers {
        _renderer_post_init(renderer);
    }
    for mesh : scene.meshes {
        _mesh_post_init(mesh);
    }
}

_scene_share_instance :: (using scene : *Scene) -> Scene.InstanceRef {
    instanceRef : InstanceRef;

    availableBucket : *SceneImpl.InstancesBucket;

    for *bucket, bucketIndex : instancesBuckets {
        if bucket.nextIndex < bucket.inputs.count {
            availableBucket = bucket;
            instanceRef.bucketIndex = cast(s32) bucketIndex;
            break;
        }
    }

    if availableBucket == null {
        instanceRef.bucketIndex = cast(s32) instancesBuckets.count;
        availableBucket = Basic.array_add(*instancesBuckets);
        _buffer_holder_init(*availableBucket.bufferHolder, engine, "scene.instancesBuckets[].bufferHolder",
                            .ShaderVertex, .PersistentStaging, size_of(type_of(availableBucket.inputs)));
    }

    instanceRef.inputIndex = availableBucket.nextIndex;
    availableBucket.nextIndex += 1;
    availableBucket.dirty = true;

    return instanceRef;
}

_scene_unshare_instance :: (using scene : *Scene, instanceRef : Scene.InstanceRef) {
    instancesBuckets[instanceRef.bucketIndex].freedCount += 1;
    if instancesBuckets[instanceRef.bucketIndex].freedCount == instancesBuckets[instanceRef.bucketIndex].inputs.count {
        instancesBuckets[instanceRef.bucketIndex].nextIndex = 0;
        instancesBuckets[instanceRef.bucketIndex].freedCount = 0;
    }
}

_scene_instance_buffer_and_offset :: (using scene : *Scene, instanceRef : Scene.InstanceRef) -> (Vk.Buffer, Vk.DeviceSize) {
    bucket := instancesBuckets[instanceRef.bucketIndex];
    return bucket.bufferHolder.buffer, cast(Vk.DeviceSize) instanceRef.inputIndex * size_of(type_of(bucket.inputs[0]));
}

#scope_file

_rebuild_instances_buffer :: (using scene : *Scene) -> bool {
    for *bucket : instancesBuckets {
        if bucket.dirty {
            _buffer_holder_copy(*bucket.bufferHolder, bucket.inputs);
            bucket.dirty = false;
        }
    }
    return true;
}

