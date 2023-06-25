MaterialImpl :: struct {
    descriptorSetIndex : u32;
    descriptorBufferHolder : BufferHolder;

    UniformBlockImpl :: struct {
        bufferHolder : BufferHolder;
    }
}

impl_material_init :: (material : *Material) {
    engine := material.shader.renderer.scene.engine;

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            _buffer_holder_init(*uniform.block.bufferHolder, engine, "material.uniforms[].block.bufferHolder",
                                .ShaderUniform, .Direct, cast(u64) uniform.block.buffer.count);
            _set_debug_utils_name(engine.device, uniform.block.bufferHolder.buffer, "material.uniforms[].block.buffer");
        }
    }

    _init_descriptor_buffer(material);
}

impl_material_cleanup :: (material : *Material) {
    engine := material.shader.renderer.scene.engine;

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            _buffer_holder_cleanup(*uniform.block.bufferHolder, false);
        }
    }

    _buffer_holder_cleanup(*material.descriptorBufferHolder, false);
}

impl_material_uniform_commit :: (material : *Material, uniform : *Material.Uniform) {
    if uniform.kind == .Texture {
        if uniform.texture.value != null {
            _material_uniform_commit(material, uniform.binding, uniform.texture.value);
        } else {
            _material_uniform_commit(material, uniform.binding, uniform.texture.fallback);
        }
    } else if uniform.kind == .Block {
        _material_uniform_commit(material, uniform.binding, uniform.block);
    }
}

_material_draw :: (material : *Material, commandBuffer : Vk.CommandBuffer) {
    // @note This can happen if the material does not have any uniforms (e.g. fallback).
    if material.uniforms.count == 0 then return;

    bindingInfo : Vk.DescriptorBufferBindingInfoEXT;
    bindingInfo.sType = .DescriptorBufferBindingInfoExt;
    bindingInfo.address = _buffer_holder_device_address(*material.descriptorBufferHolder);
    bindingInfo.usage = cast(u32) Vk.BufferUsageFlagBits.ResourceDescriptorBuffer;

    // @todo Technically known to be slow. An material catalog would help, but add complexity.
    Vk.cmd_bind_descriptor_buffers_ext(commandBuffer, 1, *bindingInfo);

    bufferIndexUbo : u32;
    bufferOffset : Vk.DeviceSize;
    Vk.cmd_set_descriptor_buffer_offsets_ext(commandBuffer, .Graphics, material.shader.pipelineLayout, material.descriptorSetIndex,
                                             1, *bufferIndexUbo, *bufferOffset);
}

#scope_file

_init_descriptor_buffer :: (material : *Material) -> bool {
    engine := material.shader.renderer.scene.engine;

    blockSize : u32 = 0;
    textureCount : u32 = 0;
    for *uniform : material.uniforms {
        if uniform.kind == .Texture {
            textureCount += 1;
        } else if uniform.kind == .Block {
            blockSize += cast(u32) uniform.block.buffer.count;
        }
    }

    if textureCount == 0 && blockSize == 0 then return true;

    memorySize : Vk.DeviceSize;
    Vk.get_descriptor_set_layout_size_ext(engine.device, material.shader.descriptorSetLayouts[material.descriptorSetIndex], *memorySize);

    _buffer_holder_init(*material.descriptorBufferHolder, engine, "material.descriptorBufferHolder",
                        .Descriptor, .AlwaysMapped, memorySize);

    // Initialization to default
    for *uniform, uniformKey : material.uniforms {
        if uniform.kind == .Texture {
            uniform.texture.fallback = *engine.textureWhite;
            uniform.dirty = true;
        } else if uniform.kind == .Block {
            uniform.dirty = true;

            offset : Vk.DeviceSize;
            Vk.get_descriptor_set_layout_binding_offset_ext(engine.device, material.shader.descriptorSetLayouts[material.descriptorSetIndex],
                                                            uniform.binding, *offset);

            descriptorAddressInfo : Vk.DescriptorAddressInfoEXT;
            descriptorAddressInfo.sType = .DescriptorAddressInfoExt;
            descriptorAddressInfo.address = _buffer_holder_device_address(*uniform.block.bufferHolder);
            descriptorAddressInfo.range = uniform.block.bufferHolder.size;

            descInfo : Vk.DescriptorGetInfoEXT;
            descInfo.sType = .DescriptorGetInfoExt;
            descInfo.type = .UniformBuffer;
            descInfo.data.pUniformBuffer = *descriptorAddressInfo;
            Vk.get_descriptor_ext(engine.device, *descInfo, engine.physicalDeviceDescriptorBufferProperties.uniformBufferDescriptorSize,
                                _buffer_holder_mapped_data(*material.descriptorBufferHolder) + offset);
        }
    }

    return true;
}

_material_uniform_commit :: (material : *Material, binding : u32, texture : *Texture) {
    engine := material.shader.renderer.scene.engine;

    offset : Vk.DeviceSize;
    Vk.get_descriptor_set_layout_binding_offset_ext(engine.device, material.shader.descriptorSetLayouts[material.descriptorSetIndex],
                                                    binding, *offset);

    descriptorII : Vk.DescriptorImageInfo;
    descriptorII.imageLayout = texture.imageLayout;
    descriptorII.imageView = texture.imageView;
    descriptorII.sampler = engine.samplerDefault;

    descInfo : Vk.DescriptorGetInfoEXT;
    descInfo.sType = .DescriptorGetInfoExt;
    descInfo.type = .CombinedImageSampler;
    descInfo.data.pCombinedImageSampler = *descriptorII;
    Vk.get_descriptor_ext(engine.device, *descInfo, engine.physicalDeviceDescriptorBufferProperties.combinedImageSamplerDescriptorSize,
                          _buffer_holder_mapped_data(*material.descriptorBufferHolder) + offset);
}

_material_uniform_commit :: (material : *Material, binding : u32, block : Material.UniformBlock) {
    _buffer_holder_copy(*block.bufferHolder, block.buffer.data, cast(Vk.DeviceSize) block.buffer.count);
}

#import "Hash_Table";
