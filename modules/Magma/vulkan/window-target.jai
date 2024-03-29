#scope_module

WindowTargetImpl :: struct {
    surface : Vk.SurfaceKHR;

    swapchain : Vk.SwapchainKHR;
    swapchainSurfaceFormat : Vk.SurfaceFormatKHR;
    swapchainImages : [..]Vk.Image;
    swapchainImageIndex : u32; // Set during render, reused during present.

    commandPool : Vk.CommandPool;

    FrameObject :: struct {
        commandBuffer : Vk.CommandBuffer;
        imageAvailableSemaphore : Vk.Semaphore;
        renderSemaphore : Vk.Semaphore;
        inFlightFence : Vk.Fence;
    }
    frameObjects : [Engine.FRAME_INDEX_COUNT]FrameObject;
}

// Surface creation
impl_window_target_init :: (windowTarget : *WindowTarget, windowHandle : Chamber.WindowHandle) -> bool {
    #if OS == .LINUX {
        surfaceCI : Vk.XcbSurfaceCreateInfoKHR;
        surfaceCI.sType = .XcbSurfaceCreateInfoKhr;
        surfaceCI.connection = windowHandle.xcb.connection;
        surfaceCI.window = windowHandle.xcb.window;

        _CHECK(Vk.create_xcb_surface_khr(windowTarget.engine.instance, *surfaceCI, null, *windowTarget.surface),
               "Unable to create XCB surface.");
    } else #if OS == .WINDOWS {
        surfaceCI : Vk.Win32SurfaceCreateInfoKHR;
        surfaceCI.sType = .Win32SurfaceCreateInfoKhr;
        surfaceCI.hinstance = windowHandle.dwm.hInstance;
        surfaceCI.hwnd = windowHandle.dwm.hWnd;

        _CHECK(Vk.create_win32_surface_khr(windowTarget.engine.instance, *surfaceCI, null, *windowTarget.surface),
               "Unable to create Win32 surface.");
    }

    return true;
}

impl_window_target_cleanup :: (windowTarget : *WindowTarget) {
    Vk.device_wait_idle(windowTarget.engine.device);

    _cleanup_swapchain(windowTarget);
    Basic.array_free(windowTarget.swapchainImages);

    for *frameObject : windowTarget.frameObjects {
        Vk.destroy_semaphore(windowTarget.engine.device, frameObject.imageAvailableSemaphore, null);
        Vk.destroy_semaphore(windowTarget.engine.device, frameObject.renderSemaphore, null);
        Vk.destroy_fence(windowTarget.engine.device, frameObject.inFlightFence, null);
        Vk.free_command_buffers(windowTarget.engine.device, windowTarget.commandPool, 1, *frameObject.commandBuffer);
    }

    Vk.destroy_command_pool(windowTarget.engine.device, windowTarget.commandPool, null);

    Vk.destroy_surface_khr(windowTarget.engine.instance, windowTarget.surface, null);
}

_window_target_post_init :: (windowTarget : *WindowTarget) -> bool {
    if !_create_graphics_command_pool(windowTarget.engine, *windowTarget.commandPool, true) then return false;

    if !_init_frame_objects(windowTarget) then return false;
    if !_init_swapchain(windowTarget) then return false;

    return true;
}

_window_target_draw :: (windowTarget : *WindowTarget, frameIndex : u8) -> bool {
    if windowTarget.rendererOutput.renderer == null {
        // Nothing is bound to this target, skip it.
        return true;
    }

    frameObject := *windowTarget.frameObjects[frameIndex];

    // Swapchain image
    result := Vk.acquire_next_image_khr(windowTarget.engine.device, windowTarget.swapchain, 5_000_000_000,
                                        frameObject.imageAvailableSemaphore, null, *windowTarget.swapchainImageIndex);

    if result == .ErrorOutOfDateKhr || result == .SuboptimalKhr {
        _recreate_swapchain(windowTarget);
        return false;
    } else {
        _CHECK(result, "Unable to acquire next swapchain image: %", result);
    }

    if !_renderer_render(windowTarget.rendererOutput.renderer, frameIndex) then return false;
    if !_render(windowTarget, frameIndex) then return false;
    if !_present(windowTarget, frameObject) then return false;

    return true;
}

#scope_file

