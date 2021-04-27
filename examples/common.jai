Basic :: #import "Basic";
Compiler :: #import "Compiler";
File :: #import "File";
String :: #import "String";

make_example_workspace :: (exampleName : string) {
    Basic.set_working_directory(#filepath);
    File.make_directory_if_it_does_not_exist("./bin");

    workspace := Compiler.compiler_create_workspace();

    options := Compiler.get_build_options();
    options.output_executable_name  = exampleName;
    options.output_path             = String.concatenate(#filepath, "/bin/");
    options.optimization_level      = .DEBUG;

    import_path: [..] string;
    Basic.array_add(*import_path, "../bindings");
    Basic.array_add(*import_path, "../modules");
    Basic.array_add(*import_path, ..options.import_path);
    options.import_path = import_path;

    // Building our main program
    Compiler.set_build_options(options, workspace);
    Compiler.add_build_file(String.concatenate(exampleName, "/main.jai"), workspace);

    // Do not generate executable for this build program
    {
        options := Compiler.get_build_options();
        options.output_type = .NO_OUTPUT;
        Compiler.set_build_options(options);
    }
}
