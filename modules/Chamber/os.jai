#if OS == .LINUX {
    PATH_SEPARATOR :: "/";
    STRATEGIES :: string.["xdg-open", "sensible-browser", "x-www-browser"];
} else #if OS == .WINDOWS {
    PATH_SEPARATOR :: "\\";
    STRATEGIES :: string.["start"];
} else {
    PATH_SEPARATOR :: #run Basic.assert(false);
    STRATEGIES := string.["open"];
}

os_user_path :: (allocator := context.allocator) -> string {
    Basic.push_allocator(allocator);

    path : string;

    // Show home if possible.
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        posixPath := POSIX.getenv("HOME");
        if posixPath == null then path = "/";
        else path =  Basic.sprint("%/", to_string(posixPath));
    } else #if OS == .WINDOWS {
        Windows :: #import "Windows";
        windowsPath := Windows.getenv("HOMEPATH");
        if windowsPath == null then path = "C:\\"; // @todo Should probably list drives.
        else path =  Basic.sprint("%\\", to_string(windowsPath));
    } else {
        #run Basic.assert(false);
    }

    return path;
}

os_application_data_storage_path :: (allocator := context.allocator) -> string {
    Basic.push_allocator(allocator);

    path : string;

    #if OS == .LINUX {
        path = os_user_path();
    } else #if OS == .WINDOWS {
        Windows :: #import "Windows";
        windowsPath := Windows.getenv("APPDATA");
        if windowsPath != null then path =  Basic.sprint("%\\", to_string(windowsPath));
        else path = os_user_path();
    } else {
        #run Basic.assert(false);
    }

    return path;
}

os_open_browser :: (url : string) -> (ok : bool) {
    for strategy : STRATEGIES {
        processResult := Process.run_command(strategy, url, capture_and_return_output = true);
        if processResult.exit_code == 0 then return true;
    }

    return false;
}

os_open_file_explorer :: (path : string) -> (ok : bool) {
    for strategy : STRATEGIES {
        processResult := Process.run_command(strategy, path, capture_and_return_output = true);
        if processResult.exit_code == 0 then return true;
    }

    return false;
}

os_get_environment_variable :: (name : string) -> (value : string) {
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        return to_string(POSIX.getenv(name.data));
    } else #if OS == .WINDOWS {
        Windows :: #import "Windows";
        return to_string(Windows.getenv(name.data));
    } else {
        #run Basic.assert(false);
    }

    return "";
}

os_set_environment_variable :: (name : string, value : string) {
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        POSIX.setenv(name.data, value.data, 1);
    } else #if OS == .WINDOWS {
        // @note As of 2023/10, no setenv nor SetEnvironmentVariable in jai modules.
        Crt :: #system_library "msvcrt";
        setenv :: (name : *u8, value : *u8, overwrite : s32)  -> *u8 #foreign Crt;
        setenv(name.data, value.data, 1);
    } else {
        #run Basic.assert(false);
    }
}

#scope_file

Process :: #import "Process";