_render :: (windowTarget : *WindowTarget, frameIndex : u8) -> bool {
    frameObject := windowTarget.frameObjects[frameIndex];

    Vk.wait_for_fences(windowTarget.engine.device, 1, *frameObject.inFlightFence, Vk.TRUE, ~0);
    Vk.reset_fences(windowTarget.engine.device, 1, *frameObject.inFlightFence);

    commandBuffer := frameObject.commandBuffer;
    commandBufferBeginInfo : Vk.CommandBufferBeginInfo;
    commandBufferBeginInfo.sType = .CommandBufferBeginInfo;

    _CHECK(Vk.begin_command_buffer(commandBuffer, *commandBufferBeginInfo),
           "Unable to begin command buffer.");

    // ----- Blitting the image handle to the swapchain one

    rendererOutputExtent := renderer_output_get_extent(windowTarget.rendererOutput);
    rendererImageInfo := _renderer_output_get_image_info(windowTarget.rendererOutput, frameIndex);
    swapchainImage := windowTarget.swapchainImages[windowTarget.swapchainImageIndex];

    imageBlit : Vk.ImageBlit;
    imageBlit.srcSubresource.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
    imageBlit.srcSubresource.layerCount = 1;
    imageBlit.srcOffsets[1].x = cast(s32) rendererOutputExtent.width;
    imageBlit.srcOffsets[1].y = cast(s32) rendererOutputExtent.height;
    imageBlit.srcOffsets[1].z = 1;
    imageBlit.dstSubresource.aspectMask = cast(u32) Vk.ImageAspectFlagBits.Color;
    imageBlit.dstSubresource.layerCount = 1;
    imageBlit.dstOffsets[1].x = cast(s32) windowTarget.extent.width;
    imageBlit.dstOffsets[1].y = cast(s32) windowTarget.extent.height;
    imageBlit.dstOffsets[1].z = 1;

    filter := Vk.Filter.Linear;
    if windowTarget.options.filter == .Nearest then filter = Vk.Filter.Nearest;

    if rendererImageInfo.layout != .Undefined {
        _change_image_layout(commandBuffer, swapchainImage, .DontCare, .TransferOutput);
        _change_image_layout(commandBuffer, rendererImageInfo.image, rendererImageInfo.usage, .TransferInput);
        Vk.cmd_blit_image(commandBuffer, rendererImageInfo.image, Vk.ImageLayout.TransferSrcOptimal,
                          swapchainImage, Vk.ImageLayout.TransferDstOptimal, 1, *imageBlit, filter);
        _change_image_layout(commandBuffer, rendererImageInfo.image, .TransferInput, rendererImageInfo.usage);
        _change_image_layout(commandBuffer, swapchainImage, .TransferOutput, .PresentInput);
    } else {
        _change_image_layout(commandBuffer, swapchainImage, .DontCare, .PresentInput);
    }

    Vk.end_command_buffer(commandBuffer);

    // ----- Submit

    renderSemaphore, renderSemaphoreFinishedValue := _renderer_output_get_render_semaphore(windowTarget.rendererOutput, frameIndex);

    waitSemaphores : [2]Vk.Semaphore;
    waitSemaphores[0] = renderSemaphore;
    waitSemaphores[1] = frameObject.imageAvailableSemaphore;

    waitDstStageMasks : [2]u32;
    waitDstStageMasks[0] = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    waitDstStageMasks[1] = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;

    timelineSemaphoreSI : Vk.TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.sType = .TimelineSemaphoreSubmitInfo;
    // @note Only the index 0 will be read, as it will be the only timeline semaphore of the two.
    // So we can pass only one value here without issue.
    timelineSemaphoreSI.waitSemaphoreValueCount = waitSemaphores.count;
    timelineSemaphoreSI.pWaitSemaphoreValues = *renderSemaphoreFinishedValue;

    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = .SubmitInfo;
    submitInfo.waitSemaphoreCount = cast(u32) waitSemaphores.count;
    submitInfo.pWaitSemaphores = waitSemaphores.data;
    submitInfo.pWaitDstStageMask = waitDstStageMasks.data;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = *frameObject.renderSemaphore;
    submitInfo.pNext = *timelineSemaphoreSI;

    _CHECK(Vk.queue_submit(windowTarget.engine.graphicsQueue, 1, *submitInfo, frameObject.inFlightFence),
           "Unable to submit command buffer.");

    return true;
}

_present :: (windowTarget : *WindowTarget, frameObject : *WindowTarget.FrameObject) -> bool {
    presentInfo : Vk.PresentInfoKHR;
    presentInfo.sType = .PresentInfoKhr;
    presentInfo.waitSemaphoreCount = 1;
    presentInfo.pWaitSemaphores = *frameObject.renderSemaphore;
    presentInfo.swapchainCount = 1;
    presentInfo.pSwapchains = *windowTarget.swapchain;
    presentInfo.pImageIndices = *windowTarget.swapchainImageIndex;

    result := Vk.queue_present_khr(windowTarget.engine.presentQueue, *presentInfo);

    if result == .ErrorOutOfDateKhr || result == .SuboptimalKhr {
        return true;
    } else {
        _CHECK(result, "Unable to present.");
    }

    return true;
}

