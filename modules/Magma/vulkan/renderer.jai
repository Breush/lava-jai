#scope_module

#load "forward-renderer.jai";

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
    engine := renderer.scene.engine;

    for frameObject : renderer.frameObjects {
        Vk.free_command_buffers(engine.device, renderer.commandPool, 1, *frameObject.commandBuffer);
        Vk.destroy_semaphore(engine.device, frameObject.renderSemaphore, null);
    }

    Vk.destroy_command_pool(engine.device, renderer.commandPool, null);
}

_renderer_post_init :: (renderer : *Renderer) -> bool {
    engine := renderer.scene.engine;

    if !_create_graphics_command_pool(engine, *renderer.commandPool, true) {
        return false;
    }
    _set_debug_utils_name(engine.device, renderer.commandPool, "renderer.commandPool");

    for *frameObject : renderer.frameObjects {
        // @note We use timeline semaphores so that multiple targets/post-processes
        // can wait for it to be done. It also allows us to use it as a fence to
        // ensure that it is not reused before the previous one is done.
        semaphoreTypeCI : Vk.SemaphoreTypeCreateInfo;
        semaphoreTypeCI.sType = .SemaphoreTypeCreateInfo;
        semaphoreTypeCI.semaphoreType = Vk.SemaphoreType.Timeline;
        semaphoreTypeCI.initialValue = 0;

        semaphoreCI : Vk.SemaphoreCreateInfo;
        semaphoreCI.sType = .SemaphoreCreateInfo;
        semaphoreCI.pNext = *semaphoreTypeCI;
        _CHECK(Vk.create_semaphore(engine.device, *semaphoreCI, null, *frameObject.renderSemaphore),
               "Unable to create semaphore.");
        _set_debug_utils_name(engine.device, frameObject.renderSemaphore, "renderer.frameObjects[].renderSemaphore");

        commandBufferAI : Vk.CommandBufferAllocateInfo;
        commandBufferAI.sType = .CommandBufferAllocateInfo;
        commandBufferAI.commandPool = renderer.commandPool;
        commandBufferAI.level = Vk.CommandBufferLevel.Primary;
        commandBufferAI.commandBufferCount = 1;
        _CHECK(Vk.allocate_command_buffers(engine.device, *commandBufferAI, *frameObject.commandBuffer),
               "Unable to allocate command buffers.");
        _set_debug_utils_name(engine.device, frameObject.commandBuffer, "renderer.frameObjects[].commandBuffer");
    }

    if renderer.kind == .ForwardRenderer {
        return _forward_renderer_post_init(cast(*ForwardRenderer) renderer);
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

    if renderer.kind == .ForwardRenderer {
        return _forward_renderer_render(cast(*ForwardRenderer) renderer, frameIndex);
    }

    // Issue, unknown renderer.
    return false;
}

_renderer_output_get_render_semaphore :: (output : RendererOutput, frameIndex : u8) -> Vk.Semaphore, u64 {
    frameObject := *output.renderer.frameObjects[frameIndex];
    return frameObject.renderSemaphore, frameObject.renderSemaphoreFinishedValue;
}

_renderer_output_get_image :: (output : RendererOutput, frameIndex : u8) -> Vk.Image {
    if output.renderer.kind == .ForwardRenderer {
        return _forward_renderer_get_output_image(cast(*ForwardRenderer) output.renderer, output.index, frameIndex);
    }

    // Issue, unknown renderer.
    return null;
}

_renderer_output_get_extent :: (output : RendererOutput) -> Chamber.uvec2 {
    if output.renderer.kind == .ForwardRenderer {
        return _forward_renderer_get_output_extent(cast(*ForwardRenderer) output.renderer, output.index);
    }

    // Issue, unknown renderer.
    return .{};
}

_fill_vertex_input_descs :: ($T : Type, binding : u32, locationStart : u32, inputRate : Vk.VertexInputRate) -> u32 #expand {
    typeInfo := type_info(T);

    `vertexInputBindingDescs[binding].binding = binding;
    `vertexInputBindingDescs[binding].stride = cast(u32) typeInfo.runtime_size;
    `vertexInputBindingDescs[binding].inputRate = inputRate;

    location := locationStart;
    for *member : typeInfo.members {
        `vertexInputAttributeDescs[location].binding = binding;
        `vertexInputAttributeDescs[location].location = location;
        `vertexInputAttributeDescs[location].offset = cast(u32) member.offset_in_bytes;

        if member.type.runtime_size == 12 { // vec3
            `vertexInputAttributeDescs[location].format = Vk.Format.R32G32B32Sfloat;
        } else if member.type.runtime_size == 16 { // vec4
            `vertexInputAttributeDescs[location].format = Vk.Format.R32G32B32A32Sfloat;
        } else {
            memberTypeInfo := cast(*Type_Info_Struct) member.type;
            Chamber.debug("Unknown format for ", typeInfo.name, ".", member.name, " (", memberTypeInfo.name, ").\n");
            Basic.assert(false);
        }
        location += 1;
    }

    return location;
}
