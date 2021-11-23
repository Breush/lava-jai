// #import "Basic"()(MEMORY_DEBUGGER=true);

Basic :: #import "Basic";
Crater :: #import "Crater";

#load "../helpers/magma.jai";

main :: () {
    // Enable VR globally by saying a target of this type will be used.
    // Each VR usage below will be ignored if not available.
    // One can check value of engine.vr.enabled after initing the engine
    // if needed.
    options : Magma.Engine.Options;
    options.targetFlags |= .Vr;
    engine := Magma.create_engine(options);

    // We create a companion window, it will display the left eye of what's displayed
    // in the vrTarget.
    window := Crater.create_window(.{width=1200, height=675}, "Magma | VR - Companion window");
    windowTarget := Magma.create_window_target(engine, Crater.window_get_handle(window));
    vrTarget := Magma.create_vr_target(engine);

    scene := Magma.create_scene(engine);
    {
        cube1 := magma_helper_make_cube(scene, 0.3);
        cube2 := magma_helper_make_cube(scene, 0.7);

        Magma.mesh_translate(cube1, .{1, 0, 0.7 + 0.15});
        Magma.mesh_translate(cube2, .{1, 0, 0.35});
    }

    // @note To allow using this program even when VR is not available,
    // we check if the extent is non-null.
    // VR eyes usually have the same extent, but we ask for both anyway.
    // Nothing prevents us to render to a different extent, image will be
    // stretched to fill the recommended extent.
    leftEyeExtent := Magma.vr_recommended_eye_extent(*engine.vr, .Left);
    rightEyeExtent := Magma.vr_recommended_eye_extent(*engine.vr, .Right);
    if leftEyeExtent.width == 0 {
        leftEyeExtent.width = window.videoMode.width;
        leftEyeExtent.height = window.videoMode.height;
    }
    if rightEyeExtent.width == 0 {
        rightEyeExtent.width = window.videoMode.width;
        rightEyeExtent.height = window.videoMode.height;
    }

    // VR targets don't need cameras to control eyes because they are tightly linked
    // to the target itself, so the renderers eyes will be automatically updated.
    leftRenderer := Magma.create_forward_renderer(scene, leftEyeExtent);
    rightRenderer := Magma.create_forward_renderer(scene, rightEyeExtent);

    // @todo Make this example interactive, allowing to grab cubes.
    // @todo Make this example display user's hands.

    Magma.target_bind(vrTarget, Magma.renderer_get_output(leftRenderer), Magma.VrTarget.LEFT_EYE_BIND_INDEX);
    Magma.target_bind(vrTarget, Magma.renderer_get_output(rightRenderer), Magma.VrTarget.RIGHT_EYE_BIND_INDEX);

    // Showing HMD left eye view to the companion window
    Magma.target_bind(windowTarget, Magma.renderer_get_output(leftRenderer));

    // Main loop, updating rendering and catching closing events.
    while window.opened {
        event := Crater.window_poll_event(window);

        if event.kind == .WindowClosed {
            Crater.window_close(window);
            break;
        }

        Magma.engine_update(engine);
        Magma.engine_draw(engine);
    }

    Magma.destroy_engine(engine);
    Crater.destroy_window(window);

    #if Basic.MEMORY_DEBUGGER {
        Basic.report_memory_leaks();
    }
}
