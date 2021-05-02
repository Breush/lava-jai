#scope_module

WindowTargetImpl :: struct {
    surface : Vk.SurfaceKHR;

    swapchain : Vk.SwapchainKHR;
    swapchainSurfaceFormat : Vk.SurfaceFormatKHR;
    swapchainImages : [..]Vk.Image;
    swapchainImageViews : [..]Vk.ImageView;

    pipeline : Vk.Pipeline;
    pipelineLayout : Vk.PipelineLayout;
    renderPass : Vk.RenderPass;
    framebuffers : [..]Vk.Framebuffer;

    commandPool : Vk.CommandPool;
    frameObjects : [Engine.FRAME_INDEX_COUNT] struct {
        commandBuffer : Vk.CommandBuffer;
        imageAvailableSemaphore : Vk.Semaphore;
        renderFinishedSemaphore : Vk.Semaphore;
        inFlightFence : Vk.Fence;
    };
}

// Surface creation
impl_window_target_init_pre_register :: (windowTarget : *WindowTarget, windowHandle : Chamber.WindowHandle) -> bool {
    #if OS == .LINUX {
        surfaceCI : Vk.XcbSurfaceCreateInfoKHR;
        surfaceCI.sType = Vk.StructureType.XcbSurfaceCreateInfoKhr;
        surfaceCI.connection = windowHandle.xcb.connection;
        surfaceCI.window = windowHandle.xcb.window;

        RESULT_CHECK(Vk.create_xcb_surface_khr(windowTarget.engine.instance, *surfaceCI, null, *windowTarget.surface),
                     "Unable to create XCB surface.");
    }

    return true;
}

impl_window_target_init_post_register :: (windowTarget : *WindowTarget) -> bool {
    if !_init_command_pool(windowTarget) then return false;
    if !_init_frame_objects(windowTarget) then return false;
    if !_init_swapchain(windowTarget) then return false;
    if !_init_render_pass(windowTarget) then return false;

    return true;
}

impl_window_target_cleanup :: (windowTarget : *WindowTarget) {
    Vk.device_wait_idle(windowTarget.engine.device);

    _cleanup_render_pass(windowTarget);
    _cleanup_swapchain(windowTarget);
    Basic.array_free(windowTarget.framebuffers);
    Basic.array_free(windowTarget.swapchainImageViews);

    for *frameObject : windowTarget.frameObjects {
        Vk.destroy_semaphore(windowTarget.engine.device, frameObject.imageAvailableSemaphore, null);
        Vk.destroy_semaphore(windowTarget.engine.device, frameObject.renderFinishedSemaphore, null);
        Vk.destroy_fence(windowTarget.engine.device, frameObject.inFlightFence, null);
        Vk.free_command_buffers(windowTarget.engine.device, windowTarget.commandPool, 1, *frameObject.commandBuffer);
    }

    Vk.destroy_command_pool(windowTarget.engine.device, windowTarget.commandPool, null);

    Vk.destroy_surface_khr(windowTarget.engine.instance, windowTarget.surface, null);

    // Reset memory
    <<windowTarget = WindowTarget.{};
}

