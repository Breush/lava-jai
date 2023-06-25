#scope_module

#load "holders.jai";

_CHECK :: Chamber._CHECK;
_CHECK_NON_FATAL :: Chamber._CHECK_NON_FATAL;

_wait_timeline_semaphore :: (device : Vk.Device, semaphore : Vk.Semaphore, value : u64) {
    semaphoreWI : Vk.SemaphoreWaitInfo ;
    semaphoreWI.sType = .SemaphoreWaitInfo;
    semaphoreWI.semaphoreCount = 1;
    semaphoreWI.pSemaphores = *semaphore;
    semaphoreWI.pValues = *value;

    Vk.wait_semaphores(device, *semaphoreWI, ~0);
}

_signal_timeline_semaphore :: (device : Vk.Device, semaphore : Vk.Semaphore, value : u64) {
    semaphoreSI : Vk.SemaphoreSignalInfo ;
    semaphoreSI.sType = .SemaphoreSignalInfo;
    semaphoreSI.semaphore = semaphore;
    semaphoreSI.value = value;

    Vk.signal_semaphore(device, *semaphoreSI);
}

_create_graphics_command_pool :: (engine : *Engine, commandPool : *Vk.CommandPool, flagReset : bool) -> bool {
    commandPoolCI : Vk.CommandPoolCreateInfo;
    commandPoolCI.sType = .CommandPoolCreateInfo;
    commandPoolCI.queueFamilyIndex = cast(u32) engine.queueIndices.graphics;
    if flagReset {
        commandPoolCI.flags = cast(u32) Vk.CommandPoolCreateFlagBits.ResetCommandBuffer;
    }

    _CHECK(Vk.create_command_pool(engine.device, *commandPoolCI, null, commandPool),
           "Unable to create command pool.");
    return true;
}

_change_image_layout :: (engine : *Engine, image : Vk.Image, srcImageUsage : ImageUsageKind, dstImageUsage : ImageUsageKind) {
    commandBuffer := _one_time_command_buffer_begin(engine.device, engine.graphicsCommandPool);
    _change_image_layout(commandBuffer, image, srcImageUsage, dstImageUsage);
    _one_time_command_buffer_end(commandBuffer, engine.device, engine.graphicsCommandPool, engine.graphicsQueue);
}

_change_image_layout :: (commandBuffer : Vk.CommandBuffer, image : Vk.Image, srcImageUsage : ImageUsageKind, dstImageUsage : ImageUsageKind) {
    srcLayout := Vk.ImageLayout.Undefined;
    dstLayout := Vk.ImageLayout.Undefined;
    srcAccessMask : Vk.AccessFlagBits;
    dstAccessMask : Vk.AccessFlagBits;
    srcStageMask := Vk.PipelineStageFlagBits.BottomOfPipe;
    dstStageMask := Vk.PipelineStageFlagBits.TopOfPipe;

    if srcImageUsage == .TransferOutput {
        srcLayout = .TransferDstOptimal;
        srcAccessMask = .TransferWrite;
        srcStageMask = .Transfer;
    } else if srcImageUsage == .TransferInput {
        srcLayout = .TransferSrcOptimal;
        srcAccessMask = .TransferRead;
        srcStageMask = .Transfer;
    } else if srcImageUsage == .FragmentInput {
        srcLayout = .ShaderReadOnlyOptimal;
        srcAccessMask = .ShaderRead;
        srcStageMask = .FragmentShader;
    } else if srcImageUsage == .FragmentOutput {
        srcLayout = .ShaderReadOnlyOptimal;
        srcAccessMask = .ShaderRead;
        srcStageMask = .FragmentShader;
    } else if dstImageUsage == .RayTracingOutput {
        dstLayout = .General;
        dstAccessMask = .ShaderWrite;
        dstStageMask = .RayTracingShaderKhr;
    } else if srcImageUsage == .DontCare {
        /* Nothing to do */
    } else {
        Basic.log("Unhandled image usage kind: %.", srcImageUsage, flags=.ERROR);
    }

    if dstImageUsage == .TransferOutput {
        dstLayout = .TransferDstOptimal;
        dstAccessMask = .TransferWrite;
        dstStageMask = .Transfer;
    } else if dstImageUsage == .TransferInput {
        dstLayout = .TransferSrcOptimal;
        dstAccessMask = .TransferRead;
        dstStageMask = .Transfer;
    } else if dstImageUsage == .FragmentInput {
        dstLayout = .ShaderReadOnlyOptimal;
        dstAccessMask = .ShaderRead;
        dstStageMask = .FragmentShader;
    } else if dstImageUsage == .FragmentOutput {
        dstLayout = .ShaderReadOnlyOptimal;
        dstAccessMask = .ShaderRead;
        dstStageMask = .FragmentShader;
    } else if dstImageUsage == .RayTracingOutput {
        dstLayout = .General;
        dstAccessMask = .ShaderWrite;
        dstStageMask = .RayTracingShaderKhr;
    } else if dstImageUsage == .PresentInput {
        dstLayout = .PresentSrcKhr;
    } else if dstImageUsage == .DontCare {
        /* Nothing to do */
    } else {
        Basic.log("Unhandled image usage kind: %.", dstImageUsage, flags=.ERROR);
    }

    imageMemoryBarrier : Vk.ImageMemoryBarrier;
    imageMemoryBarrier.sType = .ImageMemoryBarrier;
    imageMemoryBarrier.oldLayout = srcLayout;
    imageMemoryBarrier.newLayout = dstLayout;
    imageMemoryBarrier.srcAccessMask = cast(u32) srcAccessMask;
    imageMemoryBarrier.dstAccessMask = cast(u32) dstAccessMask;
    imageMemoryBarrier.image = image;
    imageMemoryBarrier.subresourceRange.levelCount = 1;
    imageMemoryBarrier.subresourceRange.layerCount = 1;
    imageMemoryBarrier.subresourceRange.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;

    Vk.cmd_pipeline_barrier(commandBuffer, cast(u32) srcStageMask, cast(u32) dstStageMask, 0, 0, null, 0, null, 1, *imageMemoryBarrier);
}

