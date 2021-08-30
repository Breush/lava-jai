Basic :: #import "Basic";
Compiler :: #import "Compiler";
File :: #import "File";
String :: #import "String";

#load "../modules/Sill/meta.jai";

make_example_workspace :: (exampleName : string) {
    Basic.set_working_directory(#filepath);
    File.make_directory_if_it_does_not_exist("./bin");

    workspace := Compiler.compiler_create_workspace();

    options := Compiler.get_build_options();
    options.output_executable_name  = exampleName;
    options.output_path             = String.join(#filepath, "/bin/");
    options.optimization_level      = .DEBUG;

    import_path: [..] string;
    Basic.array_add(*import_path, "../bindings");
    Basic.array_add(*import_path, "../modules");
    Basic.array_add(*import_path, ..options.import_path);
    options.import_path = import_path;

    // Building our main program
    Compiler.set_build_options(options, workspace);

    Compiler.compiler_begin_intercept(workspace);
    Compiler.add_build_file(String.join(exampleName, "/main.jai"), workspace);

    while true {
        message := Compiler.compiler_wait_for_message();
        if !message break;
        if message.workspace != workspace continue;

        sill_meta_handle_message(message);

        if message.kind == .COMPLETE {
            break;
        }
    }
    Compiler.compiler_end_intercept(workspace);

    // Do not generate executable for this build program
    {
        options := Compiler.get_build_options();
        options.output_type = .NO_OUTPUT;
        Compiler.set_build_options(options);
    }
}
