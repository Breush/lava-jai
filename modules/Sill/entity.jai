// An entity base, once a struct inherits from it,
// add components as fields to the latter.
// The metaprogram will register all entity kinds to the engine.
// See Sill/plugin.jai for more information.
Entity :: struct {
    engine : *EngineBase;

    // The real type behind the scenes.
    typeInfo : *Type_Info_Struct;

    name : string;
    children : [..]*Entity;     // Do not add directly, use entity_add_child.
    parent : *Entity;           // Do not edit directly.

    // Do not edit directly.
    flags : Flags;

    Flags :: enum_flags u8 {
        Destroyed;
        Disabled;
        DirectlyDisabled;

        DisabledChanged;
    }
}

// A component base, to be added to an entity.
Component :: struct {
    entity : *Entity;
}

destroy_entity :: (entity : *Entity, destroyChildren := false, warnParent := true) {
    Basic.array_add(*entity.engine.pendingDestroyedEntities, entity);
    entity.flags |= .Destroyed;
    if destroyChildren {
        for child : entity.children {
            destroy_entity(child, destroyChildren = true, warnParent = false);
        }
    }
    if warnParent then entity_set_parent(entity, null, warnOldParent = true);
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
    if warnChild {
        entity_set_parent(child, entity, warnNewParent = false);
    }
}

entity_remove_child :: (entity : *Entity, child : *Entity, warnChild := true) {
    Basic.array_unordered_remove_by_value(*entity.children, child, stop_after_first = true);
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

    _update_disabled(entity);
}

entity_set_disabled :: (entity : *Entity, disabled := true) {
    if cast(bool) (entity.flags & .DirectlyDisabled) == disabled then return;
    if disabled then entity.flags |= .DirectlyDisabled; else entity.flags &= ~.DirectlyDisabled;
    _update_disabled(entity);
}

#scope_file

_update_disabled :: (entity : *Entity) {
    newDisabled := entity.flags & .DirectlyDisabled || (entity.parent != null && entity.parent.flags & .Disabled);
    newDisabledChanged := cast(bool) (entity.flags & .Disabled) != newDisabled;

    if newDisabledChanged {
        entity.flags |= .DisabledChanged;
        if newDisabled then entity.flags |= .Disabled; else entity.flags &= ~.Disabled;

        for child : entity.children {
            _update_disabled(child);
        }
    }
}

