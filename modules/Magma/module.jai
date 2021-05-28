Basic :: #import "Basic";
File :: #import "File";
Chamber :: #import "Chamber";

/*
    @fixme Magma roadmap:
    - @fixme Autorecompile shaders
    - ComposePostProcess
*/

#load "common/engine.jai";
#load "common/eye.jai";
#load "common/mesh.jai";
#load "common/renderer.jai";
#load "common/scene.jai";
#load "common/target.jai";

// Our only back-end so far.
#load "vulkan.jai";
