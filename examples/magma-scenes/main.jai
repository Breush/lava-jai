Basic :: #import "Basic";
Crater :: #import "Crater";
Magma :: #import "Magma";

main :: () {
    smallWindow := Crater.create_window(.{width=400, height=400}, "Magma | Scenes I");
    bigWindow := Crater.create_window(.{width=800, height=800}, "Magma | Scenes II");

    engine := Magma.create_engine();

    smallTarget := Magma.create_window_target(engine, Crater.window_get_handle(smallWindow));
    bigTarget := Magma.create_window_target(engine, Crater.window_get_handle(bigWindow));

    // @todo Complete the example with scenes.
    camera1 := Magma.create_camera(engine, .{width=800, height=800});
    camera2 := Magma.create_camera(engine, .{width=11, height=11});

    Magma.target_bind(smallTarget, camera1);
    Magma.target_bind(bigTarget, camera2);

    // Main loop, updating rendering and catching closing events.
    while smallWindow.opened && bigWindow.opened {
        while true {
            event := Crater.window_poll_event(smallWindow);
            if event.kind == Crater.Event.Kind.None {
                event = Crater.window_poll_event(bigWindow);
            }
            if event.kind == Crater.Event.Kind.None then break;

            if event.kind == {
            case Crater.Event.Kind.WindowClosed;
                Crater.window_close(smallWindow);
                Crater.window_close(bigWindow);
                break;

            case Crater.Event.Kind.KeyPressed;
                if event.key.which == Crater.Key.Escape {
                    Crater.window_close(smallWindow);
                    Crater.window_close(bigWindow);
                    break;
                }
            }
        }

        Magma.engine_update(engine);
        Magma.engine_draw(engine);
    }

    Magma.destroy_engine(engine);
}
