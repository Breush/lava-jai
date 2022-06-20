// An entity base, once a struct inherits from it,
// add components as fields to the latter.
// The metaprogram will register all entity kinds to the engine.
// See Sill/plugin.jai for more information.
Entity :: struct {
    engine : *EngineBase;

    type : Type;   // The real type behind the scenes.
    typeInfo : Type_Info_Struct;

    name : string;
    children : [..]*Entity; // Do not add directly, use entity_add_child.
    parent : *Entity;       // Do not edit directly.

    childrenChanged : bool;
}

// A component base, to be added to an entity.
Component :: struct {
    entity : *Entity;
}

destroy_entity :: (entity : *Entity, destroyChildren := false, warnParent := true) {
    Basic.array_add(*entity.engine.pendingDestroyedEntities, entity);
    if destroyChildren {
        for child : entity.children {
            destroy_entity(child, destroyChildren = true, warnParent = false);
        }
    }
    if warnParent {
        entity_set_parent(entity, null, warnOldParent = warnParent);
    }
}

entity_get_component :: (entity : *Entity, $componentType : Type) -> *componentType {
    for member : entity.typeInfo.members {
        if member.type == type_info(componentType) {
            // @todo Completely fails if "entity" is not at offset_in_bytes 0.
            return cast(*componentType) ((cast(*u8) entity) + member.offset_in_bytes);
        }
    }
    return null;
}

entity_add_child :: (entity : *Entity, child : *Entity, warnChild := true) {
    isNewChild := Basic.array_add_if_unique(*entity.children, child);
    if !isNewChild then return;

    entity.childrenChanged = true;
    if warnChild {
        entity_set_parent(child, entity, warnNewParent = false);
    }
}

entity_remove_child :: (entity : *Entity, child : *Entity, warnChild := true) {
    Basic.array_unordered_remove_by_value(*entity.children, child, stop_after_first = true);
    entity.childrenChanged = true;
    if warnChild {
        entity_set_parent(child, null, warnOldParent = false);
    }
}

entity_set_parent :: (entity : *Entity, parent : *Entity, warnOldParent := true, warnNewParent := true) {
    if entity.parent == parent then return;

    if warnOldParent && entity.parent != null {
        entity_remove_child(entity.parent, entity, warnChild = false);
    }
    entity.parent = parent;
    if warnNewParent && parent != null {
        entity_add_child(parent, entity, warnChild = false);
    }
}