_impl_window_target_draw :: (windowTarget : *WindowTarget, frameIndex : u8) -> bool {
    frameObject := *windowTarget.frameObjects[frameIndex];

    // ----- Swapchain image

    swapchainImageIndex : u32;
    result := Vk.acquire_next_image_khr(windowTarget.engine.device, windowTarget.swapchain, ~0,
                                        frameObject.imageAvailableSemaphore, null, *swapchainImageIndex);

    if result == Vk.Result.ErrorOutOfDateKhr {
        _recreate_swapchain(windowTarget);
        return false;
    } else {
        RESULT_CHECK(result, "Unable to acquire next swapchain image.");
    }

    // ----- Command buffer

    // Wait for availability of command buffer with fence.
    // @todo Should just skip the draw instead of waiting? Maybe use the last parameter to decide when to stop.
    // Same timeout question with acquire_next_image_khr below!
    Vk.wait_for_fences(windowTarget.engine.device, 1, *frameObject.inFlightFence, Vk.TRUE, ~0);
    Vk.reset_fences(windowTarget.engine.device, 1, *frameObject.inFlightFence);

    commandBuffer := frameObject.commandBuffer;
    commandBufferBeginInfo : Vk.CommandBufferBeginInfo;
    commandBufferBeginInfo.sType = Vk.StructureType.CommandBufferBeginInfo;

    RESULT_CHECK(Vk.begin_command_buffer(commandBuffer, *commandBufferBeginInfo),
                    "Unable to begin command buffer.");

    // @todo Add scene recording... in parallel!

    // @note Not doing anything below in parallel, would be useless.

    renderPassBeginInfo : Vk.RenderPassBeginInfo;
    renderPassBeginInfo.sType = Vk.StructureType.RenderPassBeginInfo;
    renderPassBeginInfo.renderPass = windowTarget.renderPass;
    renderPassBeginInfo.framebuffer = windowTarget.framebuffers[swapchainImageIndex];

    renderPassBeginInfo.renderArea.extent.width = windowTarget.extent.width;
    renderPassBeginInfo.renderArea.extent.height = windowTarget.extent.height;

    clearColor : Vk.ClearValue;
    clearColor.color._float32 = .[0., 0., 0., 1.];
    renderPassBeginInfo.clearValueCount = 1;
    renderPassBeginInfo.pClearValues = *clearColor;

    Vk.cmd_begin_render_pass(commandBuffer, *renderPassBeginInfo, Vk.SubpassContents.Inline);
    Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, windowTarget.pipeline);
    Vk.cmd_draw(commandBuffer, 3, 1, 0, 0);
    Vk.cmd_end_render_pass(commandBuffer);

    Vk.end_command_buffer(commandBuffer);

    // ----- Submit

    waitDstStageMask := cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;

    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = Vk.StructureType.SubmitInfo;
    submitInfo.waitSemaphoreCount = 1;
    submitInfo.pWaitSemaphores = *frameObject.imageAvailableSemaphore;
    submitInfo.pWaitDstStageMask = *waitDstStageMask;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = *frameObject.renderFinishedSemaphore;

    RESULT_CHECK(Vk.queue_submit(windowTarget.engine.graphicsQueue, 1, *submitInfo, frameObject.inFlightFence),
                 "Unable to submit command buffer.");

    // ----- Present

    presentInfo : Vk.PresentInfoKHR;
    presentInfo.sType = Vk.StructureType.PresentInfoKhr;
    presentInfo.waitSemaphoreCount = 1;
    presentInfo.pWaitSemaphores = *frameObject.renderFinishedSemaphore;
    presentInfo.swapchainCount = 1;
    presentInfo.pSwapchains = *windowTarget.swapchain;
    presentInfo.pImageIndices = *swapchainImageIndex;

    Vk.queue_present_khr(windowTarget.engine.presentQueue, *presentInfo);

    return true;
}

#scope_file

_init_command_pool :: (windowTarget : *WindowTarget) -> bool {
    commandPoolCI : Vk.CommandPoolCreateInfo;
    commandPoolCI.sType = Vk.StructureType.CommandPoolCreateInfo;
    commandPoolCI.queueFamilyIndex = cast(u32) windowTarget.engine.queueIndices.graphics;
    commandPoolCI.flags = cast(u32) Vk.CommandPoolCreateFlagBits.ResetCommandBuffer;

    RESULT_CHECK(Vk.create_command_pool(windowTarget.engine.device, *commandPoolCI, null, *windowTarget.commandPool),
                 "Unable to create command pool.");
    return true;
}

