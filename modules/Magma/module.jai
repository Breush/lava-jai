/*
    @fixme Magma roadmap:
    - ComposePostProcess
    - Raytracing
*/

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

DATA_PATH :: #run Basic.tprint("%data", #filepath);

Basic :: #import "Basic";
File :: #import "File";
Chamber :: #import "Chamber";
