Basic :: #import "Basic";
Unicode :: #import "Unicode";

Crater :: #import "Crater";

main :: () {
    window := Crater.create_window(.{width=1600, height=900}, "Crater | Events");

    while true {
        event := Crater.window_poll_event(window);

        if event.kind != Crater.Event.Kind.None {
            Basic.print("% -> ", event.kind);

            if event.kind == Crater.Event.Kind.WindowClosed {
                Basic.print("Closing window.\n");
                break;
            }
            else if event.kind == Crater.Event.Kind.KeyPressed &&
                    event.key.which == Crater.Key.Escape {
                Basic.print("% -- Closing window.\n", event.key);
                break;
            }

            if event.kind == Crater.Event.Kind.TextEntered {
                Basic.print("%\n", event.text);
            } else if event.kind == Crater.Event.Kind.KeyPressed ||
                      event.kind == Crater.Event.Kind.KeyReleased {
                Basic.print("%\n", event.key);
            } else if event.kind == Crater.Event.Kind.MousePointerMoved {
                Basic.print("%\n", event.mousePointer);
            } else if event.kind == Crater.Event.Kind.WindowSizeChanged {
                Basic.print("%\n", event.windowSize);
            } else {
                Basic.print("\n");
            }
        }
    }

    Crater.destroy_window(window);
}
