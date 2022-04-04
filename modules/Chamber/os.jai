os_user_path :: () -> string {
    path : string;

    // Show home if possible.
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        posixPath := POSIX.getenv("HOME");
        if posixPath == null then path = "/";
        else path = Basic.to_string(posixPath);
    } else #if OS == .WINDOWS {
        // @todo Probably getenv("HOMEDRIVE")/getenv("HOMEPATH");
        #run Basic.assert(false);
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
        // @todo Probably getenv("APPDATA")
        #run Basic.assert(false);
    } else {
        #run Basic.assert(false);
    }

    return path;
}
