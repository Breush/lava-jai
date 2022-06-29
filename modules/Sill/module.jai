#module_parameters(VR_ENABLED := false);

#load "engine.jai";
#load "entity.jai";
#load "managers/fonts.jai";
#load "managers/input.jai";
#load "managers/ui.jai";
#load "components/behavior-component.jai";
#load "components/camera-component.jai";
#load "components/collider-component.jai";
#load "components/mesh-component.jai";
#load "components/transform-component.jai";
#load "components/ui-component.jai";

#scope_module

Basic :: #import "Basic";
File :: #import "File";
Hash :: #import "Hash_Table";
Sort :: #import "Sort";
Chamber :: #import "Chamber";
Crater :: #import "Crater";
Magma :: #import "Magma" (VR_ENABLED = VR_ENABLED);

_CHECK :: Chamber._CHECK;
