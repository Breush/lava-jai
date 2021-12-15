ImageHolder :: struct {
    Kind :: enum {
        Unknown :: 0;
        Texture;      // R8G8B8A8Unorm - Color | Sampled | TransferDst
        RendererOut;  // R8G8B8A8Srgb - Color | Sampled | TransferSrc
        Depth;        // D32Sfloat    - DepthStencil
    }

    engine : *Engine;
    kind : Kind;
    image : Vk.Image;
    extent : Chamber.uvec2;
    format : Vk.Format;
    deviceMemory : Vk.DeviceMemory;
}

_image_holder_init :: (using imageHolder : *ImageHolder, _engine : *Engine,
                       _name : string,
                       _kind : ImageHolder.Kind,
                       _extent : Chamber.uvec2) -> bool {
    engine = _engine;
    kind = _kind;
    extent = _extent;

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
    } else if kind == .Texture {
        format = Vk.Format.R8G8B8A8Unorm;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.TransferDst | Vk.ImageUsageFlagBits.Sampled | Vk.ImageUsageFlagBits.ColorAttachment;
    } else if kind == .Depth {
        format = Vk.Format.D32Sfloat;
        imageCI.usage = cast(u32) Vk.ImageUsageFlagBits.DepthStencilAttachment;
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

    if kind == .RendererOut || kind == .Texture {
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
        Staging;        // TransferSrc
        ShaderVertex;   // VertexBuffer
        ShaderIndex;    // IndexBuffer
        ShaderUniform;  // UniformBuffer
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
    } else if kind == .ShaderIndex {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.IndexBuffer;
    } else if kind == .ShaderUniform {
        bufferCIFlags = cast(u32) Vk.BufferUsageFlagBits.UniformBuffer;
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

    Vk.destroy_buffer(engine.device, buffer, null);
    Vk.free_memory(engine.device, deviceMemory, null);

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
