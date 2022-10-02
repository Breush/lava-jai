#scope_module

MeshImpl :: struct {
    vertexBufferHolder : BufferHolder;
    indexBufferHolder : BufferHolder;

    // @todo Could have a mesh info about it being static or dynamic,
    // and don't share the instance buffer if it's static.
    sharedInstanceRef : Scene.InstanceRef;

    blasHolder : AsHolder; // @todo Could reduce the size of meshes by not storing this when RayTracing is not active.
}

impl_mesh_init :: (using mesh : *Mesh) {
    sharedInstanceRef = _scene_share_instance(scene);
}

impl_mesh_cleanup :: (mesh : *Mesh) {
    engine := mesh.scene.engine;
    Vk.device_wait_idle(engine.device);

    _scene_unshare_instance(mesh.scene, mesh.sharedInstanceRef);

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

    return true;
}

_mesh_post_init :: (mesh : *Mesh) {
}

_mesh_draw :: (mesh : *Mesh, commandBuffer : Vk.CommandBuffer) {
    if mesh.indices.count == 0 then return;

    offsets := cast(Vk.DeviceSize) 0;
    Vk.cmd_bind_vertex_buffers(commandBuffer, 0, 1, *mesh.vertexBufferHolder.buffer, *offsets);
    instanceBuffer, instanceOffset := _scene_instance_buffer_and_offset(mesh.scene, mesh.sharedInstanceRef);
    Vk.cmd_bind_vertex_buffers(commandBuffer, 1, 1, *instanceBuffer, *instanceOffset);
    Vk.cmd_bind_index_buffer(commandBuffer, mesh.indexBufferHolder.buffer, 0, Vk.IndexType.Uint16);
    Vk.cmd_draw_indexed(commandBuffer, cast(u32) mesh.indices.count, 1, 0, 0, 0);
    mesh.scene.engine.stats.drawCalls += 1;
}

#scope_file

_rebuild_vertex_buffer :: (using mesh : *Mesh) -> bool {
    // @todo Using .Direct instead of .OnDemandStaging for vertex and index buffers
    // make them really fast for integrated GPUs. Definitely an idea.
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
