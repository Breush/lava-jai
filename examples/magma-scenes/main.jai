Basic :: #import "Basic";
Crater :: #import "Crater";

#load "../helpers/magma.jai";

main :: () {
    // Here's the goal of the program:
    //
    // +=================================+  +=================================+
    // | Window I                        |  | Window II                       |
    // |=================================|  |=================================|
    // |                |                |  |                |                |
    // | Scene 1        | Scene 1        |  | Scene 2        | Scene 1        |
    // | (Two cubes)    | (Two cubes)    |  | (Pyramid)      | (Two cubes)    |
    // |                |                |  |                |                |
    // | Camera 1.A     | Camera 1.B     |  | Camera 2.B     | Camera 1.A     |
    // |                |                |  |                |                |
    // |---------------------------------|  +=================================+
    // |                                 |
    // | Scene 2                         |
    // | (Pyramid)                       |
    // |                                 |
    // | Camera 2.A                      |
    // |                                 |
    // +=================================+
    //
    // This demonstrates:
    // - Multiple targets (here, multiple windows) managed by only one engine
    // - Multiple scenes (here, one with cubes and one with a pyramid), working independently with targets
    // - Multiple cameras (here, two for each scene), controlled independently
    // - Cameras outputs composed via ComposePostProcesses (one for each target)

    // The following are our displays.
    bigWindow := Crater.create_window(.{width=800, height=800}, "Magma | Scenes I");
    smallWindow := Crater.create_window(.{width=800, height=400}, "Magma | Scenes II");

    // To ensure better communication with the graphic cards,
    // having only one engine is a good idea.
    engine := Magma.create_engine();

    // We could have targeted files or a VR display directly, but we will display to our windows.
    // Note that on the "bigTarget" we used an option to have "nearest" filter, which means that
    // pixels from the renderer image
    bigTarget := Magma.create_window_target(engine, Crater.window_get_handle(bigWindow), .{filter=.Nearest});
    smallTarget := Magma.create_window_target(engine, Crater.window_get_handle(smallWindow));

    // This scene containing two cubes will be displayed
    // to the two targets.
    // Internally, the camera view is renderered only once per frame.
    // If for some reason you have a renderer (e.g. camera) that is not used
    // or its bounding chain does not go to a target, nothing will happen on draw,
    // but updates will occur.
    scene1 := Magma.create_scene(engine);
    {
        // Go check out magma_helper_make_cube to know how to write a mesh by hand!
        cube1 := magma_helper_make_cube(scene1, 0.3);
        cube2 := magma_helper_make_cube(scene1, 0.7);

        Magma.mesh_translate(cube1, .{0, 0, 0.5});
    }

    scene2 := Magma.create_scene(engine);
    {
        pyramid := magma_helper_make_pyramid(scene2, 1.);
    }

    // @todo ComposeStage

    renderer1A := Magma.create_forward_renderer(scene1, .{width=800, height=450});
    camera1A := Magma.renderer_make_orbit_camera(renderer1A);

    renderer2A := Magma.create_forward_renderer(scene2, .{width=120, height=90});
    camera2A := Magma.renderer_make_orbit_camera(renderer2A);

    Magma.orbit_camera_origin_target(*camera1A, .{-2, -1, 1}, .{0, 0, 0});
    Magma.orbit_camera_origin_target(*camera2A, .{-2, -1, 1}, .{0, 0, 0});

    Magma.target_bind(smallTarget, Magma.renderer_get_output(renderer1A));
    Magma.target_bind(bigTarget, Magma.renderer_get_output(renderer2A));

    // Main loop, updating rendering and catching closing events.
    while smallWindow.opened && bigWindow.opened {
        while true {
            event := Crater.window_poll_event(smallWindow);
            if event.kind == .MousePointerMoved {
                dx := cast(float) event.mousePointer.dx / 100.;
                dy := cast(float) event.mousePointer.dy / 100.;
                Magma.orbit_camera_rotate_around_target(*camera1A, -dx, dy);
            } else if event.kind == .None {
                event = Crater.window_poll_event(bigWindow);

                if event.kind == .MousePointerMoved {
                    dx := cast(float) event.mousePointer.dx / 100.;
                    dy := cast(float) event.mousePointer.dy / 100.;
                    Magma.orbit_camera_rotate_around_target(*camera2A, -dx, dy);
                } else if event.kind == .None {
                    break;
                }
            }

            // Events below are handled the same way,
            // whether they come from the small or the big window.
            if event.kind == {
            case .WindowClosed;
                Crater.window_close(smallWindow);
                Crater.window_close(bigWindow);
                break;

            case .KeyPressed;
                if event.key.which == Crater.Key.Escape {
                    Crater.window_close(smallWindow);
                    Crater.window_close(bigWindow);
                    break;
                }

            case .MousePointerMoved;
            }
        }

        Magma.engine_update(engine);
        Magma.engine_draw(engine);
    }

    Magma.destroy_engine(engine);
}
