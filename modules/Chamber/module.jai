#load "glb-parser.jai";
#load "json.jai";
#load "lib-extensions.jai";
#load "linear-algebra.jai";
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

loggerData : struct {
    indentationLevel : u32;
    padding : u32;
    nonFatalOnErrorLocks : u32;
    ourPath : File_Utilities.Path;
    oldLogger : type_of(Context_Base.logger);
    oldLoggerData : *void;
};

init_logger :: () {
    {
        push_allocator(temp);
        loggerData.ourPath = File_Utilities.parse_path(#run Basic.tprint(#filepath, "/.."));
    }

    loggerData.oldLogger = context.logger;
    loggerData.oldLoggerData = context.logger_data;
    loggerData.ourPath = File_Utilities.copy_to_permanent(loggerData.ourPath);
    context.logger = logger;
    context.logger_data = *loggerData;
}

cleanup_logger :: () {
    File_Utilities.free_permanent(loggerData.ourPath);
    context.logger = loggerData.oldLogger;
    context.logger_data = loggerData.oldLoggerData;
}

logger :: (message : string, data : *void, info : Log_Info) {
    push_allocator(temp);

    needFileAndLine := (info.common_flags & .WARNING) || (info.common_flags & .ERROR);

    if ((context.log_level < .VERY_VERBOSE) && (info.common_flags & .VERY_VERBOSE_ONLY)) ||
       ((context.log_level < .VERBOSE) && (info.common_flags & .VERBOSE_ONLY)) {
        return;
    }

    // @note Here we cut down path.words which has been
    // allocated on a temporary storage by removing all
    // parts that have the same prefix than us.
    file := info.location.fully_pathed_filename;
    path := File_Utilities.parse_path(file);
    originalPathWords : []string = path.words;
    if file.count != 0 {
        for word, wordIndex : loggerData.ourPath.words {
            if word == path.words[0] {
                path.words.data += 1;
                path.words.count -= 1;
            } else {
                break;
            }
        }

        Basic.peek_pointer(path.words).count -= 4; // Remove ".jai".
        path.number_of_leading_slashes = 0;
    }

    name := File_Utilities.path_to_string(path);

    if needFileAndLine {
        name = Basic.tprint("%.jai:%", name, info.location.line_number);
    }

    padding := "                                        ";
    if name.count > loggerData.padding {
        loggerData.padding = cast(u32) name.count;
        padding.count = 0;
    } else {
        padding.count = loggerData.padding - name.count;
    }

    if info.common_flags & .VERY_VERBOSE_ONLY {
        Basic.print("(%) %", name, padding);
    } else if info.common_flags & .VERBOSE_ONLY {
        Basic.print("\e[1m(%)\e[0m %", name, padding);
    } else {
        Basic.print("\e[1m[%]\e[0m %", name, padding);
    }

    // @note Print_Color module is incomplete, missing colors.
    if info.common_flags & .WARNING {
        Basic.print("\e[0;33m/!\\ %\e[0;m\n", message);
    } else if info.common_flags & .ERROR {
        Basic.print("\e[0;31m/!\\ %\e[0;m\n", message);
    } else if (info.common_flags & .VERBOSE_ONLY) || (info.common_flags & .VERY_VERBOSE_ONLY) {
        Basic.print("\e[0;90m%\e[0;m\n", message);
    } else if info.common_flags & .CONTENT {
        Basic.print("\e[0;36m%\e[0;m\n", message);
    } else {
        Basic.print("%\n", message);
    }

    if (info.common_flags & .ERROR) &&
       (loggerData.nonFatalOnErrorLocks == 0) {
        Basic.assert(false, loc=info.location);
    }
}

loggerPushNonFatalOnError :: () {
    loggerData.nonFatalOnErrorLocks += 1;
}

loggerPopNonFatalOnError :: () {
    loggerData.nonFatalOnErrorLocks -= 1;
}

min :: (a : $T, b : T) -> T #expand {
    return ifx a <= b then a else b;
}

max :: (a : $T, b : T) -> T #expand {
    return ifx a >= b then a else b;
}

mix :: (from : $T, to : T, factor : float32) -> T {
    return from * (1 - factor) + to * factor;
}

align_up :: (value : u32, alignment : u32) -> u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

debug :: (args : ..Any, loc := #caller_location) {
    format := "%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+%+";
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

#scope_file

String :: #import "String";
File_Utilities :: #import "File_Utilities";
