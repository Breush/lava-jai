/*
 * Metaprogram to be called during compilation.
 * (Call sill_meta_handle_message.)
 *
 * Create a new struct which inherits from Entity.
 *
 * ```
 * Player :: struct {
 *     using entity : Sill.Entity;
 *     transform : TransformComponent;  // Provides a way to move the entity around. It is a requirement of MeshComponent.
 *     mesh : MeshComponent;            // Provides a way to attach a mesh to the entity.
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
    structName : string;    // "MyCustomEntity" Expected PascalCase is user source code.
    idCamelCase : string;   // "myCustom"
    idSnakeCase : string;   // "my_custom"
    components : [..]Component;

    // This entity has multiple components defined as "some : SomeComponent;"
    Component :: struct {
        structName : string;    // "SomeComponent"
        id : string;            // "some"
        // SomeComponent's dependencies ids are mapped to MyCustomEntity's components ids.
        dependencies : [..]struct {
            id : string;
            targetComponentId : string;
        };
    }
}

MetaComponent :: struct {
    structName : string;                    // MyCustomComponent
    dependencies : [..]Dependency;

    Dependency :: struct {
        structName : string;
        id : string;
    }
}

metaEntityList : [..]MetaEntity;
metaComponentList : [..]MetaComponent;

META_STRING :: #string DONE
SillMeta :: struct {
%1
%2
}
DONE

_generated := false;

// Will pass through pointers to get the base type.
_get_type_module_and_identifier :: (codeTypeInst : *Compiler.Code_Type_Instantiation) -> (string, string) {
    typeInst := codeTypeInst;
    if typeInst == null then return "", "";

    while typeInst.pointer_to != null {
        typeInst = typeInst.pointer_to;
    }

    type := typeInst.type_valued_expression;
    if type == null then return "", "";

    while type.kind == .BINARY_OPERATOR {
        type = (cast(*Compiler.Code_Binary_Operator) type).right;
    }
    if type.kind != .IDENT then return "", "";

    typeIdent := cast(*Compiler.Code_Ident) type;

    module : string;
    if typeIdent.resolved_declaration &&
        typeIdent.resolved_declaration.location.enclosing_load &&
        typeIdent.resolved_declaration.location.enclosing_load.enclosing_import {
        module = typeIdent.resolved_declaration.location.enclosing_load.enclosing_import.module_name;
    }

    return module, typeIdent.name;
}

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
        module, typeIdentifier := _get_type_module_and_identifier(memberCodeDeclaration.type_inst);
        if typeIdentifier == "" then continue;

        if module == "Sill" {
            if typeIdentifier == "Entity" {
                _add_meta_entity(codeDeclaration.name, codeStruct.block.members);
                break;
            } else if typeIdentifier == "Component" {
                _add_meta_component(codeDeclaration.name, codeStruct.block.members);
                break;
            }
        }
    }
}

_add_meta_entity :: (name : string, members : []*Compiler.Code_Scope_Entry) {
    Basic.array_resize(*metaEntityList, metaEntityList.count + 1);
    metaEntity := Basic.peek_pointer(metaEntityList);

    metaEntity.structName = name;

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

        _, typeIdentifier := _get_type_module_and_identifier(memberCodeDeclaration.type_inst);
        if typeIdentifier == "" then continue;

        // Ensuring that all components have their dependencies resolved.
        metaComponent := _find_meta_component(typeIdentifier);
        if metaComponent == null then continue;

        // @note We know this is a component because we found a matching
        // meta-component.
        component : MetaEntity.Component;
        component.id = memberCodeDeclaration.name;
        component.structName = typeIdentifier;

        for dependency : metaComponent.dependencies {
            entityDependeeComponent := _find_meta_entity_component(metaEntity, dependency.structName);
            if entityDependeeComponent == null {
                message := Basic.sprint("[SillMeta] Component % of entity % cannot resolve its dependency to %.",
                                        component.structName, metaEntity.structName, dependency.structName);
                Compiler.compiler_report(message, Compiler.make_location(memberCodeDeclaration.type_inst));
                continue;
            }

            Basic.array_add(*component.dependencies, .{});
            otherDependency := Basic.peek_pointer(component.dependencies);
            otherDependency.id = dependency.id;
            otherDependency.targetComponentId = entityDependeeComponent.id;
        }

        Basic.array_add(*metaEntity.components, component);
    }
}

_find_meta_entity_component :: (metaEntity : *MetaEntity, name : string) -> *MetaEntity.Component {
    for *component : metaEntity.components {
        if component.structName == name {
            return component;
        }
    }
    return null;
}

_add_meta_component :: (name : string, members : []*Compiler.Code_Scope_Entry) {
    Basic.array_resize(*metaComponentList, metaComponentList.count + 1);
    metaComponent := Basic.peek_pointer(metaComponentList);

    metaComponent.structName = name;

    for member : members {
        if member.kind != .DECLARATION then continue;

        memberCodeDeclaration := cast(*Compiler.Code_Declaration) member;
        if memberCodeDeclaration.flags & .IS_MARKED_AS_USING != 0 ||
           memberCodeDeclaration.flags & .IS_IMPORTED != 0 {
            continue;
        }

        _, typeIdentifier := _get_type_module_and_identifier(memberCodeDeclaration.type_inst);
        if typeIdentifier == "" then continue;

        // @note No better way to find that this is really a component,
        // because the dependency is of pointer type. So, things might
        // not be resolved at this time.
        // @todo Store everything needed, and wait for everything to be ready
        // before computing MetaEntity dependencies?
        if !String.ends_with(typeIdentifier, "Component") {
            continue;
        }

        dependency : MetaComponent.Dependency;
        dependency.structName = typeIdentifier;
        dependency.id = memberCodeDeclaration.name;
        Basic.array_add(*metaComponent.dependencies, dependency);
    }
}

_find_meta_component :: (name : string) -> *MetaComponent {
    for *metaComponent : metaComponentList {
        if metaComponent.structName == name {
            return metaComponent;
        }
    }
    return null;
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
        Basic.print_to_builder(*builder, "\n        % : [..]%;", metaEntity.idCamelCase, metaEntity.structName);
    }
    Basic.append(*builder, "\n    }");

    entitiesString := Basic.builder_to_string(*builder);

    // Building functions string
    Basic.reset(*builder);

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    create_%_entity :: (engine : *Sill.Engine) -> *% {\n", metaEntity.idSnakeCase, metaEntity.structName);
        Basic.print_to_builder(*builder, "        array := *engine.entities.%;\n", metaEntity.idCamelCase);
        Basic.append(*builder, "        Basic.array_resize(array, array.count + 1);\n");
        Basic.append(*builder, "        entity := Basic.peek_pointer(engine.entities.mesh);\n");
        Basic.append(*builder, "        engine.Meta.entity_init(entity, engine);\n");
        Basic.append(*builder, "        return entity;\n");
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_init :: (entity : *%, engine : *Sill.EngineBase) {\n", metaEntity.structName);
        Basic.append(*builder, "        entity.engine = engine;\n");
        for component : metaEntity.components {
            Basic.print_to_builder(*builder, "        entity.%.entity = entity;\n", component.id);
            for componentDependency : component.dependencies {
                Basic.print_to_builder(*builder, "        entity.%.% = *entity.%;\n", component.id, componentDependency.id,  componentDependency.targetComponentId);
            }
            Basic.print_to_builder(*builder, "        Sill.component_init(*entity.%);\n", component.id);
        }
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_cleanup :: (entity : *%) {\n", metaEntity.structName);
        for component : metaEntity.components {
            Basic.print_to_builder(*builder, "        Sill.component_cleanup(*entity.%);\n", component.id);
        }
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_update :: (entity : *%, dt : float64) {\n", metaEntity.structName);
        for component : metaEntity.components {
            Basic.print_to_builder(*builder, "        Sill.component_update(*entity.%, dt);\n", component.id);
        }
        Basic.append(*builder, "    }\n");
    }

    Basic.append(*builder, "\n    _cleanup_entities :: (engine : *Sill.Engine) {\n");
    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "        for *entity : engine.entities.% {\n", metaEntity.idCamelCase);
        Basic.append(*builder, "            engine.Meta.entity_cleanup(entity);\n");
        Basic.append(*builder, "        }\n");
        Basic.print_to_builder(*builder, "        Basic.array_free(engine.entities.%);\n", metaEntity.idCamelCase);
    }
    Basic.append(*builder, "    }\n");

    Basic.append(*builder, "\n    _update_entities :: (engine : *Sill.Engine, dt : float64) {\n");
    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "        for *entity : engine.entities.% {\n", metaEntity.idCamelCase);
        Basic.append(*builder, "            engine.Meta.entity_update(entity, dt);\n");
        Basic.append(*builder, "        }\n");
    }
    Basic.append(*builder, "    }\n");

    functionsString := Basic.builder_to_string(*builder);

    // Generating final meta
    metaString := Basic.sprint(META_STRING, entitiesString, functionsString);
    Compiler.add_build_string(metaString, workspace);
}
