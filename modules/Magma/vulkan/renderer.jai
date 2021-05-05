#scope_module

/*
    About draw/render/present.
    We have this internal naming convention.
    - *present* Displays to screen (WindowTarget) or outputs bytes to a file.
    - *render*  Generate and dispatch instructions for the graphics card to render an image.
    - *draw*    Means both *render* and *present*
*/
RendererImpl :: struct {
    imageLayout : Vk.ImageLayout;

    lastFrameIndex := cast,trunc(u8) ~0;
    commandPool : Vk.CommandPool;
    FrameObject :: struct {
        imageHolder : ImageHolder;
        imageView : Vk.ImageView;
        commandBuffer : Vk.CommandBuffer;
        renderSemaphore : Vk.Semaphore;
        // @note This is a strictly increasing counter.
        // If you're scared, just think that, if it gets +10 at each frame at 10000FPS,
        // the counter will last 6 million years.
        // Sounds enough to me. I sincerely hope that our program infinitely waiting
        // for this value being bigger than its limit will not be our biggest issue
        // in the whole universe at this time.
        renderSemaphoreFinishedValue : u64;
    }
    frameObjects : [Engine.FRAME_INDEX_COUNT]FrameObject;
}

impl_renderer_cleanup :: (renderer : *Renderer) {
    for frameObject : renderer.frameObjects {
        _image_holder_cleanup(*frameObject.imageHolder, renderer.engine);
        Vk.destroy_image_view(renderer.engine.device, frameObject.imageView, null);
        Vk.free_command_buffers(renderer.engine.device, renderer.commandPool, 1, *frameObject.commandBuffer);
        Vk.destroy_semaphore(renderer.engine.device, frameObject.renderSemaphore, null);
    }

    Vk.destroy_command_pool(renderer.engine.device, renderer.commandPool, null);
}

_renderer_post_init :: (renderer : *Renderer) -> bool {
    if !_create_graphics_command_pool(renderer.engine, *renderer.commandPool) {
        return false;
    }
    _set_debug_utils_name(renderer.engine.device, renderer.commandPool, "renderer.commandPool");

    for *frameObject : renderer.frameObjects {
        if !_image_holder_init(*frameObject.imageHolder, renderer.engine, renderer.extent, Vk.Format.R8G8B8A8Srgb) {
            return false;
        }
        _set_debug_utils_name(renderer.engine.device, frameObject.imageHolder.image, "renderer.frameObjects[].imageHolder");

        frameObject.imageView = _image_holder_create_view(*frameObject.imageHolder, renderer.engine);
        if frameObject.imageView == null then return false;
        _set_debug_utils_name(renderer.engine.device, frameObject.imageView, "renderer.frameObjects[].imageView");

        // @note We use timeline semaphores so that multiple targets/post-processes
        // can wait for it to be done. It also allows us to use it as a fence to
        // ensure that it is not reused before the previous one is done.
        semaphoreTypeCI : Vk.SemaphoreTypeCreateInfo;
        semaphoreTypeCI.sType = Vk.StructureType.SemaphoreTypeCreateInfo;
        semaphoreTypeCI.semaphoreType = Vk.SemaphoreType.Timeline;
        semaphoreTypeCI.initialValue = 0;

        semaphoreCI : Vk.SemaphoreCreateInfo;
        semaphoreCI.sType = Vk.StructureType.SemaphoreCreateInfo;
        semaphoreCI.pNext = *semaphoreTypeCI;
        _CHECK(Vk.create_semaphore(renderer.engine.device, *semaphoreCI, null, *frameObject.renderSemaphore),
               "Unable to create semaphore.");
        _set_debug_utils_name(renderer.engine.device, frameObject.renderSemaphore, "renderer.frameObjects[].renderSemaphore");

        commandBufferAI : Vk.CommandBufferAllocateInfo;
        commandBufferAI.sType = Vk.StructureType.CommandBufferAllocateInfo;
        commandBufferAI.commandPool = renderer.commandPool;
        commandBufferAI.level = Vk.CommandBufferLevel.Primary;
        commandBufferAI.commandBufferCount = 1;
        _CHECK(Vk.allocate_command_buffers(renderer.engine.device, *commandBufferAI, *frameObject.commandBuffer),
               "Unable to allocate command buffers.");
        _set_debug_utils_name(renderer.engine.device, frameObject.commandBuffer, "renderer.frameObjects[].commandBuffer");
    }

    if renderer.kind == Renderer.Kind.Camera {
        return _camera_post_init(cast(*Camera) renderer);
    }

    // Issue, unknown renderer.
    return false;
}

_renderer_render :: (renderer : *Renderer, frameIndex : u8) -> bool {
    if renderer.lastFrameIndex == frameIndex {
        // Renderer is already being rendered for this frame.
        return true;
    }
    renderer.lastFrameIndex = frameIndex;

    if renderer.kind == Renderer.Kind.Camera {
        return _camera_render(cast(*Camera) renderer, frameIndex);
    }

    // Issue, unknown renderer.
    return false;
}

_renderer_get_render_semaphore :: (renderer : *Renderer, frameIndex : u8) -> Vk.Semaphore, u64 {
    frameObject := *renderer.frameObjects[frameIndex];
    return frameObject.renderSemaphore, frameObject.renderSemaphoreFinishedValue;
}

_renderer_get_image :: (renderer : *Renderer, frameIndex : u8) -> Vk.Image {
    frameObject := *renderer.frameObjects[frameIndex];
    return frameObject.imageHolder.image;
}
