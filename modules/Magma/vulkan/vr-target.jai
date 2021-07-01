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
    vr := *vrTarget.engine.vr;

    if !vrTarget.sessionRunning then return false;

    frameWI : Xr.FrameWaitInfo;
    frameWI.type = .TypeFrameWaitInfo;
    frameState : Xr.FrameState;
    frameState.type = .TypeFrameState;
    _CHECK(Xr.wait_frame(vrTarget.session, *frameWI, *frameState),
           "Unable to wait for OpenXR frame.");

    frameBI : Xr.FrameBeginInfo;
    frameBI.type = .TypeFrameBeginInfo;
    _CHECK(Xr.begin_frame(vrTarget.session, *frameBI),
           "Unable to begin OpenXR frame.");

    compositionLayer : Xr.CompositionLayerProjection;
    compositionLayer.type = .TypeCompositionLayerProjection;
    compositionLayers : [1]*Xr.CompositionLayerBaseHeader;
    compositionLayerViews : [2]Xr.CompositionLayerProjectionView;

    hasRendered := false;
    if frameState.shouldRender {
        if _render(vrTarget, frameIndex, *frameState, compositionLayerViews) {
            hasRendered = true;
            compositionLayer.space = vrTarget.referenceSpace;
            compositionLayer.viewCount = compositionLayerViews.count;
            compositionLayer.views = compositionLayerViews.data;
            compositionLayers[0] = cast(*Xr.CompositionLayerBaseHeader) *compositionLayer;
        }
    }

    frameEI : Xr.FrameEndInfo;
    frameEI.type = .TypeFrameEndInfo;
    frameEI.displayTime = frameState.predictedDisplayTime;
    frameEI.environmentBlendMode = Xr.EnvironmentBlendMode.Opaque;
    if hasRendered {
        frameEI.layerCount = compositionLayers.count;
        frameEI.layers = compositionLayers.data;
    }

    _CHECK(Xr.end_frame(vrTarget.session, *frameEI),
           "Unable to end OpenXR frame.");

    return true;
}

_render :: (vrTarget : *VrTarget, frameIndex : u8, frameState : *Xr.FrameState, compositionLayerViews : []Xr.CompositionLayerProjectionView) -> bool {
    vr := *vrTarget.engine.vr;

    frameObject := vrTarget.frameObjects[frameIndex];
    Vk.wait_for_fences(vrTarget.engine.device, 1, *frameObject.inFlightFence, Vk.TRUE, ~0);
    Vk.reset_fences(vrTarget.engine.device, 1, *frameObject.inFlightFence);

    // Views...
    viewLI : Xr.ViewLocateInfo;
    viewLI.type = .TypeViewLocateInfo;
    viewLI.viewConfigurationType = .PrimaryStereo;
    viewLI.displayTime = frameState.predictedDisplayTime;
    viewLI.space = vrTarget.referenceSpace;

    viewState : Xr.ViewState;
    viewState.type = .TypeViewState;
    viewCount : u32;

    _CHECK(Xr.locate_views(vrTarget.session, *viewLI, *viewState, cast(u32) vrTarget.views.count, *viewCount, vrTarget.views.data),
            "Unable to locate OpenXR views.");

    for *view, viewIndex : vrTarget.views {
        eye := renderer_get_eye(vrTarget.rendererOutputs[viewIndex].renderer, 0);

        // Going from right-handed Y up, -Z forward coordinate system
        // to ours, right-handed Z up, X forward.
        orientation : Chamber.quat = ---;
        orientation.x = -view.pose.orientation.z;
        orientation.y = -view.pose.orientation.x;
        orientation.z = view.pose.orientation.y;
        orientation.w = view.pose.orientation.w;

        matrix := make_rotation_matrix4(orientation);
        matrix.coef[0][3] = -view.pose.position.z;
        matrix.coef[1][3] = -view.pose.position.x;
        matrix.coef[2][3] = view.pose.position.y;

        eye.viewMatrix = Chamber.inverse_and_prepare_for_projection(matrix);
        Chamber.infinite_perspective_projection(*eye.projectionMatrix, view.fov.angleLeft, view.fov.angleRight, view.fov.angleUp, view.fov.angleDown, 0.1);
        eye_commit(eye);
    }

    if !_renderer_render(vrTarget.rendererOutputs[0].renderer, frameIndex) then return false;
    if !_renderer_render(vrTarget.rendererOutputs[1].renderer, frameIndex) then return false;

    // Our rendering.
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
        rendererOutputExtent := _renderer_output_get_extent(vrTarget.rendererOutputs[viewIndex]);
        rendererImage := _renderer_output_get_image(vrTarget.rendererOutputs[viewIndex], frameIndex);
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
        Vk.cmd_blit_image(commandBuffer, rendererImage, Vk.ImageLayout.TransferSrcOptimal,
                          swapchainImage, Vk.ImageLayout.TransferDstOptimal, 1, *imageBlit, filter);
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

    bestFormatIndex := -1;
    for format, formatIndex : swapchainFormats {
        if cast(Vk.Format) format == .R8G8B8A8Srgb {
            bestFormatIndex = formatIndex;
            break;
        }
    }

    _CHECK(bestFormatIndex != -1, "Could not find valid OpenXR swapchain format.");

    for *swapchainInfo, viewIndex : vrTarget.swapchainInfos {
        // @todo Make that user configurable?
        swapchainInfo.extent.width = vrTarget.configurationViews[viewIndex].recommendedImageRectWidth;
        swapchainInfo.extent.height = vrTarget.configurationViews[viewIndex].recommendedImageRectHeight;

        swapchainCI : Xr.SwapchainCreateInfo;
        swapchainCI.type = .TypeSwapchainCreateInfo;
        swapchainCI.arraySize = 1;
        swapchainCI.format = bestFormatIndex;
        swapchainCI.width = swapchainInfo.extent.width;
        swapchainCI.height = swapchainInfo.extent.height;
        swapchainCI.mipCount = 1;
        swapchainCI.faceCount = 1;
        swapchainCI.sampleCount = 1;
        swapchainCI.usageFlags = Xr.SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
        _CHECK(Xr.create_swapchain(vrTarget.session, *swapchainCI, *swapchainInfo.swapchain),
               "Unable to create OpenXR session.");

        Xr.array_fill_stype(*swapchainInfo.images, Xr.enumerate_swapchain_images, swapchainInfo.swapchain, .TypeSwapchainImageVulkanKhr);

        for *swapchainImage : swapchainInfo.images {
            _set_debug_utils_name(vrTarget.engine.device, cast(Vk.Image) swapchainImage.image, "vr-target.swapchainImages[][].image");
        }
    }

    return true;
}
