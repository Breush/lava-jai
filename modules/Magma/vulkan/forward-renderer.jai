#scope_module

ForwardRendererImpl :: struct {
    extraFrameObjects : [Engine.FRAME_INDEX_COUNT]struct {
        imageHolder : ImageHolder;
        imageView : Vk.ImageView;
        depthImageHolder : ImageHolder;
        depthImageView : Vk.ImageView;
        framebuffer : Vk.Framebuffer;
    };

    // Fallback material when mesh have none. (Basic Phong.)
    // @note The shader won't be registered within the renderer.
    shaderFallback : Shader;
    materialFallback : Material;
}

impl_forward_renderer_init :: (forwardRenderer : *ForwardRenderer) {
    forwardRenderer.imageLayout = Vk.ImageLayout.TransferSrcOptimal;
}

impl_forward_renderer_cleanup :: (forwardRenderer : *ForwardRenderer) {
    engine := forwardRenderer.scene.engine;
    Vk.device_wait_idle(engine.device); // @todo Anything more clever?

    material_cleanup(*forwardRenderer.materialFallback);
    shader_cleanup(*forwardRenderer.shaderFallback);

    Vk.destroy_render_pass(engine.device, forwardRenderer.renderPass, null);

    for *extraFrameObject : forwardRenderer.extraFrameObjects {
        _image_holder_cleanup(*extraFrameObject.imageHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.imageView, null);
        _image_holder_cleanup(*extraFrameObject.depthImageHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.depthImageView, null);
        Vk.destroy_framebuffer(forwardRenderer.scene.engine.device, extraFrameObject.framebuffer, null);
    }
}

_forward_renderer_post_init :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;

    if !_init_render_pass(forwardRenderer) then return false;
    if !_init_extra_frame_objects(forwardRenderer) then return false;

    // Resources
    shader_init(*forwardRenderer.shaderFallback, forwardRenderer, "fallback");
    material_init(*forwardRenderer.materialFallback, *forwardRenderer.shaderFallback);

    return true;
}

_forward_renderer_render :: (forwardRenderer : *ForwardRenderer, frameIndex : u8) -> bool {
    commandBuffer := forwardRenderer.frameObjects[frameIndex].commandBuffer;

    renderPassBeginInfo : Vk.RenderPassBeginInfo;
    renderPassBeginInfo.sType = .RenderPassBeginInfo;
    renderPassBeginInfo.renderPass = forwardRenderer.renderPass;
    renderPassBeginInfo.framebuffer = forwardRenderer.extraFrameObjects[frameIndex].framebuffer;

    renderPassBeginInfo.renderArea.extent.width = forwardRenderer.eye.extent.width;
    renderPassBeginInfo.renderArea.extent.height = forwardRenderer.eye.extent.height;

    clearColors : [2]Vk.ClearValue;
    clearColors[0].depthStencil = .{0., 0};
    clearColors[1].color._float32 = .[0.1, 0.2, 0.3, 1.];
    renderPassBeginInfo.clearValueCount = clearColors.count;
    renderPassBeginInfo.pClearValues = clearColors.data;

    Vk.cmd_begin_render_pass(commandBuffer, *renderPassBeginInfo, Vk.SubpassContents.Inline);

    // Push constant for the eye
    eyePushConstantStages := Vk.ShaderStageFlagBits.Vertex | Vk.ShaderStageFlagBits.Fragment;
    Vk.cmd_push_constants(commandBuffer, forwardRenderer.pipelineLayout, cast(u32) eyePushConstantStages, 0,
                          size_of(EyeShaderObject), *forwardRenderer.eye.shaderObject);

    // Drawing meshes
    // @note We have a small trick here. If we had set lastDrawnMaterial to null,
    // the first iteration could go wrong, as a mesh material can be null.
    // So, we set it to something impossible.
    lastDrawnMaterial := cast(*Material) 0x1;
    lastBoundPipeline : Vk.Pipeline = null;

    // @todo Sort meshes by shaders, in order to reduce context switches.
    for mesh : forwardRenderer.scene.meshes {
        if mesh.material != lastDrawnMaterial {
            lastDrawnMaterial = mesh.material;
            if mesh.material != null {
                if lastBoundPipeline != mesh.material.shader.pipeline {
                    lastBoundPipeline = mesh.material.shader.pipeline;
                    Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, lastBoundPipeline);
                }
                _material_draw(mesh.material, commandBuffer);
            } else {
                if lastBoundPipeline != forwardRenderer.materialFallback.shader.pipeline {
                    lastBoundPipeline = forwardRenderer.materialFallback.shader.pipeline;
                    Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, lastBoundPipeline);
                }
                _material_draw(*forwardRenderer.materialFallback, commandBuffer);
            }
        }
        _mesh_draw(mesh, commandBuffer);
    }

    Vk.cmd_end_render_pass(commandBuffer);

    return true;
}

_forward_renderer_get_output_image :: (forwardRenderer : *ForwardRenderer, outputIndex : u8, frameIndex : u8) -> Vk.Image {
    Basic.assert(outputIndex == 0);
    return forwardRenderer.extraFrameObjects[frameIndex].imageHolder.image;
}

_forward_renderer_get_output_extent :: (forwardRenderer : *ForwardRenderer, outputIndex : u8) -> Chamber.uvec2 {
    Basic.assert(outputIndex == 0);
    return forwardRenderer.eye.extent;
}

