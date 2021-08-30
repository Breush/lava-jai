/*
 * Metaprogram to be called during compilation.
 * (Call sill_meta_handle_message.)
 *
 * Create a new struct which inherits from Entity.
 *
 * ```
 * Player :: struct {
 *     using entity : Sill.Entity;  // Provides hierarchy and transform.
 *     mesh : MeshComponent;        // Provides a way to attach a mesh to the entity.
 * }
 * ```
 *
 * Your entity kind will be usable as is, it will get a dedicated storage
 * and performant methods.
 *
 * ```
 * engine := Sill.create_engine(SillMeta);
 * player := SillMeta.create_player_entity(engine); // This function has been generated based on the name of your struct.
 * ```
 *
 * During the update of the engine, all entities will be updated automatically,
 * and all their components too.
 */

#load "helpers/string-utilities.jai";

sill_meta_handle_message :: (message : *Compiler.Message) {
    if message.kind == .TYPECHECKED {
        messageTypechecked := cast(*Compiler.Message_Typechecked) message;
        for decl : messageTypechecked.declarations {
            _check_declaration(decl.expression);
        }
    }
    else if message.kind == .PHASE {
        phase := cast(*Compiler.Message_Phase) message;
        if phase.phase == .TYPECHECKED_ALL_WE_CAN {
            _generate(message.workspace);
        }
    }
}

#scope_file

MetaEntity :: struct {
    name : string;          // "MyCustomEntity" Expected PascalCase is user source code.
    idCamelCase : string;   // "myCustom"
    idSnakeCase : string;   // "my_custom"
    components : [..]string;
}

metaEntityList : [..]MetaEntity;

META_STRING :: #string DONE
SillMeta :: struct {
%1
%2
    _update_entities :: (engine : *Sill.Engine, dt : float64) {
        // @todo Have automatic components update called. (Only if there update method exists.)
    }
}
DONE

_generated := false;

_check_declaration :: (codeDeclaration : *Compiler.Code_Declaration) {
    if codeDeclaration == null then return;
    if codeDeclaration.flags & .IS_CONSTANT == 0 then return;
    if codeDeclaration.expression.kind != .STRUCT then return;
    codeStruct := cast(*Compiler.Code_Struct) codeDeclaration.expression;

    for member : codeStruct.block.members {
        if member.kind != .DECLARATION then continue;

        // Checking the struct "inherits" from something.
        memberCodeDeclaration := cast(*Compiler.Code_Declaration) member;
        if memberCodeDeclaration.flags & .IS_MARKED_AS_USING == 0 then continue;

        // Checking if the base struct is Entity from the Sill module.
        memberCodeType := memberCodeDeclaration.type_inst.type_valued_expression;
        while memberCodeType.kind == .BINARY_OPERATOR {
            memberCodeType = (cast(*Compiler.Code_Binary_Operator) memberCodeType).right;
        }

        if memberCodeType.kind != .IDENT then continue;
        memberCodeTypeIdent := cast(*Compiler.Code_Ident) memberCodeType;

        if memberCodeTypeIdent.name == "Entity" &&
           memberCodeTypeIdent.resolved_declaration &&
           memberCodeTypeIdent.resolved_declaration.location.enclosing_load &&
           memberCodeTypeIdent.resolved_declaration.location.enclosing_load.enclosing_import &&
           memberCodeTypeIdent.resolved_declaration.location.enclosing_load.enclosing_import.module_name == "Sill" {
            _add_meta_entity(codeDeclaration.name, codeStruct.block.members);
            break;
        }
    }
}

_add_meta_entity :: (name : string, members : []*Compiler.Code_Scope_Entry) {
    Basic.array_resize(*metaEntityList, metaEntityList.count + 1);
    metaEntity := Basic.peek_pointer(metaEntityList);

    metaEntity.name = name;

    // Extracting canonical name
    nameWords := split_from_pascal_or_camel_case(name);
    defer Basic.array_free(nameWords);
    if Basic.peek(nameWords) == "Entity" {
        Basic.pop(*nameWords);
    }

    metaEntity.idSnakeCase = join_as_snake_case(nameWords);
    metaEntity.idCamelCase = join_as_camel_case(nameWords);

    for member : members {
        if member.kind != .DECLARATION then continue;

        memberCodeDeclaration := cast(*Compiler.Code_Declaration) member;
        if memberCodeDeclaration.flags & .IS_MARKED_AS_USING != 0 ||
           memberCodeDeclaration.flags & .IS_IMPORTED != 0 {
            continue;
        }

        // @todo Should probably check if it is indeed a component.
        Basic.array_add(*metaEntity.components, memberCodeDeclaration.name);
    }
}

_generate :: (workspace : s64) {
    if _generated then return;
    if metaEntityList.count == 0 then return;
    _generated = true;

    // Building Entities string
    builder : Basic.String_Builder;
    Basic.init_string_builder(*builder);
    defer Basic.reset(*builder);

    Basic.append(*builder, "    Entities :: struct {");
    for metaEntity : metaEntityList {
        Basic.append(*builder, "\n        ");
        Basic.append(*builder, metaEntity.idCamelCase);
        Basic.append(*builder, " : [..]");
        Basic.append(*builder, metaEntity.name);
        Basic.append(*builder, ";");
    }
    Basic.append(*builder, "\n    }");

    entitiesString := Basic.builder_to_string(*builder);

    // Building create_xxx_entity string
    Basic.reset(*builder);

    for metaEntity : metaEntityList {
        Basic.append(*builder, "\n    create_");
        Basic.append(*builder, metaEntity.idSnakeCase);
        Basic.append(*builder, "_entity :: (engine : *Sill.Engine) -> *");
        Basic.append(*builder, metaEntity.name);
        Basic.append(*builder, " {\n");
        Basic.append(*builder, "        array := *engine.entities.");
        Basic.append(*builder, metaEntity.idCamelCase);
        Basic.append(*builder, ";\n");
        Basic.append(*builder, "        Basic.array_resize(array, array.count + 1);\n");
        Basic.append(*builder, "        entity := Basic.peek_pointer(engine.entities.mesh);\n");
        // @todo entity_init should be generated, so that components are inited too.
        // And that ugly component loop below should be hidden in entity_init.
        Basic.append(*builder, "        entity.engine = engine;\n");
        for component : metaEntity.components {
            Basic.append(*builder, "        entity.");
            Basic.append(*builder, component);
            Basic.append(*builder, ".entity = entity;\n");
        }
        Basic.append(*builder, "        return entity;\n");
        Basic.append(*builder, "    }\n");
    }

    createEntitiesString := Basic.builder_to_string(*builder);

    // Generating final meta
    metaString := Basic.sprint(META_STRING, entitiesString, createEntitiesString);
    Compiler.add_build_string(metaString, workspace);
}
