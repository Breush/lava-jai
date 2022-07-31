#load "linear-algebra/mat.jai";
#load "linear-algebra/quat.jai";
#load "linear-algebra/ray.jai";
#load "linear-algebra/vec.jai";
#load "glb-parser.jai";
#load "json.jai";
#load "lib-extensions.jai";
#load "logger.jai";
#load "os.jai";
#load "string-utilities.jai";
#load "spirv.jai";
#load "font.jai";

WindowHandle :: struct {
    union {
        xcb : struct {
            connection : *void; // *xcb_connection_t
            window : u32 ;      // xcb_window_t
        }
        dwm : struct {
            hWnd : *void;
            hInstance : *void;
        }
    }
}

Sphere :: struct {
    center : vec3;
    radius : float;
}

AxisAlignedBox :: struct {
    center : vec3;
    extent : vec3;
}

min :: (a : $T, b : T) -> T #expand {
    return ifx a <= b then a else b;
}

max :: (a : $T, b : T) -> T #expand {
    return ifx a >= b then a else b;
}

to_radians :: (degrees : float32) -> float32 {
    return degrees * #run cast(float32) (PI / 180.);
}

mix :: (from : $T, to : T, factor : float32) -> T {
    return from * (1 - factor) + to * factor;
}

align_up :: (value : u32, alignment : u32) -> u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

debug :: (args : ..Any, loc := #caller_location) {
    format := "%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0";
    if args.count == 0 || 2 * args.count > format.count then return;

    format.count = 2 * args.count;

    default_format_struct := *context.print_style.default_format_struct;
    default_format_struct.use_newlines_if_long_form = true;
    default_format_struct.indentation_width = 2;
    Basic.log(format, ..args, loc=loc, flags=.CONTENT);
}

_CHECK :: (result : $R, returnedValue : $T, message : string, fatal := true, loc := #caller_location) #expand {
    if !fatal then loggerPushNonFatalOnError();

    #if type_of(result) == bool {
        if !result {
            // @note Don't use message directly, as it can have % in its content,
            // raising an error because there are no formatted arguments.
            Basic.log("%", message, loc=loc, flags=.ERROR);
            if !fatal then loggerPopNonFatalOnError();
            `return returnedValue;
        }
    } else {
        if result != .Success {
            Basic.log("% (%)", message, result, loc=loc, flags=.ERROR);
            if !fatal then loggerPopNonFatalOnError();
            `return returnedValue;
        }
    }
}

_CHECK :: (result : $R, message : string, loc := #caller_location) #expand {
    _CHECK(result, false, message, loc=loc);
}

_CHECK_NON_FATAL :: (result : $R, message : string, loc := #caller_location) #expand {
    _CHECK(result, false, message, fatal=false, loc=loc);
}

#scope_module

Basic :: #import "Basic";
File_Utilities :: #import "File_Utilities";
Math :: #import "Math";
String :: #import "String";