_init_frame_objects :: (windowTarget : *WindowTarget) -> bool {
    for *frameObject : windowTarget.frameObjects {
        semaphoreCI : Vk.SemaphoreCreateInfo;
        semaphoreCI.sType = .SemaphoreCreateInfo;
        _CHECK(Vk.create_semaphore(windowTarget.engine.device, *semaphoreCI, null, *frameObject.imageAvailableSemaphore),
               "Unable to create semaphore.");
        _CHECK(Vk.create_semaphore(windowTarget.engine.device, *semaphoreCI, null, *frameObject.renderSemaphore),
               "Unable to create semaphore.");

        fenceCI : Vk.FenceCreateInfo;
        fenceCI.sType = .FenceCreateInfo;
        fenceCI.flags = cast(u32) Vk.FenceCreateFlagBits.Signaled;
        _CHECK(Vk.create_fence(windowTarget.engine.device, *fenceCI, null, *frameObject.inFlightFence),
               "Unable to create fence.");

        commandBufferAI : Vk.CommandBufferAllocateInfo;
        commandBufferAI.sType = .CommandBufferAllocateInfo;
        commandBufferAI.commandPool = windowTarget.commandPool;
        commandBufferAI.level = Vk.CommandBufferLevel.Primary;
        commandBufferAI.commandBufferCount = 1;
        _CHECK(Vk.allocate_command_buffers(windowTarget.engine.device, *commandBufferAI, *frameObject.commandBuffer),
               "Unable to allocate command buffers.");
        _set_debug_utils_name(windowTarget.engine.device, frameObject.commandBuffer, "window-target.frameObjects[].commandBuffer");
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
    swapchainCI.sType = .SwapchainCreateInfoKhr;
    swapchainCI.surface = windowTarget.surface;
    swapchainCI.minImageCount = imageCount;
    swapchainCI.imageFormat = windowTarget.swapchainSurfaceFormat.format;
    swapchainCI.imageColorSpace = windowTarget.swapchainSurfaceFormat.colorSpace;
    swapchainCI.imageExtent.width = windowTarget.extent.width;
    swapchainCI.imageExtent.height = windowTarget.extent.height;
    swapchainCI.imageArrayLayers = 1;
    swapchainCI.imageUsage = cast(Vk.ImageUsageFlags) Vk.ImageUsageFlagBits.TransferDst;
    swapchainCI.imageSharingMode = Vk.SharingMode.Exclusive;
    swapchainCI.preTransform = surfaceCapabilities.currentTransform;
    swapchainCI.compositeAlpha = Vk.CompositeAlphaFlagBitsKHR.Opaque;
    swapchainCI.presentMode = presentMode;
    swapchainCI.clipped = Vk.TRUE;
    swapchainCI.preTransform = .Identity;
    swapchainCI.oldSwapchain = windowTarget.swapchain;

    _CHECK(Vk.create_swapchain_khr(windowTarget.engine.device, *swapchainCI, null, *windowTarget.swapchain),
           "Unable to create swapchain.");

    if swapchainCI.oldSwapchain != null && swapchainCI.oldSwapchain != windowTarget.swapchain {
        Vk.destroy_swapchain_khr(windowTarget.engine.device, swapchainCI.oldSwapchain, null);
    }

    // Swapchain images
    Vk.array_fill(*windowTarget.swapchainImages, Vk.get_swapchain_images_khr, windowTarget.engine.device, windowTarget.swapchain);

    for image : windowTarget.swapchainImages {
        _set_debug_utils_name(windowTarget.engine.device, image, "window-target.swapchainImages[]");
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
    immediateAvailable := false;
    fifoRelaxedAvailable := false;

    for presentMode : presentModes {
        // We prefer mailbox if available
        if presentMode == .Mailbox {
            return presentMode;
        } else if presentMode == .Immediate {
            immediateAvailable = true;
        } else if presentMode == .FifoRelaxed {
            fifoRelaxedAvailable = true;
        }
    }

    // We prefer non V-Sync if available
    if immediateAvailable then return .Immediate;
    if fifoRelaxedAvailable then return .FifoRelaxed;

    return .Fifo;
}

_cleanup_swapchain :: (windowTarget : *WindowTarget) {
    Vk.destroy_swapchain_khr(windowTarget.engine.device, windowTarget.swapchain, null);
}

_recreate_swapchain :: (windowTarget : *WindowTarget) {
    Vk.device_wait_idle(windowTarget.engine.device);
    _init_swapchain(windowTarget);
}
