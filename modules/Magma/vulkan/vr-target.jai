#scope_module

VrTargetImpl :: struct {
    commandPool : Vk.CommandPool;

    swapchainInfos : [2]struct {
        swapchain : Xr.Swapchain;
        extent : Chamber.uvec2;
        images : [..]Xr.SwapchainImageVulkanKHR;
    };

    FrameObject :: struct {
        commandBuffer : Vk.CommandBuffer;
        inFlightFence : Vk.Fence;
    }
    frameObjects : [Engine.FRAME_INDEX_COUNT]FrameObject;
}

impl_vr_target_init :: (vrTarget : *VrTarget) -> bool {
    return true;
}

impl_vr_target_cleanup :: (vrTarget : *VrTarget) {
    if !vrTarget.engine.vr.enabled then return;

    for *swapchainInfo : vrTarget.swapchainInfos {
        Basic.array_free(swapchainInfo.images);
    }

    for *frameObject : vrTarget.frameObjects {
        Vk.free_command_buffers(vrTarget.engine.device, vrTarget.commandPool, 1, *frameObject.commandBuffer);
        Vk.destroy_fence(vrTarget.engine.device, frameObject.inFlightFence, null);
    }

    Vk.destroy_command_pool(vrTarget.engine.device, vrTarget.commandPool, null);
}

impl_vr_target_get_graphics_binding :: (vrTarget : *VrTarget) -> Xr.GraphicsBindingVulkanKHR {
    vr := *vrTarget.engine.vr;

    graphicsRequirements : Xr.GraphicsRequirementsVulkanKHR;
    graphicsRequirements.type = .TypeGraphicsRequirementsVulkanKhr;
    Xr.get_vulkan_graphics_requirements_khr(vr.instance, vr.systemId, *graphicsRequirements);

    graphicsBinding : Xr.GraphicsBindingVulkanKHR;
    graphicsBinding.type = .TypeGraphicsBindingVulkanKhr;
    graphicsBinding.instance = vrTarget.engine.instance;
    graphicsBinding.physicalDevice = vrTarget.engine.physicalDevice;
    graphicsBinding.device = vrTarget.engine.device;
    graphicsBinding.queueFamilyIndex = cast(u32) vrTarget.engine.queueIndices.graphics;

    return graphicsBinding;
}

_vr_target_post_init :: (vrTarget : *VrTarget) -> bool {
    if !vrTarget.engine.vr.enabled then return true;

    if !_create_graphics_command_pool(vrTarget.engine, *vrTarget.commandPool, true) then return false;

    if !_init_frame_objects(vrTarget) then return false;
    if !_init_swapchain(vrTarget) then return false;

    return true;
}

_vr_target_draw :: (vrTarget : *VrTarget, frameIndex : u8) -> bool {
    if vrTarget.rendererOutputs[0].renderer == null ||
       vrTarget.rendererOutputs[1].renderer == null ||
       !vrTarget.engine.vr.enabled {
        // Nothing is bound to this target, skip it.
        return true;
    }

    if !_present(vrTarget, frameIndex) then return false;

    return true;
}

#scope_file

_present :: (vrTarget : *VrTarget, frameIndex : u8) -> bool {
    if !vr_target_pre_render(vrTarget) then return false;

    compositionLayer : Xr.CompositionLayerProjection;
    compositionLayer.type = .TypeCompositionLayerProjection;
    compositionLayers : [1]*Xr.CompositionLayerBaseHeader;
    compositionLayerViews : [2]Xr.CompositionLayerProjectionView;

    compositionLayersArrayView : []*Xr.CompositionLayerBaseHeader = compositionLayers;
    compositionLayersArrayView.count = 0;

    if vrTarget.frameState.shouldRender {
        if _render(vrTarget, frameIndex, compositionLayerViews) {
            compositionLayer.space = vrTarget.stageReferenceSpace;
            compositionLayer.viewCount = compositionLayerViews.count;
            compositionLayer.views = compositionLayerViews.data;
            compositionLayers[0] = cast(*Xr.CompositionLayerBaseHeader) *compositionLayer;
            compositionLayersArrayView.count = 1;
        }
    }

    return vr_target_post_render(vrTarget, compositionLayersArrayView);
}

