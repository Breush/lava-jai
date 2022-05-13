ImageHolder :: struct {
    Kind :: enum {
        Unknown :: 0;
        Texture;            // R8G8B8A8Unorm - Color | Sampled | TransferDst
        RendererOut;        // R8G8B8A8Srgb  - Color | Sampled | TransferSrc
        RendererOutStorage; // R8G8B8A8Unorm - Storage | Sampled | TransferSrc
        StorageR8;          // R8Unorm       - Storage
        StorageR32;         // R32Sfloat     - Storage
        Depth;              // D32Sfloat     - DepthStencil
    }

    engine : *Engine;
    kind : Kind;
    image : Vk.Image;
    extent : Chamber.uvec2;
    format : Vk.Format;
    channelsCount : u8;
    deviceMemory : Vk.DeviceMemory;
}

_image_holder_init :: (using imageHolder : *ImageHolder, _engine : *Engine,
                       _name : string,
                       _kind : ImageHolder.Kind,
                       _extent : Chamber.uvec2,
                       _channelsCount : u8 = 0) -> bool {
    engine = _engine;
    kind = _kind;
    extent = _extent;
    channelsCount = _channelsCount;

    // Image itself
    imageCI : Vk.ImageCreateInfo;
    imageCI.sType = .ImageCreateInfo;
    imageCI.imageType = Vk.ImageType._2D;
    imageCI.extent.width = _extent.width;
    imageCI.extent.height = _extent.height;
    imageCI.extent.depth = 1;
    imageCI.mipLevels = 1;
    imageCI.arrayLayers = 1;
    imageCI.tiling = Vk.ImageTiling.Optimal;
    imageCI.sharingMode = Vk.SharingMode.Exclusive;
    imageCI.samples = Vk.SampleCountFlagBits._1;
    imageCI.initialLayout = Vk.ImageLayout.Undefined;

    if kind == .RendererOut {
        format = Vk.Format.R8G8B8A8Srgb;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.TransferSrc | Vk.ImageUsageFlagBits.Sampled | Vk.ImageUsageFlagBits.ColorAttachment;
    } else if kind == .RendererOutStorage {
        format = Vk.Format.R8G8B8A8Unorm;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.TransferSrc | Vk.ImageUsageFlagBits.Sampled | Vk.ImageUsageFlagBits.Storage;
    } else if kind == .Texture {
        if channelsCount == 4 {
            format = Vk.Format.R8G8B8A8Unorm;
        } else if channelsCount == 1 {
            format = Vk.Format.R8Unorm;
        } else {
            Basic.log("Invalid channels count for texture: %.", channelsCount, flags=.ERROR);
        }
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.TransferDst | Vk.ImageUsageFlagBits.Sampled | Vk.ImageUsageFlagBits.ColorAttachment;
    } else if kind == .Depth {
        format = Vk.Format.D32Sfloat;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.DepthStencilAttachment;
    } else if kind == .StorageR8 {
        format = Vk.Format.R8Unorm;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.Storage;
    } else if kind == .StorageR32 {
        format = Vk.Format.R32Sfloat;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.Storage;
    } else {
        Basic.log("Trying to create an image of unhandled kind: %.", kind, flags=.ERROR);
    }

    imageCI.format = format;

    _CHECK(Vk.create_image(engine.device, *imageCI, null, *image),
           "Unable to create image.");
    _set_debug_utils_name(engine.device, image, Basic.tprint("%.image\0", _name).data);

    // Device memory
    memoryRequirements : Vk.MemoryRequirements;
    Vk.get_image_memory_requirements(engine.device, image, *memoryRequirements);

    memoryAI : Vk.MemoryAllocateInfo;
    memoryAI.sType = .MemoryAllocateInfo;
    memoryAI.allocationSize = memoryRequirements.size;
    memoryAI.memoryTypeIndex = _select_best_memory_type_index(engine, memoryRequirements.memoryTypeBits, cast(u32) Vk.MemoryPropertyFlagBits.DeviceLocal);

    _CHECK(Vk.allocate_memory(engine.device, *memoryAI, null, *deviceMemory),
           "Unable to allocate image memory.");

    Vk.bind_image_memory(engine.device, image, deviceMemory, 0);

    return true;
}

