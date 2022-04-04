#module_parameters(VR_ENABLED := false);

#load "engine.jai";
#load "input.jai";
#load "ui.jai";
#load "components/behavior-component.jai";
#load "components/camera-component.jai";
#load "components/mesh-component.jai";
#load "components/transform-component.jai";
#load "components/ui-component.jai";

// An entity base, once a struct inherits from it,
// add components as fields to the latter.
// The metaprogram will register all entity kinds to the engine.
// See Sill/meta.jai for more information.
Entity :: struct {
    engine : *EngineBase;

    type : Type;
    name : string;
    children : [..]*Entity; // Do not add directly, use entity_add_child.

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
        // @todo Not implemented yet. Should remove the child from the parent's children array.
    }
}

entity_add_child :: (entity : *Entity, child : *Entity) {
    Basic.array_add(*entity.children, child);
    entity.childrenChanged = true;
}

#scope_module

Basic :: #import "Basic";
File :: #import "File";
Hash :: #import "Hash_Table";
Chamber :: #import "Chamber";
Crater :: #import "Crater";
Magma :: #import "Magma" (VR_ENABLED = VR_ENABLED);

_CHECK :: Chamber._CHECK;
