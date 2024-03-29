#if OS == .LINUX {
    #load "xcb.jai";
} else #if OS == .WINDOWS {
    #load "dwm.jai";
}

Window :: struct {
    videoMode : VideoMode;
    title : string;
    events : [..]Event;
    mousePosition : Chamber.svec2;
    opened : bool;

    pointerAutoCentered := false;
    pointerStyle : PointerStyle;

    using details : struct {
        // To prevent big deltas when moving the mouse the first time.
        pointerPositionToReset : bool;
        pointerCurrentlyCentered : bool;
        pointerLastKnownPosition : Chamber.svec2;
    };

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
        MouseButtonPressed;
        MouseButtonReleased;
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
        dx : float32;
        dy : float32;
    }

    KeyData :: struct {
        which : Key;
    }

    MouseButtonData :: struct {
        which : MouseButton;
    }

    TextData :: struct {
        str : string/*~s8 @fixme Jai compiler bug */;    // Points to the utf8 data below
        utf8 : [5]u8;       // UTF-8, zero-terminated
        utf32 : u32;        // UTF-32
    }

    kind : Kind;
    union {
        windowSize : WindowSizeData;     // On WindowSizeChanged
        mousePointer : MousePointerData; // On MousePointerMoved
        mouseWheel : MouseWheelData;     // On MouseWheelScrolled
        mouseButton : MouseButtonData;   // On MouseButtonPressed, MouseButtonReleased
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
    _0; _1; _2; _3; _4; _5; _6; _7; _8; _9;
    Numpad0; Numpad1; Numpad2; Numpad3; Numpad4; Numpad5; Numpad6; Numpad7; Numpad8; Numpad9;
    NumpadEnter; // Not handled on Windows -- yet.
    EAcute; EGrave;
    Ampersand; QuoteDouble; Apostrophe; ParenthesisLeft; ParenthesisRight; Underscore;
    Minus; Plus;
    Escape;
    AltLeft; AltRight;
    ControlLeft; ControlRight;
    ShiftLeft; ShiftRight;
    Delete;
    Tab; Space; Backspace; Return;
    Home; End;
}

MouseButton :: enum {
    Unknown :: 0;
    Left;
    Middle;
    Right;
}

PointerStyle :: enum {
    Default :: 0;
    Hidden;
    Hand;           // Usually for draggable elements.
    HandPointing;   // Usually for links and buttons.
    HandGrabbing;   // Usually while dragging elements.
    Text;           // I-beam, usually for horizontal text.
}

ClipboardKind :: enum {
    Default :: 0;
    MousePaste;     // Linux-only, the middle-click paste.
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
    window.pointerPositionToReset = true;
    return window.opened;
}

window_cleanup :: (window : *Window, resetMemory := true) {
    if window.opened {
        window_close(window);
    }

    Basic.array_free(window.events);

    if resetMemory {
         window.* = .{};
    }
}

destroy_window :: (window : *Window) {
    window_cleanup(window, false);

    if window.allocator.proc != null {
        Basic.free(window,, window.allocator);
    }
}

window_get_extent :: (window : *Window, $T := Chamber.uvec2) -> T {
    extent : T;
    extent.width = cast(type_of(T.width)) window.videoMode.width;
    extent.height = cast(type_of(T.height)) window.videoMode.height;
    return extent;
}

window_get_handle :: (window : *Window) -> Chamber.WindowHandle {
    return impl_window_get_handle(window);
}

