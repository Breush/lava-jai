RayTracingRendererImpl :: struct {
    pipeline : Vk.Pipeline;

    sceneDescriptorHolder : DescriptorHolder; // Holds TLAS and object descriptions
    asInstances : [..]Vk.AccelerationStructureInstanceKHR;
    asInstancesBufferHolder : BufferHolder;

    pushConstantRanges : [1]Vk.PushConstantRange;

    outputDescriptorHolder : DescriptorHolder;
    extraFrameObjects : [Engine.FRAME_INDEX_COUNT]struct {
        outputImageHolder : ImageHolder;
        outputImageView : Vk.ImageView;
        outputDescriptorSet : Vk.DescriptorSet;

        tlasHolder : AsHolder;
        objectDescriptionsBufferHolder : BufferHolder;
        sceneDescriptorSet : Vk.DescriptorSet;
    };

    // @todo Own descriptor set for things stable like this?
    aoImageHolder : ImageHolder;
    aoImageView : Vk.ImageView;

    raygenSbtBufferHolder : BufferHolder;
    missSbtBufferHolder : BufferHolder;
    hitSbtBufferHolder : BufferHolder;
    sbtEntries : struct {
        raygen : Vk.StridedDeviceAddressRegionKHR;
        miss : Vk.StridedDeviceAddressRegionKHR;
        hit : Vk.StridedDeviceAddressRegionKHR;
        callable : Vk.StridedDeviceAddressRegionKHR;
    };

    ObjectDescription :: struct {
        verticesAddress : Vk.DeviceAddress;
        indicesAddress : Vk.DeviceAddress;
    };
    objectDescriptions : [..]ObjectDescription;

    OUTPUT_DESCRIPTOR_SET_INDEX :: 0;
    SCENE_DESCRIPTOR_SET_INDEX :: 1;

    FINAL_IMAGE_LAYOUT :: Vk.ImageLayout.General;
}

FrameShaderObject :: struct {
    frame : u32;
}

impl_ray_tracing_renderer_init :: (rayTracingRenderer : *RayTracingRenderer) {
    rayTracingRenderer.pushConstantRanges[0].size = size_of(EyeShaderObject) + size_of(FrameShaderObject);
    rayTracingRenderer.pushConstantRanges[0].stageFlags = cast(u32) Vk.ShaderStageFlagBits.RaygenKhr | Vk.ShaderStageFlagBits.ClosestHitKhr;
}

impl_ray_tracing_renderer_cleanup :: (using rayTracingRenderer : *RayTracingRenderer) {
    engine := scene.engine;

    Basic.array_free(objectDescriptions);
    Basic.array_free(asInstances);

    _descriptor_holder_cleanup(*sceneDescriptorHolder);
    _descriptor_holder_cleanup(*outputDescriptorHolder);

    _buffer_holder_cleanup(*asInstancesBufferHolder);
    _buffer_holder_cleanup(*raygenSbtBufferHolder);
    _buffer_holder_cleanup(*missSbtBufferHolder);
    _buffer_holder_cleanup(*hitSbtBufferHolder);

    for *extraFrameObject : extraFrameObjects {
        _image_holder_cleanup(*extraFrameObject.outputImageHolder);
        _buffer_holder_cleanup(*extraFrameObject.objectDescriptionsBufferHolder);
        _as_holder_cleanup(*extraFrameObject.tlasHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.outputImageView, null);
    }

    Vk.destroy_pipeline(engine.device, rayTracingRenderer.pipeline, null);
}

impl_ray_tracing_renderer_get_output_extent :: (rayTracingRenderer : *RayTracingRenderer, outputIndex : u8) -> Chamber.uvec2 {
    Basic.assert(outputIndex == 0);
    return rayTracingRenderer.eye.extent;
}

_ray_tracing_renderer_post_init :: (rayTracingRenderer : *RayTracingRenderer) -> bool {
    if !_init_pipeline(rayTracingRenderer) then return false;
    if !_init_extra_frame_objects(rayTracingRenderer) then return false;

    return true;
}

