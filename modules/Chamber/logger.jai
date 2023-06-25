loggerData : struct {
    indentationLevel : u32;
    padding : u32;
    nonFatalOnErrorLocks : u32;
    ourPath : FileUtilities.Path;
    oldLogger : type_of(Context_Base.logger);
    oldLoggerData : *void;
};

init_logger :: () {
    {
        push_allocator(temp);
        loggerData.ourPath = FileUtilities.parse_path(#run Basic.tprint(#filepath, "/.."));
    }

    loggerData.oldLogger = context.logger;
    loggerData.oldLoggerData = context.logger_data;
    loggerData.ourPath = FileUtilities.copy_to_permanent(loggerData.ourPath);
    context.logger = logger;
    context.logger_data = *loggerData;
}

cleanup_logger :: () {
    FileUtilities.free_permanent(loggerData.ourPath);
    context.logger = loggerData.oldLogger;
    context.logger_data = loggerData.oldLoggerData;
}

logger :: (inMessage : string, data : *void, info : Log_Info) {
    needFileAndLine := (info.common_flags & .WARNING) || (info.common_flags & .ERROR);

    if ((context.log_level < .VERY_VERBOSE) && (info.common_flags & .VERY_VERBOSE_ONLY)) ||
       ((context.log_level < .VERBOSE) && (info.common_flags & .VERBOSE_ONLY)) {
        return;
    }

    message := String.trim_right(inMessage);

    push_allocator(Basic.temp);

    // @note Here we cut down path.words which has been
    // allocated on a temporary storage by removing all
    // parts that have the same prefix than us.
    file := info.location.fully_pathed_filename;
    path := FileUtilities.parse_path(file);
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

    name := FileUtilities.path_to_string(path);

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