_init_frame_objects :: (windowTarget : *WindowTarget) -> bool {
    for *frameObject : windowTarget.frameObjects {
        semaphoreCI : Vk.SemaphoreCreateInfo;
        semaphoreCI.sType = Vk.StructureType.SemaphoreCreateInfo;
        RESULT_CHECK(Vk.create_semaphore(windowTarget.engine.device, *semaphoreCI, null, *frameObject.imageAvailableSemaphore),
                    "Unable to create semaphore.");
        RESULT_CHECK(Vk.create_semaphore(windowTarget.engine.device, *semaphoreCI, null, *frameObject.renderFinishedSemaphore),
                    "Unable to create semaphore.");

        fenceCI : Vk.FenceCreateInfo;
        fenceCI.sType = Vk.StructureType.FenceCreateInfo;
        fenceCI.flags = cast(u32) Vk.FenceCreateFlagBits.Signaled;
        RESULT_CHECK(Vk.create_fence(windowTarget.engine.device, *fenceCI, null, *frameObject.inFlightFence),
                     "Unable to create fence.");

        commandBufferAI : Vk.CommandBufferAllocateInfo;
        commandBufferAI.sType = Vk.StructureType.CommandBufferAllocateInfo;
        commandBufferAI.commandPool = windowTarget.commandPool;
        commandBufferAI.level = Vk.CommandBufferLevel.Primary;
        commandBufferAI.commandBufferCount = 1;
        RESULT_CHECK(Vk.allocate_command_buffers(windowTarget.engine.device, *commandBufferAI, *frameObject.commandBuffer),
                    "Unable to allocate command buffers.");
    }

    return true;
}

_init_swapchain :: (windowTarget : *WindowTarget) -> bool {
    surfaceCapabilities : Vk.SurfaceCapabilitiesKHR;
    surfaceFormats : [..]Vk.SurfaceFormatKHR;
    surfacePresentModes : [..]Vk.PresentModeKHR;

    Vk.get_physical_device_surface_capabilities_khr(windowTarget.engine.physicalDevice, windowTarget.surface, *surfaceCapabilities);
    Vk.array_fill(*surfaceFormats, Vk.get_physical_device_surface_formats_khr, windowTarget.engine.physicalDevice, windowTarget.surface);
    Vk.array_fill(*surfacePresentModes, Vk.get_physical_device_surface_present_modes_khr, windowTarget.engine.physicalDevice, windowTarget.surface);
    defer Basic.array_free(surfaceFormats);
    defer Basic.array_free(surfacePresentModes);

    windowTarget.extent = _select_best_extent(surfaceCapabilities);
    windowTarget.swapchainSurfaceFormat = _select_best_surface_format(surfaceFormats);
    presentMode := _select_best_present_mode(surfacePresentModes);

    // @note 0 as maxImageCount means infinite
    imageCount := surfaceCapabilities.minImageCount + 1;
    if surfaceCapabilities.maxImageCount != 0 &&
       imageCount > surfaceCapabilities.maxImageCount {
        imageCount = surfaceCapabilities.maxImageCount;
    }

    swapchainCI : Vk.SwapchainCreateInfoKHR;
    swapchainCI.sType = Vk.StructureType.SwapchainCreateInfoKhr;
    swapchainCI.surface = windowTarget.surface;
    swapchainCI.minImageCount = imageCount;
    swapchainCI.imageFormat = windowTarget.swapchainSurfaceFormat.format;
    swapchainCI.imageColorSpace = windowTarget.swapchainSurfaceFormat.colorSpace;
    swapchainCI.imageExtent.width = windowTarget.extent.width;
    swapchainCI.imageExtent.height = windowTarget.extent.height;
    swapchainCI.imageArrayLayers = 1;
    // @todo TransferDst to avoid copying from scene out image?
    swapchainCI.imageUsage = cast(Vk.ImageUsageFlags) Vk.ImageUsageFlagBits.ColorAttachment;
    // @todo Exclusive Not always possible
    swapchainCI.imageSharingMode = Vk.SharingMode.Exclusive;
    swapchainCI.preTransform = surfaceCapabilities.currentTransform;
    swapchainCI.compositeAlpha = Vk.CompositeAlphaFlagBitsKHR.Opaque;
    swapchainCI.presentMode = presentMode;
    swapchainCI.clipped = Vk.TRUE;

    RESULT_CHECK(Vk.create_swapchain_khr(windowTarget.engine.device, *swapchainCI, null, *windowTarget.swapchain),
                 "Unable to create swapchain.");

    // Swapchain images
    Vk.array_fill(*windowTarget.swapchainImages, Vk.get_swapchain_images_khr, windowTarget.engine.device, windowTarget.swapchain);

    Basic.array_resize(*windowTarget.swapchainImageViews, windowTarget.swapchainImages.count);
    for image, imageIndex : windowTarget.swapchainImages {
        imageViewCI : Vk.ImageViewCreateInfo;
        imageViewCI.sType = Vk.StructureType.ImageViewCreateInfo;
        imageViewCI.image = image;
        imageViewCI.viewType = Vk.ImageViewType._2D;
        imageViewCI.format = windowTarget.swapchainSurfaceFormat.format;
        imageViewCI.components.r = Vk.ComponentSwizzle.Identity;
        imageViewCI.components.g = Vk.ComponentSwizzle.Identity;
        imageViewCI.components.b = Vk.ComponentSwizzle.Identity;
        imageViewCI.components.a = Vk.ComponentSwizzle.Identity;
        imageViewCI.subresourceRange.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
        imageViewCI.subresourceRange.levelCount = 1;
        imageViewCI.subresourceRange.layerCount = 1;

        RESULT_CHECK(Vk.create_image_view(windowTarget.engine.device, *imageViewCI, null, *windowTarget.swapchainImageViews[imageIndex]),
                     "Unable to create swapchain image view.");
    }

    return true;
}