_one_time_command_buffer_begin :: (device : Vk.Device, commandPool : Vk.CommandPool) -> Vk.CommandBuffer {
    commandBuffer : Vk.CommandBuffer;

    commandBufferAI : Vk.CommandBufferAllocateInfo;
    commandBufferAI.sType = .CommandBufferAllocateInfo;
    commandBufferAI.commandPool = commandPool;
    commandBufferAI.commandBufferCount = 1;
    commandBufferAI.level = .Primary;
    _CHECK(Vk.allocate_command_buffers(device, *commandBufferAI, *commandBuffer), null,
           "Unable to allocate one-time command buffer.");

    commandBufferBI : Vk.CommandBufferBeginInfo;
    commandBufferBI.sType = .CommandBufferBeginInfo;
    commandBufferBI.flags = cast(u32) Vk.CommandBufferUsageFlagBits.OneTimeSubmit;
    Vk.begin_command_buffer(commandBuffer, *commandBufferBI);

    return commandBuffer;
}

_one_time_command_buffer_end :: (commandBuffer : Vk.CommandBuffer, device : Vk.Device, commandPool : Vk.CommandPool, queue : Vk.Queue) -> bool {
    Vk.end_command_buffer(commandBuffer);

    fence : Vk.Fence;
    fenceCI : Vk.FenceCreateInfo;
    fenceCI.sType = .FenceCreateInfo;

    _CHECK(Vk.create_fence(device, *fenceCI, null, *fence), "Unable to create fence for one-time command buffer.");

    // Submit indeed
    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = .SubmitInfo;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    _CHECK(Vk.queue_submit(queue, 1, *submitInfo, fence),
           "Unable to submit one-time command buffer.");

    Vk.wait_for_fences(device, 1, *fence, Vk.TRUE, ~0);
    Vk.destroy_fence(device, fence, null);
    Vk.free_command_buffers(device, commandPool, 1, *commandBuffer);

    return true;
}

_select_best_memory_type_index :: (engine : *Engine, typeFilter : u32, memoryPropertyFlags : Vk.MemoryPropertyFlags) -> u32 {
    for i : 0..engine.physicalDeviceMemoryProperties.memoryTypeCount - 1 {
        if (typeFilter & (1 << i)) &&
           (engine.physicalDeviceMemoryProperties.memoryTypes[i].propertyFlags & memoryPropertyFlags) == memoryPropertyFlags {
            return i;
        }
    }

    _CHECK(false, 0, "Unable to find suitable memory type.");
    return 0;
}

_set_debug_utils_name :: (device : Vk.Device, objectHandle : u64, objectType : Vk.ObjectType, name : *u8) {
    debugUtilsObjectNI : Vk.DebugUtilsObjectNameInfoEXT;
    debugUtilsObjectNI.sType = .DebugUtilsObjectNameInfoExt;
    debugUtilsObjectNI.objectHandle = objectHandle;
    debugUtilsObjectNI.objectType = objectType;
    debugUtilsObjectNI.pObjectName = name;

    Vk.set_debug_utils_object_name_ext(device, *debugUtilsObjectNI);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.CommandBuffer, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.CommandBuffer, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Buffer, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Buffer, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Image, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Image, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.ImageView, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.ImageView, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Fence, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Fence, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Semaphore, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Semaphore, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Framebuffer, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Framebuffer, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.CommandPool, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.CommandPool, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.PipelineLayout, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.PipelineLayout, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.DescriptorSet, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.DescriptorSet, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.DeviceMemory, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.DeviceMemory, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.AccelerationStructureKHR, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.AccelerationStructureKhr, name);
}