_ray_tracing_renderer_render :: (using rayTracingRenderer : *RayTracingRenderer, frameIndex : u8) -> bool {
    extraFrameObject := *extraFrameObjects[frameIndex];
    commandBuffer := frameObjects[frameIndex].commandBuffer;

    _update_tlas(rayTracingRenderer, commandBuffer, frameIndex);

    Vk.cmd_bind_pipeline(commandBuffer, .RayTracingKhr, pipeline);

    // Push constants
    frameShaderObject : FrameShaderObject; // @todo Temporary, probably SceneShaderObject.
    frameShaderObject.frame = rayTracingRenderer.frame;

    if eye.shaderObject.lastChangeFrame == 0xFFFF_FFFF {
        eye.shaderObject.lastChangeFrame = rayTracingRenderer.frame;
    }

    eyePushConstantStages := Vk.ShaderStageFlagBits.RaygenKhr | Vk.ShaderStageFlagBits.ClosestHitKhr;
    Vk.cmd_push_constants(commandBuffer, pipelineLayout, cast(u32) eyePushConstantStages, 0,
                          size_of(EyeShaderObject), *eye.shaderObject);
    Vk.cmd_push_constants(commandBuffer, pipelineLayout, cast(u32) eyePushConstantStages, size_of(EyeShaderObject),
                          size_of(FrameShaderObject), *frameShaderObject);

    Vk.cmd_bind_descriptor_sets(commandBuffer, .RayTracingKhr, pipelineLayout, OUTPUT_DESCRIPTOR_SET_INDEX, 1, *extraFrameObject.outputDescriptorSet, 0, null);
    Vk.cmd_bind_descriptor_sets(commandBuffer, .RayTracingKhr, pipelineLayout, SCENE_DESCRIPTOR_SET_INDEX, 1, *extraFrameObject.sceneDescriptorSet, 0, null);

    Vk.cmd_trace_rays_khr(commandBuffer, *sbtEntries.raygen, *sbtEntries.miss, *sbtEntries.hit, *sbtEntries.callable, eye.extent.width, eye.extent.height, 1);

    return true;
}

_ray_tracing_renderer_get_output_image_info :: (rayTracingRenderer : *RayTracingRenderer, outputIndex : u8, frameIndex : u8) -> ImageInfo {
    Basic.assert(outputIndex == 0);
    imageInfo : ImageInfo;
    imageInfo.image = rayTracingRenderer.extraFrameObjects[frameIndex].outputImageHolder.image;
    imageInfo.view = rayTracingRenderer.extraFrameObjects[frameIndex].outputImageView;
    imageInfo.layout = rayTracingRenderer.FINAL_IMAGE_LAYOUT;
    imageInfo.usage = .RayTracingOutput;
    return imageInfo;
}

#scope_file