_image_holder_cleanup :: (using imageHolder : *ImageHolder, resetMemory := true) {
    if image != null {
        Vk.destroy_image(engine.device, image, null);
        Vk.free_memory(engine.device, deviceMemory, null);
    }

    if resetMemory {
        <<imageHolder = .{};
    }
}

_image_holder_copy :: (using imageHolder : *ImageHolder, data : []u8, usage : ImageUsageKind) {
    stagingBufferHolder : BufferHolder;
    _buffer_holder_init(*stagingBufferHolder, engine, "image-holder.stagingBufferHolder",
                        .Staging, .Direct, cast(u64) data.count);
    _buffer_holder_copy(*stagingBufferHolder, data.data, cast(Vk.DeviceSize) data.count);
    defer _buffer_holder_cleanup(*stagingBufferHolder, resetMemory=false);

    commandBuffer := _one_time_command_buffer_begin(engine.device, engine.graphicsCommandPool);

    bufferImageCopy : Vk.BufferImageCopy;
    bufferImageCopy.imageSubresource.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
    bufferImageCopy.imageSubresource.baseArrayLayer = 0;
    bufferImageCopy.imageSubresource.layerCount = 1;
    bufferImageCopy.imageSubresource.mipLevel = 0;
    bufferImageCopy.imageExtent.width = extent.width;
    bufferImageCopy.imageExtent.height = extent.height;
    bufferImageCopy.imageExtent.depth = 1;

    _change_image_layout(commandBuffer, image, .DontCare, .TransferOutput);
    Vk.cmd_copy_buffer_to_image(commandBuffer, stagingBufferHolder.buffer, image, .TransferDstOptimal, 1, *bufferImageCopy);
    _change_image_layout(commandBuffer, image, .TransferOutput, usage);

    _one_time_command_buffer_end(commandBuffer, engine.device, engine.graphicsCommandPool, engine.graphicsQueue);
}

_image_holder_create_view :: (using imageHolder : *ImageHolder) -> Vk.ImageView {
    aspect : Vk.ImageAspectFlags;

    if kind == .RendererOut || kind == .RendererOutStorage || kind == .Texture || kind == .StorageR8 || kind == .StorageR32 {
        aspect = cast(u32) Vk.ImageAspectFlagBits.Color;
    } else if kind == .Depth {
        aspect = cast(u32) Vk.ImageAspectFlagBits.Depth;
    } else {
        Basic.log("Trying to create an image view of unhandled kind: %.", kind, flags=.ERROR);
    }

    imageViewCI : Vk.ImageViewCreateInfo;
    imageViewCI.sType = .ImageViewCreateInfo;
    imageViewCI.image = image;
    imageViewCI.viewType = Vk.ImageViewType._2D;
    imageViewCI.format = format;
    imageViewCI.components.r = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.g = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.b = Vk.ComponentSwizzle.Identity;
    imageViewCI.components.a = Vk.ComponentSwizzle.Identity;
    imageViewCI.subresourceRange.aspectMask = aspect;
    imageViewCI.subresourceRange.levelCount = 1;
    imageViewCI.subresourceRange.layerCount = 1;

    imageView : Vk.ImageView;
    _CHECK(Vk.create_image_view(engine.device, *imageViewCI, null, *imageView), null,
           "Unable to create image view.");

    return imageView;
}

// -----

