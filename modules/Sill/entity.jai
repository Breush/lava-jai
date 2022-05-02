// An entity base, once a struct inherits from it,
// add components as fields to the latter.
// The metaprogram will register all entity kinds to the engine.
// See Sill/meta.jai for more information.
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
        entity_set_parent(entity, null, warnParent = true);
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

entity_add_child :: (entity : *Entity, child : *Entity) {
    Basic.array_add(*entity.children, child);
    entity.childrenChanged = true;
    entity_set_parent(child, entity, warnParent = false);
}

entity_set_parent :: (entity : *Entity, parent : *Entity, warnParent := true) {
    if entity.parent != null {
        // @todo Should warn previous parent if any.
    }
    entity.parent = parent;
}