_init_pipeline :: (using rayTracingRenderer : *RayTracingRenderer) -> bool {
    engine := scene.engine;

    // --- Pipeline Layout

    _descriptor_holder_init(*outputDescriptorHolder, engine, .{ storageImages = .[1, 1] });
    _descriptor_holder_init(*sceneDescriptorHolder, engine, .{ accelerationStructures = 1, storageBuffers = 1 });

    setLayouts : [2]Vk.DescriptorSetLayout = ---;
    setLayouts[OUTPUT_DESCRIPTOR_SET_INDEX] = outputDescriptorHolder.setLayout;
    setLayouts[SCENE_DESCRIPTOR_SET_INDEX] = sceneDescriptorHolder.setLayout;

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.setLayoutCount = setLayouts.count;
    pipelineLayoutCI.pSetLayouts = setLayouts.data;
    pipelineLayoutCI.pushConstantRangeCount = cast(u32) pushConstantRanges.count;
    pipelineLayoutCI.pPushConstantRanges = pushConstantRanges.data;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *pipelineLayout),
           "Unable to create pipeline layout.");
    _set_debug_utils_name(engine.device, pipelineLayout, "ray-tracing-renderer.pipelineLayout");

    // ----- Pipeline

    // -- Shaders

    rgenShaderModule := _engine_get_shader_module(engine, "$/ray-tracing-renderer/default", .Raygen);
    rgenShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    rgenShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    rgenShaderStageCI.stage = .RaygenKhr;
    rgenShaderStageCI.module = rgenShaderModule.vk;
    rgenShaderStageCI.pName = "main";

    missShaderModule := _engine_get_shader_module(engine, "$/ray-tracing-renderer/default", .Miss);
    missShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    missShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    missShaderStageCI.stage = .MissKhr;
    missShaderStageCI.module = missShaderModule.vk;
    missShaderStageCI.pName = "main";

    hitShaderModule := _engine_get_shader_module(engine, "$/ray-tracing-renderer/default", .ClosestHit);
    hitShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    hitShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    hitShaderStageCI.stage = .ClosestHitKhr;
    hitShaderStageCI.module = hitShaderModule.vk;
    hitShaderStageCI.pName = "main";

    shaderStages : [3]Vk.PipelineShaderStageCreateInfo;
    shaderStages[0] = rgenShaderStageCI;
    shaderStages[1] = missShaderStageCI;
    shaderStages[2] = hitShaderStageCI;

    // @todo Might be a good idea to automate that, somehow.
    shaderGroups : [3]Vk.RayTracingShaderGroupCreateInfoKHR;
    shaderGroups[0].sType = .RayTracingShaderGroupCreateInfoKhr;
    shaderGroups[0].type = .General;
    shaderGroups[0].generalShader = 0;
    shaderGroups[0].closestHitShader = 0xFFFF_FFFF;
    shaderGroups[0].anyHitShader = 0xFFFF_FFFF;
    shaderGroups[0].intersectionShader = 0xFFFF_FFFF;
    shaderGroups[1].sType = .RayTracingShaderGroupCreateInfoKhr;
    shaderGroups[1].type = .General;
    shaderGroups[1].generalShader = 1;
    shaderGroups[1].closestHitShader = 0xFFFF_FFFF;
    shaderGroups[1].anyHitShader = 0xFFFF_FFFF;
    shaderGroups[1].intersectionShader = 0xFFFF_FFFF;
    shaderGroups[2].sType = .RayTracingShaderGroupCreateInfoKhr;
    shaderGroups[2].type = .TrianglesHitGroup;
    shaderGroups[2].generalShader = 0xFFFF_FFFF;
    shaderGroups[2].closestHitShader = 2;
    shaderGroups[2].anyHitShader = 0xFFFF_FFFF;
    shaderGroups[2].intersectionShader = 0xFFFF_FFFF;

    pipelineCI : Vk.RayTracingPipelineCreateInfoKHR;
    pipelineCI.sType = .RayTracingPipelineCreateInfoKhr;
    pipelineCI.stageCount = shaderStages.count;
    pipelineCI.pStages = shaderStages.data;
    pipelineCI.layout = rayTracingRenderer.pipelineLayout;
    pipelineCI.groupCount = shaderGroups.count;
    pipelineCI.pGroups = shaderGroups.data;

    _CHECK(Vk.create_ray_tracing_pipelines_khr(engine.device, null, null, 1, *pipelineCI, null, *pipeline),
           "Unable to create ray tracing pipeline.");


    // -- Shader binding table

    pipelineProperties := *engine.physicalDeviceRayTracingPipelineProperties;
    handleSize := pipelineProperties.shaderGroupHandleSize;
    handleSizeAligned := Chamber.align_up(pipelineProperties.shaderGroupHandleSize, pipelineProperties.shaderGroupHandleAlignment);

    {
        groupCount := cast(u32) shaderGroups.count;
        sbtSize := groupCount * handleSizeAligned;

        shaderHandleStorage : [..]u8;
        Basic.array_resize(*shaderHandleStorage, sbtSize);
        defer Basic.array_free(shaderHandleStorage);
        Vk.get_ray_tracing_shader_group_handles_khr(engine.device, rayTracingRenderer.pipeline, 0, groupCount, cast(u64) shaderHandleStorage.count, shaderHandleStorage.data);

        _buffer_holder_init(*rayTracingRenderer.raygenSbtBufferHolder, engine, "ray-tracing-renderer.raygenSbtBufferHolder",
                            .ShaderBindingTable, .Direct, handleSize);
        _buffer_holder_copy(*rayTracingRenderer.raygenSbtBufferHolder, shaderHandleStorage.data, handleSize);
        rayTracingRenderer.sbtEntries.raygen.deviceAddress = _buffer_holder_device_address(*rayTracingRenderer.raygenSbtBufferHolder);
        rayTracingRenderer.sbtEntries.raygen.stride = handleSizeAligned;
        rayTracingRenderer.sbtEntries.raygen.size = handleSizeAligned;

        _buffer_holder_init(*rayTracingRenderer.missSbtBufferHolder, engine, "ray-tracing-renderer.missSbtBufferHolder",
                            .ShaderBindingTable, .Direct, handleSize);
        _buffer_holder_copy(*rayTracingRenderer.missSbtBufferHolder, shaderHandleStorage.data + handleSizeAligned, handleSize);
        rayTracingRenderer.sbtEntries.miss.deviceAddress = _buffer_holder_device_address(*rayTracingRenderer.missSbtBufferHolder);
        rayTracingRenderer.sbtEntries.miss.stride = handleSizeAligned;
        rayTracingRenderer.sbtEntries.miss.size = handleSizeAligned;

        _buffer_holder_init(*rayTracingRenderer.hitSbtBufferHolder, engine, "ray-tracing-renderer.hitSbtBufferHolder",
                            .ShaderBindingTable, .Direct, handleSize);
        _buffer_holder_copy(*rayTracingRenderer.hitSbtBufferHolder, shaderHandleStorage.data + 2 * handleSizeAligned, handleSize);
        rayTracingRenderer.sbtEntries.hit.deviceAddress = _buffer_holder_device_address(*rayTracingRenderer.hitSbtBufferHolder);
        rayTracingRenderer.sbtEntries.hit.stride = handleSizeAligned;
        rayTracingRenderer.sbtEntries.hit.size = handleSizeAligned;
    }

    return true;
}

