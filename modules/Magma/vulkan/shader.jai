ShaderImpl :: struct {
    pipelineLayout : Vk.PipelineLayout;
    pipeline : Vk.Pipeline;
    descriptorSetLayouts : [..]Vk.DescriptorSetLayout;
}

impl_shader_init :: (shader : *Shader) {
    _init_pipeline(shader);
}

impl_shader_cleanup :: (shader : *Shader) {
    engine := shader.renderer.scene.engine;

    Vk.destroy_pipeline(engine.device, shader.pipeline, null);
    Vk.destroy_pipeline_layout(engine.device, shader.pipelineLayout, null);

    for descriptorSetLayout : shader.descriptorSetLayouts {
        Vk.destroy_descriptor_set_layout(engine.device, descriptorSetLayout, null);
    }

    Basic.array_free(shader.descriptorSetLayouts);
}

// @todo Why not in common/shader.jai?
_shader_on_shader_modules_changed :: (shader : *Shader) {
    engine := shader.renderer.scene.engine;

    vertShaderModule := _engine_get_shader_module(engine, shader.id, .Vertex);
    fragShaderModule := _engine_get_shader_module(engine, shader.id, .Fragment, true);
    if vertShaderModule == null || fragShaderModule == null then return;

    Vk.device_wait_idle(shader.renderer.scene.engine.device);
    impl_shader_cleanup(shader);
    shader.shaderImpl = .{};
    _init_pipeline(shader, vertShaderModule, fragShaderModule);
}

#scope_file

