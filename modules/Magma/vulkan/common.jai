#scope_module

_CHECK :: (ok : bool, returnedValue : $T, message : ..Any) #expand {
    if !ok {
        // @todo Use official context logger.
        Chamber.debug(..message);
        Chamber.debug("\n");
        `return returnedValue;
    }
}

_CHECK :: (result : Vk.Result, returnedValue : $T, message : string) #expand {
    _CHECK(result == Vk.Result.Success, returnedValue, message, "(", result, ")");
}

_CHECK :: (result : Vk.Result, message : string) #expand {
    _CHECK(result, false, message);
}

_wait_timeline_semaphore :: (device : Vk.Device, semaphore : Vk.Semaphore, value : u64) {
    semaphoreWI : Vk.SemaphoreWaitInfo ;
    semaphoreWI.sType = Vk.StructureType.SemaphoreWaitInfo;
    semaphoreWI.semaphoreCount = 1;
    semaphoreWI.pSemaphores = *semaphore;
    semaphoreWI.pValues = *value;

    Vk.wait_semaphores(device, *semaphoreWI, ~0);
}

_signal_timeline_semaphore :: (device : Vk.Device, semaphore : Vk.Semaphore, value : u64) {
    semaphoreSI : Vk.SemaphoreSignalInfo ;
    semaphoreSI.sType = Vk.StructureType.SemaphoreSignalInfo;
    semaphoreSI.semaphore = semaphore;
    semaphoreSI.value = value;

    Vk.signal_semaphore(device, *semaphoreSI);
}

_create_graphics_command_pool :: (engine : *Engine, commandPool : *Vk.CommandPool) -> bool {
    commandPoolCI : Vk.CommandPoolCreateInfo;
    commandPoolCI.sType = Vk.StructureType.CommandPoolCreateInfo;
    commandPoolCI.queueFamilyIndex = cast(u32) engine.queueIndices.graphics;
    commandPoolCI.flags = cast(u32) Vk.CommandPoolCreateFlagBits.ResetCommandBuffer;

    _CHECK(Vk.create_command_pool(engine.device, *commandPoolCI, null, commandPool),
           "Unable to create command pool.");
    return true;
}

ImageHolder :: struct {
    image : Vk.Image;
    format : Vk.Format;
    deviceMemory : Vk.DeviceMemory;
}

_image_holder_init :: (imageHolder : *ImageHolder, engine : *Engine,
                       extent : Chamber.uvec2, format : Vk.Format) -> bool {
    imageHolder.format = format;

    // Image itself
    imageCI : Vk.ImageCreateInfo;
    imageCI.sType = Vk.StructureType.ImageCreateInfo;
    imageCI.imageType = Vk.ImageType._2D;
    imageCI.extent.width = extent.width;
    imageCI.extent.height = extent.height;
    imageCI.extent.depth = 1;
    imageCI.mipLevels = 1;
    imageCI.arrayLayers = 1;
    imageCI.format = format;
    imageCI.tiling = Vk.ImageTiling.Optimal;
    imageCI.initialLayout = Vk.ImageLayout.Undefined;
    imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.TransferSrc | Vk.ImageUsageFlagBits.ColorAttachment;
    imageCI.sharingMode = Vk.SharingMode.Exclusive;
    imageCI.samples = Vk.SampleCountFlagBits._1;

    _CHECK(Vk.create_image(engine.device, *imageCI, null, *imageHolder.image),
           "Unable to create image.");

    // Device memory
    memoryRequirements : Vk.MemoryRequirements;
    Vk.get_image_memory_requirements(engine.device, imageHolder.image, *memoryRequirements);

    memoryAI : Vk.MemoryAllocateInfo;
    memoryAI.sType = Vk.StructureType.MemoryAllocateInfo;
    memoryAI.allocationSize = memoryRequirements.size;
    memoryAI.memoryTypeIndex = _select_best_memory_type_index(engine, memoryRequirements.memoryTypeBits, cast(u32) Vk.MemoryPropertyFlagBits.DeviceLocal);

    _CHECK(Vk.allocate_memory(engine.device, *memoryAI, null, *imageHolder.deviceMemory),
           "Unable to allocate image memory.");

    Vk.bind_image_memory(engine.device, imageHolder.image, imageHolder.deviceMemory, 0);

    return true;
}

_image_holder_cleanup :: (imageHolder : *ImageHolder, engine : *Engine) {
    Vk.destroy_image(engine.device, imageHolder.image, null);
    Vk.free_memory(engine.device, imageHolder.deviceMemory, null);
}

_image_holder_create_view :: (imageHolder : *ImageHolder, engine : *Engine) -> Vk.ImageView {
    imageViewCI : Vk.ImageViewCreateInfo;
    imageViewCI.sType = Vk.StructureType.ImageViewCreateInfo;
    imageViewCI.image = imageHolder.image;
    imageViewCI.viewType = Vk.ImageViewType._2D;
    imageViewCI.format = imageHolder.format;
    imageViewCI.components.r = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.g = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.b = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.a = Vk.ComponentSwizzle.Identity;
    imageViewCI.subresourceRange.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
    imageViewCI.subresourceRange.levelCount = 1;
    imageViewCI.subresourceRange.layerCount = 1;

    imageView : Vk.ImageView;
    _CHECK(Vk.create_image_view(engine.device, *imageViewCI, null, *imageView), null,
           "Unable to create image view.");

    return imageView;
}

_change_image_layout :: (commandBuffer : Vk.CommandBuffer, image : Vk.Image, oldLayout : Vk.ImageLayout, newLayout : Vk.ImageLayout) {
    imageMemoryBarrier : Vk.ImageMemoryBarrier;
    imageMemoryBarrier.sType = Vk.StructureType.ImageMemoryBarrier;
    imageMemoryBarrier.oldLayout = oldLayout;
    imageMemoryBarrier.newLayout = newLayout;
    imageMemoryBarrier.image = image;
    imageMemoryBarrier.subresourceRange.levelCount = 1;
    imageMemoryBarrier.subresourceRange.layerCount = 1;
    imageMemoryBarrier.subresourceRange.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;

    stageMask := cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput; // @todo How can we be sure this is the right thing to do?
    Vk.cmd_pipeline_barrier(commandBuffer, stageMask, stageMask, 0, 0, null, 0, null, 1, *imageMemoryBarrier);
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
    debugUtilsObjectNI.sType = Vk.StructureType.DebugUtilsObjectNameInfoExt;
    debugUtilsObjectNI.objectHandle = objectHandle;
    debugUtilsObjectNI.objectType = objectType;
    debugUtilsObjectNI.pObjectName = name;

    Vk.set_debug_utils_object_name_ext(device, *debugUtilsObjectNI);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.CommandBuffer, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.CommandBuffer, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.Image, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.Image, name);
}

_set_debug_utils_name :: (device : Vk.Device, object : Vk.ImageView, name : *u8) {
    _set_debug_utils_name(device, cast(u64) object, Vk.ObjectType.ImageView, name);
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
