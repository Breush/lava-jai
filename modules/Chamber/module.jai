Basic :: #import "Basic";

#load "glb-parser.jai";
#load "json.jai";
#load "lib-extensions.jai";
#load "linear-algebra.jai";
#load "spirv-parser.jai";

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

_CHECK :: (result : $R, returnedValue : $T, message : string) #expand {
    #if type_of(result) == bool {
        if !result {
            // @todo Use official context logger.
            debug(message, "\n");
            `return returnedValue;
        }
    } else {
        if result != .Success {
            debug(message, " (", result, ")\n");
            `return returnedValue;
        }
    }
}

_CHECK :: (result : $R, message : string) #expand {
    _CHECK(result, false, message);
}