_init_render_pass :: (windowTarget : *WindowTarget) -> bool {
    engine := windowTarget.engine;

    // ----- Shaders

    vertShaderModule := _impl_engine_get_shader_module(windowTarget.engine, "./examples/magma-scenes/vert.spv");
    fragShaderModule := _impl_engine_get_shader_module(windowTarget.engine, "./examples/magma-scenes/frag.spv");

    vertShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    vertShaderStageCI.sType = Vk.StructureType.PipelineShaderStageCreateInfo;
    vertShaderStageCI.stage = Vk.ShaderStageFlagBits.Vertex;
    vertShaderStageCI.module = vertShaderModule;
    vertShaderStageCI.pName = "main";
    // @todo Using pSpecializationInfo might be interesting here!

    fragShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    fragShaderStageCI.sType = Vk.StructureType.PipelineShaderStageCreateInfo;
    fragShaderStageCI.stage = Vk.ShaderStageFlagBits.Fragment;
    fragShaderStageCI.module = fragShaderModule;
    fragShaderStageCI.pName = "main";

    shaderStages : [2]Vk.PipelineShaderStageCreateInfo;
    shaderStages[0] = vertShaderStageCI;
    shaderStages[1] = fragShaderStageCI;

    // ---

    vertexInputStateCI : Vk.PipelineVertexInputStateCreateInfo;
    vertexInputStateCI.sType = Vk.StructureType.PipelineVertexInputStateCreateInfo;

    inputAssemblyStateCI : Vk.PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.sType = Vk.StructureType.PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.topology = Vk.PrimitiveTopology.TriangleList;
    inputAssemblyStateCI.primitiveRestartEnable = Vk.FALSE;

    // ---

    viewport : Vk.Viewport;
    viewport.width = cast(float32) windowTarget.extent.width;
    viewport.height = cast(float32) windowTarget.extent.height;

    scissor : Vk.Rect2D;
    scissor.extent.width = windowTarget.extent.width;
    scissor.extent.height = windowTarget.extent.height;

    viewportStateCI : Vk.PipelineViewportStateCreateInfo;
    viewportStateCI.sType = Vk.StructureType.PipelineViewportStateCreateInfo;
    viewportStateCI.viewportCount = 1;
    viewportStateCI.pViewports = *viewport;
    viewportStateCI.scissorCount = 1;
    viewportStateCI.pScissors = *scissor;

    // ---

    rasterizationStateCI : Vk.PipelineRasterizationStateCreateInfo;
    rasterizationStateCI.sType = Vk.StructureType.PipelineRasterizationStateCreateInfo;
    rasterizationStateCI.depthClampEnable = Vk.FALSE; // @todo True for shadow maps?
    rasterizationStateCI.polygonMode = Vk.PolygonMode.Fill;
    rasterizationStateCI.lineWidth = 1.;
    rasterizationStateCI.cullMode = cast(u32) Vk.CullModeFlagBits.Back;
    rasterizationStateCI.frontFace = Vk.FrontFace.Clockwise;
    // @todo .depthBiasEnable Useful for shadow maps?

    // ---

    multisampleStateCI : Vk.PipelineMultisampleStateCreateInfo;
    multisampleStateCI.sType = Vk.StructureType.PipelineMultisampleStateCreateInfo;
    multisampleStateCI.sampleShadingEnable = Vk.FALSE;
    multisampleStateCI.rasterizationSamples = Vk.SampleCountFlagBits._1;

    // ---

    colorBlendAttachmentState : Vk.PipelineColorBlendAttachmentState;
    colorBlendAttachmentState.colorWriteMask = cast(u32) (Vk.ColorComponentFlagBits.R | Vk.ColorComponentFlagBits.G | Vk.ColorComponentFlagBits.B | Vk.ColorComponentFlagBits.A);
    colorBlendAttachmentState.blendEnable = Vk.FALSE;

    colorBlendStateCI : Vk.PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.sType = Vk.StructureType.PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.logicOpEnable = Vk.FALSE;
    colorBlendStateCI.attachmentCount = 1;
    colorBlendStateCI.pAttachments = *colorBlendAttachmentState;

    // --- Pipeline Layout

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = Vk.StructureType.PipelineLayoutCreateInfo;

    RESULT_CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *windowTarget.pipelineLayout),
                 "Unable to create pipeline layout.");

    // ----- RenderPass

    attachmentDesc : Vk.AttachmentDescription;
    attachmentDesc.format = windowTarget.swapchainSurfaceFormat.format;
    attachmentDesc.samples = Vk.SampleCountFlagBits._1;
    attachmentDesc.loadOp = Vk.AttachmentLoadOp.Clear;
    attachmentDesc.storeOp = Vk.AttachmentStoreOp.Store;
    attachmentDesc.stencilLoadOp = Vk.AttachmentLoadOp.DontCare;
    attachmentDesc.stencilStoreOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDesc.initialLayout = Vk.ImageLayout.Undefined;
    attachmentDesc.finalLayout = Vk.ImageLayout.PresentSrcKhr;

    attachmentRef : Vk.AttachmentReference;
    attachmentRef.attachment = 0;
    attachmentRef.layout = Vk.ImageLayout.ColorAttachmentOptimal;

    subpassDesc : Vk.SubpassDescription;
    subpassDesc.pipelineBindPoint = Vk.PipelineBindPoint.Graphics;
    subpassDesc.colorAttachmentCount = 1;
    subpassDesc.pColorAttachments = *attachmentRef;

    // @todo Clarify, why is this needed really?
    subpassDependency : Vk.SubpassDependency;
    subpassDependency.srcSubpass = cast,no_check(u32) Vk.SUBPASS_EXTERNAL;
    subpassDependency.dstSubpass = 0;
    subpassDependency.srcStageMask = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    subpassDependency.srcAccessMask = 0;
    subpassDependency.dstStageMask = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    subpassDependency.dstAccessMask = cast(u32) Vk.AccessFlagBits.ColorAttachmentWrite;

    renderPassCI : Vk.RenderPassCreateInfo;
    renderPassCI.sType = Vk.StructureType.RenderPassCreateInfo;
    renderPassCI.attachmentCount = 1;
    renderPassCI.pAttachments = *attachmentDesc;
    renderPassCI.subpassCount = 1;
    renderPassCI.pSubpasses = *subpassDesc;
    renderPassCI.dependencyCount = 1;
    renderPassCI.pDependencies = *subpassDependency;

    RESULT_CHECK(Vk.create_render_pass(engine.device, *renderPassCI, null, *windowTarget.renderPass),
                 "Unable to create render pass.");

    // ----- Pipeline

    pipelineCI : Vk.GraphicsPipelineCreateInfo;
    pipelineCI.sType = Vk.StructureType.GraphicsPipelineCreateInfo;
    pipelineCI.stageCount = shaderStages.count;
    pipelineCI.pStages = shaderStages.data;
    pipelineCI.pVertexInputState = *vertexInputStateCI;
    pipelineCI.pInputAssemblyState = *inputAssemblyStateCI;
    pipelineCI.pViewportState = *viewportStateCI;
    pipelineCI.pRasterizationState = *rasterizationStateCI;
    pipelineCI.pMultisampleState = *multisampleStateCI;
    pipelineCI.pDepthStencilState = null;
    pipelineCI.pColorBlendState = *colorBlendStateCI;
    pipelineCI.pDynamicState = null;
    pipelineCI.layout = windowTarget.pipelineLayout;
    pipelineCI.renderPass = windowTarget.renderPass;
    pipelineCI.subpass = 0;
    pipelineCI.basePipelineHandle = null; // @todo Useful some day?

    RESULT_CHECK(Vk.create_graphics_pipelines(engine.device, null, 1, *pipelineCI, null, *windowTarget.pipeline),
                 "Unable to create graphics pipeline.");

    // ----- Framebuffers

    Basic.array_resize(*windowTarget.framebuffers, windowTarget.swapchainImageViews.count);
    for imageView, imageViewIndex : windowTarget.swapchainImageViews {
        framebufferCI : Vk.FramebufferCreateInfo;
        framebufferCI.sType = Vk.StructureType.FramebufferCreateInfo;
        framebufferCI.renderPass = windowTarget.renderPass;
        framebufferCI.attachmentCount = 1;
        framebufferCI.pAttachments = *imageView;
        framebufferCI.width = windowTarget.extent.width;
        framebufferCI.height = windowTarget.extent.height;
        framebufferCI.layers = 1;

        RESULT_CHECK(Vk.create_framebuffer(windowTarget.engine.device, *framebufferCI, null, *windowTarget.framebuffers[imageViewIndex]),
                     "Unable to create framebuffer.");
    }

    return true;
}

