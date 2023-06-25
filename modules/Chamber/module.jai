#load "linear-algebra/mat.jai";
#load "linear-algebra/quat.jai";
#load "linear-algebra/ray.jai";
#load "linear-algebra/vec.jai";
#load "file-formats/bos.jai";
#load "file-formats/glb.jai";
#load "file-formats/json.jai";
#load "file-formats/spirv.jai";
#load "lib-extensions.jai";
#load "download.jai";
#load "logger.jai";
#load "os.jai";
#load "string-utilities.jai";
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

Anchor :: enum {
    Center :: 0;
    Top; Bottom;
    Left; Right;
    TopLeft; TopRight;
    BottomLeft; BottomRight;
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

copy_files_recursively :: (source : string, dest : string) {
    Basic.push_allocator(Basic.temp);

    Paths :: struct { source : string; dest : string; };
    paths : Paths;
    paths.source = source;
    paths.dest = dest;

    visitor :: (info : *FileUtilities.File_Visit_Info, paths : Paths) {
        relativePath := info.full_name;
        Basic.advance(*relativePath, paths.source.count);
        outPath := String.join(paths.dest, PATH_SEPARATOR, relativePath);
        File.make_directory_if_it_does_not_exist(String.path_strip_filename(outPath));
        FileUtilities.copy_file(info.full_name, outPath);
    }

    FileUtilities.visit_files(paths.source, true, paths, visitor);
}

BUILD_IS_DEBUG :: #run Compiler.get_build_options().array_bounds_check;

debug :: (args : ..Any, loc := #caller_location) {
    format := "%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0%0";
    if args.count == 0 || 2 * args.count > format.count then return;

    format.count = 2 * args.count;

    default_format_struct := *context.print_style.default_format_struct;
    default_format_struct.use_newlines_if_long_form = true;
    default_format_struct.indentation_width = 2;
    Basic.log(format, ..args, loc=loc, flags=.CONTENT);
}

_CHECK :: (result : $R, returnedValue : $T, message : string, args : ..Any, fatal := true, loc := #caller_location) #expand
#modify {
    return T != string; // To avoid ambuiguity with the other _CHECK below.
}
 {
    if !fatal then loggerPushNonFatalOnError();

    #if type_of(result) == bool {
        if !result {
            // @note Don't use message directly, as it can have % in its content,
            // raising an error because there are no formatted arguments.
            Basic.log(message, ..args, loc=loc, flags=.ERROR);
            if !fatal then loggerPopNonFatalOnError();
            `return returnedValue;
        }
    } else {
        if result != .Success {
            Basic.log("Result: %", result, loc=loc, flags=.WARNING);
            Basic.log(message, ..args, loc=loc, flags=.ERROR);
            if !fatal then loggerPopNonFatalOnError();
            `return returnedValue;
        }
    }
}

_CHECK :: (result : $R, message : string, args : ..Any, loc := #caller_location) #expand {
    _CHECK(result, false, message, ..args, loc=loc);
}

_CHECK_NON_FATAL :: (result : $R, message : string, args : ..Any, loc := #caller_location) #expand {
    _CHECK(result, false, message, ..args, fatal=false, loc=loc);
}

#scope_module

Basic :: #import "Basic";
File :: #import "File";
FileUtilities :: #import "File_Utilities";
Hash :: #import "Hash_Table";
Math :: #import "Math";
String :: #import "String";
Compiler :: #import "Compiler";
