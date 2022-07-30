/*
 * Metaprogram to be called during compilation.
 * (Either use -plug Sill/plugin with the default metaprogram or call message.)
 *
 * Create a new struct which inherits from Entity.
 *
 * ```
 * Player :: struct {
 *     using #as entity : Sill.Entity;
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

#load "../Chamber/string-utilities.jai";

get_plugin :: () -> *Compiler.Metaprogram_Plugin {
    p := Basic.New(Compiler.Metaprogram_Plugin);
    p.message = sill_plugin_message;
    return p;
}

sill_plugin_message :: (p : *Compiler.Metaprogram_Plugin, message : *Compiler.Message) {
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

Basic :: #import "Basic";
Compiler :: #import "Compiler";

MetaEntity :: struct {
    structName : string;    // "MyCustomEntity" Expected PascalCase is user source code.
    idCamelCase : string;   // "myCustom"
    idSnakeCase : string;   // "my_custom"
    structMembers : [..]StructMember;
    hasOnCleanup : bool;
    noStorage : bool;

    // This entity has multiple components defined as "some : SomeComponent;"
    // @note During compilation, we're not sure whether this is a component or not.
    // This will finally be determined during _check_dependencies.
    StructMember :: struct {
        Kind :: enum {
            Unknown :: 0;
            Component;
            Entity;
        }

        kind : Kind;
        location : Source_Code_Location;
        typeName : string;    // "SomeComponent"
        fieldName : string;   // "some"

        // Fields below became valid when kind is known to be Component.
        // SomeComponent's dependencies ids are mapped to MyCustomEntity's components ids.
        id : string;   // "some", same as fieldName
        dependencies : [..]struct {
            id : string;
            targetComponentId : string;
        };
    }
}

MetaComponent :: struct {
    structName : string;                    // MyCustomComponent
    dependencies : [..]Dependency;

    // During compile, we don't know for sure whether this is a real dependency to an other component.
    // This becomes sure only during _check_dependencies.
    Dependency :: struct {
        isComponent : bool;
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

#scope_file
Bucket_Array :: #import "Bucket_Array";
for_expansion :: Bucket_Array.for_expansion;
#scope_export
DONE

_generated := false;

// Will pass through pointers to get the base type.
_get_type_module_and_identifier :: (codeTypeInst : *Compiler.Code_Type_Instantiation) -> (string, string, pointerCount : u32) {
    pointerCount : u32;
    typeInst := codeTypeInst;
    if typeInst == null then return "", "", pointerCount;

    while typeInst.pointer_to != null {
        typeInst = typeInst.pointer_to;
        pointerCount += 1;
    }

    type := typeInst.type_valued_expression;
    if type == null then return "", "", pointerCount;

    while type.kind == .BINARY_OPERATOR {
        type = (cast(*Compiler.Code_Binary_Operator) type).right;
    }
    if type.kind != .IDENT then return "", "", pointerCount;

    typeIdent := cast(*Compiler.Code_Ident) type;

    module : string;
    if typeIdent.resolved_declaration &&
        typeIdent.resolved_declaration.location.enclosing_load &&
        typeIdent.resolved_declaration.location.enclosing_load.enclosing_import {
        module = typeIdent.resolved_declaration.location.enclosing_load.enclosing_import.module_name;
    }

    return module, typeIdent.name, pointerCount;
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
                metaEntity := _add_meta_entity(codeDeclaration.name, codeStruct.block.members);
                for note : memberCodeDeclaration.notes {
                    if note.text == "Sill:NoStorage" then metaEntity.noStorage = true;
                }
                break;
            }
            else if typeIdentifier == "Component" {
                _add_meta_component(codeDeclaration.name, codeStruct.block.members);
                break;
            }
        }
    }
}

_add_meta_entity :: (name : string, members : []*Compiler.Code_Scope_Entry) -> *MetaEntity {
    metaEntity := Basic.array_add(*metaEntityList);
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
        metaEntity.hasOnCleanup = metaEntity.hasOnCleanup || (memberCodeDeclaration.name == "on_cleanup");

        if memberCodeDeclaration.flags & .IS_MARKED_AS_USING != 0 ||
           memberCodeDeclaration.flags & .IS_IMPORTED != 0 {
            continue;
        }

        _, typeIdentifier, pointerCount := _get_type_module_and_identifier(memberCodeDeclaration.type_inst);
        if typeIdentifier == "" || pointerCount > 0 then continue;

        // @note We don't know for sure that this is a component for now,
        // as the type might not exist.
        structMember : MetaEntity.StructMember;
        structMember.typeName = typeIdentifier;
        structMember.fieldName = memberCodeDeclaration.name;
        structMember.location = Compiler.make_location(memberCodeDeclaration.type_inst);

        Basic.array_add(*metaEntity.structMembers, structMember);
    }

    return metaEntity;
}

_find_meta_entity_struct_member :: (metaEntity : *MetaEntity, typeName : string) -> *MetaEntity.StructMember {
    for *structMember : metaEntity.structMembers {
        if structMember.typeName == typeName {
            return structMember;
        }
    }
    return null;
}

_add_meta_component :: (name : string, members : []*Compiler.Code_Scope_Entry) {
    metaComponent := Basic.array_add(*metaComponentList);
    metaComponent.structName = name;

    for member : members {
        if member.kind != .DECLARATION then continue;

        memberCodeDeclaration := cast(*Compiler.Code_Declaration) member;
        if memberCodeDeclaration.flags & .IS_MARKED_AS_USING ||
           memberCodeDeclaration.flags & .IS_IMPORTED {
            continue;
        }

        // @note Ignoring non-pointers members as component's dependencies
        // must be expressed as pointers to a struct.
        if memberCodeDeclaration.type_inst == null then continue;
        if memberCodeDeclaration.type_inst.pointer_to == null then continue;

        _, typeIdentifier := _get_type_module_and_identifier(memberCodeDeclaration.type_inst);
        if typeIdentifier == "" then continue;

        dependency : MetaComponent.Dependency;
        dependency.structName = typeIdentifier;
        dependency.id = memberCodeDeclaration.name;
        Basic.array_add(*metaComponent.dependencies, dependency);
    }
}

_find_meta_component :: (name : string) -> *MetaComponent {
    for *metaComponent : metaComponentList {
        if metaComponent.structName == name then return metaComponent;
    }
    return null;
}

_find_meta_entity :: (name : string) -> *MetaEntity {
    for *metaEntity : metaEntityList {
        if metaEntity.structName == name then return metaEntity;
    }
    return null;
}

_check_dependencies :: () {
    // Checking component's dependencies to other components are effectively components.
    for *metaComponent : metaComponentList {
        for *dependency : metaComponent.dependencies {
            dependency.isComponent = (_find_meta_component(dependency.structName) != null);
        }
    }

    // Checking that entities's components have all their dependencies resolved.
    // This is done at the end of the compilation, to be sure that everything has been
    // tagged within meta-structures.
    for *metaEntity : metaEntityList {
        for *structMember : metaEntity.structMembers {
            if _find_meta_component(structMember.typeName) {
                structMember.kind = .Component; // We found a meta-component, yeah!
                structMember.id = structMember.fieldName; // Just for simplicity of saying "component.id" later on.
            } else if _find_meta_entity(structMember.typeName) {
                structMember.kind = .Entity;
                structMember.id = structMember.fieldName;
            }
        }

        for *structMember : metaEntity.structMembers {
            if structMember.kind != .Component then continue;

            metaComponent := _find_meta_component(structMember.typeName);
            for dependency : metaComponent.dependencies {
                if !dependency.isComponent then continue;

                entityDependeeComponent := _find_meta_entity_struct_member(metaEntity, dependency.structName);
                if (entityDependeeComponent == null) || entityDependeeComponent.kind != .Component {
                    message := Basic.sprint("[SillMeta] Component % of entity % cannot resolve its dependency to %.",
                                            structMember.typeName, metaEntity.structName, dependency.structName);
                    Compiler.compiler_report(message, structMember.location);
                    continue;
                }

                Basic.array_add(*structMember.dependencies, .{});
                otherDependency := Basic.peek_pointer(structMember.dependencies);
                otherDependency.id = dependency.id;
                otherDependency.targetComponentId = entityDependeeComponent.id;
            }
        }
    }
}

_generate :: (workspace : s64) {
    if _generated then return;
    _generated = true;

    _check_dependencies();

    // Building Entities string
    builder : Basic.String_Builder;
    Basic.init_string_builder(*builder);
    defer Basic.reset(*builder);

    Basic.append(*builder, "    Entities :: struct {");
    for metaEntity : metaEntityList {
        // @todo We could make the size of buckets configurable.
        if metaEntity.noStorage then continue;
        Basic.print_to_builder(*builder, "\n        % : Bucket_Array.Bucket_Array(%, 16);", metaEntity.idCamelCase, metaEntity.structName);
    }
    Basic.append(*builder, "\n    }");

    entitiesString := Basic.builder_to_string(*builder);

    // Building functions string
    Basic.reset(*builder);

    Basic.append(*builder, "\n    _destroy_entity :: (entity : *Sill.Entity) {\n");
    Basic.append(*builder, "        if entity.type == {\n");
    for metaEntity : metaEntityList {
        if metaEntity.noStorage then continue;
        Basic.print_to_builder(*builder, "            case %;\n", metaEntity.structName);
        Basic.print_to_builder(*builder, "                destroy_%_entity(cast(*%) entity);\n", metaEntity.idSnakeCase, metaEntity.structName);
    }
    Basic.append(*builder, "        }\n");
    Basic.append(*builder, "    }\n");

    for metaEntity : metaEntityList {
        if metaEntity.noStorage then continue;
        Basic.print_to_builder(*builder, "\n    create_%_entity :: (engine : *Sill.Engine) -> *% {\n", metaEntity.idSnakeCase, metaEntity.structName);
        Basic.print_to_builder(*builder, "        array := *engine.entities.%;\n", metaEntity.idCamelCase);
        Basic.append(*builder, "        entity, _ := Bucket_Array.find_and_occupy_empty_slot(array);\n");
        Basic.print_to_builder(*builder, "        <<entity = %.{};\n", metaEntity.structName);
        Basic.append(*builder, "        engine.Meta.entity_init(entity, engine);\n");
        Basic.append(*builder, "        return entity;\n");
        Basic.append(*builder, "    }\n");
        Basic.print_to_builder(*builder, "\n    destroy_%_entity :: (entity : *%) {\n", metaEntity.idSnakeCase, metaEntity.structName);
        Basic.print_to_builder(*builder, "        array := *(cast(*Sill.Engine(SillMeta)) entity.engine).entities.%;\n", metaEntity.idCamelCase);
        Basic.append(*builder, "        for *bucketedEntity : <<array {\n");
        Basic.append(*builder, "            if entity == bucketedEntity {\n");
        Basic.append(*builder, "                remove bucketedEntity;\n");
        Basic.append(*builder, "                break;\n");
        Basic.append(*builder, "            }\n");
        Basic.append(*builder, "        }\n");
        Basic.append(*builder, "        entity_cleanup(entity);\n");
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_init :: (entity : *%, engine : *Sill.EngineBase) {\n", metaEntity.structName);
        Basic.append(*builder, "        entity.engine = engine;\n");
        Basic.print_to_builder(*builder, "        entity.type = %;\n", metaEntity.structName);
        Basic.print_to_builder(*builder, "        entity.typeInfo = type_info(%);\n", metaEntity.structName);
        for structMember : metaEntity.structMembers {
            if structMember.kind == .Component {
                Basic.print_to_builder(*builder, "        entity.%.entity = entity;\n", structMember.id);
                for componentDependency : structMember.dependencies {
                    Basic.print_to_builder(*builder, "        entity.%.% = *entity.%;\n", structMember.id, componentDependency.id,  componentDependency.targetComponentId);
                }
                Basic.print_to_builder(*builder, "        Sill.component_init(*entity.%);\n", structMember.id);
            } else if structMember.kind == .Entity {
                Basic.print_to_builder(*builder, "        entity_init(*entity.%, engine);\n", structMember.id);
            }
        }
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_cleanup :: (entity : *%) {\n", metaEntity.structName);
        if metaEntity.hasOnCleanup {
            Basic.append(*builder, "        entity.on_cleanup(entity);\n");
        }
        for structMember : metaEntity.structMembers {
            if structMember.kind == .Component {
                Basic.print_to_builder(*builder, "        Sill.component_cleanup(*entity.%);\n", structMember.id);
            } else if structMember.kind == .Entity {
                Basic.print_to_builder(*builder, "        entity_cleanup(*entity.%);\n", structMember.id);
            }
        }
        Basic.append(*builder, "        Basic.array_free(entity.children);\n");
        Basic.append(*builder, "    }\n");
    }

    for metaEntity : metaEntityList {
        Basic.print_to_builder(*builder, "\n    entity_update :: (entity : *%, dt : float64) {\n", metaEntity.structName);
        for structMember : metaEntity.structMembers {
            if structMember.kind == .Component {
                Basic.print_to_builder(*builder, "        Sill.component_update(*entity.%, dt);\n", structMember.id);
            } else if structMember.kind == .Entity {
                Basic.print_to_builder(*builder, "        entity_update(*entity.%, dt);\n", structMember.id);
            }
        }
        Basic.append(*builder, "    }\n");
    }

    Basic.append(*builder, "\n    _cleanup_entities :: (engine : *Sill.Engine) {\n");
    for metaEntity : metaEntityList {
        if metaEntity.noStorage then continue;
        Basic.print_to_builder(*builder, "        for *entity : engine.entities.% {\n", metaEntity.idCamelCase);
        Basic.append(*builder, "            engine.Meta.entity_cleanup(entity);\n");
        Basic.append(*builder, "        }\n");
        Basic.print_to_builder(*builder, "        Bucket_Array.bucket_array_reset(*engine.entities.%);\n", metaEntity.idCamelCase);
    }
    Basic.append(*builder, "    }\n");

    Basic.append(*builder, "\n    _update_entities :: (engine : *Sill.Engine, dt : float64) {\n");
    for metaEntity : metaEntityList {
        if metaEntity.noStorage then continue;
        Basic.print_to_builder(*builder, "        for *entity : engine.entities.% {\n", metaEntity.idCamelCase);
        Basic.append(*builder, "            engine.Meta.entity_update(entity, dt);\n");
        Basic.append(*builder, "            entity.childrenChanged = false;\n");
        Basic.append(*builder, "        }\n");
    }
    Basic.append(*builder, "    }\n");

    functionsString := Basic.builder_to_string(*builder);

    // Generating final meta
    metaString := Basic.sprint(META_STRING, entitiesString, functionsString);
    Compiler.add_build_string(metaString, workspace);
}
