// #import "Basic"()(MEMORY_DEBUGGER=true);

Basic :: #import "Basic";
Sill :: #import "Sill";

MeshEntity :: struct {
    using entity : Sill.Entity;

    mesh : Sill.MeshComponent;
}

main :: () {
    // @todo So far, We don't have any good way to generate code inside modules,
    // so the generated data structures are provided to the module with this trick
    // on create_engine.
    engine := Sill.create_engine(SillMeta);

    glbMeshEntity := SillMeta.create_mesh_entity(engine);
    glbMeshEntity.name = "mesh.glb";

    Sill.mesh_load_glb(*glbMeshEntity.mesh, "./assets/models/corset.glb");

    Sill.engine_run(engine);
}
