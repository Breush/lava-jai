#scope_module

PostProcessRendererImpl :: struct {
    pipeline : Vk.Pipeline;
    descriptorSetLayout : Vk.DescriptorSetLayout;

    descriptorPool : Vk.DescriptorPool;

    extraFrameObjects : [Engine.FRAME_INDEX_COUNT]struct {
        imageHolder : ImageHolder;
        imageView : Vk.ImageView;
        framebuffer : Vk.Framebuffer;
        descriptorSet : Vk.DescriptorSet;
    };

    FINAL_IMAGE_LAYOUT :: Vk.ImageLayout.ShaderReadOnlyOptimal;
}

impl_post_process_renderer_cleanup :: (postProcessRenderer : *PostProcessRenderer) {
    engine := postProcessRenderer.scene.engine;
    Vk.device_wait_idle(engine.device); // @todo :WaitIdle

    Vk.destroy_pipeline(engine.device, postProcessRenderer.pipeline, null);
    Vk.destroy_descriptor_set_layout(engine.device, postProcessRenderer.descriptorSetLayout, null);
    Vk.destroy_descriptor_pool(engine.device, postProcessRenderer.descriptorPool, null);

    for *extraFrameObject : postProcessRenderer.extraFrameObjects {
        _image_holder_cleanup(*extraFrameObject.imageHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.imageView, null);
        Vk.destroy_framebuffer(engine.device, extraFrameObject.framebuffer, null);
    }
}

impl_post_process_renderer_get_output_extent :: (postProcessRenderer : *PostProcessRenderer, outputIndex : u8) -> Chamber.uvec2 {
    Basic.assert(outputIndex == 0);
    return renderer_output_get_extent(postProcessRenderer.rendererOutput);
}

_post_process_renderer_post_init :: (postProcessRenderer : *PostProcessRenderer) -> bool {
    if !_init_render_pass(postProcessRenderer) then return false;
    if !_init_extra_frame_objects(postProcessRenderer) then return false;

    return true;
}

_post_process_renderer_render :: (postProcessRenderer : *PostProcessRenderer, frameIndex : u8) -> bool {
    if !_renderer_render(postProcessRenderer.rendererOutput.renderer, frameIndex) then return false;

    commandBuffer := postProcessRenderer.frameObjects[frameIndex].commandBuffer;
    extent := renderer_output_get_extent(postProcessRenderer.rendererOutput);

    renderPassBeginInfo : Vk.RenderPassBeginInfo;
    renderPassBeginInfo.sType = .RenderPassBeginInfo;
    renderPassBeginInfo.renderPass = postProcessRenderer.renderPass;
    renderPassBeginInfo.framebuffer = postProcessRenderer.extraFrameObjects[frameIndex].framebuffer;
    renderPassBeginInfo.renderArea.extent.width = extent.width;
    renderPassBeginInfo.renderArea.extent.height = extent.height;

    clearColors : [1]Vk.ClearValue;
    clearColors[0].color._float32 = .[0.1, 0.2, 0.3, 1.];
    renderPassBeginInfo.clearValueCount = clearColors.count;
    renderPassBeginInfo.pClearValues = clearColors.data;

    Vk.cmd_begin_render_pass(commandBuffer, *renderPassBeginInfo, Vk.SubpassContents.Inline);

    descriptorSet := postProcessRenderer.extraFrameObjects[frameIndex].descriptorSet;
    Vk.cmd_bind_descriptor_sets(commandBuffer, .Graphics, postProcessRenderer.pipelineLayout, PostProcessRenderer.SOURCE_DESCRIPTOR_SET_INDEX,
                                1, *descriptorSet, 0, null);

    for shader : postProcessRenderer.shaders {
        Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, shader.pipeline);
        for material : shader.materials {
            _material_draw(material, commandBuffer);
            Vk.cmd_draw(commandBuffer, 3, 1, 0, 0);
        }
    }

    Vk.cmd_end_render_pass(commandBuffer);

    return true;
}

_post_process_renderer_get_output_image_info :: (postProcessRenderer : *PostProcessRenderer, outputIndex : u8, frameIndex : u8) -> ImageInfo {
    Basic.assert(outputIndex == 0);
    imageInfo : ImageInfo;
    imageInfo.image = postProcessRenderer.extraFrameObjects[frameIndex].imageHolder.image;
    // @todo No view provided, will probably fail at some point when we will want to
    // chain things.
    imageInfo.layout = postProcessRenderer.FINAL_IMAGE_LAYOUT;
    return imageInfo;
}

