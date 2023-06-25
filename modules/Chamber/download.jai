download :: (url : string, target : string) -> bool {
    curl := curl_easy_init();
    if !curl {
        log_error("An error occured while initting up the Curl connection, but Curl doesn't tell us why.\n");
        return false;
    }
    defer curl_easy_cleanup(curl);

    // Set target URL
    curl_easy_setopt(curl, .URL, temp_c_string(url));
    file, ok := file_open(target, for_writing=true);
    if !ok {
        log_error("Failed to open the output file '%' for storing the download.\n", target);
        return false;
    }
    defer file_close(*file);

    downloadData := DownloadData.{*context, curl, *file};
    debug(downloadData);
    curl_easy_setopt(curl, .WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, .WRITEDATA, *downloadData);

    // Perform the "easy" action
    log("Downloading %...\n", target);
    error_code := curl_easy_perform(curl);

    contentLength : curl_off_t;
    curl_easy_getinfo(curl, .CONTENT_LENGTH_DOWNLOAD_T, *contentLength);
    debug(contentLength);

    if error_code != .OK {
        error_message := to_string(curl_easy_strerror(error_code));
        log_error("Curl Error: %\n", error_message);
        return false;
    }
    print_curl_stats(curl);
    return true;
}

#scope_file

DownloadData :: struct {
    ctx : *Context;
    curl : *CURL;
    file : *File.File;
}

// Curl expects a C function, that's why we have to use #c_call, and since #c_call doesn't provide a context and JAI function need it, we push_context
write_callback :: (contents : *u8, count : u64, size : u64, downloadData : *DownloadData) -> u64 #c_call {
    totalSize := count * size;
    push_context downloadData.ctx.* {
        file_write(downloadData.file, contents, cast(s64) totalSize);
        // print_curl_stats(downloadData.curl);
    }
    return totalSize;
}

print_curl_stats :: (curl : *CURL) {
    // Fetch and print stats
    totalTimeMs      : curl_off_t;
    downloadSpeed  : curl_off_t;
    sizeDownloaded : curl_off_t;

    curl_easy_getinfo(curl, .TOTAL_TIME_T,     *totalTimeMs);
    curl_easy_getinfo(curl, .SPEED_DOWNLOAD_T, *downloadSpeed);
    curl_easy_getinfo(curl, .SIZE_DOWNLOAD_T,  *sizeDownloaded);

    log("Time: %µs, Speed: %MB/s, Downloaded: %MB\n", totalTimeMs, downloadSpeed / 1024.0 / 1024.0, sizeDownloaded / 1024.0 / 1024.0);
}

#import "Curl";
