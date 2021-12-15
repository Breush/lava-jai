#scope_module

#load "forward-renderer.jai";
#load "ray-tracing-renderer.jai";
#load "post-process-renderer.jai";

/*
    About draw/render/present.
    We have this internal naming convention.
    - *present* Displays to screen (WindowTarget) or outputs bytes to a file.
    - *render*  Generate and dispatch instructions for the graphics card to render an image.
    - *draw*    Means both *render* and *present*
*/
RendererImpl :: struct {
    pipelineLayout : Vk.PipelineLayout;

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

ImageUsageKind :: enum {
    Unknown;
    DontCare;
    FragmentInput;
    FragmentOutput;
    RayTracingOutput;
    TransferInput;
    TransferOutput;
    PresentInput;
}

ImageInfo :: struct {
    image : Vk.Image;
    view : Vk.ImageView;
    layout : Vk.ImageLayout;
    usage : ImageUsageKind;
}

VertexInputDescription :: struct {
    bindings : []Vk.VertexInputBindingDescription;
    attributes : []Vk.VertexInputAttributeDescription;
}

impl_renderer_cleanup :: (renderer : *Renderer) {
    engine := renderer.scene.engine;

    for frameObject : renderer.frameObjects {
        Vk.free_command_buffers(engine.device, renderer.commandPool, 1, *frameObject.commandBuffer);
        Vk.destroy_semaphore(engine.device, frameObject.renderSemaphore, null);
    }

    Vk.destroy_command_pool(engine.device, renderer.commandPool, null);

    Vk.destroy_pipeline_layout(engine.device, renderer.pipelineLayout, null);
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
    } else if renderer.kind == .RayTracingRenderer {
        return _ray_tracing_renderer_post_init(cast(*RayTracingRenderer) renderer);
    } else if renderer.kind == .PostProcessRenderer {
        return _post_process_renderer_post_init(cast(*PostProcessRenderer) renderer);
    }

    Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    return false;
}

_renderer_render :: (renderer : *Renderer, frameIndex : u8) -> bool {
    if renderer.lastFrameIndex == frameIndex {
        // Renderer is already being rendered for this frame.
        return true;
    }
    renderer.lastFrameIndex = frameIndex;

    engine := renderer.scene.engine;
    frameObject := *renderer.frameObjects[frameIndex];

    // Works like a fence, we're waiting for the previous command buffer to be done.
    _wait_timeline_semaphore(engine.device, frameObject.renderSemaphore, frameObject.renderSemaphoreFinishedValue);

    commandBuffer := frameObject.commandBuffer;
    commandBufferBeginInfo : Vk.CommandBufferBeginInfo;
    commandBufferBeginInfo.sType = .CommandBufferBeginInfo;

    _CHECK(Vk.begin_command_buffer(commandBuffer, *commandBufferBeginInfo),
           "Unable to begin command buffer.");

    if renderer.kind == .ForwardRenderer {
        _forward_renderer_render(cast(*ForwardRenderer) renderer, frameIndex);
    } else if renderer.kind == .RayTracingRenderer {
        _ray_tracing_renderer_render(cast(*RayTracingRenderer) renderer, frameIndex);
    } else if renderer.kind == .PostProcessRenderer {
        _post_process_renderer_render(cast(*PostProcessRenderer) renderer, frameIndex);
    } else {
        Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    }

    Vk.end_command_buffer(commandBuffer);

    // Submit
    frameObject.renderSemaphoreFinishedValue += 1;
    timelineSemaphoreSI : Vk.TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.sType = .TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.signalSemaphoreValueCount = 1;
    timelineSemaphoreSI.pSignalSemaphoreValues = *frameObject.renderSemaphoreFinishedValue;

    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = .SubmitInfo;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    submitInfo.pNext = *timelineSemaphoreSI;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = *frameObject.renderSemaphore;

    _CHECK(Vk.queue_submit(engine.graphicsQueue, 1, *submitInfo, null),
           "Unable to submit command buffer.");

    return true;
}

_renderer_get_push_constant_ranges :: (renderer : *Renderer) -> []Vk.PushConstantRange {
    if (renderer.kind == .ForwardRenderer) {
        return (cast(*ForwardRenderer) renderer).pushConstantRanges;
    } else if (renderer.kind == .RayTracingRenderer) {
        return (cast(*RayTracingRenderer) renderer).pushConstantRanges;
    }
    return .[];
}