_render :: (vrTarget : *VrTarget, frameIndex : u8, compositionLayerViews : []Xr.CompositionLayerProjectionView) -> bool {
    vr := *vrTarget.engine.vr;

    frameObject := vrTarget.frameObjects[frameIndex];
    Vk.wait_for_fences(vrTarget.engine.device, 1, *frameObject.inFlightFence, Vk.TRUE, ~0);
    Vk.reset_fences(vrTarget.engine.device, 1, *frameObject.inFlightFence);

    vr_target_sync(vrTarget);

    if !_renderer_render(vrTarget.rendererOutputs[0].renderer, frameIndex) then return false;
    if !_renderer_render(vrTarget.rendererOutputs[1].renderer, frameIndex) then return false;

    // ----- Rendering

    commandBuffer := frameObject.commandBuffer;
    commandBufferBeginInfo : Vk.CommandBufferBeginInfo;
    commandBufferBeginInfo.sType = .CommandBufferBeginInfo;

    _CHECK(Vk.begin_command_buffer(commandBuffer, *commandBufferBeginInfo),
           "Unable to begin command buffer.");

    waitSemaphores : [2]Vk.Semaphore;
    waitSemaphoreValues : [2]u64;

    for *swapchainInfo, viewIndex : vrTarget.swapchainInfos {
        swapchainImageAI : Xr.SwapchainImageAcquireInfo;
        swapchainImageAI.type = .TypeSwapchainImageAcquireInfo;
        swapchainImageIndex : u32;
        _CHECK(Xr.acquire_swapchain_image(swapchainInfo.swapchain, *swapchainImageAI, *swapchainImageIndex),
               "Unable to acquire OpenXR swapchain image.");

        swapchainImageWI : Xr.SwapchainImageWaitInfo;
        swapchainImageWI.type = .TypeSwapchainImageWaitInfo;
        swapchainImageWI.timeout = ~0;
        _CHECK(Xr.wait_swapchain_image(swapchainInfo.swapchain, *swapchainImageWI),
               "Unable to wait for OpenXR swapchain image.");

        compositionLayerViews[viewIndex].type = .TypeCompositionLayerProjectionView;
        compositionLayerViews[viewIndex].pose = vrTarget.views[viewIndex].pose;
        compositionLayerViews[viewIndex].fov = vrTarget.views[viewIndex].fov;
        compositionLayerViews[viewIndex].subImage.swapchain = swapchainInfo.swapchain;
        compositionLayerViews[viewIndex].subImage.imageRect.extent.width = cast(s32) swapchainInfo.extent.width;
        compositionLayerViews[viewIndex].subImage.imageRect.extent.height = cast(s32) swapchainInfo.extent.height;

        // Copying image data
        rendererOutputExtent := renderer_output_get_extent(vrTarget.rendererOutputs[viewIndex]);
        rendererImageInfo := _renderer_output_get_image_info(vrTarget.rendererOutputs[viewIndex], frameIndex);
        swapchainImage := swapchainInfo.images[swapchainImageIndex].image;

        renderSemaphore, renderSemaphoreFinishedValue := _renderer_output_get_render_semaphore(vrTarget.rendererOutputs[viewIndex], frameIndex);
        waitSemaphores[viewIndex] = renderSemaphore;
        waitSemaphoreValues[viewIndex] = renderSemaphoreFinishedValue;

        imageBlit : Vk.ImageBlit;
        imageBlit.srcSubresource.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
        imageBlit.srcSubresource.layerCount = 1;
        imageBlit.srcOffsets[1].x = cast(s32) rendererOutputExtent.width;
        imageBlit.srcOffsets[1].y = cast(s32) rendererOutputExtent.height;
        imageBlit.srcOffsets[1].z = 1;
        imageBlit.dstSubresource.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
        imageBlit.dstSubresource.layerCount = 1;
        imageBlit.dstOffsets[1].x = cast(s32) cast(s32) swapchainInfo.extent.width;
        imageBlit.dstOffsets[1].y = cast(s32) cast(s32) swapchainInfo.extent.height;
        imageBlit.dstOffsets[1].z = 1;

        filter := Vk.Filter.Linear;
        if vrTarget.options.filter == .Nearest then filter = Vk.Filter.Nearest;

        _change_image_layout(commandBuffer, swapchainImage, Vk.ImageLayout.ColorAttachmentOptimal, Vk.ImageLayout.TransferDstOptimal);
        _change_image_layout(commandBuffer, rendererImageInfo.image, rendererImageInfo.layout, Vk.ImageLayout.TransferSrcOptimal);
        Vk.cmd_blit_image(commandBuffer, rendererImageInfo.image, Vk.ImageLayout.TransferSrcOptimal,
                          swapchainImage, Vk.ImageLayout.TransferDstOptimal, 1, *imageBlit, filter);
        _change_image_layout(commandBuffer, rendererImageInfo.image, Vk.ImageLayout.TransferSrcOptimal, rendererImageInfo.layout);
        _change_image_layout(commandBuffer, swapchainImage, Vk.ImageLayout.TransferDstOptimal, Vk.ImageLayout.ColorAttachmentOptimal);
    }

    Vk.end_command_buffer(commandBuffer);

    // ----- Submit

    waitDstStageMasks : [2]u32;
    waitDstStageMasks[0] = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    waitDstStageMasks[1] = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;

    timelineSemaphoreSI : Vk.TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.sType = .TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.waitSemaphoreValueCount = waitSemaphoreValues.count;
    timelineSemaphoreSI.pWaitSemaphoreValues = waitSemaphoreValues.data;

    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = .SubmitInfo;
    submitInfo.waitSemaphoreCount = cast(u32) waitSemaphores.count;
    submitInfo.pWaitSemaphores = waitSemaphores.data;
    submitInfo.pWaitDstStageMask = waitDstStageMasks.data;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    submitInfo.pNext = *timelineSemaphoreSI;

    _CHECK(Vk.queue_submit(vrTarget.engine.graphicsQueue, 1, *submitInfo, frameObject.inFlightFence),
           "Unable to submit command buffer.");

    for swapchainInfo : vrTarget.swapchainInfos {
        swapchainImageRI : Xr.SwapchainImageReleaseInfo;
        swapchainImageRI.type = .TypeSwapchainImageReleaseInfo;
        _CHECK(Xr.release_swapchain_image(swapchainInfo.swapchain, *swapchainImageRI),
               "Unable to release OpenXR swapchain image.");
    }

    return true;
}