_init_pipeline :: (shader : *Shader, vertShaderModule : *ShaderModule = null, fragShaderModule : *ShaderModule = null) -> bool {
    engine := shader.renderer.scene.engine;

    // @note Doing that first, because we need the info about the uniforms.
    if vertShaderModule == null then vertShaderModule = _engine_get_shader_module(engine, shader.id, .Vertex);
    if fragShaderModule == null then fragShaderModule = _engine_get_shader_module(engine, shader.id, .Fragment, true);
    shader.uniformsFrame = *fragShaderModule.uniformsFrame;

    // --- Pipeline Layout

    setLayoutMaxIndex := -1;
    for *uniformFrame : shader.uniformsFrame {
        if uniformFrame.set > setLayoutMaxIndex then setLayoutMaxIndex = uniformFrame.set;
    }
    if setLayoutMaxIndex >= 0 {
        Basic.array_resize(*shader.descriptorSetLayouts, setLayoutMaxIndex + 1);
    }

    uniformIndex : u32 = 0;
    for *uniformFrame, uniformName : shader.uniformsFrame {
        Hash.table_add(*shader.uniformsNameToIndex, Basic.copy_string(uniformName), uniformIndex);
        uniformIndex += 1;
    }

    for setLayoutIndex : 0..setLayoutMaxIndex {
        setLayoutBindings : [..]Vk.DescriptorSetLayoutBinding;
        defer Basic.array_free(setLayoutBindings);

        for *uniformFrame : shader.uniformsFrame {
            if uniformFrame.set != setLayoutIndex then continue;
            if uniformFrame.kind == .BlockField then continue;

            setLayoutBinding : Vk.DescriptorSetLayoutBinding;
            setLayoutBinding.binding = cast(u32) uniformFrame.binding;
            setLayoutBinding.descriptorCount = 1; // @todo Will probably be more than one, one day.
            setLayoutBinding.stageFlags = cast(u32) Vk.ShaderStageFlagBits.Fragment;

            if uniformFrame.kind == .Texture {
                setLayoutBinding.descriptorType = .CombinedImageSampler;
            } else if uniformFrame.kind == .Block {
                setLayoutBinding.descriptorType = .UniformBuffer;
            }

            Basic.array_add(*setLayoutBindings, setLayoutBinding);
        }

        descriptorSetLayoutCI : Vk.DescriptorSetLayoutCreateInfo;
        descriptorSetLayoutCI.sType = .DescriptorSetLayoutCreateInfo;
        descriptorSetLayoutCI.bindingCount = cast(u32) setLayoutBindings.count;
        descriptorSetLayoutCI.pBindings = setLayoutBindings.data;
        descriptorSetLayoutCI.flags = cast(u32) Vk.DescriptorSetLayoutCreateFlagBits.DescriptorBufferExt;

        _CHECK(Vk.create_descriptor_set_layout(engine.device, *descriptorSetLayoutCI, null, *shader.descriptorSetLayouts[setLayoutIndex]),
               "Unable to create descriptor set layout.");
    }

    // @todo :ExtractPushConstants Could be extracted from SPIR-V too.
    pushConstantRanges := _renderer_get_push_constant_ranges(shader.renderer);

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.pushConstantRangeCount = cast(u32) pushConstantRanges.count;
    pipelineLayoutCI.pPushConstantRanges = pushConstantRanges.data;
    pipelineLayoutCI.setLayoutCount = cast(u32) shader.descriptorSetLayouts.count;
    pipelineLayoutCI.pSetLayouts = shader.descriptorSetLayouts.data;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *shader.pipelineLayout),
           "Unable to create pipeline layout.");
    _set_debug_utils_name(engine.device, shader.pipelineLayout, "shader.pipelineLayout");


    // ----- Shaders

    vertShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    vertShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    vertShaderStageCI.stage = Vk.ShaderStageFlagBits.Vertex;
    vertShaderStageCI.module = vertShaderModule.vk;
    vertShaderStageCI.pName = "main";
    // @todo Using pSpecializationInfo might be interesting here!

    fragShaderStageCI : Vk.PipelineShaderStageCreateInfo;
    fragShaderStageCI.sType = .PipelineShaderStageCreateInfo;
    fragShaderStageCI.stage = Vk.ShaderStageFlagBits.Fragment;
    fragShaderStageCI.module = fragShaderModule.vk;
    fragShaderStageCI.pName = "main";

    shaderStages : [2]Vk.PipelineShaderStageCreateInfo;
    shaderStages[0] = vertShaderStageCI;
    shaderStages[1] = fragShaderStageCI;

    // ---

    vertexInputDescription := _renderer_get_vertex_input_description(shader.renderer);

    vertexInputStateCI : Vk.PipelineVertexInputStateCreateInfo;
    vertexInputStateCI.sType = .PipelineVertexInputStateCreateInfo;
    vertexInputStateCI.vertexBindingDescriptionCount = cast(u32) vertexInputDescription.bindings.count;
    vertexInputStateCI.pVertexBindingDescriptions = vertexInputDescription.bindings.data;
    vertexInputStateCI.vertexAttributeDescriptionCount = cast(u32) vertexInputDescription.attributes.count;
    vertexInputStateCI.pVertexAttributeDescriptions = vertexInputDescription.attributes.data;

    inputAssemblyStateCI : Vk.PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.sType = .PipelineInputAssemblyStateCreateInfo;
    inputAssemblyStateCI.topology = Vk.PrimitiveTopology.TriangleList;
    inputAssemblyStateCI.primitiveRestartEnable = Vk.FALSE;

    // ---

    // Will be dynamic
    viewport : Vk.Viewport;
    scissor : Vk.Rect2D;

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
    depthStencilStateCI.depthWriteEnable = cast(u32) ifx shader.options.depthWriteEnabled then Vk.TRUE else Vk.FALSE;
    depthStencilStateCI.depthCompareOp = .Greater;
    depthStencilStateCI.depthBoundsTestEnable = Vk.FALSE;
    depthStencilStateCI.stencilTestEnable = Vk.FALSE;

    // ---

    colorBlendAttachmentState : Vk.PipelineColorBlendAttachmentState;
    colorBlendAttachmentState.colorWriteMask = cast(u32) (Vk.ColorComponentFlagBits.R | Vk.ColorComponentFlagBits.G | Vk.ColorComponentFlagBits.B | Vk.ColorComponentFlagBits.A);
    ifx shader.options.alphaBlendingEnabled {
        colorBlendAttachmentState.blendEnable = Vk.TRUE;
        colorBlendAttachmentState.srcColorBlendFactor = Vk.BlendFactor.SrcAlpha;
        colorBlendAttachmentState.dstColorBlendFactor = Vk.BlendFactor.OneMinusSrcAlpha;
        colorBlendAttachmentState.colorBlendOp = Vk.BlendOp.Add;
        colorBlendAttachmentState.srcAlphaBlendFactor = Vk.BlendFactor.One;
        colorBlendAttachmentState.dstAlphaBlendFactor = Vk.BlendFactor.Zero;
        colorBlendAttachmentState.alphaBlendOp = Vk.BlendOp.Add;
    }

    colorBlendStateCI : Vk.PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.sType = .PipelineColorBlendStateCreateInfo;
    colorBlendStateCI.logicOpEnable = Vk.FALSE;
    colorBlendStateCI.attachmentCount = 1;
    colorBlendStateCI.pAttachments = *colorBlendAttachmentState;

    // ---

    dynamicStates : [2]Vk.DynamicState;
    dynamicStates[0] = .Viewport;
    dynamicStates[1] = .Scissor;

    dynamicStateCI : Vk.PipelineDynamicStateCreateInfo;
    dynamicStateCI.sType = .PipelineDynamicStateCreateInfo;
    dynamicStateCI.dynamicStateCount = dynamicStates.count;
    dynamicStateCI.pDynamicStates = dynamicStates.data;

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
    pipelineCI.pDynamicState = *dynamicStateCI;
    pipelineCI.layout = shader.pipelineLayout;
    pipelineCI.renderPass = _renderer_get_render_pass(shader.renderer);
    pipelineCI.subpass = 0;
    pipelineCI.basePipelineHandle = null;
    pipelineCI.flags = cast(u32) Vk.PipelineCreateFlagBits.DescriptorBufferExt;

    _CHECK(Vk.create_graphics_pipelines(engine.device, null, 1, *pipelineCI, null, *shader.pipeline),
           "Unable to create graphics pipeline.");

    return true;
}