WindowImpl :: struct {
    hInstance : Windows.HINSTANCE;
    hWnd : Windows.HWND;
}

// @note Somehow the types and functions below are not defined in shipped module Windows.jai
user32      :: #foreign_system_library "user32";
LONG_PTR :: s64;
SetWindowLongPtrW :: (hwnd : Windows.HWND, nIndex : s32, dwNewLong : LONG_PTR) -> s32 #foreign user32;
GetWindowLongPtrW :: (hwnd : Windows.HWND, nIndex : s32) -> LONG_PTR #foreign user32;
SetCursorPos :: (x : s64, y : s64) #foreign user32;
CloseWindow :: (hwnd : Windows.HWND) #foreign user32;

wndClassRegistered : bool;

impl_window_init :: (window : *Window) -> bool {
    window.hInstance =  Windows.GetModuleHandleW(null);
    className := WindowsUtf8.utf8_to_wide("lava.crater.window");

    if !wndClassRegistered {
        wndClass : Windows.WNDCLASSEXW;
        wndClass.cbSize = size_of(Windows.WNDCLASSEXW);
        wndClass.style = Windows.CS_HREDRAW | Windows.CS_VREDRAW | Windows.CS_OWNDC;
        wndClass.lpfnWndProc = xx _on_message;
        wndClass.hInstance = window.hInstance;
        wndClass.lpszClassName = className;
        _CHECK(Windows.RegisterClassExW(*wndClass) != 0, "Unable to register DWM window class.");

        wndClassRegistered = true;
    }

    // @note Window size specifided in CreateWindowExW takes the decorations into account.
    // To get the effective client area we do the thing below.
    rect : Windows.RECT;
    rect.right  = window.videoMode.width;
    rect.bottom = window.videoMode.height;
    Windows.AdjustWindowRect(*rect, Windows.WS_OVERLAPPEDWINDOW, Windows.BOOL.FALSE);

    window.hWnd = Windows.CreateWindowExW(0, className, WindowsUtf8.utf8_to_wide(window.title),
                                          Windows.WS_OVERLAPPEDWINDOW,
                                          Windows.CW_USEDEFAULT, Windows.CW_USEDEFAULT,
                                          (rect.right - rect.left), (rect.bottom - rect.top),
                                          null, null,
                                          window.hInstance, null);

    _CHECK(window.hWnd != null, Basic.tprint("Unable to create window handle: %.", Windows.GetLastError()));

    SetWindowLongPtrW(window.hWnd, Windows.GWL_USERDATA, cast(LONG_PTR) window);

    Windows.UpdateWindow(window.hWnd);
    Windows.ShowWindow(window.hWnd, Windows.SW_SHOW);

    return true;
}

impl_window_process_events :: (window : *Window) {
    msg : Windows.MSG;
    while Windows.PeekMessageW(*msg, window.hWnd, 0, 0, Windows.PM_REMOVE) > 0 {
        Windows.TranslateMessage(*msg);
        Windows.DispatchMessageW(*msg);
    }
}

impl_window_close :: (window : *Window) {
    CloseWindow(window.hWnd);
}

impl_window_get_handle :: (window : *Window) -> Chamber.WindowHandle {
    handle : Chamber.WindowHandle;
    handle.dwm.hInstance = window.hInstance;
    handle.dwm.hWnd = window.hWnd;
    return handle;
}

impl_window_center_pointer :: (window : *Window) {
    point : Windows.POINT;
    point.x = window.videoMode.width / 2;
    point.y = window.videoMode.height / 2;
    Windows.ClientToScreen(window.hWnd, *point);
    SetCursorPos(point.x, point.y);
}

impl_window_update_pointer_hidden :: (window : *Window) {
    Windows.ShowCursor(cast(s32) !window.pointerHidden);
}

#scope_file