BufferHolder :: struct {
    Kind :: enum {
        Unknown :: 0;
        Staging;                        // TransferSrc
        ShaderVertex;                   // VertexBuffer (RayTracing: | AccelerationStructureBuildInputReadOnlyKHR)
        ShaderIndex;                    // IndexBuffer (RayTracing: | AccelerationStructureBuildInputReadOnlyKHR)
        ShaderUniform;                  // UniformBuffer
        ShaderStorage;                  // StorageBuffer
        ShaderBindingTable;             // ShaderBindingTableKHR
        AccelerationStructureInput;     // AccelerationStructureBuildInputReadOnlyKHR
        AccelerationStructureStorage;   // AccelerationStructureStorageKHR
        AccelerationStructureScratch;   // StorageBuffer
    }

    CpuIo :: enum {
        Unknown :: 0;
        None;               // Should never be read/written from CPU.
        Direct;             // Manipulated directly, meaning that the buffer is stored on CPU.
        OnDemandStaging;    // Manipulated through a staging buffer created each time a copy is needed.
        PersistentStaging;  // Manipulated through a persistent staging buffer.
    }

    engine : *Engine;
    kind : Kind;
    cpuIo : CpuIo;
    size : Vk.DeviceSize;

    buffer : Vk.Buffer;
    deviceMemory : Vk.DeviceMemory;
    deviceAddress : Vk.DeviceAddress;

    stagingBufferHolder : *BufferHolder; // Set only when cpuIo == .PersistentStaging
}

_buffer_holder_init :: (using bufferHolder : *BufferHolder, _engine : *Engine, name : string,
                        _kind : BufferHolder.Kind, _cpuIo : BufferHolder.CpuIo,
                        _size : Vk.DeviceSize) -> bool {
    if engine == _engine && kind == _kind && cpuIo == _cpuIo && size == _size then return true;

    if engine != null {
        _buffer_holder_cleanup(bufferHolder);
    }

    engine = _engine;
    kind = _kind;
    cpuIo = _cpuIo;
    size = _size;

    if (cpuIo == .PersistentStaging) {
        stagingBufferHolder = Basic.New(BufferHolder);
        _buffer_holder_init(stagingBufferHolder, engine, Basic.tprint("%.stagingBufferHolder", name), .Staging, .Direct, size);
    }

    bufferCIFlags : Vk.BufferUsageFlags;
    if kind == .Staging {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.TransferSrc;
    } else if kind == .ShaderVertex {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.VertexBuffer;
        if engine.options.features & .RayTracing {
            bufferCIFlags |= cast(u32) Vk.BufferUsageFlagBits.AccelerationStructureBuildInputReadOnlyKhr;
        }
    } else if kind == .ShaderIndex {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.IndexBuffer;
        if engine.options.features & .RayTracing {
            bufferCIFlags |= cast(u32) Vk.BufferUsageFlagBits.AccelerationStructureBuildInputReadOnlyKhr;
        }
    } else if kind == .ShaderUniform {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.UniformBuffer;
    } else if kind == .ShaderStorage {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.StorageBuffer;
    } else if kind == .ShaderBindingTable {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.ShaderBindingTableKhr;
    } else if kind == .AccelerationStructureInput {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.AccelerationStructureBuildInputReadOnlyKhr;
    } else if kind == .AccelerationStructureStorage {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.AccelerationStructureStorageKhr;
    } else if kind == .AccelerationStructureScratch {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.StorageBuffer;
    }

    if engine.options.features & .RayTracing {
        bufferCIFlags |= cast(u32) Vk.BufferUsageFlagBits.ShaderDeviceAddress;
    }

    if cpuIo == .OnDemandStaging || cpuIo == .PersistentStaging {
        bufferCIFlags |= cast(u32) Vk.BufferUsageFlagBits.TransferDst;
    }

    bufferCI : Vk.BufferCreateInfo;
    bufferCI.sType = .BufferCreateInfo;
    bufferCI.size = size;
    bufferCI.usage = bufferCIFlags;
    bufferCI.sharingMode = Vk.SharingMode.Exclusive;
    _CHECK(Vk.create_buffer(engine.device, *bufferCI, null, *buffer),
           "Unable to create buffer.");
    _set_debug_utils_name(engine.device, buffer, Basic.tprint("%.buffer\0", name).data);

    memoryRequirements : Vk.MemoryRequirements;
    Vk.get_buffer_memory_requirements(engine.device, buffer, *memoryRequirements);

    memoryPropertyFlags := cast(Vk.MemoryPropertyFlags) Vk.MemoryPropertyFlagBits.DeviceLocal;
    if cpuIo == .Direct {
        memoryPropertyFlags = cast(u32) Vk.MemoryPropertyFlagBits.HostVisible | Vk.MemoryPropertyFlagBits.HostCoherent;
    }

    memoryAI : Vk.MemoryAllocateInfo;
    memoryAI.sType = .MemoryAllocateInfo;
    memoryAI.allocationSize = memoryRequirements.size;
    memoryAI.memoryTypeIndex = _select_best_memory_type_index(engine, memoryRequirements.memoryTypeBits,
                                                              memoryPropertyFlags);

    memoryAFI : Vk.MemoryAllocateFlagsInfo;
    if bufferCIFlags & cast(u32) Vk.BufferUsageFlagBits.ShaderDeviceAddress {
        memoryAFI.sType = .MemoryAllocateFlagsInfo;
        memoryAFI.flags = cast(u32) Vk.MemoryAllocateFlagBits.DeviceAddress;
        memoryAI.pNext = *memoryAFI;
    }

    _CHECK(Vk.allocate_memory(engine.device, *memoryAI, null, *deviceMemory),
           "Unable to create buffer device memory.");
    _set_debug_utils_name(engine.device, deviceMemory, Basic.tprint("%.deviceMemory\0", name).data);

    Vk.bind_buffer_memory(engine.device, buffer, deviceMemory, 0);

    return true;
}

