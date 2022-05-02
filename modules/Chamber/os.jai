#if OS == .LINUX {
    PATH_SEPARATOR :: "/";
} else #if OS == .WINDOWS {
    PATH_SEPARATOR :: "\\";
} else {
    PATH_SEPARATOR :: #run Basic.assert(false);
}

os_user_path :: () -> string {
    path : string;

    // Show home if possible.
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        posixPath := POSIX.getenv("HOME");
        if posixPath == null then path = "/";
        else path =  Basic.sprint("%/", Basic.to_string(posixPath));
    } else #if OS == .WINDOWS {
        Windows :: #import "Windows";
        windowsPath := Windows.getenv("HOMEPATH");
        if windowsPath == null then path = "C:\\"; // @todo Should probably list drives.
        else path =  Basic.sprint("%\\", Basic.to_string(windowsPath));
    } else {
        #run Basic.assert(false);
    }

    return path;
}

os_application_data_storage_path :: () -> string {
    path : string;

    #if OS == .LINUX {
        path = os_user_path();
    } else #if OS == .WINDOWS {
        Windows :: #import "Windows";
        windowsPath := Windows.getenv("APPDATA");
        if windowsPath != null then path =  Basic.sprint("%\\", Basic.to_string(windowsPath));
        else path = os_user_path();
    } else {
        #run Basic.assert(false);
    }

    return path;
}