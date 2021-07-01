Basic :: #import "Basic";

#load "linear-algebra.jai";

WindowHandle :: struct {
    union {
        xcb : struct {
            connection : *void; // *xcb_connection_t
            window : u32 ;      // xcb_window_t
        }
        dwm : struct {
            hwnd : *void;
            hinstance : *void;
        }
    }
}

debug :: (args: ..Any) {
    format := "%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+";
    if args.count == 0 || 2 * args.count > format.count then return;

    format.count = 2 * args.count;

    default_format_struct := *context.print_style.default_format_struct;
    default_format_struct.use_newlines_if_long_form = true;
    default_format_struct.indentation_width = 2;
    Basic.print(format, ..args);
    Basic.print("\n");
}