_get_push_constant_range :: () -> Vk.PushConstantRange {
    // @note These are the shared data between all other pipelines (i.e. materials)
    // so they must all derive from that. But we might have a design issue, here.
    pushConstantRange : Vk.PushConstantRange;
    pushConstantRange.size = size_of(EyeShaderObject);
    pushConstantRange.stageFlags = cast(u32) Vk.ShaderStageFlagBits.Vertex | Vk.ShaderStageFlagBits.Fragment;
    return pushConstantRange;
}

#scope_file

_init_render_pass :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;

    // --- Pipeline Layout

    pushConstantRange := _get_push_constant_range();

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.pushConstantRangeCount = 1;
    pipelineLayoutCI.pPushConstantRanges = *pushConstantRange;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *forwardRenderer.pipelineLayout),
           "Unable to create pipeline layout.");
    _set_debug_utils_name(engine.device, forwardRenderer.pipelineLayout, "forwardRenderer.pipelineLayout");

    // ----- RenderPass

    attachmentDescs : [2]Vk.AttachmentDescription;

    subpassDesc : Vk.SubpassDescription;
    subpassDesc.pipelineBindPoint = Vk.PipelineBindPoint.Graphics;

    // Depth
    attachmentDescs[0].format = Vk.Format.D32Sfloat; // @note This is widely supported.
    attachmentDescs[0].samples = Vk.SampleCountFlagBits._1;
    attachmentDescs[0].loadOp = Vk.AttachmentLoadOp.Clear;
    attachmentDescs[0].storeOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDescs[0].stencilLoadOp = Vk.AttachmentLoadOp.DontCare;
    attachmentDescs[0].stencilStoreOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDescs[0].initialLayout = Vk.ImageLayout.Undefined;
    attachmentDescs[0].finalLayout = Vk.ImageLayout.DepthStencilAttachmentOptimal;

    depthStencilAttachmentRef : Vk.AttachmentReference;
    depthStencilAttachmentRef.attachment = 0;
    depthStencilAttachmentRef.layout = Vk.ImageLayout.DepthStencilAttachmentOptimal;
    subpassDesc.pDepthStencilAttachment = *depthStencilAttachmentRef;

    // Color
    attachmentDescs[1].format = Vk.Format.R8G8B8A8Srgb;
    attachmentDescs[1].samples = Vk.SampleCountFlagBits._1;
    attachmentDescs[1].loadOp = Vk.AttachmentLoadOp.Clear;
    attachmentDescs[1].storeOp = Vk.AttachmentStoreOp.Store;
    attachmentDescs[1].stencilLoadOp = Vk.AttachmentLoadOp.DontCare;
    attachmentDescs[1].stencilStoreOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDescs[1].initialLayout = Vk.ImageLayout.Undefined;
    attachmentDescs[1].finalLayout = forwardRenderer.imageLayout;

    colorAttachmentRef : Vk.AttachmentReference;
    colorAttachmentRef.attachment = 1;
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

    _CHECK(Vk.create_render_pass(engine.device, *renderPassCI, null, *forwardRenderer.renderPass),
           "Unable to create render pass.");

    return true;
}

_init_extra_frame_objects :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;

    for *extraFrameObject : forwardRenderer.extraFrameObjects {
        // Output image
        if !_image_holder_init(*extraFrameObject.imageHolder, engine, .RendererOut, forwardRenderer.eye.extent) {
            return false;
        }
        _set_debug_utils_name(engine.device, extraFrameObject.imageHolder.image, "forwardRenderer.extraFrameObjects[].image");

        extraFrameObject.imageView = _image_holder_create_view(*extraFrameObject.imageHolder);
        if extraFrameObject.imageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.imageView, "forwardRenderer.extraFrameObjects[].imageView");

        // Depth image
        if !_image_holder_init(*extraFrameObject.depthImageHolder, engine, .Depth, forwardRenderer.eye.extent) {
            return false;
        }
        _set_debug_utils_name(engine.device, extraFrameObject.depthImageHolder.image, "forwardRenderer.extraFrameObjects[].depthImage");

        extraFrameObject.depthImageView = _image_holder_create_view(*extraFrameObject.depthImageHolder);
        if extraFrameObject.depthImageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.depthImageView, "forwardRenderer.extraFrameObject[].depthImageView");

        // Framebuffer
        imageViews : [2]Vk.ImageView;
        imageViews[0] = extraFrameObject.depthImageView;
        imageViews[1] = extraFrameObject.imageView;

        framebufferCI : Vk.FramebufferCreateInfo;
        framebufferCI.sType = .FramebufferCreateInfo;
        framebufferCI.renderPass = forwardRenderer.renderPass;
        framebufferCI.attachmentCount = imageViews.count;
        framebufferCI.pAttachments = *imageViews[0];
        framebufferCI.width = forwardRenderer.eye.extent.width;
        framebufferCI.height = forwardRenderer.eye.extent.height;
        framebufferCI.layers = 1;
        _CHECK(Vk.create_framebuffer(engine.device, *framebufferCI, null, *extraFrameObject.framebuffer),
               "Unable to create framebuffer.");
        _set_debug_utils_name(engine.device, extraFrameObject.framebuffer, "forwardRenderer.framebuffers[]");
    }

    return true;
}
