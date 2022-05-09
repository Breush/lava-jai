#scope_module

MeshImpl :: struct {
    instanceBufferHolder : BufferHolder;
    vertexBufferHolder : BufferHolder;
    indexBufferHolder : BufferHolder;

    blasHolder : AsHolder;
}

impl_mesh_init :: (mesh : *Mesh) {
}

impl_mesh_cleanup :: (mesh : *Mesh) {
    engine := mesh.scene.engine;
    Vk.device_wait_idle(engine.device);

    _buffer_holder_cleanup(*mesh.instanceBufferHolder);
    _buffer_holder_cleanup(*mesh.vertexBufferHolder);
    _buffer_holder_cleanup(*mesh.indexBufferHolder);

    _as_holder_cleanup(*mesh.blasHolder);
}

impl_mesh_update :: (mesh : *Mesh) -> bool {
    if mesh.verticesDirty {
        if !_rebuild_vertex_buffer(mesh) then return false;
    }
    if mesh.indicesDirty {
        if !_rebuild_index_buffer(mesh) then return false;
    }
    if (mesh.verticesDirty || mesh.indicesDirty) &&
       (mesh.scene.engine.options.features & .RayTracing){
        if !_rebuild_blas(mesh) then return false;
    }
    if mesh.instanceDirty {
        if !_rebuild_instance_buffer(mesh) then return false;
    }

    return true;
}

_mesh_post_init :: (mesh : *Mesh) {
    _rebuild_instance_buffer(mesh);
}

_mesh_draw :: (mesh : *Mesh, commandBuffer : Vk.CommandBuffer) {
    if mesh.indices.count == 0 then return;

    offsets := cast(Vk.DeviceSize) 0;
    Vk.cmd_bind_vertex_buffers(commandBuffer, 0, 1, *mesh.vertexBufferHolder.buffer, *offsets);
    Vk.cmd_bind_vertex_buffers(commandBuffer, 1, 1, *mesh.instanceBufferHolder.buffer, *offsets);
    Vk.cmd_bind_index_buffer(commandBuffer, mesh.indexBufferHolder.buffer, 0, Vk.IndexType.Uint16);
    Vk.cmd_draw_indexed(commandBuffer, cast(u32) mesh.indices.count, 1, 0, 0, 0);
    mesh.scene.engine.stats.drawCalls += 1;
}

#scope_file

_rebuild_vertex_buffer :: (using mesh : *Mesh) -> bool {
    _buffer_holder_init(*vertexBufferHolder, scene.engine, "mesh.vertexBufferHolder",
                        .ShaderVertex, .OnDemandStaging, size_of(VertexInput) * cast(u64) vertices.count);
    _buffer_holder_copy(*vertexBufferHolder, vertices.data, vertexBufferHolder.size);
    return true;
}

_rebuild_index_buffer :: (using mesh : *Mesh) -> bool {
    _buffer_holder_init(*indexBufferHolder, scene.engine, "mesh.indexBufferHolder",
                        .ShaderIndex, .OnDemandStaging, size_of(u16) * cast(u64) indices.count);
    _buffer_holder_copy(*indexBufferHolder, indices.data, indexBufferHolder.size);
    return true;
}

_rebuild_instance_buffer :: (using mesh : *Mesh) -> bool {
    // @todo This "PersistentStaging" should depend if the mesh is static or not.
    // If the mesh is "static", then .OnDemandStaging might make more sense.
    _buffer_holder_init(*instanceBufferHolder, scene.engine, "mesh.instanceBufferHolder",
                        .ShaderVertex, .PersistentStaging, size_of(InstanceInput));
    _buffer_holder_copy(*instanceBufferHolder, instance);

    return true;
}

_rebuild_blas :: (using mesh : *Mesh) -> bool {
    primitiveCount := cast(u32) indices.count / 3;

    asGeometryTrianglesData : Vk.AccelerationStructureGeometryTrianglesDataKHR;
    asGeometryTrianglesData.sType = .AccelerationStructureGeometryTrianglesDataKhr;
    asGeometryTrianglesData.vertexFormat = .R32G32B32Sfloat;
    asGeometryTrianglesData.vertexStride = size_of(VertexInput);
    asGeometryTrianglesData.vertexData.deviceAddress = _buffer_holder_device_address(*vertexBufferHolder);
    asGeometryTrianglesData.maxVertex = cast(u32) (vertices.count - 1);
    asGeometryTrianglesData.indexType = .Uint16;
    asGeometryTrianglesData.indexData.deviceAddress = _buffer_holder_device_address(*indexBufferHolder);

    asGeometry : Vk.AccelerationStructureGeometryKHR;
    asGeometry.sType = .AccelerationStructureGeometryKhr;
    asGeometry.flags = cast(u32) Vk.GeometryFlagBitsKHR.Opaque;
    asGeometry.geometryType = .Triangles;
    asGeometry.geometry.triangles = asGeometryTrianglesData;

    _as_holder_init(*blasHolder, mesh.scene.engine, "mesh.blasHolder", .BottomLevel, primitiveCount, asGeometry);
    _as_holder_build(*blasHolder);

    return true;
}
