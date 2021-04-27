Basic :: #import "Basic";
Posix :: #import "POSIX";
Unicode :: #import "Unicode";

Xcb :: #import "Xcb";
Xkb :: #import "Xkb";

#scope_module

WindowImpl :: struct {
    xcbId : u32;
    xcbConnection : *Xcb.Connection;
    xcbScreen : *Xcb.Screen;
    xcbProtocolsReply : *Xcb.InternAtomReply;
    xcbDeleteWindowReply : *Xcb.InternAtomReply;

    xkbContext : *Xkb.Context;
    xkbKeymap : *Xkb.Keymap;
    xkbState : *Xkb.State;
    xkbComposeTable : *Xkb.ComposeTable;
    xkbComposeState : *Xkb.ComposeState;

    // To prevent big deltas when moving the mouse the first time.
    needsMousePositionReset : bool;
}

impl_window_init :: (window : *Window) -> bool {
    if !setup_xcb(window) then return false;
    if !setup_xkb(window) then return false;

    // Creating window indeed
    window.xcbId = Xcb.generate_id(window.xcbConnection);
    window.needsMousePositionReset = true;

    valueMask := cast(u32) (Xcb.Cw.BackPixel | Xcb.Cw.EventMask);
    valueList : [8]u32;
    valueList[0] = window.xcbScreen.blackPixel;
    valueList[1] = cast(u32) (Xcb.EventMask.PointerMotion |
                              Xcb.EventMask.KeyPress | Xcb.EventMask.KeyRelease |
                              Xcb.EventMask.StructureNotify);

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

impl_window_cleanup :: (window : *Window) {
    Xkb.state_unref(window.xkbState);
    Xkb.keymap_unref(window.xkbKeymap);
    Xkb.context_unref(window.xkbContext);

    // Using default_allocator because these were allocated
    // in C code, so we don't want to call any other allocators.
    context.default_allocator(Allocator_Mode.FREE, 0, 0, window.xcbProtocolsReply, null);
    context.default_allocator(Allocator_Mode.FREE, 0, 0, window.xcbDeleteWindowReply, null);

    // Reset memory
    (<<window) = Window.{};
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
        context.default_allocator(Allocator_Mode.FREE, 0, 0, event, null);
    }

    // if (m_mouseKeptCentered && !m_mouseCurrentlyCentered) {
    //     mouseMoveIgnored(true);
    //     xcb_warp_pointer(m_connection, XCB_NONE, m_window, 0, 0, 0, 0,
    //                      m_extent.width / 2, m_extent.height / 2);
    //     mouseMoveIgnored(false);

    //     m_mouseCurrentlyCentered = true;
    //     m_mousePositionToReset = true; // Won't emit delta for the centering
    // }
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
        event.kind = Event.Kind.WindowClosed;
        Basic.array_add(*window.events, event);

    case Xcb.CONFIGURE_NOTIFY;
        configureNotifyEvent := cast(*Xcb.ConfigureNotifyEvent) xcbEvent;
        if window.videoMode.width == configureNotifyEvent.width &&
           window.videoMode.height == configureNotifyEvent.height {
           return;
        }

        event : Event;
        event.kind = Event.Kind.WindowSizeChanged;
        event.windowSize.width = configureNotifyEvent.width;
        event.windowSize.height = configureNotifyEvent.height;
        Basic.array_add(*window.events, event);

        window.videoMode.width = configureNotifyEvent.width;
        window.videoMode.height = configureNotifyEvent.height;

    case Xcb.MOTION_NOTIFY;
        motionNotifyEvent := cast(*Xcb.MotionNotifyEvent) xcbEvent;

        event : Event;
        event.kind = Event.Kind.MousePointerMoved;

        event.mousePointer.x = motionNotifyEvent.eventX;
        event.mousePointer.y = motionNotifyEvent.eventY;
        event.mousePointer.dx = event.mousePointer.x - cast(s16) window.mousePosition.x;
        event.mousePointer.dy = event.mousePointer.y - cast(s16) window.mousePosition.y;


        if (window.needsMousePositionReset) {
            window.mousePosition.x = motionNotifyEvent.eventX;
            window.mousePosition.y = motionNotifyEvent.eventY;
            event.mousePointer.dx = 0;
            event.mousePointer.dy = 0;
            window.needsMousePositionReset = false;
        } else {
            window.mousePosition.x = event.mousePointer.x;
            window.mousePosition.y = event.mousePointer.y;
            // m_mouseCurrentlyCentered = false;
        }

        Basic.array_add(*window.events, event);

    case Xcb.KEY_PRESS;
        keyPressEvent := cast(*Xcb.KeyPressEvent) xcbEvent;

        keycode := keyPressEvent.detail;
        Xkb.state_update_key(window.xkbState, keycode, Xkb.KeyDirection.KeyDown);
        keysym := Xkb.state_key_get_one_sym(window.xkbState, keycode);

        event : Event;
        event.kind = Event.Kind.KeyPressed;
        event. key.which = _keysym_to_key(keysym);
        Basic.array_add(*window.events, event);

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
            event.kind = Event.Kind.TextEntered;
            Basic.write_relative_pointer(u8, *event.text.str.data, *event.text.utf8);
            event.text.str.count = cast(s8) utf8ByteCount; // @fixme Why count changes type? Is this a compiler issue?
            event.text.utf8 = utf8;
            event.text.utf32 = utf32;
            Basic.array_add(*window.events, event);
        }

    case Xcb.KEY_RELEASE;
        keyReleaseEvent := cast(*Xcb.KeyReleaseEvent) xcbEvent;

        keycode := keyReleaseEvent.detail;
        Xkb.state_update_key(window.xkbState, keycode, Xkb.KeyDirection.KeyUp);
        keysym := Xkb.state_key_get_one_sym(window.xkbState, keycode);

        event : Event;
        event.kind = Event.Kind.KeyReleased;
        event. key.which = _keysym_to_key(keysym);
        Basic.array_add(*window.events, event);
    }
}

