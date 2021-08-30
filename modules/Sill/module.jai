/*
    @fixme Sill roadmap:
    - Entity hierarchy (+ TransformComponent -- and a way to access other components from one)
    - MeshComponent: Materials (textures) + Data cache...
*/

#load "engine.jai";
#load "components/mesh-component.jai";

// An entity base, once a struct inherits from it,
// add components as fields to the latter.
// The metaprogram will register all entity kinds to the engine.
// See Sill/meta.jai for more information.
Entity :: struct {
    engine : *EngineBase;

    name : string;
}

// A component base, to be added to an entity.
Component :: struct {
    entity : *Entity;
}

#scope_module

Basic :: #import "Basic";
File :: #import "File";
Hash :: #import "Hash_Table";
Chamber :: #import "Chamber";
Crater :: #import "Crater";
Magma :: #import "Magma";

_CHECK :: Chamber._CHECK;
