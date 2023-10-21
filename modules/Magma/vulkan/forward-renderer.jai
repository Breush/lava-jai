#scope_module

ForwardRendererImpl :: struct {
    renderPass : Vk.RenderPass;

    extraFrameObjects : [Engine.FRAME_INDEX_COUNT]struct {
        imageHolder : ImageHolder;
        imageInfo : ImageInfo;
        depthImageHolder : ImageHolder;
        depthImageView : Vk.ImageView;
        framebuffer : Vk.Framebuffer;
    };

    // Fallback material when mesh have none. (Basic Phong.)
    // @note The shader won't be registered within the renderer.
    shaderFallback : Shader;
    materialFallback : Material;

    vertexInputBindingDescs : [2]Vk.VertexInputBindingDescription;
    vertexInputAttributeDescs : [7]Vk.VertexInputAttributeDescription;
    pushConstantRanges : [1]Vk.PushConstantRange;

    FINAL_IMAGE_LAYOUT :: Vk.ImageLayout.ShaderReadOnlyOptimal;
}

impl_forward_renderer_init :: (forwardRenderer : *ForwardRenderer) {
    renderer := forwardRenderer;
    nextLocation := _fill_vertex_input_descs(VertexInput, 0, 0, Vk.VertexInputRate.Vertex);
    _fill_vertex_input_descs(InstanceInput, 1, nextLocation, Vk.VertexInputRate.Instance);

    forwardRenderer.pushConstantRanges[0].size = size_of(EyeShaderObject) + size_of(u32) /* frame trick */;
    forwardRenderer.pushConstantRanges[0].stageFlags = cast(u32) Vk.ShaderStageFlagBits.Vertex | Vk.ShaderStageFlagBits.Fragment;
}

impl_forward_renderer_cleanup :: (forwardRenderer : *ForwardRenderer) {
    engine := forwardRenderer.scene.engine;
    Vk.device_wait_idle(engine.device); // @todo :WaitIdle Anything more clever?

    material_cleanup(*forwardRenderer.materialFallback);
    shader_cleanup(*forwardRenderer.shaderFallback);
    _cleanup_extra_frame_objects(forwardRenderer);

    Vk.destroy_render_pass(engine.device, forwardRenderer.renderPass, null);
}

impl_forward_renderer_get_output_extent :: (forwardRenderer : *ForwardRenderer, outputIndex : u8) -> Chamber.uvec2 {
    Basic.assert(outputIndex == 0);
    return forwardRenderer.eye.extent;
}

impl_forward_renderer_update_from_eye :: (forwardRenderer : *ForwardRenderer) {
    _cleanup_extra_frame_objects(forwardRenderer);
    _init_extra_frame_objects(forwardRenderer);
}

_forward_renderer_post_init :: (forwardRenderer : *ForwardRenderer) -> bool {
    if !_init_render_pass(forwardRenderer) then return false;
    if !_init_extra_frame_objects(forwardRenderer) then return false;

    // Resources
    shader_init(*forwardRenderer.shaderFallback, forwardRenderer, "$/forward-renderer/materials/fallback");
    material_init(*forwardRenderer.materialFallback, *forwardRenderer.shaderFallback);

    return true;
}