_select_best_extent :: (surfaceCapabilities : Vk.SurfaceCapabilitiesKHR) -> Chamber.uvec2 {
    extent : Chamber.uvec2;

    // @note Some window manager set the current extent to UINT32_MAX meaning
    // that we have the choice.
    if surfaceCapabilities.currentExtent.width != ~0 {
        extent.width = surfaceCapabilities.currentExtent.width;
        extent.height = surfaceCapabilities.currentExtent.height;
        return extent;
    }

    // @todo This might be getting wrong with some Retina-like displays.
    // We should fallback to the window information somehow.
    extent.width = (surfaceCapabilities.minImageExtent.width + surfaceCapabilities.maxImageExtent.width) / 2;
    extent.height = (surfaceCapabilities.minImageExtent.height + surfaceCapabilities.maxImageExtent.height) / 2;
    return extent;
}

_select_best_surface_format :: (surfaceFormats : []Vk.SurfaceFormatKHR) -> Vk.SurfaceFormatKHR {
    for surfaceFormat : surfaceFormats {
        // Prefer SRGB if available.
        if surfaceFormat.format == Vk.Format.B8G8R8A8Srgb &&
           surfaceFormat.colorSpace == Vk.ColorSpaceKHR.SrgbNonlinear {
            return surfaceFormat;
        }
    }

    return surfaceFormats[0];
}

