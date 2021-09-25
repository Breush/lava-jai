// #import "Basic"()(MEMORY_DEBUGGER=true);

Basic :: #import "Basic";
Sill :: #import "Sill";
Chamber :: #import "Chamber";
Math :: #import "Math";

MeshEntity :: struct {
    using entity : Sill.Entity;

    transform : Sill.TransformComponent;
    mesh : Sill.MeshComponent;
}

CameraEntity :: struct {
    using entity : Sill.Entity;

    behavior : Sill.BehaviorComponent;
    transform : Sill.TransformComponent;
    camera : Sill.CameraComponent;

    origin : Chamber.vec3;
    target : Chamber.vec3;
}

main :: () {
    // @todo So far, We don't have any good way to generate code inside modules,
    // so the generated data structures are provided to the module with this trick
    // on create_engine.
    engine := Sill.create_engine(SillMeta);

    glbMeshEntity := SillMeta.create_mesh_entity(engine);
    glbMeshEntity.name = "mesh.glb";

    Sill.mesh_load_glb(*glbMeshEntity.mesh, "./assets/models/corset.glb");
    Sill.transform_scale(*glbMeshEntity.transform, 20);
    Sill.transform_rotate(*glbMeshEntity.transform, Math.PI, .{0, 0, 1});

    Sill.input_axis_bind(*engine.input, "camera.look-x", .MousePointerX);
    Sill.input_axis_bind(*engine.input, "camera.look-y", .MousePointerY);
    Sill.input_axis_bind(*engine.input, "camera.zoom", .MouseWheelY);

    camera := SillMeta.create_camera_entity(engine);
    camera.origin = .{2, 0, 1};
    camera.target = .{0, 0, 0.5};
    Sill.transform_origin_target(*camera.transform, camera.origin, camera.target);

    Sill.behavior_on_update(*camera.behavior, xx (dt : float64, camera : *CameraEntity) {
        engine := camera.engine;

        lookX := Sill.input_axis_value(*engine.input, "camera.look-x");
        lookY := Sill.input_axis_value(*engine.input, "camera.look-y");
        if lookX != 0. || lookY != 0. {
            camera.origin.std += Chamber.rotate_around_target(camera.origin, camera.target, -lookX / 100., lookY / 100.);
            Sill.transform_origin_target(*camera.transform, camera.origin, camera.target);
        }

        zoom := Sill.input_axis_value(*engine.input, "camera.zoom");
        if zoom != 0. {
            direction := normalize(camera.target - camera.origin);
            radius := length(camera.target - camera.origin);
            radius += -(zoom / 10.) * radius;
            camera.origin.std = camera.target - radius * direction;
            Sill.transform_origin_target(*camera.transform, camera.origin, camera.target);
        }
    }, camera);

    Sill.engine_run(engine);

    // Just for sakeness, but you shouldn't be destroying anything if you're just
    // terminating the program.
    Sill.destroy_engine(engine);

    // Basic.report_memory_leaks();
}

#scope_file

#import "Math";
