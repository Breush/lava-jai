Chamber :: #import "Chamber";

#if OS == .LINUX {
    #load "xcb.jai";
}

Window :: struct {
    videoMode : VideoMode;
    title : string;
    events : [..]Event;
    mousePosition : Chamber.svec2;
    opened : bool;

    pointerAutoCentered := false;
    pointerHidden := false;

    using impl : WindowImpl;

    allocator : Allocator;
    allocator_data : *void;
}

VideoMode :: struct {
    width : u16;
    height : u16;
    bitsPerPixels : u16 = 32;
}

Event :: struct {
    Kind :: enum {
        None :: 0;
        WindowClosed;
        WindowSizeChanged;
        MousePointerMoved;
        MouseWheelScrolled;
        KeyPressed;
        KeyReleased;
        TextEntered;
    }

    WindowSizeData :: struct {
        width : u16;
        height : u16;
    }

    MousePointerData :: struct  {
        x : s16;
        y : s16;
        dx : s16;
        dy : s16;
    }

    MouseWheelData :: struct {
        dy : float32;
    }

    KeyData :: struct {
        which : Key;
    }

    TextData :: struct {
        str : string~s8;    // Points to the utf8 data below
        utf8 : [5]u8;       // UTF-8, zero-terminated
        utf32 : u32;        // UTF-32
    }

    kind : Kind;
    union {
        windowSize : WindowSizeData;     // On WindowSizeChanged
        mousePointer : MousePointerData; // On MousePointerMoved
        mouseWheel : MouseWheelData;     // On MouseWheelScrolled
        key : KeyData;                   // On KeyPressed, KeyReleased
        text : TextData;                 // On TextEntered
    }
}

// A keyboard's key. Look at TextEntered event if you want effective composed text.
Key :: enum {
    Unknown :: 0;
    A; B; C; D; E; F; G; H; I; J; K; L; M; N; O; P; Q; R; S; T; U; V; W; X; Y; Z;
    Left; Right; Up; Down;
    F1; F2; F3; F4; F5; F6; F7; F8; F9; F10; F11; F12;
    Escape;
    AltLeft; AltRight;
    ControlLeft; ControlRight;
    ShiftLeft; ShiftRight;
    Delete;
    Tab; Space; Backspace;
    Home; End;
}

create_window :: (videoMode : VideoMode, title := "") -> *Window {
    window := cast(*Window) Basic.New(Window);
    Basic.remember_allocators(window);
    if !window_init(window, videoMode, title) {
        destroy_window(window);
        return null;
    }
    return window;
}

window_init :: (window : *Window, videoMode : VideoMode, title : string) -> bool {
    window.videoMode = videoMode;
    window.title = title;
    window.opened = impl_window_init(window);
    return window.opened;
}

window_cleanup :: (window : *Window, resetMemory := true) {
    if window.opened {
        window_close(window);
    }

    Basic.array_free(window.events);

    if resetMemory {
         (<<window) = Window.{};
    }
}

destroy_window :: (window : *Window) {
    window_cleanup(window, false);

    if window.allocator.proc != null {
        Basic.free(window, window.allocator);
    }
}

window_get_extent :: (window : *Window) -> Chamber.uvec2 {
    extent : Chamber.uvec2;
    extent.width = cast(u32) window.videoMode.width;
    extent.height = cast(u32) window.videoMode.height;
    return extent;
}

window_get_handle :: (window : *Window) -> Chamber.WindowHandle {
    return impl_window_get_handle(window);
}

window_poll_event :: (window : *Window) -> Event {
    event : Event;
    event.kind = Event.Kind.None;

    if window.events.count == 0 {
        impl_window_process_events(window);
        if window.events.count == 0 {
            return event;
        }
    }

    // @fixme This is not popped from the right side.
    return Basic.pop(*window.events);
}

window_close :: (window : *Window) {
    if !window.opened then return;
    window.opened = false;
    impl_window_close(window);
}

window_pointer_auto_centered :: (window : *Window, autoCentered := true) {
    window.pointerAutoCentered = autoCentered;
    impl_window_update_pointer_auto_centered(window);
}

window_pointer_hidden :: (window : *Window, hidden := true) {
    window.pointerHidden = hidden;
    impl_window_update_pointer_hidden(window);
}