_buffer_holder_cleanup :: (using bufferHolder : *BufferHolder, resetMemory := true) {
    if stagingBufferHolder != null {
        _buffer_holder_cleanup(stagingBufferHolder, false);
        Basic.free(stagingBufferHolder);
    }

    if bufferHolder.engine != null {
        Vk.destroy_buffer(engine.device, buffer, null);
        Vk.free_memory(engine.device, deviceMemory, null);
    }

    if resetMemory {
        <<bufferHolder = .{};
    }
}

_buffer_holder_copy :: (using bufferHolder : *BufferHolder, data : $T) -> bool {
    return _buffer_holder_copy(bufferHolder, *data, size_of(T));
}

_buffer_holder_copy :: (using bufferHolder : *BufferHolder, data : *void, dataSize : Vk.DeviceSize) -> bool {
    if cpuIo == .Direct {
        targetData : *void;
        Vk.map_memory(engine.device, deviceMemory, 0, size, 0, *targetData);
        memcpy(targetData, data, cast(s64) dataSize);
        Vk.unmap_memory(engine.device, deviceMemory);
    } else if cpuIo == .OnDemandStaging {
        stagingBufferHolder : BufferHolder;
        _buffer_holder_init(*stagingBufferHolder, engine, "buffer-holder.stagingBufferHolder", .Staging, .Direct, dataSize);
        _buffer_holder_copy(*stagingBufferHolder, data, dataSize);
        _copy_buffer(engine.device, engine.graphicsQueue, engine.graphicsCommandPool,
                     stagingBufferHolder.buffer, buffer, cast(u64) dataSize, 0, 0);
        _buffer_holder_cleanup(*stagingBufferHolder, resetMemory=false);
    } else if cpuIo == .PersistentStaging {
        _buffer_holder_copy(stagingBufferHolder, data, dataSize);
        _copy_buffer(engine.device, engine.graphicsQueue, engine.graphicsCommandPool,
                     stagingBufferHolder.buffer, buffer, cast(u64) dataSize, 0, 0);
    } else {
        _CHECK(false, false, "Buffer holder cannot be copied because of its CpuIo.");
    }

    return true;
}

_buffer_holder_device_address :: (using bufferHolder : *BufferHolder) -> Vk.DeviceAddress {
    if deviceAddress == 0 {
        bufferDAI : Vk.BufferDeviceAddressInfo;
        bufferDAI.sType = .BufferDeviceAddressInfo;
        bufferDAI.buffer = buffer;
        deviceAddress = Vk.get_buffer_device_address(engine.device, *bufferDAI);
    }

    return deviceAddress;
}