#scope_file

_init_render_pass :: (postProcessRenderer : *PostProcessRenderer) -> bool {
    engine := postProcessRenderer.scene.engine;

    // --- Pipeline Layout

    setLayoutBinding : Vk.DescriptorSetLayoutBinding;
    setLayoutBinding.binding = postProcessRenderer.SOURCE_DESCRIPTOR_SET_INDEX;
    setLayoutBinding.descriptorCount = 1;
    setLayoutBinding.stageFlags = cast(u32) Vk.ShaderStageFlagBits.Fragment;
    setLayoutBinding.descriptorType = .CombinedImageSampler;

    descriptorSetLayoutCI : Vk.DescriptorSetLayoutCreateInfo;
    descriptorSetLayoutCI.sType = .DescriptorSetLayoutCreateInfo;
    descriptorSetLayoutCI.bindingCount = 1;
    descriptorSetLayoutCI.pBindings = *setLayoutBinding;

    _CHECK(Vk.create_descriptor_set_layout(engine.device, *descriptorSetLayoutCI, null, *postProcessRenderer.descriptorSetLayout),
           "Unable to create descriptor set layout.");

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.setLayoutCount = 1;
    pipelineLayoutCI.pSetLayouts = *postProcessRenderer.descriptorSetLayout;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *postProcessRenderer.pipelineLayout),
           "Unable to create pipeline layout.");
    _set_debug_utils_name(engine.device, postProcessRenderer.pipelineLayout, "postProcessRenderer.pipelineLayout");

    // ----- RenderPass

    attachmentDescs : [1]Vk.AttachmentDescription;

    subpassDesc : Vk.SubpassDescription;
    subpassDesc.pipelineBindPoint = Vk.PipelineBindPoint.Graphics;

    // Color
    attachmentDescs[0].format = Vk.Format.R8G8B8A8Srgb;
    attachmentDescs[0].samples = Vk.SampleCountFlagBits._1;
    attachmentDescs[0].loadOp = Vk.AttachmentLoadOp.Clear;
    attachmentDescs[0].storeOp = Vk.AttachmentStoreOp.Store;
    attachmentDescs[0].stencilLoadOp = Vk.AttachmentLoadOp.DontCare;
    attachmentDescs[0].stencilStoreOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDescs[0].initialLayout = Vk.ImageLayout.Undefined;
    attachmentDescs[0].finalLayout = postProcessRenderer.FINAL_IMAGE_LAYOUT;

    colorAttachmentRef : Vk.AttachmentReference;
    colorAttachmentRef.attachment = 0;
    colorAttachmentRef.layout = Vk.ImageLayout.ColorAttachmentOptimal;
    subpassDesc.colorAttachmentCount = 1;
    subpassDesc.pColorAttachments = *colorAttachmentRef;

    // @todo Clarify, why is this needed really?
    subpassDependency : Vk.SubpassDependency;
    subpassDependency.srcSubpass = cast,no_check(u32) Vk.SUBPASS_EXTERNAL;
    subpassDependency.dstSubpass = 0;
    subpassDependency.srcStageMask = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    subpassDependency.srcAccessMask = 0;
    subpassDependency.dstStageMask = cast(u32) Vk.PipelineStageFlagBits.ColorAttachmentOutput;
    subpassDependency.dstAccessMask = cast(u32) Vk.AccessFlagBits.ColorAttachmentWrite;

    renderPassCI : Vk.RenderPassCreateInfo;
    renderPassCI.sType = .RenderPassCreateInfo;
    renderPassCI.attachmentCount = attachmentDescs.count;
    renderPassCI.pAttachments = attachmentDescs.data;
    renderPassCI.subpassCount = 1;
    renderPassCI.pSubpasses = *subpassDesc;
    renderPassCI.dependencyCount = 1;
    renderPassCI.pDependencies = *subpassDependency;

    _CHECK(Vk.create_render_pass(engine.device, *renderPassCI, null, *postProcessRenderer.renderPass),
           "Unable to create render pass.");

    return true;
}