_keysym_to_key :: (keysym : Xkb.Keysym) -> Key {
    if keysym == {
    case Xkb.KEY_a; #through; case Xkb.KEY_A; return Key.A;
    case Xkb.KEY_b; #through; case Xkb.KEY_B; return Key.B;
    case Xkb.KEY_c; #through; case Xkb.KEY_C; return Key.C;
    case Xkb.KEY_d; #through; case Xkb.KEY_D; return Key.D;
    case Xkb.KEY_e; #through; case Xkb.KEY_E; return Key.E;
    case Xkb.KEY_f; #through; case Xkb.KEY_F; return Key.F;
    case Xkb.KEY_g; #through; case Xkb.KEY_G; return Key.G;
    case Xkb.KEY_h; #through; case Xkb.KEY_H; return Key.H;
    case Xkb.KEY_i; #through; case Xkb.KEY_I; return Key.I;
    case Xkb.KEY_j; #through; case Xkb.KEY_J; return Key.J;
    case Xkb.KEY_k; #through; case Xkb.KEY_K; return Key.K;
    case Xkb.KEY_l; #through; case Xkb.KEY_L; return Key.L;
    case Xkb.KEY_m; #through; case Xkb.KEY_M; return Key.M;
    case Xkb.KEY_n; #through; case Xkb.KEY_N; return Key.N;
    case Xkb.KEY_o; #through; case Xkb.KEY_O; return Key.O;
    case Xkb.KEY_p; #through; case Xkb.KEY_P; return Key.P;
    case Xkb.KEY_q; #through; case Xkb.KEY_Q; return Key.Q;
    case Xkb.KEY_r; #through; case Xkb.KEY_R; return Key.R;
    case Xkb.KEY_s; #through; case Xkb.KEY_S; return Key.S;
    case Xkb.KEY_t; #through; case Xkb.KEY_T; return Key.T;
    case Xkb.KEY_u; #through; case Xkb.KEY_U; return Key.U;
    case Xkb.KEY_v; #through; case Xkb.KEY_V; return Key.V;
    case Xkb.KEY_w; #through; case Xkb.KEY_W; return Key.W;
    case Xkb.KEY_x; #through; case Xkb.KEY_X; return Key.X;
    case Xkb.KEY_y; #through; case Xkb.KEY_Y; return Key.Y;
    case Xkb.KEY_z; #through; case Xkb.KEY_Z; return Key.Z;
    case Xkb.KEY_BackSpace; return Key.Backspace;
    case Xkb.KEY_Tab; return Key.Tab;
    case Xkb.KEY_Escape; return Key.Escape;
    case Xkb.KEY_F1; return Key.F1;
    case Xkb.KEY_F2; return Key.F2;
    case Xkb.KEY_F3; return Key.F3;
    case Xkb.KEY_F4; return Key.F4;
    case Xkb.KEY_F5; return Key.F5;
    case Xkb.KEY_F6; return Key.F6;
    case Xkb.KEY_F7; return Key.F7;
    case Xkb.KEY_F8; return Key.F8;
    case Xkb.KEY_F9; return Key.F9;
    case Xkb.KEY_F10; return Key.F10;
    case Xkb.KEY_F11; return Key.F11;
    case Xkb.KEY_F12; return Key.F12;
    case Xkb.KEY_Left; return Key.Left;
    case Xkb.KEY_Up; return Key.Up;
    case Xkb.KEY_Right; return Key.Right;
    case Xkb.KEY_Down; return Key.Down;
    case Xkb.KEY_Shift_L; return Key.ShiftLeft;
    case Xkb.KEY_Shift_R; return Key.ShiftRight;
    case Xkb.KEY_Control_L; return Key.ControlLeft;
    case Xkb.KEY_Control_R; return Key.ControlRight;
    case Xkb.KEY_Alt_L; return Key.AltLeft;
    case Xkb.KEY_Alt_R; return Key.AltRight;
    case Xkb.KEY_Delete; return Key.Delete;
    }

    return Key.Unknown;
}