// -----

// @todo Could be used more generally in each renderer.
// Currently only used in RayTracingRenderer.
DescriptorHolder :: struct {
    engine : *Engine;
    setLayout : Vk.DescriptorSetLayout;
    pool : Vk.DescriptorPool;
    options : DescriptorHolderOptions;
}

DescriptorHolderOptions :: struct {
    accelerationStructures : u32;
    storageBuffers : u32;
    storageImages : []u32;
}

_descriptor_holder_init :: (using descriptorHolder : *DescriptorHolder, _engine : *Engine, _options : DescriptorHolderOptions) -> bool {
    engine = _engine;
    options = _options;

    // --- Set layout

    bindingIndex : u32;
    setLayoutBindings : [..]Vk.DescriptorSetLayoutBinding;
    defer Basic.array_free(setLayoutBindings);

    // @todo We should get the stageFlags from the parameters, somehow.

    if options.accelerationStructures > 0 {
        Basic.array_resize(*setLayoutBindings, setLayoutBindings.count + 1);
        setLayoutBinding := Basic.peek_pointer(setLayoutBindings);
        setLayoutBindings[bindingIndex].binding = bindingIndex;
        setLayoutBindings[bindingIndex].descriptorCount = options.accelerationStructures;
        setLayoutBindings[bindingIndex].stageFlags = cast(u32) Vk.ShaderStageFlagBits.RaygenKhr | Vk.ShaderStageFlagBits.ClosestHitKhr;
        setLayoutBindings[bindingIndex].descriptorType = .AccelerationStructureKhr;

        bindingIndex += 1;
    }

    if options.storageBuffers > 0 {
        Basic.array_resize(*setLayoutBindings, setLayoutBindings.count + 1);
        setLayoutBinding := Basic.peek_pointer(setLayoutBindings);
        setLayoutBindings[bindingIndex].binding = bindingIndex;
        setLayoutBindings[bindingIndex].descriptorCount = options.storageBuffers;
        setLayoutBindings[bindingIndex].stageFlags = cast(u32) Vk.ShaderStageFlagBits.ClosestHitKhr;
        setLayoutBindings[bindingIndex].descriptorType = .StorageBuffer;

        bindingIndex += 1;
    }

    storageImagesCountsSum : u32 = 0;
    for storageImagesCount : options.storageImages {
        Basic.array_resize(*setLayoutBindings, setLayoutBindings.count + 1);
        setLayoutBinding := Basic.peek_pointer(setLayoutBindings);
        setLayoutBindings[bindingIndex].binding = bindingIndex;
        setLayoutBindings[bindingIndex].descriptorCount = storageImagesCount;
        setLayoutBindings[bindingIndex].stageFlags = cast(u32) Vk.ShaderStageFlagBits.RaygenKhr;
        setLayoutBindings[bindingIndex].descriptorType = .StorageImage;

        storageImagesCountsSum += storageImagesCount;
        bindingIndex += 1;
    }

    setLayoutCI : Vk.DescriptorSetLayoutCreateInfo;
    setLayoutCI.sType = .DescriptorSetLayoutCreateInfo;
    setLayoutCI.bindingCount = cast(u32) setLayoutBindings.count;
    setLayoutCI.pBindings = setLayoutBindings.data;

    _CHECK(Vk.create_descriptor_set_layout(engine.device, *setLayoutCI, null, *setLayout),
           "Unable to create descriptor set layout.");

    // --- Pool

    // @todo Should definitely be parametrable.
    MAX_DESCRIPTOR_SET_COUNT :: Engine.FRAME_INDEX_COUNT;

    poolSizes : [..]Vk.DescriptorPoolSize;
    defer Basic.array_free(poolSizes);

    if options.accelerationStructures > 0 {
        Basic.array_resize(*poolSizes, poolSizes.count + 1);
        poolSize := Basic.peek_pointer(poolSizes);
        poolSize.type = .AccelerationStructureKhr;
        poolSize.descriptorCount = options.accelerationStructures * MAX_DESCRIPTOR_SET_COUNT;
    }

    if storageImagesCountsSum > 0 {
        Basic.array_resize(*poolSizes, poolSizes.count + 1);
        poolSize := Basic.peek_pointer(poolSizes);
        poolSize.type = .StorageImage;
        poolSize.descriptorCount = storageImagesCountsSum * MAX_DESCRIPTOR_SET_COUNT;
    }

    poolCI : Vk.DescriptorPoolCreateInfo;
    poolCI.sType = .DescriptorPoolCreateInfo;
    poolCI.poolSizeCount = cast(u32) poolSizes.count;
    poolCI.pPoolSizes = poolSizes.data;
    poolCI.maxSets = MAX_DESCRIPTOR_SET_COUNT;

    _CHECK(Vk.create_descriptor_pool(engine.device, *poolCI, null, *pool),
           "Unable to create descriptor pool.");

    return true;
}