_forward_renderer_render :: (forwardRenderer : *ForwardRenderer, frameIndex : u8) -> bool {
    commandBuffer := forwardRenderer.frameObjects[frameIndex].commandBuffer;
    forwardRenderer.extraFrameObjects[frameIndex].imageInfo.layout = forwardRenderer.FINAL_IMAGE_LAYOUT;

    renderPassBeginInfo : Vk.RenderPassBeginInfo;
    renderPassBeginInfo.sType = .RenderPassBeginInfo;
    renderPassBeginInfo.renderPass = forwardRenderer.renderPass;
    renderPassBeginInfo.framebuffer = forwardRenderer.extraFrameObjects[frameIndex].framebuffer;
    // @todo Could use the render area and viewports and avoid the ComposePostProcess
    renderPassBeginInfo.renderArea.extent.width = forwardRenderer.eye.extent.width;
    renderPassBeginInfo.renderArea.extent.height = forwardRenderer.eye.extent.height;

    clearColors : [2]Vk.ClearValue;
    clearColors[0].depthStencil = .{0., 0};
    clearColors[1].color._float32 = .[0.1, 0.2, 0.3, 1.];
    renderPassBeginInfo.clearValueCount = clearColors.count;
    renderPassBeginInfo.pClearValues = clearColors.data;

    Vk.cmd_begin_render_pass(commandBuffer, *renderPassBeginInfo, Vk.SubpassContents.Inline);

    // Dynamic viewport
    viewport : Vk.Viewport;
    viewport.width = cast(float32) forwardRenderer.eye.extent.width;
    viewport.height = cast(float32) forwardRenderer.eye.extent.height;
    viewport.minDepth = 0.;
    viewport.maxDepth = 1.;
    Vk.cmd_set_viewport(commandBuffer, 0, 1, *viewport);

    scissor : Vk.Rect2D;
    scissor.extent.width = forwardRenderer.eye.extent.width;
    scissor.extent.height = forwardRenderer.eye.extent.height;
    Vk.cmd_set_scissor(commandBuffer, 0, 1, *scissor);

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

    // @note We sort the meshes by shader to reduce switches, except for the translucent materials
    // that go at the end and are sorted by distance to the camera.
    // @fixme If the array is already sorted (very possible), quick sort  will still
    // move objects around. Which is a bit sad.
    // Maybe we should filter meshes by eye_is_seeing beforehand anyway and have some
    // kind of an insertion sort.
    forwardRenderer.scene.currentRendererMaterialFallback = *forwardRenderer.materialFallback;
    Sort.quick_sort(forwardRenderer.scene.meshes, (m1 : *Mesh, m2 : *Mesh) -> int {
        // Put disabled meshes at the end.
        if m1.disabled && m2.disabled then return 0;
        if m1.disabled != m2.disabled then return cast(int) m1.disabled - cast(int) m2.disabled;

        material1 := ifx m1.material == null then m1.scene.currentRendererMaterialFallback else m1.material;
        material2 := ifx m2.material == null then m2.scene.currentRendererMaterialFallback else m2.material;

        if material1.shader.options.alphaBlendingEnabled != material2.shader.options.alphaBlendingEnabled {
            return cast(int) material1.shader.options.alphaBlendingEnabled - cast(int) material2.shader.options.alphaBlendingEnabled;
        }

        if material1.shader.options.alphaBlendingEnabled {
            // @fixme Should be distance to camera! This does not work outside 2D.
            if m1.boundingSphere.center.z < m2.boundingSphere.center.z then return 1;
            if m1.boundingSphere.center.z > m2.boundingSphere.center.z then return -1;
        }

        return material2.shader - material1.shader;
    });

    for mesh : forwardRenderer.scene.meshes {
        // @note We can break here because the meshes have been sorted with disabled meshes at the end.
        if mesh.disabled then break;
        if !eye_is_seeing(*forwardRenderer.eye, mesh.boundingSphere) then continue;

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

_forward_renderer_get_output_image_info :: (forwardRenderer : *ForwardRenderer, outputIndex : u8, frameIndex : u8) -> ImageInfo {
    Basic.assert(outputIndex == 0);
    return forwardRenderer.extraFrameObjects[frameIndex].imageInfo;
}

#scope_file

_init_render_pass :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;

    // --- Pipeline Layout

    pushConstantRanges := _renderer_get_push_constant_ranges(forwardRenderer);

    pipelineLayoutCI : Vk.PipelineLayoutCreateInfo;
    pipelineLayoutCI.sType = .PipelineLayoutCreateInfo;
    pipelineLayoutCI.pushConstantRangeCount = cast(u32) pushConstantRanges.count;
    pipelineLayoutCI.pPushConstantRanges = pushConstantRanges.data;

    _CHECK(Vk.create_pipeline_layout(engine.device, *pipelineLayoutCI, null, *forwardRenderer.pipelineLayout),
           "Unable to create pipeline layout.");
    _set_debug_utils_name(engine.device, forwardRenderer.pipelineLayout, "forwardRenderer.pipelineLayout");

    // ----- RenderPass

    attachmentDescs : [2]Vk.AttachmentDescription;

    subpassDesc : Vk.SubpassDescription;
    subpassDesc.pipelineBindPoint = Vk.PipelineBindPoint.Graphics;

    // Depth
    attachmentDescs[0].format = Vk.Format.D32SfloatS8Uint; // @note This is widely supported.
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
    attachmentDescs[1].finalLayout = forwardRenderer.FINAL_IMAGE_LAYOUT;

    colorAttachmentRef : Vk.AttachmentReference;
    colorAttachmentRef.attachment = 1;
    colorAttachmentRef.layout = Vk.ImageLayout.ColorAttachmentOptimal;
    subpassDesc.colorAttachmentCount = 1;
    subpassDesc.pColorAttachments = *colorAttachmentRef;

    renderPassCI : Vk.RenderPassCreateInfo;
    renderPassCI.sType = .RenderPassCreateInfo;
    renderPassCI.attachmentCount = attachmentDescs.count;
    renderPassCI.pAttachments = attachmentDescs.data;
    renderPassCI.subpassCount = 1;
    renderPassCI.pSubpasses = *subpassDesc;

    _CHECK(Vk.create_render_pass(engine.device, *renderPassCI, null, *forwardRenderer.renderPass),
           "Unable to create render pass.");

    return true;
}

_init_extra_frame_objects :: (forwardRenderer : *ForwardRenderer) -> bool {
    engine := forwardRenderer.scene.engine;

    for *extraFrameObject : forwardRenderer.extraFrameObjects {
        // Output image
        _image_holder_init(*extraFrameObject.imageHolder, engine, "forwardRenderer.extraFrameObjects[].imageHolder", .RendererOut, forwardRenderer.eye.extent);
        extraFrameObject.imageInfo.image = extraFrameObject.imageHolder.image;
        extraFrameObject.imageInfo.view = _image_holder_create_view(*extraFrameObject.imageHolder);
        extraFrameObject.imageInfo.layout = .Undefined;
        extraFrameObject.imageInfo.usage = .FragmentOutput;
        if extraFrameObject.imageInfo.view == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.imageInfo.view, "forwardRenderer.extraFrameObjects[].imageInfo.view");

        // Depth image
        _image_holder_init(*extraFrameObject.depthImageHolder, engine, "forwardRenderer.extraFrameObjects[].depthImageHolder", .Depth, forwardRenderer.eye.extent);
        extraFrameObject.depthImageView = _image_holder_create_view(*extraFrameObject.depthImageHolder);
        if extraFrameObject.depthImageView == null then return false;
        _set_debug_utils_name(engine.device, extraFrameObject.depthImageView, "forwardRenderer.extraFrameObject[].depthImageView");

        // Framebuffer
        imageViews : [2]Vk.ImageView;
        imageViews[0] = extraFrameObject.depthImageView;
        imageViews[1] = extraFrameObject.imageInfo.view;

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

_cleanup_extra_frame_objects :: (forwardRenderer : *ForwardRenderer) {
    engine := forwardRenderer.scene.engine;

    Vk.device_wait_idle(forwardRenderer.scene.engine.device);
    for *extraFrameObject : forwardRenderer.extraFrameObjects {
        _image_holder_cleanup(*extraFrameObject.imageHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.imageInfo.view, null);
        _image_holder_cleanup(*extraFrameObject.depthImageHolder);
        Vk.destroy_image_view(engine.device, extraFrameObject.depthImageView, null);
        Vk.destroy_framebuffer(forwardRenderer.scene.engine.device, extraFrameObject.framebuffer, null);
    }
}
