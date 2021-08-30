#scope_module

ForwardRendererImpl :: struct {
    pipeline : Vk.Pipeline;
    pipelineLayout : Vk.PipelineLayout;
    renderPass : Vk.RenderPass;

    extraFrameObjects : [Engine.FRAME_INDEX_COUNT]struct {
        imageHolder : ImageHolder;
        imageView : Vk.ImageView;
        depthImageHolder : ImageHolder;
        depthImageView : Vk.ImageView;
        framebuffer : Vk.Framebuffer;
    };
}

impl_forward_renderer_init :: (forwardRenderer : *ForwardRenderer) {
    forwardRenderer.imageLayout = Vk.ImageLayout.TransferSrcOptimal;
}

impl_forward_renderer_cleanup :: (forwardRenderer : *ForwardRenderer) {
    engine := forwardRenderer.scene.engine;
    Vk.device_wait_idle(engine.device); // @todo Anything more clever?

    _cleanup_render_pass(forwardRenderer);

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

    // Drawing opaque meshes
    Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, forwardRenderer.pipeline);
    for mesh : forwardRenderer.scene.meshes {
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

#scope_file

_init_render_pass :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;
    // ----- Shaders

    vertShaderModule := _engine_get_shader_module(engine, "./examples/magma-scenes/phong.vert.spv");
    fragShaderModule := _engine_get_shader_module(engine, "./examples/magma-scenes/phong.frag.spv");

    vertShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    vertShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    vertShaderStageCI.stage = Vk.ShaderStageFlagBits.Vertex;
    vertShaderStageCI.module = vertShaderModule;
    vertShaderStageCI.pName = "main";
    // @todo Using pSpecializationInfo might be interesting here!

    fragShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    fragShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    fragShaderStageCI.stage = Vk.ShaderStageFlagBits.Fragment;
    fragShaderStageCI.module = fragShaderModule;
    fragShaderStageCI.pName = "main";

    shaderStages : [2]Vk.PipelineShaderStageCreateInfo;
    shaderStages[0] = vertShaderStageCI;
    shaderStages[1] = fragShaderStageCI;

    // ---

    vertexInputBindingDescs : [2]Vk.VertexInputBindingDescription;
    vertexInputAttributeDescs : [5]Vk.VertexInputAttributeDescription;

    nextLocation := _fill_vertex_input_descs(VertexInput, 0, 0, Vk.VertexInputRate.Vertex);
    _fill_vertex_input_descs(InstanceInput, 1, nextLocation, Vk.VertexInputRate.Instance);

    vertexInputStateCI : Vk.PipelineVertexInputStateCreateInfo;
    vertexInputStateCI.sType = .PipelineVertexInputStateCreateInfo;
    vertexInputStateCI.vertexBindingDescriptionCount = vertexInputBindingDescs.count;
    vertexInputStateCI.pVertexBindingDescriptions = *vertexInputBindingDescs[0];
    vertexInputStateCI.vertexAttributeDescriptionCount = vertexInputAttributeDescs.count;
    vertexInputStateCI.pVertexAttributeDescriptions = vertexInputAttributeDescs.data;

    inputAssemblyStateCI : Vk.PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.sType = .PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.topology = Vk.PrimitiveTopology.TriangleList;
    inputAssemblyStateCI.primitiveRestartEnable = Vk.FALSE;

    // ---

    viewport : Vk.Viewport;
    viewport.width = cast(float32) forwardRenderer.eye.extent.width;
    viewport.height = cast(float32) forwardRenderer.eye.extent.height;

    scissor : Vk.Rect2D;
    scissor.extent.width = forwardRenderer.eye.extent.width;
    scissor.extent.height = forwardRenderer.eye.extent.height;

    viewportStateCI : Vk.PipelineViewportStateCreateInfo;
    viewportStateCI.sType = .PipelineViewportStateCreateInfo;
    viewportStateCI.viewportCount = 1;
    viewportStateCI.pViewports = *viewport;
    viewportStateCI.scissorCount = 1;
    viewportStateCI.pScissors = *scissor;

    // ---

    rasterizationStateCI : Vk.PipelineRasterizationStateCreateInfo;
    rasterizationStateCI.sType = .PipelineRasterizationStateCreateInfo;
    rasterizationStateCI.depthClampEnable = Vk.FALSE; // @todo True for shadow maps?
    rasterizationStateCI.polygonMode = Vk.PolygonMode.Fill;
    rasterizationStateCI.lineWidth = 1.;
    rasterizationStateCI.cullMode = cast(u32) Vk.CullModeFlagBits.Back;
    rasterizationStateCI.frontFace = Vk.FrontFace.CounterClockwise;
    // @todo .depthBiasEnable Useful for shadow maps?

    // ---

    multisampleStateCI : Vk.PipelineMultisampleStateCreateInfo;
    multisampleStateCI.sType = .PipelineMultisampleStateCreateInfo;
    multisampleStateCI.sampleShadingEnable = Vk.FALSE;
    multisampleStateCI.rasterizationSamples = Vk.SampleCountFlagBits._1;

    // ---

    depthStencilStateCI : Vk.PipelineDepthStencilStateCreateInfo;
    depthStencilStateCI.sType = .PipelineDepthStencilStateCreateInfo;
    depthStencilStateCI.depthTestEnable = Vk.TRUE;
    depthStencilStateCI.depthWriteEnable = Vk.TRUE;
    depthStencilStateCI.depthCompareOp = Vk.CompareOp.Greater;
    depthStencilStateCI.depthBoundsTestEnable = Vk.FALSE;
    depthStencilStateCI.stencilTestEnable = Vk.FALSE;

    // ---

    colorBlendAttachmentState : Vk.PipelineColorBlendAttachmentState;
    colorBlendAttachmentState.colorWriteMask = cast(u32) (Vk.ColorComponentFlagBits.R | Vk.ColorComponentFlagBits.G | Vk.ColorComponentFlagBits.B | Vk.ColorComponentFlagBits.A);
    colorBlendAttachmentState.blendEnable = Vk.FALSE;

    colorBlendStateCI : Vk.PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.sType = .PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.logicOpEnable = Vk.FALSE;
    colorBlendStateCI.attachmentCount = 1;
    colorBlendStateCI.pAttachments = *colorBlendAttachmentState;

    // --- Pipeline Layout

    pushConstantRange : Vk.PushConstantRange;
    pushConstantRange.size = size_of(EyeShaderObject);
    pushConstantRange.stageFlags = cast(u32) Vk.ShaderStageFlagBits.Vertex | Vk.ShaderStageFlagBits.Fragment;

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.pushConstantRangeCount = 1;
    pipelineLayoutCI.pPushConstantRanges = *pushConstantRange;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *forwardRenderer.pipelineLayout),
           "Unable to create pipeline layout.");

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

    // ----- Pipeline

    pipelineCI : Vk.GraphicsPipelineCreateInfo;
    pipelineCI.sType = .GraphicsPipelineCreateInfo;
    pipelineCI.stageCount = shaderStages.count;
    pipelineCI.pStages = shaderStages.data;
    pipelineCI.pVertexInputState = *vertexInputStateCI;
    pipelineCI.pInputAssemblyState = *inputAssemblyStateCI;
    pipelineCI.pViewportState = *viewportStateCI;
    pipelineCI.pRasterizationState = *rasterizationStateCI;
    pipelineCI.pMultisampleState = *multisampleStateCI;
    pipelineCI.pDepthStencilState = *depthStencilStateCI;
    pipelineCI.pColorBlendState = *colorBlendStateCI;
    pipelineCI.pDynamicState = null;
    pipelineCI.layout = forwardRenderer.pipelineLayout;
    pipelineCI.renderPass = forwardRenderer.renderPass;
    pipelineCI.subpass = 0;
    pipelineCI.basePipelineHandle = null;

    _CHECK(Vk.create_graphics_pipelines(engine.device, null, 1, *pipelineCI, null, *forwardRenderer.pipeline),
           "Unable to create graphics pipeline.");

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

        extraFrameObject.imageView = _image_holder_create_view(extraFrameObject.imageHolder);
        if extraFrameObject.imageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.imageView, "forwardRenderer.extraFrameObjects[].imageView");

        // Depth image
        if !_image_holder_init(*extraFrameObject.depthImageHolder, engine, .Depth, forwardRenderer.eye.extent) {
            return false;
        }
        _set_debug_utils_name(engine.device, extraFrameObject.depthImageHolder.image, "forwardRenderer.extraFrameObjects[].depthImage");

        extraFrameObject.depthImageView = _image_holder_create_view(extraFrameObject.depthImageHolder);
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

_cleanup_render_pass :: (forwardRenderer : *ForwardRenderer) {
    engine := forwardRenderer.scene.engine;

    Vk.destroy_render_pass(engine.device, forwardRenderer.renderPass, null);
    Vk.destroy_pipeline(engine.device, forwardRenderer.pipeline, null);
    Vk.destroy_pipeline_layout(engine.device, forwardRenderer.pipelineLayout, null);
}
