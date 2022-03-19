#scope_module

Posix :: #import "POSIX";
Unicode :: #import "Unicode";

Xcb :: #import "Xcb";
Xkb :: #import "Xkb";

WindowImpl :: struct {
    xcbId : u32;
    xcbConnection : *Xcb.Connection;
    xcbScreen : *Xcb.Screen;
    xcbProtocolsReply : *Xcb.InternAtomReply;
    xcbDeleteWindowReply : *Xcb.InternAtomReply;
    xcbEmptyCursor : u32;

    xkbContext : *Xkb.Context;
    xkbKeymap : *Xkb.Keymap;
    xkbState : *Xkb.State;
    xkbComposeTable : *Xkb.ComposeTable;
    xkbComposeState : *Xkb.ComposeState;
}

EVENT_MASKS :: cast(u32) (Xcb.EventMask.PointerMotion |
                          Xcb.EventMask.ButtonPress |
                          Xcb.EventMask.KeyPress | Xcb.EventMask.KeyRelease |
                          Xcb.EventMask.StructureNotify);

impl_window_init :: (window : *Window) -> bool {
    if !setup_xcb(window) then return false;
    if !setup_xkb(window) then return false;

    // Creating window indeed
    window.xcbId = Xcb.generate_id(window.xcbConnection);

    valueMask := cast(u32) (Xcb.Cw.BackPixel | Xcb.Cw.EventMask);
    valueList : [8]u32;
    valueList[0] = window.xcbScreen.blackPixel;
    valueList[1] = EVENT_MASKS;

    Xcb.create_window(window.xcbConnection, 0, window.xcbId, window.xcbScreen.root, 0, 0, window.videoMode.width, window.videoMode.height, 0,
                      cast(u16) Xcb.WindowClass.InputOutput, window.xcbScreen.rootVisual, valueMask, *valueList[0]);

    // Enable window destroyed notifications
    window.xcbProtocolsReply = Xcb.helper_get_intern_atom(window.xcbConnection, true, "WM_PROTOCOLS");
    window.xcbDeleteWindowReply = Xcb.helper_get_intern_atom(window.xcbConnection, false, "WM_DELETE_WINDOW");
    Xcb.change_property(window.xcbConnection, cast(u8) Xcb.PropMode.Replace, window.xcbId, window.xcbProtocolsReply.atom,
                        cast(u32) Xcb.AtomEnum.AtomAtom, 32, 1, *window.xcbDeleteWindowReply.atom);

    // Set title
    Xcb.change_property(window.xcbConnection, cast(u8) Xcb.PropMode.Replace, window.xcbId,
                        cast(u32) Xcb.AtomEnum.AtomWmName, cast(u32) Xcb.AtomEnum.AtomString, 8, cast(u32) window.title.count, window.title.data);

    // Show the final window
    Xcb.map_window(window.xcbConnection, window.xcbId);
    Xcb.flush(window.xcbConnection);

    return true;
}

impl_window_get_handle :: (window : *Window) -> Chamber.WindowHandle {
    handle : Chamber.WindowHandle;
    handle.xcb.connection = window.xcbConnection;
    handle.xcb.window = window.xcbId;
    return handle;
}

// Fill the window.events array.
impl_window_process_events :: (window : *Window) {
    Xcb.flush(window.xcbConnection);

    event : *Xcb.GenericEvent;
    while true {
        event = Xcb.poll_for_event(window.xcbConnection);
        if event == null then break;

        _window_event_process(window, event);
        context.default_allocator.proc(Allocator_Mode.FREE, 0, 0, event, null);
    }
}

impl_window_close :: (window : *Window) {
    Xkb.state_unref(window.xkbState);
    Xkb.keymap_unref(window.xkbKeymap);
    Xkb.context_unref(window.xkbContext);

    // Using default_allocator because these were allocated
    // in C code, so we don't want to call any other allocators.
    context.default_allocator.proc(Allocator_Mode.FREE, 0, 0, window.xcbProtocolsReply, null);
    context.default_allocator.proc(Allocator_Mode.FREE, 0, 0, window.xcbDeleteWindowReply, null);
}

