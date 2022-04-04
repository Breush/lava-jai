os_application_data_storage_path :: () -> string {
    #if OS == .LINUX {
        POSIX :: #import "POSIX";
        return Basic.to_string(POSIX.getenv("HOME"));
    } else #if OS == .WINDOWS {
        #run Basic.assert(false);
        return "";
    }
}
