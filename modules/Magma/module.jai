/*
    @fixme Magma roadmap:
    - ComposeRenderer
    - 2D (UI) renderer
*/

#module_parameters(VR_ENABLED := false);

#load "common/engine.jai";
#load "common/eye.jai";
#load "common/material.jai";
#load "common/mesh.jai";
#load "common/renderer.jai";
#load "common/scene.jai";
#load "common/shader.jai";
#load "common/target.jai";
#load "common/texture.jai";

// Our only back-end so far.
#load "vulkan.jai";

#scope_module

DOLLAR_SHADERS_PATH :: #run Basic.tprint("%data/shaders", #filepath);

Basic :: #import "Basic";
File :: #import "File";
Chamber :: #import "Chamber";
Math :: #import "Math";
Sort :: #import "Sort";
#import "Math"; // For operators