impl_window_center_pointer :: (window : *Window) {
    Xcb.warp_pointer(window.xcbConnection, Xcb.NONE, window.xcbId, 0, 0, 0, 0,
                     cast(s16) window.videoMode.width / 2, cast(s16) window.videoMode.height / 2);
}

impl_window_update_pointer_hidden :: (window : *Window) {
    if window.xcbEmptyCursor == Xcb.NONE {
        window.xcbEmptyCursor = Xcb.generate_id(window.xcbConnection);
        pixmap := Xcb.generate_id(window.xcbConnection);
        Xcb.create_pixmap(window.xcbConnection, 1, pixmap, window.xcbId, 1, 1);
        Xcb.create_cursor(window.xcbConnection, window.xcbEmptyCursor, pixmap, pixmap,
                          0, 0, 0, 0, 0, 0, 0, 0);
        Xcb.free_pixmap(window.xcbConnection, pixmap);
    }

    values := ifx window.pointerHidden then window.xcbEmptyCursor else Xcb.NONE;
    Xcb.change_window_attributes(window.xcbConnection, window.xcbId, cast(u32) Xcb.Cw.Cursor, *values);
    Xcb.flush(window.xcbConnection);
}

#scope_file

setup_xcb :: (window : *Window) -> bool {
    screenIndex : int;
    window.xcbConnection = Xcb.connect(null, *screenIndex);

    // Find the correct screen
    setup := Xcb.get_setup(window.xcbConnection);
    window.xcbScreen = Xcb.setup_get_screen(setup, screenIndex);

    if window.xcbScreen == null {
        context.logger("Could not find XCB screen.\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    return true;
}

setup_xkb :: (window : *Window) -> bool {
    // @note All that knowledge for correct setup comes from
    // - https://github.com/xkbcommon/libxkbcommon/blob/master/doc/quick-guide.md
    // - https://xkbcommon.org/doc/current/group__x11.html
    Xkb.x11_setup_xkb_extension(window.xcbConnection, Xkb.X11_MIN_MAJOR_XKB_VERSION, Xkb.X11_MIN_MINOR_XKB_VERSION,
                                Xkb.X11SetupXkbExtensionFlags.No, null, null, null, null);

    // Context
    window.xkbContext = Xkb.context_new(Xkb.ContextFlags.No);
    if window.xkbContext == null {
        context.logger("Could not setup XKB context.\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    // Keymap
    deviceId := Xkb.x11_get_core_keyboard_device_id(window.xcbConnection);
    if deviceId == -1 {
        context.logger("Could not get XKB device ID.\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    window.xkbKeymap = Xkb.x11_keymap_new_from_device(window.xkbContext, window.xcbConnection, deviceId, Xkb.KeymapCompileFlags.No);
    if window.xkbKeymap == null {
        context.logger("Could not setup XKB keymap.\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    // State
    window.xkbState = Xkb.x11_state_new_from_device(window.xkbKeymap, window.xcbConnection, deviceId);
    if window.xkbState == null {
        context.logger("Could not setup XKB state.\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    // Compose
    window.xkbComposeTable = Xkb.compose_table_new_from_locale(window.xkbContext, Posix.getenv("LANG"), Xkb.ComposeCompileFlags.No);
    if window.xkbComposeTable == null {
        context.logger("Could not setup XKB compose table (wrong LANG environment variable?).\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    window.xkbComposeState = Xkb.compose_state_new(window.xkbComposeTable, Xkb.ComposeStateFlags.No);
    if window.xkbComposeState == null {
        context.logger("Could not setup XKB compose state (wrong LANG environment variable?).\n", null, .{common_flags=Log_Flags.ERROR});
        return false;
    }

    return true;
}

_window_event_process :: (window : *Window, xcbEvent : *Xcb.GenericEvent) {
    if xcbEvent.responseType & 0x7f == {
    case Xcb.CLIENT_MESSAGE;
        clientMessageEvent := cast(*Xcb.ClientMessageEvent) xcbEvent;
        if clientMessageEvent.data.data32[0] != window.xcbDeleteWindowReply.atom {
            return;
        }

        event : Event;
        event.kind = .WindowClosed;
        _window_add_event(window, *event);

    case Xcb.CONFIGURE_NOTIFY;
        configureNotifyEvent := cast(*Xcb.ConfigureNotifyEvent) xcbEvent;

        event : Event;
        event.kind = .WindowSizeChanged;
        event.windowSize.width = configureNotifyEvent.width;
        event.windowSize.height = configureNotifyEvent.height;
        _window_add_event(window, *event);

    case Xcb.MOTION_NOTIFY;
        motionNotifyEvent := cast(*Xcb.MotionNotifyEvent) xcbEvent;

        event : Event;
        event.kind = .MousePointerMoved;
        event.mousePointer.x = motionNotifyEvent.eventX;
        event.mousePointer.y = motionNotifyEvent.eventY;
        _window_add_event(window, *event);

    case Xcb.KEY_PRESS;
        keyPressEvent := cast(*Xcb.KeyPressEvent) xcbEvent;

        keycode := keyPressEvent.detail;
        Xkb.state_update_key(window.xkbState, keycode, Xkb.KeyDirection.KeyDown);
        keysym := Xkb.state_key_get_one_sym(window.xkbState, keycode);

        event : Event;
        event.kind = .KeyPressed;
        event.key.which = _keysym_to_key(keysym);
        _window_add_event(window, *event);

        // We have two state machines running: one for dead-key composing
        // and one classical. We use the unicode codepoint of the dead-key composing
        // one if it has any result.
        utf8ByteCount : u32;
        utf8 : [5]u8;
        utf32 : u32;
        composeFeedResult := Xkb.compose_state_feed(window.xkbComposeState, keysym);
        composeStateStatus := Xkb.compose_state_get_status(window.xkbComposeState);
        if composeFeedResult == Xkb.ComposeFeedResult.Accepted && composeStateStatus == Xkb.ComposeStatus.Composed {
            utf8ByteCount = cast(u32) Xkb.compose_state_get_utf8(window.xkbComposeState, *utf8[0], 4);
            utf32 = Unicode.character_utf8_to_utf32(*utf8[0], utf8ByteCount);
        }
        else if composeStateStatus == Xkb.ComposeStatus.Nothing {
            utf8ByteCount = cast(u32) Xkb.state_key_get_utf8(window.xkbState, keycode, *utf8[0], 4);
            utf32 = Unicode.character_utf8_to_utf32(*utf8[0], 4);
        }
        // Else:
        // 1) XKB_COMPOSE_CANCELLED
        // Example: typing <dead_acute> <b> cancels the composition,
        // in that case, we don't want to emit <b> codepoint.
        // 2) XKB_COMPOSE_COMPOSING
        // No need to produce a codepoint in that case.

        // @note ASCII below 32 (SPACE) is non-text
        // and 127 (DELETE) should be ignored too.
        if (utf32 > 31 && utf32 != 127) {
            event : Event;
            event.kind = .TextEntered;
            event.text.str.data = *event.text.utf8[0]; // Relative pointer
            event.text.str.count = cast(s8) utf8ByteCount; // @note Count type changes to reduce size, nothing planned to change that in the compiler.
            event.text.utf8 = utf8;
            event.text.utf32 = utf32;
            _window_add_event(window, *event);
        }

    case Xcb.KEY_RELEASE;
        keyReleaseEvent := cast(*Xcb.KeyReleaseEvent) xcbEvent;

        keycode := keyReleaseEvent.detail;
        Xkb.state_update_key(window.xkbState, keycode, Xkb.KeyDirection.KeyUp);
        keysym := Xkb.state_key_get_one_sym(window.xkbState, keycode);

        event : Event;
        event.kind = .KeyReleased;
        event.key.which = _keysym_to_key(keysym);
        _window_add_event(window, *event);

    case Xcb.BUTTON_PRESS;
        buttonPressEvent := cast(*Xcb.ButtonPressEvent) xcbEvent;

        // Vertical mouse wheel buttons
        if buttonPressEvent.detail == 4 ||
           buttonPressEvent.detail == 5 {
            event : Event;
            event.kind = .MouseWheelScrolled;
            if buttonPressEvent.detail == 4 {
                event.mouseWheel.dy = 1.;
            } else {
                event.mouseWheel.dy = -1.;
            }
            _window_add_event(window, *event);
        }
    }
}

_keysym_to_key :: (keysym : Xkb.Keysym) -> Key {
    if keysym == {
    case Xkb.KEY_space; return .Space;
    case Xkb.KEY_a; #through; case Xkb.KEY_A; return .A;
    case Xkb.KEY_b; #through; case Xkb.KEY_B; return .B;
    case Xkb.KEY_c; #through; case Xkb.KEY_C; return .C;
    case Xkb.KEY_d; #through; case Xkb.KEY_D; return .D;
    case Xkb.KEY_e; #through; case Xkb.KEY_E; return .E;
    case Xkb.KEY_f; #through; case Xkb.KEY_F; return .F;
    case Xkb.KEY_g; #through; case Xkb.KEY_G; return .G;
    case Xkb.KEY_h; #through; case Xkb.KEY_H; return .H;
    case Xkb.KEY_i; #through; case Xkb.KEY_I; return .I;
    case Xkb.KEY_j; #through; case Xkb.KEY_J; return .J;
    case Xkb.KEY_k; #through; case Xkb.KEY_K; return .K;
    case Xkb.KEY_l; #through; case Xkb.KEY_L; return .L;
    case Xkb.KEY_m; #through; case Xkb.KEY_M; return .M;
    case Xkb.KEY_n; #through; case Xkb.KEY_N; return .N;
    case Xkb.KEY_o; #through; case Xkb.KEY_O; return .O;
    case Xkb.KEY_p; #through; case Xkb.KEY_P; return .P;
    case Xkb.KEY_q; #through; case Xkb.KEY_Q; return .Q;
    case Xkb.KEY_r; #through; case Xkb.KEY_R; return .R;
    case Xkb.KEY_s; #through; case Xkb.KEY_S; return .S;
    case Xkb.KEY_t; #through; case Xkb.KEY_T; return .T;
    case Xkb.KEY_u; #through; case Xkb.KEY_U; return .U;
    case Xkb.KEY_v; #through; case Xkb.KEY_V; return .V;
    case Xkb.KEY_w; #through; case Xkb.KEY_W; return .W;
    case Xkb.KEY_x; #through; case Xkb.KEY_X; return .X;
    case Xkb.KEY_y; #through; case Xkb.KEY_Y; return .Y;
    case Xkb.KEY_z; #through; case Xkb.KEY_Z; return .Z;
    case Xkb.KEY_BackSpace; return .Backspace;
    case Xkb.KEY_Tab; return .Tab;
    case Xkb.KEY_Escape; return .Escape;
    case Xkb.KEY_F1; return .F1;
    case Xkb.KEY_F2; return .F2;
    case Xkb.KEY_F3; return .F3;
    case Xkb.KEY_F4; return .F4;
    case Xkb.KEY_F5; return .F5;
    case Xkb.KEY_F6; return .F6;
    case Xkb.KEY_F7; return .F7;
    case Xkb.KEY_F8; return .F8;
    case Xkb.KEY_F9; return .F9;
    case Xkb.KEY_F10; return .F10;
    case Xkb.KEY_F11; return .F11;
    case Xkb.KEY_F12; return .F12;
    case Xkb.KEY_Left; return .Left;
    case Xkb.KEY_Up; return .Up;
    case Xkb.KEY_Right; return .Right;
    case Xkb.KEY_Down; return .Down;
    case Xkb.KEY_Shift_L; return .ShiftLeft;
    case Xkb.KEY_Shift_R; return .ShiftRight;
    case Xkb.KEY_Control_L; return .ControlLeft;
    case Xkb.KEY_Control_R; return .ControlRight;
    case Xkb.KEY_Alt_L; return .AltLeft;
    case Xkb.KEY_Alt_R; return .AltRight;
    case Xkb.KEY_Delete; return .Delete;
    case Xkb.KEY_Home; return .Home;
    case Xkb.KEY_End; return .End;
    }

    return .Unknown;
}