_init_extra_frame_objects :: (postProcessRenderer : *PostProcessRenderer) -> bool {
    engine := postProcessRenderer.scene.engine;
    extent := renderer_output_get_extent(postProcessRenderer.rendererOutput);

    for *extraFrameObject : postProcessRenderer.extraFrameObjects {
        // Output image
        if !_image_holder_init(*extraFrameObject.imageHolder, engine, .RendererOut, extent) {
            return false;
        }
        _set_debug_utils_name(engine.device, extraFrameObject.imageHolder.image, "postProcessRenderer.extraFrameObjects[].image");

        extraFrameObject.imageView = _image_holder_create_view(*extraFrameObject.imageHolder);
        if extraFrameObject.imageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.imageView, "postProcessRenderer.extraFrameObjects[].imageView");

        // Framebuffer
        framebufferCI : Vk.FramebufferCreateInfo;
        framebufferCI.sType = .FramebufferCreateInfo;
        framebufferCI.renderPass = postProcessRenderer.renderPass;
        framebufferCI.attachmentCount = 1;
        framebufferCI.pAttachments = *extraFrameObject.imageView;
        framebufferCI.width = extent.width;
        framebufferCI.height = extent.height;
        framebufferCI.layers = 1;
        _CHECK(Vk.create_framebuffer(engine.device, *framebufferCI, null, *extraFrameObject.framebuffer),
               "Unable to create framebuffer.");
        _set_debug_utils_name(engine.device, extraFrameObject.framebuffer, "postProcessRenderer.framebuffers[]");
    }

    // ----- Descriptor sets

    MAX_DESCRIPTOR_SET_COUNT :: Engine.FRAME_INDEX_COUNT;

    descriptorPoolSize : Vk.DescriptorPoolSize;
    descriptorPoolSize.type = .CombinedImageSampler;
    descriptorPoolSize.descriptorCount = MAX_DESCRIPTOR_SET_COUNT;

    descriptorPoolCI : Vk.DescriptorPoolCreateInfo;
    descriptorPoolCI.sType = .DescriptorPoolCreateInfo;
    descriptorPoolCI.poolSizeCount = 1;
    descriptorPoolCI.pPoolSizes = *descriptorPoolSize;
    descriptorPoolCI.maxSets = MAX_DESCRIPTOR_SET_COUNT;

    _CHECK(Vk.create_descriptor_pool(engine.device, *descriptorPoolCI, null, *postProcessRenderer.descriptorPool),
           "Unable to create descriptor pool.");

    // Binding the images to the sets
    for frameIndex : 0..Engine.FRAME_INDEX_COUNT-1 {
        descriptorSetAI : Vk.DescriptorSetAllocateInfo;
        descriptorSetAI.sType = .DescriptorSetAllocateInfo;
        descriptorSetAI.descriptorPool = postProcessRenderer.descriptorPool;
        descriptorSetAI.descriptorSetCount = 1;
        descriptorSetAI.pSetLayouts = *postProcessRenderer.descriptorSetLayout;

        _CHECK(Vk.allocate_descriptor_sets(engine.device, *descriptorSetAI, *postProcessRenderer.extraFrameObjects[frameIndex].descriptorSet),
               "Unable to allocate descriptor sets.");

        imageInfo := _renderer_output_get_image_info(postProcessRenderer.rendererOutput, frameIndex);

        descriptorII : Vk.DescriptorImageInfo;
        descriptorII.imageLayout = imageInfo.layout;
        descriptorII.imageView = imageInfo.view;
        descriptorII.sampler = engine.samplerDefault; // @todo Could use linear sampler

        writeDescriptorSet : Vk.WriteDescriptorSet;
        writeDescriptorSet.sType = .WriteDescriptorSet;
        writeDescriptorSet.dstSet = postProcessRenderer.extraFrameObjects[frameIndex].descriptorSet;
        writeDescriptorSet.dstBinding = postProcessRenderer.SOURCE_DESCRIPTOR_SET_INDEX;
        writeDescriptorSet.dstArrayElement = 0;
        writeDescriptorSet.descriptorType = .CombinedImageSampler;
        writeDescriptorSet.descriptorCount = 1;
        writeDescriptorSet.pImageInfo = *descriptorII;

        Vk.update_descriptor_sets(engine.device, 1, *writeDescriptorSet, 0, null);
    }

    return true;
}