_renderer_get_render_pass :: (renderer : *Renderer) -> Vk.RenderPass {
    if (renderer.kind == .ForwardRenderer) {
        return (cast(*ForwardRenderer) renderer).renderPass;
    } else if (renderer.kind == .PostProcessRenderer) {
        return (cast(*PostProcessRenderer) renderer).renderPass;
    }
    Basic.log("Unhandled renderer kind: %.", renderer.kind, flags=.ERROR);
    return null;
}

_renderer_get_vertex_input_description :: (renderer : *Renderer) -> VertexInputDescription {
    if (renderer.kind == .ForwardRenderer) {
        vertexInputDescription : VertexInputDescription;
        vertexInputDescription.bindings = (cast(*ForwardRenderer) renderer).vertexInputBindingDescs;
        vertexInputDescription.attributes = (cast(*ForwardRenderer) renderer).vertexInputAttributeDescs;
        return vertexInputDescription;
    }
    return .{};
}

_renderer_output_get_render_semaphore :: (output : RendererOutput, frameIndex : u8) -> Vk.Semaphore, u64 {
    frameObject := *output.renderer.frameObjects[frameIndex];
    return frameObject.renderSemaphore, frameObject.renderSemaphoreFinishedValue;
}

_renderer_output_get_image_info :: (output : RendererOutput, frameIndex : u8) -> ImageInfo {
    if output.renderer.kind == .ForwardRenderer {
        return _forward_renderer_get_output_image_info(cast(*ForwardRenderer) output.renderer, output.index, frameIndex);
    } else if output.renderer.kind == .RayTracingRenderer {
        return _ray_tracing_renderer_get_output_image_info(cast(*RayTracingRenderer) output.renderer, output.index, frameIndex);
    } else if output.renderer.kind == .PostProcessRenderer {
        return _post_process_renderer_get_output_image_info(cast(*PostProcessRenderer) output.renderer, output.index, frameIndex);
    }

    Basic.log("Unhandled renderer kind: %.", output.renderer.kind, flags=.ERROR);
    imageInfo : ImageInfo;
    return imageInfo;
}

_fill_vertex_input_descs :: ($T : Type, binding : u32, locationStart : u32, inputRate : Vk.VertexInputRate) -> u32 #expand {
    typeInfo := type_info(T);

    `renderer.vertexInputBindingDescs[binding].binding = binding;
    `renderer.vertexInputBindingDescs[binding].stride = cast(u32) typeInfo.runtime_size;
    `renderer.vertexInputBindingDescs[binding].inputRate = inputRate;

    location := locationStart;
    for *member : typeInfo.members {
        if member.type.runtime_size == 8 { // vec2
            `renderer.vertexInputAttributeDescs[location].binding = binding;
            `renderer.vertexInputAttributeDescs[location].location = location;
            `renderer.vertexInputAttributeDescs[location].offset = cast(u32) member.offset_in_bytes;
            `renderer.vertexInputAttributeDescs[location].format = Vk.Format.R32G32Sfloat;
            location += 1;
        } else if member.type.runtime_size == 12 { // vec3
            `renderer.vertexInputAttributeDescs[location].binding = binding;
            `renderer.vertexInputAttributeDescs[location].location = location;
            `renderer.vertexInputAttributeDescs[location].offset = cast(u32) member.offset_in_bytes;
            `renderer.vertexInputAttributeDescs[location].format = Vk.Format.R32G32B32Sfloat;
            location += 1;
        } else if member.type.runtime_size == 16 { // vec4
            `renderer.vertexInputAttributeDescs[location].binding = binding;
            `renderer.vertexInputAttributeDescs[location].location = location;
            `renderer.vertexInputAttributeDescs[location].offset = cast(u32) member.offset_in_bytes;
            `renderer.vertexInputAttributeDescs[location].format = Vk.Format.R32G32B32A32Sfloat;
            location += 1;
        } else if member.type.runtime_size == 48 { // mat3x4
            for i : 0 .. 2 {
                `renderer.vertexInputAttributeDescs[location + i].binding = binding;
                `renderer.vertexInputAttributeDescs[location + i].location = cast(u32) (location + i);
                `renderer.vertexInputAttributeDescs[location + i].offset = cast(u32) (member.offset_in_bytes + i * 16);
                `renderer.vertexInputAttributeDescs[location + i].format = Vk.Format.R32G32B32A32Sfloat;
            }
            location += 3;
        } else {
            memberTypeInfo := cast(*Type_Info_Struct) member.type;
            Basic.log("Unknown format for %.% (%).", typeInfo.name, member.name, memberTypeInfo.name, flags=.ERROR);
        }
    }

    return location;
}