_on_message :: (hWnd : Windows.HWND, msg : u32, wParam : Windows.WPARAM, lParam : Windows.LPARAM) -> s64 #c_call {
    ctx: Context;
    ctx.allocator = Context.default_allocator;
    ctx.logger    = Context.default_logger;

    push_context ctx {
        window := cast(*Window) GetWindowLongPtrW(hWnd, Windows.GWL_USERDATA);

  	    if msg == {
        case Windows.WM_CLOSE;
            event: Event;
            event.kind = .WindowClosed;
            _window_add_event(window, *event);

        case Windows.WM_SIZE;
            event : Event;
            event.kind = .WindowSizeChanged;
            event.windowSize.width = cast(u16) (lParam & 0xFFFF);
            event.windowSize.height = cast(u16) ((lParam >> 16) & 0xFFFF);
            _window_add_event(window, *event);

        case Windows.WM_KEYDOWN; #through;
        case Windows.WM_SYSKEYDOWN;
            event : Event;
            event.kind = .KeyPressed;
            event.key.which = _virtual_key_to_key(wParam);
            _window_add_event(window, *event);

        case Windows.WM_KEYUP; #through;
        case Windows.WM_SYSKEYUP;
            event : Event;
            event.kind = .KeyReleased;
            event.key.which = _virtual_key_to_key(wParam);
            _window_add_event(window, *event);

        case Windows.WM_MOUSEMOVE;
            event : Event;
            event.kind = .MousePointerMoved;
            event.mousePointer.x = cast(s16) (lParam & 0xFFFF);
            event.mousePointer.y = cast(s16) ((lParam >> 16) & 0xFFFF);
            _window_add_event(window, *event);

        case Windows.WM_LBUTTONDOWN; #through;
        case Windows.WM_MBUTTONDOWN; #through;
        case Windows.WM_RBUTTONDOWN;
            event : Event;
            event.kind = .MouseButtonPressed;
            if msg == Windows.WM_LBUTTONUP then event.mouseButton.which = .Left;
            else if msg == Windows.WM_MBUTTONUP then event.mouseButton.which = .Middle;
            else if msg == Windows.WM_RBUTTONUP then event.mouseButton.which = .Right;
            _window_add_event(window, *event);

        case Windows.WM_LBUTTONUP; #through;
        case Windows.WM_MBUTTONUP; #through;
        case Windows.WM_RBUTTONUP;
            event : Event;
            event.kind = .MouseButtonReleased;
            if msg == Windows.WM_LBUTTONUP then event.mouseButton.which = .Left;
            else if msg == Windows.WM_MBUTTONUP then event.mouseButton.which = .Middle;
            else if msg == Windows.WM_RBUTTONUP then event.mouseButton.which = .Right;
            _window_add_event(window, *event);

        case Windows.WM_MOUSEWHEEL;
            WHEEL_DELTA :: 120;

            event : Event;
            event.kind = .MouseWheelScrolled;
            event.mouseWheel.dy = cast(float) cast,trunc(s16) (wParam >> 16) / WHEEL_DELTA;
            _window_add_event(window, *event);

        case Windows.WM_CHAR;
            utf32 := cast(u32) wParam;
            if utf32 > 31 && utf32 != 127 {
                event : Event;
                event.kind = .TextEntered;
                utf8ByteCount := Chamber.utf32_to_utf8(utf32, event.text.utf8);
                event.text.utf32 = utf32;
                event.text.str.data = *event.text.utf8[0]; // Relative pointer
                event.text.str.count = utf8ByteCount;
                _window_add_event(window, *event);
            }
        }
    }

    return Windows.DefWindowProcW(hWnd, msg, wParam, lParam);
}

// Got list from https://msdn.microsoft.com/en-us/library/windows/desktop/dd375731(v=vs.85).aspx
_virtual_key_to_key :: (wParam : Windows.WPARAM) -> Key {
    if wParam == {
    case Windows.VK_SPACE; return .Space;
    case #char "A"; return .A;
    case #char "B"; return .B;
    case #char "C"; return .C;
    case #char "D"; return .D;
    case #char "E"; return .E;
    case #char "F"; return .F;
    case #char "G"; return .G;
    case #char "H"; return .H;
    case #char "I"; return .I;
    case #char "J"; return .J;
    case #char "K"; return .K;
    case #char "L"; return .L;
    case #char "M"; return .M;
    case #char "N"; return .N;
    case #char "O"; return .O;
    case #char "P"; return .P;
    case #char "Q"; return .Q;
    case #char "R"; return .R;
    case #char "S"; return .S;
    case #char "T"; return .T;
    case #char "U"; return .U;
    case #char "V"; return .V;
    case #char "W"; return .W;
    case #char "X"; return .X;
    case #char "Y"; return .Y;
    case #char "Z"; return .Z;
    case Windows.VK_BACK; return .Backspace;
    case Windows.VK_TAB; return .Tab;
    case Windows.VK_ESCAPE; return .Escape;
    case Windows.VK_F1; return .F1;
    case Windows.VK_F2; return .F2;
    case Windows.VK_F3; return .F3;
    case Windows.VK_F4; return .F4;
    case Windows.VK_F5; return .F5;
    case Windows.VK_F6; return .F6;
    case Windows.VK_F7; return .F7;
    case Windows.VK_F8; return .F8;
    case Windows.VK_F9; return .F9;
    case Windows.VK_F10; return .F10;
    case Windows.VK_F11; return .F11;
    case Windows.VK_F12; return .F12;
    case Windows.VK_LEFT; return .Left;
    case Windows.VK_UP; return .Up;
    case Windows.VK_RIGHT; return .Right;
    case Windows.VK_DOWN; return .Down;
    case Windows.VK_LSHIFT; return .ShiftLeft;
    case Windows.VK_RSHIFT; return .ShiftRight;
    case Windows.VK_LCONTROL; return .ControlLeft;
    case Windows.VK_RCONTROL; return .ControlRight;
    case Windows.VK_LMENU; return .AltLeft;
    case Windows.VK_RMENU; return .AltRight;
    case Windows.VK_DELETE; return .Delete;
    case Windows.VK_HOME; return .Home;
    case Windows.VK_END; return .End;
    }

    return .Unknown;
}

DPI :: #import "DPI";
Windows :: #import "Windows";
WindowsUtf8 :: #import "Windows_Utf8";
