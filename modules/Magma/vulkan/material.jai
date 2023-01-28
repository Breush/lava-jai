MaterialImpl :: struct {
    // @todo :PushDescriptors or descriptor buffers (https://www.khronos.org/blog/vk-ext-descriptor-buffer)
    // might be a better solution long term than having multiple descriptor sets.
    descriptorSets : [2]Vk.DescriptorSet;
    descriptorPool : Vk.DescriptorPool;
    descriptorSetIndex : u32;

    UniformBlockImpl :: struct {
        bufferHolder : BufferHolder;
    }
}

impl_material_init :: (material : *Material) {
    engine := material.shader.renderer.scene.engine;

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            _buffer_holder_init(*uniform.block.bufferHolder, engine, "material.uniforms[].block.bufferHolder",
                                .ShaderUniform, .PersistentStaging, cast(u64) uniform.block.buffer.count);
            _set_debug_utils_name(engine.device, uniform.block.bufferHolder.buffer, "material.uniforms[].block.buffer");
        }
    }

    _init_descriptor_set(material);
}

impl_material_cleanup :: (material : *Material) {
    engine := material.shader.renderer.scene.engine;

    for *uniform : material.uniforms {
        if uniform.kind == .Block {
            _buffer_holder_cleanup(*uniform.block.bufferHolder, false);
        }
    }

    // @todo This will be needed when the pool moves to shader.
    // So that one can destroy a material at will.
    // Vk.free_descriptor_sets(engine.device, material.descriptorPool, 1, *material.descriptorSet);
    Vk.destroy_descriptor_pool(engine.device, material.descriptorPool, null);
}

impl_material_uniform_commit :: (material : *Material, uniform : *Material.Uniform) {
    if uniform.kind == .Texture {
        if uniform.texture.value != null {
            _material_uniform_commit(material, uniform.binding, uniform.texture.value);
        } else {
            _material_uniform_commit(material, uniform.binding, uniform.texture.fallback);
        }
    } else if uniform.kind == .Block {
        _buffer_holder_copy(*uniform.block.bufferHolder, uniform.block.buffer.data, cast(Vk.DeviceSize) uniform.block.buffer.count);
        _material_uniform_commit(material, uniform.binding, uniform.block);
    }
}

_material_draw :: (material : *Material, commandBuffer : Vk.CommandBuffer) {
    // @note This can happen if the material does not have any uniforms (e.g. fallback).
    if material.descriptorSets[material.inFlightDescriptorSetIndex] == null then return;

    Vk.cmd_bind_descriptor_sets(commandBuffer, .Graphics, material.shader.pipelineLayout, material.descriptorSetIndex,
                                1, *material.descriptorSets[material.inFlightDescriptorSetIndex], 0, null);
}

#scope_file