_select_best_present_mode :: (presentModes : []Vk.PresentModeKHR) -> Vk.PresentModeKHR {
    for presentMode : presentModes {
        if presentMode == Vk.PresentModeKHR.Mailbox {
            return presentMode;
        }
    }
    return Vk.PresentModeKHR.Fifo;
}

_cleanup_swapchain :: (windowTarget : *WindowTarget) {
    for framebuffer : windowTarget.framebuffers {
        Vk.destroy_framebuffer(windowTarget.engine.device, framebuffer, null);
    }

    for imageView : windowTarget.swapchainImageViews {
        Vk.destroy_image_view(windowTarget.engine.device, imageView, null);
    }

    Vk.destroy_swapchain_khr(windowTarget.engine.device, windowTarget.swapchain, null);
}

_cleanup_render_pass :: (windowTarget : *WindowTarget) {
    Vk.destroy_render_pass(windowTarget.engine.device, windowTarget.renderPass, null);
    Vk.destroy_pipeline(windowTarget.engine.device, windowTarget.pipeline, null);
    Vk.destroy_pipeline_layout(windowTarget.engine.device, windowTarget.pipelineLayout, null);
}

_recreate_swapchain :: (windowTarget : *WindowTarget) {
    Vk.device_wait_idle(windowTarget.engine.device);

    _cleanup_render_pass(windowTarget);
    _cleanup_swapchain(windowTarget);

    _init_swapchain(windowTarget);
    _init_render_pass(windowTarget);
}