_descriptor_holder_cleanup :: (using descriptorHolder : *DescriptorHolder) -> bool {
    Vk.destroy_descriptor_pool(engine.device, pool, null);
    Vk.destroy_descriptor_set_layout(engine.device, setLayout, null);
    return true;
}

_descriptor_holder_allocate_set :: (using descriptorHolder : *DescriptorHolder) -> Vk.DescriptorSet {
    setAI : Vk.DescriptorSetAllocateInfo;
    setAI.sType = .DescriptorSetAllocateInfo;
    setAI.descriptorPool = pool;
    setAI.descriptorSetCount = 1;
    setAI.pSetLayouts = *setLayout;

    set : Vk.DescriptorSet;
    _CHECK(Vk.allocate_descriptor_sets(engine.device, *setAI, *set),
           null, "Unable to allocate descriptor sets.");

    return set;
}

_descriptor_holder_update_set :: (using descriptorHolder : *DescriptorHolder, set : Vk.DescriptorSet, accelerationStructure : Vk.AccelerationStructureKHR) -> bool {
    writeSetAccelerationStructure : Vk.WriteDescriptorSetAccelerationStructureKHR;
    writeSetAccelerationStructure.sType = .WriteDescriptorSetAccelerationStructureKhr;
    writeSetAccelerationStructure.accelerationStructureCount = 1;
    writeSetAccelerationStructure.pAccelerationStructures = *accelerationStructure;

    writeSet : Vk.WriteDescriptorSet;
    writeSet.sType = .WriteDescriptorSet;
    writeSet.pNext = *writeSetAccelerationStructure;
    writeSet.dstSet = set;
    writeSet.dstBinding = 0; // @todo Should be parametrable + offseted by start of binding
    writeSet.dstArrayElement = 0;
    writeSet.descriptorType = .AccelerationStructureKhr;
    writeSet.descriptorCount = 1;

    Vk.device_wait_idle(engine.device); // @fixme :MaterialDescriptorsWaitIdle
    Vk.update_descriptor_sets(engine.device, 1, *writeSet, 0, null);

    return true;
}

_descriptor_holder_update_set :: (using descriptorHolder : *DescriptorHolder, set : Vk.DescriptorSet, imageView : Vk.ImageView, imageLayout : Vk.ImageLayout, dstBinding : u32 = 0) -> bool {
    imageInfo : Vk.DescriptorImageInfo;
    imageInfo.imageLayout = imageLayout;
    imageInfo.imageView = imageView;

    writeSet : Vk.WriteDescriptorSet;
    writeSet.sType = .WriteDescriptorSet;
    writeSet.pImageInfo = *imageInfo;
    writeSet.dstSet = set;
    writeSet.dstBinding = dstBinding; // @todo Should be offseted by start of binding
    writeSet.dstArrayElement = 0;
    writeSet.descriptorType = .StorageImage;
    writeSet.descriptorCount = 1;

    Vk.device_wait_idle(engine.device); // @fixme :MaterialDescriptorsWaitIdle
    Vk.update_descriptor_sets(engine.device, 1, *writeSet, 0, null);

    return true;
}

