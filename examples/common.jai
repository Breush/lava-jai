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
        if !message continue;
        if message.workspace != workspace continue;

        if message.kind == .TYPECHECKED then {
            code := cast(*Compiler.Message_Typechecked) message;

            for decl : code.declarations {
                fromLocalModule := false;
                if decl.location.enclosing_load {
                    if decl.location.enclosing_load.enclosing_import.module_type == .FILE {
                        // Fast check that the pathed filename starts with ../modules/
                        fromLocalModule = decl.location.enclosing_load.enclosing_import.fully_pathed_filename[0] == #char ".";
                        fromLocalModule = fromLocalModule && decl.location.enclosing_load.enclosing_import.fully_pathed_filename[3] == #char "m";
                    }
                }

                if !fromLocalModule continue;

                rootExpr := decl.root_expression;
                if rootExpr != null && rootExpr.kind == .PROCEDURE_BODY {
                    procedureBody := cast(*Compiler.Code_Procedure_Body) rootExpr;

                    walk_code_node(procedureBody.block);
                }
            }
            continue;
        }

        if message.kind == .COMPLETE then {
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

// @todo Incomplete walker so far, but should catch most usage.
walk_code_node :: (codeNode : *Compiler.Code_Node) {
    if codeNode.kind == {
    case .BLOCK;
        for statement : (cast(*Compiler.Code_Block) codeNode).statements {
            walk_code_node(statement);
        }
    case .PROCEDURE_CALL;
        for argument : (cast(*Compiler.Code_Procedure_Call) codeNode).arguments_unsorted {
            walk_code_node(argument.expression);
        }
    case .UNARY_OPERATOR;
        check_unary_operator(cast(*Compiler.Code_Unary_Operator) codeNode);
        walk_code_node((cast(*Compiler.Code_Unary_Operator) codeNode).subexpression);
    case .BINARY_OPERATOR;
        walk_code_node((cast(*Compiler.Code_Binary_Operator) codeNode).left);
        walk_code_node((cast(*Compiler.Code_Binary_Operator) codeNode).right);
    }
}

check_unary_operator :: (unaryOperator : *Compiler.Code_Unary_Operator) {
    // Taking pointer from a "big" procedure argument, flag!
    // This is dangerous because arguments are supposed to be immutable.
    // @note This could become a native error in the compiler later, be sure to have this cleaned up if so.
    if unaryOperator.operator_type == #char "*" &&
       unaryOperator.subexpression.kind == .IDENT {
        ident := cast(*Compiler.Code_Ident) unaryOperator.subexpression;
        if ident.resolved_declaration.type.runtime_size > 8 &&
           ident.resolved_declaration.flags & .IS_PROCEDURE_ARGUMENT {
            Compiler.compiler_report(Compiler.get_filename(unaryOperator), cast(s64) unaryOperator.location.l0, cast(s64) unaryOperator.location.c0,
                                     "[LAVA_CHECKER] Taking pointer to a big immutable argument.");
        }
    }
}