_init_descriptor_set :: (material : *Material) -> bool {
    engine := material.shader.renderer.scene.engine;

    // @todo We could move the descriptor pool to the shader,
    // and that number should not be arbitrary anymore.
    MAX_DESCRIPTOR_SET_COUNT :: 2; // :PushDescriptors

    blockSize : u32 = 0;
    textureCount : u32 = 0;
    for *uniform : material.uniforms {
        if uniform.kind == .Texture {
            textureCount += 1;
        } else if uniform.kind == .Block {
            blockSize += cast(u32) uniform.block.buffer.count;
        }
    }

    // Some trick here to not do dynamic allocations.
    descriptorPoolSizes : [2]Vk.DescriptorPoolSize;
    descriptorPoolSizesCount : u32 = 0;

    if blockSize != 0 {
        descriptorPoolSizes[descriptorPoolSizesCount].type = .UniformBuffer;
        descriptorPoolSizes[descriptorPoolSizesCount].descriptorCount = blockSize * MAX_DESCRIPTOR_SET_COUNT;
        descriptorPoolSizesCount += 1;
    }
    if textureCount != 0 {
        descriptorPoolSizes[descriptorPoolSizesCount].type = .CombinedImageSampler;
        descriptorPoolSizes[descriptorPoolSizesCount].descriptorCount = textureCount * MAX_DESCRIPTOR_SET_COUNT;
        descriptorPoolSizesCount += 1;
    }

    // @note No descriptor set to create: neither block nor texture.
    if descriptorPoolSizesCount == 0 then return true;

    descriptorPoolCI : Vk.DescriptorPoolCreateInfo;
    descriptorPoolCI.sType = .DescriptorPoolCreateInfo;
    descriptorPoolCI.poolSizeCount = descriptorPoolSizesCount;
    descriptorPoolCI.pPoolSizes = descriptorPoolSizes.data;
    descriptorPoolCI.maxSets = MAX_DESCRIPTOR_SET_COUNT;
    // descriptorPoolCI.flags = cast(u32) Vk.DescriptorPoolCreateFlagBits.FreeDescriptorSet;

    _CHECK(Vk.create_descriptor_pool(engine.device, *descriptorPoolCI, null, *material.descriptorPool),
           "Unable to create descriptor pool.");

    // :PushDescriptors
    descriptorsetLayouts : [2]Vk.DescriptorSetLayout;
    descriptorsetLayouts[0] = material.shader.descriptorSetLayouts[material.descriptorSetIndex];
    descriptorsetLayouts[1] = material.shader.descriptorSetLayouts[material.descriptorSetIndex];

    descriptorSetAI : Vk.DescriptorSetAllocateInfo;
    descriptorSetAI.sType = .DescriptorSetAllocateInfo;
    descriptorSetAI.descriptorPool = material.descriptorPool;
    descriptorSetAI.descriptorSetCount = 2; // :PushDescriptors
    descriptorSetAI.pSetLayouts = descriptorsetLayouts.data;

    _CHECK(Vk.allocate_descriptor_sets(engine.device, *descriptorSetAI, *material.descriptorSets[0]),
           "Unable to allocate descriptor sets.");

    for descriptorSet : material.descriptorSets {
        _set_debug_utils_name(engine.device, descriptorSet, Basic.tprint("material{%}.descriptorSets[]\0", material.shader.id).data);
    }

    // Initialization to default
    for *uniform, uniformKey : material.uniforms {
        if uniform.kind == .Texture {
            uniform.texture.fallback = *engine.textureWhite;
            uniform.dirties[0] = true;
            uniform.dirties[1] = true;
            material.anyUniformDirty = true;
        } else if uniform.kind == .Block {
            uniform.dirties[0] = true;
            uniform.dirties[1] = true;
            material.anyUniformDirty = true;
        }
    }

    return true;
}

_material_uniform_commit :: (material : *Material, binding : u32, texture : *Texture) {
    engine := material.shader.renderer.scene.engine;

    descriptorII : Vk.DescriptorImageInfo;
    descriptorII.imageLayout = texture.imageLayout;
    descriptorII.imageView = texture.imageView;
    descriptorII.sampler = engine.samplerDefault;

    writeDescriptorSet : Vk.WriteDescriptorSet;
    writeDescriptorSet.sType = .WriteDescriptorSet;
    writeDescriptorSet.dstSet = material.descriptorSets[material.inFlightDescriptorSetIndex];
    writeDescriptorSet.dstBinding = binding;
    writeDescriptorSet.dstArrayElement = 0;
    writeDescriptorSet.descriptorType = .CombinedImageSampler;
    writeDescriptorSet.descriptorCount = 1;
    writeDescriptorSet.pImageInfo = *descriptorII;

    Vk.update_descriptor_sets(engine.device, 1, *writeDescriptorSet, 0, null);
}

_material_uniform_commit :: (material : *Material, binding : u32, block : Material.UniformBlock) {
    engine := material.shader.renderer.scene.engine;

    descriptorBI : Vk.DescriptorBufferInfo;
    descriptorBI.buffer = block.bufferHolder.buffer;
    descriptorBI.offset = 0;
    descriptorBI.range = block.bufferHolder.size;

    writeDescriptorSet : Vk.WriteDescriptorSet;
    writeDescriptorSet.sType = .WriteDescriptorSet;
    writeDescriptorSet.dstSet = material.descriptorSets[material.inFlightDescriptorSetIndex];
    writeDescriptorSet.dstBinding = binding;
    writeDescriptorSet.dstArrayElement = 0;
    writeDescriptorSet.descriptorType = .UniformBuffer;
    writeDescriptorSet.descriptorCount = 1;
    writeDescriptorSet.pBufferInfo = *descriptorBI;

    Vk.update_descriptor_sets(engine.device, 1, *writeDescriptorSet, 0, null);
}

#import "Hash_Table";