_descriptor_holder_update_set :: (using descriptorHolder : *DescriptorHolder, set : Vk.DescriptorSet, buffer : Vk.Buffer, size : Vk.DeviceSize) -> bool {
    bufferInfo : Vk.DescriptorBufferInfo;
    bufferInfo.buffer = buffer;
    bufferInfo.range = size;

    writeSet : Vk.WriteDescriptorSet;
    writeSet.sType = .WriteDescriptorSet;
    writeSet.pBufferInfo = *bufferInfo;
    writeSet.dstSet = set;
    writeSet.dstBinding = 1; // @todo Should be parametrable + offseted by start of binding
    writeSet.dstArrayElement = 0;
    writeSet.descriptorType = .StorageBuffer;
    writeSet.descriptorCount = 1;

    Vk.device_wait_idle(engine.device); // @fixme :MaterialDescriptorsWaitIdle
    Vk.update_descriptor_sets(engine.device, 1, *writeSet, 0, null);

    return true;
}

// -----

AsHolder :: struct {
    engine : *Engine;

    as : Vk.AccelerationStructureKHR;
    bufferHolder : BufferHolder;
    scratchBufferHolder : BufferHolder;
    geometry : Vk.AccelerationStructureGeometryKHR;
    buildRangeInfo : Vk.AccelerationStructureBuildRangeInfoKHR;
    buildGeometryInfo : Vk.AccelerationStructureBuildGeometryInfoKHR;

    buildSizesInfo : Vk.AccelerationStructureBuildSizesInfoKHR;
    deviceAddress : Vk.DeviceAddress;
}

_as_holder_init :: (asHolder : *AsHolder, engine : *Engine, name : string,
                    type : Vk.AccelerationStructureTypeKHR, primitiveCount : u32, geometry : Vk.AccelerationStructureGeometryKHR) -> bool {
    asHolder.engine = engine;
    asHolder.geometry = geometry;

    asHolder.buildRangeInfo.primitiveCount = primitiveCount;

    asHolder.buildGeometryInfo.sType = .AccelerationStructureBuildGeometryInfoKhr;
    asHolder.buildGeometryInfo.type = type;
    asHolder.buildGeometryInfo.flags = cast(u32) Vk.BuildAccelerationStructureFlagBitsKHR.PreferFastTrace;
    asHolder.buildGeometryInfo.geometryCount = 1;
    asHolder.buildGeometryInfo.pGeometries = *asHolder.geometry;
    asHolder.buildGeometryInfo.mode = .Build;

    buildSizesInfo : Vk.AccelerationStructureBuildSizesInfoKHR;
    buildSizesInfo.sType = .AccelerationStructureBuildSizesInfoKhr;
    Vk.get_acceleration_structure_build_sizes_khr(engine.device, .Device, *asHolder.buildGeometryInfo, *primitiveCount, *buildSizesInfo);

    if asHolder.as != null {
        // Don't recreate the acceleration structure if it is already the same
        if buildSizesInfo.accelerationStructureSize == asHolder.buildSizesInfo.accelerationStructureSize &&
           buildSizesInfo.buildScratchSize == asHolder.buildSizesInfo.buildScratchSize {
            return true;
        }

        _as_holder_cleanup(asHolder);
    }

    asHolder.buildSizesInfo = buildSizesInfo;

    _buffer_holder_init(*asHolder.bufferHolder, engine, Basic.tprint("%.bufferHolder", name),
                        .AccelerationStructureStorage, .OnDemandStaging, asHolder.buildSizesInfo.accelerationStructureSize);

    asCI : Vk.AccelerationStructureCreateInfoKHR;
    asCI.sType = .AccelerationStructureCreateInfoKhr;
    asCI.buffer = asHolder.bufferHolder.buffer;
    asCI.size = asHolder.bufferHolder.size;
    asCI.type = type;

    _CHECK(Vk.create_acceleration_structure_khr(engine.device, *asCI, null, *asHolder.as),
           "Unable to create acceleration structure");
    _set_debug_utils_name(engine.device, asHolder.as, Basic.tprint("%.as\0", name).data);

    _buffer_holder_init(*asHolder.scratchBufferHolder, engine, Basic.tprint("%.scratchBufferHolder", name),
                        .AccelerationStructureScratch, .None, buildSizesInfo.buildScratchSize);

    asHolder.buildGeometryInfo.dstAccelerationStructure = asHolder.as;
    asHolder.buildGeometryInfo.scratchData.deviceAddress = _buffer_holder_device_address(*asHolder.scratchBufferHolder);

    // Device address
    asAI : Vk.AccelerationStructureDeviceAddressInfoKHR;
    asAI.sType = .AccelerationStructureDeviceAddressInfoKhr;
    asAI.accelerationStructure = asHolder.as;
    asHolder.deviceAddress = Vk.get_acceleration_structure_device_address_khr(engine.device, *asAI);

    return true;
}