#scope_file

_init_frame_objects :: (vrTarget : *VrTarget) -> bool {
    for *frameObject : vrTarget.frameObjects {
        fenceCI : Vk.FenceCreateInfo;
        fenceCI.sType = .FenceCreateInfo;
        fenceCI.flags = cast(u32) Vk.FenceCreateFlagBits.Signaled;
        _CHECK(Vk.create_fence(vrTarget.engine.device, *fenceCI, null, *frameObject.inFlightFence),
               "Unable to create fence.");
        _set_debug_utils_name(vrTarget.engine.device, frameObject.inFlightFence, "vr-target.frameObjects[].inFlightFence");

        commandBufferAI : Vk.CommandBufferAllocateInfo;
        commandBufferAI.sType = .CommandBufferAllocateInfo;
        commandBufferAI.commandPool = vrTarget.commandPool;
        commandBufferAI.level = Vk.CommandBufferLevel.Primary;
        commandBufferAI.commandBufferCount = 1;
        _CHECK(Vk.allocate_command_buffers(vrTarget.engine.device, *commandBufferAI, *frameObject.commandBuffer),
               "Unable to allocate command buffers.");
        _set_debug_utils_name(vrTarget.engine.device, frameObject.commandBuffer, "vr-target.frameObjects[].commandBuffer");
    }

    return true;
}

_init_swapchain :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    swapchainFormats : [..]s64;
    Xr.array_fill(*swapchainFormats, Xr.enumerate_swapchain_formats, vrTarget.session);
    defer Basic.array_free(swapchainFormats);

    for *swapchainInfo, viewIndex : vrTarget.swapchainInfos {
        swapchainInfo.extent.width = vr.configurationViews[viewIndex].recommendedImageRectWidth;
        swapchainInfo.extent.height = vr.configurationViews[viewIndex].recommendedImageRectHeight;

        swapchainCI : Xr.SwapchainCreateInfo;
        swapchainCI.type = .TypeSwapchainCreateInfo;
        swapchainCI.arraySize = 1;
        swapchainCI.format = cast(s64) Vk.Format.R8G8B8A8Srgb;
        swapchainCI.width = swapchainInfo.extent.width;
        swapchainCI.height = swapchainInfo.extent.height;
        swapchainCI.mipCount = 1;
        swapchainCI.faceCount = 1;
        swapchainCI.sampleCount = 1;
        swapchainCI.usageFlags = Xr.SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
        _CHECK(Xr.create_swapchain(vrTarget.session, *swapchainCI, *swapchainInfo.swapchain),
               "Unable to create OpenXR swapchain.");

        Xr.array_fill_stype(*swapchainInfo.images, Xr.enumerate_swapchain_images, swapchainInfo.swapchain, .TypeSwapchainImageVulkanKhr);

        for *swapchainImage : swapchainInfo.images {
            _set_debug_utils_name(vrTarget.engine.device, cast(Vk.Image) swapchainImage.image, "vr-target.swapchainImages[][].image");
        }
    }

    return true;
}
