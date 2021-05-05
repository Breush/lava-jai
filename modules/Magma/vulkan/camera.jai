#scope_module

CameraImpl :: struct {
    pipeline : Vk.Pipeline;
    pipelineLayout : Vk.PipelineLayout;
    renderPass : Vk.RenderPass;
    framebuffers : [Engine.FRAME_INDEX_COUNT]Vk.Framebuffer;
}

impl_camera_init :: (camera : *Camera) {
    camera.imageLayout = Vk.ImageLayout.TransferSrcOptimal;
}

impl_camera_cleanup :: (camera : *Camera) {
    _cleanup_render_pass(camera);

    for framebuffer : camera.framebuffers {
        Vk.destroy_framebuffer(camera.engine.device, framebuffer, null);
    }
}

_camera_post_init :: (camera : *Camera) -> bool {
    if !_init_render_pass(camera) then return false;
    return true;
}

_camera_render :: (camera : *Camera, frameIndex : u8) -> bool {
    frameObject := *camera.frameObjects[frameIndex];

    // Works like a fence, we're waiting for the previous command buffer to be done.
    _wait_timeline_semaphore(camera.engine.device, frameObject.renderSemaphore, frameObject.renderSemaphoreFinishedValue);

    commandBuffer := frameObject.commandBuffer;
    commandBufferBeginInfo : Vk.CommandBufferBeginInfo;
    commandBufferBeginInfo.sType = Vk.StructureType.CommandBufferBeginInfo;

    _CHECK(Vk.begin_command_buffer(commandBuffer, *commandBufferBeginInfo),
           "Unable to begin command buffer.");

    // Rendering
    renderPassBeginInfo : Vk.RenderPassBeginInfo;
    renderPassBeginInfo.sType = Vk.StructureType.RenderPassBeginInfo;
    renderPassBeginInfo.renderPass = camera.renderPass;
    renderPassBeginInfo.framebuffer = camera.framebuffers[frameIndex];

    renderPassBeginInfo.renderArea.extent.width = camera.extent.width;
    renderPassBeginInfo.renderArea.extent.height = camera.extent.height;

    clearColor : Vk.ClearValue;
    clearColor.color._float32 = .[0., 0., 0., 1.];
    renderPassBeginInfo.clearValueCount = 1;
    renderPassBeginInfo.pClearValues = *clearColor;

    // @todo Draw meshes etc. - Have ForwardRenderer apart?

    Vk.cmd_begin_render_pass(commandBuffer, *renderPassBeginInfo, Vk.SubpassContents.Inline);
    Vk.cmd_bind_pipeline(commandBuffer, Vk.PipelineBindPoint.Graphics, camera.pipeline);
    Vk.cmd_draw(commandBuffer, 3, 1, 0, 0);
    Vk.cmd_end_render_pass(commandBuffer);

    Vk.end_command_buffer(commandBuffer);

    // Submit
    frameObject.renderSemaphoreFinishedValue += 1;
    timelineSemaphoreSI : Vk.TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.sType = Vk.StructureType.TimelineSemaphoreSubmitInfo;
    timelineSemaphoreSI.signalSemaphoreValueCount = 1;
    timelineSemaphoreSI.pSignalSemaphoreValues = *frameObject.renderSemaphoreFinishedValue;

    submitInfo : Vk.SubmitInfo;
    submitInfo.sType = Vk.StructureType.SubmitInfo;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = *commandBuffer;
    submitInfo.pNext = *timelineSemaphoreSI;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = *frameObject.renderSemaphore;

    _CHECK(Vk.queue_submit(camera.engine.graphicsQueue, 1, *submitInfo, null),
           "Unable to submit command buffer.");

    return true;
}

#scope_file

_init_render_pass :: (camera : *Camera) -> bool {
    engine := camera.engine;

    // ----- Shaders

    vertShaderModule := _engine_get_shader_module(camera.engine, "./examples/magma-scenes/vert.spv");
    fragShaderModule := _engine_get_shader_module(camera.engine, "./examples/magma-scenes/frag.spv");

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
    viewport.width = cast(float32) camera.extent.width;
    viewport.height = cast(float32) camera.extent.height;

    scissor : Vk.Rect2D;
    scissor.extent.width = camera.extent.width;
    scissor.extent.height = camera.extent.height;

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

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *camera.pipelineLayout),
           "Unable to create pipeline layout.");

    // ----- RenderPass

    attachmentDesc : Vk.AttachmentDescription;
    attachmentDesc.format = Vk.Format.R8G8B8A8Srgb;
    attachmentDesc.samples = Vk.SampleCountFlagBits._1;
    attachmentDesc.loadOp = Vk.AttachmentLoadOp.Clear;
    attachmentDesc.storeOp = Vk.AttachmentStoreOp.Store;
    attachmentDesc.stencilLoadOp = Vk.AttachmentLoadOp.DontCare;
    attachmentDesc.stencilStoreOp = Vk.AttachmentStoreOp.DontCare;
    attachmentDesc.initialLayout = Vk.ImageLayout.Undefined;
    attachmentDesc.finalLayout = camera.imageLayout;

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

    _CHECK(Vk.create_render_pass(engine.device, *renderPassCI, null, *camera.renderPass),
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
    pipelineCI.layout = camera.pipelineLayout;
    pipelineCI.renderPass = camera.renderPass;
    pipelineCI.subpass = 0;
    pipelineCI.basePipelineHandle = null;

    _CHECK(Vk.create_graphics_pipelines(engine.device, null, 1, *pipelineCI, null, *camera.pipeline),
           "Unable to create graphics pipeline.");

    for *framebuffer, frameIndex : camera.framebuffers {
        framebufferCI : Vk.FramebufferCreateInfo;
        framebufferCI.sType = Vk.StructureType.FramebufferCreateInfo;
        framebufferCI.renderPass = camera.renderPass;
        framebufferCI.attachmentCount = 1;
        framebufferCI.pAttachments = *camera.frameObjects[frameIndex].imageView;
        framebufferCI.width = camera.extent.width;
        framebufferCI.height = camera.extent.height;
        framebufferCI.layers = 1;
        _CHECK(Vk.create_framebuffer(camera.engine.device, *framebufferCI, null, framebuffer),
               "Unable to create framebuffer.");
        _set_debug_utils_name(camera.engine.device, <<framebuffer, "camera.framebuffers[]");
    }

    return true;
}

_cleanup_render_pass :: (camera : *Camera) {
    Vk.destroy_render_pass(camera.engine.device, camera.renderPass, null);
    Vk.destroy_pipeline(camera.engine.device, camera.pipeline, null);
    Vk.destroy_pipeline_layout(camera.engine.device, camera.pipelineLayout, null);
}