_update_tlas :: (using rayTracingRenderer : *RayTracingRenderer, commandBuffer : Vk.CommandBuffer, frameIndex : u8) {
    engine := scene.engine;
    extraFrameObject := *extraFrameObjects[frameIndex];

    // @note We're just rebuilding the TLAS each frame,
    // it is adviced to rebuild it instead of just update each
    // individual BLAS. https://developer.nvidia.com/blog/rtx-best-practices/

    // @todo Should be affected by the number of instances in each mesh
    Basic.array_reserve(*asInstances, scene.meshes.count);
    asInstances.count = 0;

    for mesh, meshIndex : scene.meshes {
        asInstance : Vk.AccelerationStructureInstanceKHR;
        asInstance.instanceCustomIndex24_mask8 = (0xFF << 24) + cast(u32) meshIndex;
        asInstance.instanceShaderBindingTableRecordOffset24_flags8 = (cast(u32) Vk.GeometryInstanceFlagBitsKHR.TriangleFacingCullDisable << 24);
        asInstance.accelerationStructureReference = mesh.blasHolder.deviceAddress;

        // @note This is Vulkan's row-major convention, so we transpose.
        meshTransform := *mesh.instance.matrix;
        asInstance.transform.matrix[0][0] = meshTransform.coef[0][0];
        asInstance.transform.matrix[0][1] = meshTransform.coef[0][1];
        asInstance.transform.matrix[0][2] = meshTransform.coef[0][2];
        asInstance.transform.matrix[0][3] = meshTransform.coef[0][3];
        asInstance.transform.matrix[1][0] = meshTransform.coef[1][0];
        asInstance.transform.matrix[1][1] = meshTransform.coef[1][1];
        asInstance.transform.matrix[1][2] = meshTransform.coef[1][2];
        asInstance.transform.matrix[1][3] = meshTransform.coef[1][3];
        asInstance.transform.matrix[2][0] = meshTransform.coef[2][0];
        asInstance.transform.matrix[2][1] = meshTransform.coef[2][1];
        asInstance.transform.matrix[2][2] = meshTransform.coef[2][2];
        asInstance.transform.matrix[2][3] = meshTransform.coef[2][3];

        Basic.array_add(*asInstances, asInstance);
    }

    // @todo Below won't realloc if already the same size.
    // However:
    //   - We could have a distinction between "allocatedSize" and "size"
    //   - If the size changes, we currently don't free the old buffer
    // @todo The init/copy can be done within the same command buffer, we would just need a valid pipeline barrier
    _buffer_holder_init(*asInstancesBufferHolder, engine, "ray-tracing-renderer.asInstancesBufferHolder",
                        .AccelerationStructureInput, .Direct, cast(u64) asInstances.count * size_of(Vk.AccelerationStructureInstanceKHR));
    _buffer_holder_copy(*asInstancesBufferHolder, asInstances.data, cast(u64) asInstances.count * size_of(Vk.AccelerationStructureInstanceKHR));

    asGeometryInstancesData : Vk.AccelerationStructureGeometryInstancesDataKHR;
    asGeometryInstancesData.sType = .AccelerationStructureGeometryInstancesDataKhr;
    asGeometryInstancesData.data.deviceAddress = _buffer_holder_device_address(*asInstancesBufferHolder);

    asGeometry : Vk.AccelerationStructureGeometryKHR;
    asGeometry.sType = .AccelerationStructureGeometryKhr;
    asGeometry.flags = cast(u32) Vk.GeometryFlagBitsKHR.Opaque;
    asGeometry.geometryType = .Instances;
    asGeometry.geometry.instances = asGeometryInstancesData;

    _as_holder_init(*extraFrameObject.tlasHolder, engine, "ray-tracing-renderer.extraFrameObjects[].tlasHolder", .TopLevel, cast(u32) asInstances.count, asGeometry);
    _as_holder_build(*extraFrameObject.tlasHolder, commandBuffer);
    _descriptor_holder_update_set(*sceneDescriptorHolder, extraFrameObject.sceneDescriptorSet, extraFrameObject.tlasHolder.as);

    // Object descriptions

    Basic.array_reserve(*objectDescriptions, scene.meshes.count);
    objectDescriptions.count = 0;

    for mesh : scene.meshes {
        objectDescription : ObjectDescription;
        objectDescription.verticesAddress = _buffer_holder_device_address(*mesh.vertexBufferHolder);
        objectDescription.indicesAddress = _buffer_holder_device_address(*mesh.indexBufferHolder);

        Basic.array_add(*objectDescriptions, objectDescription);
    }

    _buffer_holder_init(*extraFrameObject.objectDescriptionsBufferHolder, engine, "ray-tracing-renderer.extraFrameObjects[].objectDescriptionsBufferHolder",
                        .ShaderStorage, .Direct, cast(u64) objectDescriptions.count * size_of(ObjectDescription));
    _buffer_holder_copy(*extraFrameObject.objectDescriptionsBufferHolder, objectDescriptions.data, cast(u64) objectDescriptions.count * size_of(ObjectDescription));
    _descriptor_holder_update_set(*sceneDescriptorHolder, extraFrameObject.sceneDescriptorSet, extraFrameObject.objectDescriptionsBufferHolder.buffer, extraFrameObject.objectDescriptionsBufferHolder.size);
}