window_poll_event :: (window : *Window, squash := false) -> Event {
    event : Event;
    event.kind = .None;

    if window.events.count == 0 {
        impl_window_process_events(window);
        if window.pointerAutoCentered && !window.pointerCurrentlyCentered {
            _center_pointer(window);
        }

        if window.events.count == 0 {
            return event;
        }
    }

    event = Basic.pop(*window.events);

    if squash {
        if event.kind == .MousePointerMoved {
            for < futureEvent : window.events {
                if futureEvent.kind != .MousePointerMoved then continue;
                event.mousePointer.x = futureEvent.mousePointer.x;
                event.mousePointer.y = futureEvent.mousePointer.y;
                event.mousePointer.dx += futureEvent.mousePointer.dx;
                event.mousePointer.dy += futureEvent.mousePointer.dy;
                remove futureEvent;
            }
        } else if event.kind == .MouseWheelScrolled {
            for < futureEvent : window.events {
                if futureEvent.kind != .MouseWheelScrolled then continue;
                event.mouseWheel.dx += futureEvent.mouseWheel.dx;
                event.mouseWheel.dy += futureEvent.mouseWheel.dy;
                remove futureEvent;
            }
        } else if event.kind == .WindowSizeChanged {
            for < futureEvent : window.events {
                if futureEvent.kind != .WindowSizeChanged then continue;
                event.windowSize.width = futureEvent.windowSize.width;
                event.windowSize.height = futureEvent.windowSize.height;
                remove futureEvent;
            }
        }
    }

    return event;
}

window_get_clipboard :: (window : *Window, clipboardKind : ClipboardKind) -> string {
    return impl_window_get_clipboard(window, clipboardKind);
}

window_close :: (window : *Window) {
    if !window.opened then return;
    window.opened = false;
    impl_window_close(window);
}

// During auto-centering, the only mouse position you can get is the
// center of the window. Only the (dx,dy) events are interesting.
window_pointer_auto_centered :: (window : *Window, autoCentered := true) {
    window.pointerAutoCentered = autoCentered;
    window.pointerCurrentlyCentered = false;
    window.mousePosition.x = window.videoMode.width / 2;
    window.mousePosition.y = window.videoMode.height / 2;
}

window_pointer_style :: (window : *Window, pointerStyle : PointerStyle) {
    if window.pointerStyle == pointerStyle then return;
    window.pointerStyle = pointerStyle;
    impl_window_update_pointer_style(window);
}

#scope_module

_window_add_event :: (window : *Window, event : *Event) {
    if event.kind == .WindowSizeChanged {
        if window.videoMode.width == event.windowSize.width &&
           window.videoMode.height == event.windowSize.height {
           return;
        }

        window.videoMode.width = event.windowSize.width;
        window.videoMode.height = event.windowSize.height;
    } else if event.kind == .MousePointerMoved {
        // @note We do not emit an event when the mouse is meant to be centered.
        // We just flag it might not be at the right position.
        // And it's window_center_pointer that does the job of emitting one event per frame if necessary.
        if window.pointerAutoCentered {
            window.pointerLastKnownPosition.x = event.mousePointer.x;
            window.pointerLastKnownPosition.y = event.mousePointer.y;
            // This way, centering events won't flag this back to not centered.
            window.pointerCurrentlyCentered = window.mousePosition.x == event.mousePointer.x &&
                                              window.mousePosition.y == event.mousePointer.y;
            return;
        }

        if !window.pointerPositionToReset {
            event.mousePointer.dx = event.mousePointer.x - cast(s16) window.mousePosition.x;
            event.mousePointer.dy = event.mousePointer.y - cast(s16) window.mousePosition.y;
        } else {
            window.pointerPositionToReset = false;
        }

        window.mousePosition.x = event.mousePointer.x;
        window.mousePosition.y = event.mousePointer.y;
    }

    // @note Adding the event at the start so that we pop the right event.
    Basic.array_insert_at(*window.events, event.*, 0);
}

_center_pointer :: (window : *Window) {
    impl_window_center_pointer(window);
    window.pointerCurrentlyCentered = true;

    // Emit an event, (x,y) centered and (dx,dy) the movement.
    event : Event;
    event.kind = .MousePointerMoved;
    event.mousePointer.x = cast(s16) window.mousePosition.x;
    event.mousePointer.y = cast(s16) window.mousePosition.y;
    if !window.pointerPositionToReset {
        event.mousePointer.dx = cast(s16) (window.pointerLastKnownPosition.x - window.mousePosition.x);
        event.mousePointer.dy = cast(s16) (window.pointerLastKnownPosition.y - window.mousePosition.y);
    } else {
        window.pointerPositionToReset = false;
    }

    Basic.array_insert_at(*window.events, event, 0);
}

Basic :: #import "Basic";
Chamber :: #import "Chamber";

_CHECK :: Chamber._CHECK;