_as_holder_cleanup :: (using asHolder : *AsHolder) {
    if engine == null then return;

    Vk.destroy_acceleration_structure_khr(asHolder.engine.device, asHolder.as, null);

    _buffer_holder_cleanup(*asHolder.bufferHolder);
    _buffer_holder_cleanup(*asHolder.scratchBufferHolder);
}

_as_holder_build :: (using asHolder : *AsHolder) {
    commandBuffer := _one_time_command_buffer_begin(engine.device, engine.graphicsCommandPool);
    _as_holder_build(asHolder, commandBuffer);
    _one_time_command_buffer_end(commandBuffer, engine.device, engine.graphicsCommandPool, engine.graphicsQueue);
}

_as_holder_build :: (using asHolder : *AsHolder, commandBuffer : Vk.CommandBuffer) {
    asBuildRangeInfos : [1]*Vk.AccelerationStructureBuildRangeInfoKHR;
    asBuildRangeInfos[0] = *buildRangeInfo;

    Vk.cmd_build_acceleration_structures_khr(commandBuffer, 1, *asHolder.buildGeometryInfo, asBuildRangeInfos.data);

    // @note Synchronization below is needed to be able to use the built acceleration structure
    // within the same command buffer.
    memoryBarrier : Vk.MemoryBarrier;
    memoryBarrier.sType = .MemoryBarrier;
    memoryBarrier.srcAccessMask = cast(u32) Vk.AccessFlagBits.AccelerationStructureWriteKhr;
    memoryBarrier.dstAccessMask = cast(u32) Vk.AccessFlagBits.AccelerationStructureReadKhr;

    srcStageMask := cast(u32) Vk.PipelineStageFlagBits.AccelerationStructureBuildKhr;
    dstStageMask := cast(u32) Vk.PipelineStageFlagBits.RayTracingShaderKhr;
    Vk.cmd_pipeline_barrier(commandBuffer, srcStageMask, dstStageMask, 0, 1, *memoryBarrier, 0, null, 0, null);
}

#scope_file

_copy_buffer :: (device : Vk.Device, queue : Vk.Queue, commandPool : Vk.CommandPool,
                 srcBuffer : Vk.Buffer, dstBuffer : Vk.Buffer,
                 size : Vk.DeviceSize, srcOffset : Vk.DeviceSize, dstOffset : Vk.DeviceSize) {
    commandBuffer := _one_time_command_buffer_begin(device, commandPool);

    bufferCopy : Vk.BufferCopy;
    bufferCopy.size = size;
    bufferCopy.srcOffset = srcOffset;
    bufferCopy.dstOffset = dstOffset;
    Vk.cmd_copy_buffer(commandBuffer, srcBuffer, dstBuffer, 1, *bufferCopy);

    _one_time_command_buffer_end(commandBuffer, device, commandPool, queue);
}