_init_extra_frame_objects :: (rayTracingRenderer : *RayTracingRenderer) -> bool {
    engine := rayTracingRenderer.scene.engine;

    for *extraFrameObject : rayTracingRenderer.extraFrameObjects {
        extent := rayTracingRenderer.eye.extent;
        _image_holder_init(*extraFrameObject.outputImageHolder, engine, "rayTracingRenderer.extraFrameObjects[].imageHolder", .RendererOutStorage, extent);
        _change_image_layout(engine, extraFrameObject.outputImageHolder.image, .DontCare, .RayTracingOutput);

        extraFrameObject.outputImageView = _image_holder_create_view(*extraFrameObject.outputImageHolder);
        if extraFrameObject.outputImageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.outputImageView, "rayTracingRenderer.extraFrameObjects[].imageView");
    }

    // @fixme TODO: Running at half the size for AO
    extent := rayTracingRenderer.eye.extent;
    _image_holder_init(*rayTracingRenderer.aoImageHolder, engine, "rayTracingRenderer.aoImageHolder", .StorageR32, extent);
    _change_image_layout(engine, rayTracingRenderer.aoImageHolder.image, .DontCare, .RayTracingOutput);

    rayTracingRenderer.aoImageView = _image_holder_create_view(*rayTracingRenderer.aoImageHolder);
    if rayTracingRenderer.aoImageView == null then return false;
    _set_debug_utils_name(engine.device, rayTracingRenderer.aoImageView, "rayTracingRenderer.aoImageView");

    // Descriptor sets

    for *extraFrameObject : rayTracingRenderer.extraFrameObjects {
        extraFrameObject.sceneDescriptorSet = _descriptor_holder_allocate_set(*rayTracingRenderer.sceneDescriptorHolder);
        _set_debug_utils_name(engine.device, extraFrameObject.sceneDescriptorSet, "rayTracingRenderer.extraFrameObjects[].sceneDescriptorSet");

        extraFrameObject.outputDescriptorSet = _descriptor_holder_allocate_set(*rayTracingRenderer.outputDescriptorHolder);
        _set_debug_utils_name(engine.device, extraFrameObject.outputDescriptorSet, "rayTracingRenderer.extraFrameObjects[].descriptorSet");
        _descriptor_holder_update_set(*rayTracingRenderer.outputDescriptorHolder, extraFrameObject.outputDescriptorSet, extraFrameObject.outputImageView, .General, 0);
        _descriptor_holder_update_set(*rayTracingRenderer.outputDescriptorHolder, extraFrameObject.outputDescriptorSet, rayTracingRenderer.aoImageView, .General, 1);
    }

    return true;
}
