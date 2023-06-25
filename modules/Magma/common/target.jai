#scope_module

/*
    A Target is the final presenter of a rendered image.

    For instance, WindowTarget displays an image to an OS window.
    Not available yet, but FileTarget would be able to write a rendered
    image to a PNG file.

    To display anything to a target, you need to bind a renderer
    to the target. For instance, a Camera or a PostProcessRenderer.
*/

Target :: struct {
    Kind :: enum {
        None :: 0;
        Window;
        Vr;
    }

    Options :: struct {
        Filter :: enum {
            Linear :: 0;
            Nearest;
        }

        // How the renderer's output should be mapped to the final window.
        filter : Filter;
    }

    kind := Kind.None;
    engine : *Engine;
    options : Options;

    allocator : Allocator;
}

destroy_target :: (target : *Target) {
    if target.kind == .Window {
        window_target_cleanup(cast(*WindowTarget) target, resetMemory = false);
    }
    else if target.kind == .Vr {
        vr_target_cleanup(cast(*VrTarget) target, resetMemory = false);
    }

    if target.allocator.proc != null {
        Basic.free(target, target.allocator);
    }
}

target_cleanup :: (target : *Target) {
    if target.kind == Target.Kind.Window {
        window_target_cleanup(cast(*WindowTarget) target);
    }
    else if target.kind == .Vr {
        vr_target_cleanup(cast(*VrTarget) target);
    }
}

target_update :: (target : *Target) {
    if target.kind == .Window {
        window_target_update(cast(*WindowTarget) target);
    }
    else if target.kind == .Vr {
        vr_target_update(cast(*VrTarget) target);
    }
}

target_bind :: (target : *Target, rendererOutput : RendererOutput, bindIndex : u8 = 0) {
    if target.kind == .Window {
        window_target_bind(cast(*WindowTarget) target, rendererOutput, bindIndex);
    }
    else if target.kind == .Vr {
        vr_target_bind(cast(*VrTarget) target, rendererOutput, bindIndex);
    }
}

// -----

WindowTarget :: struct {
    using #as target : Target;
    target.kind = Target.Kind.Window;

    extent : Chamber.uvec2;
    rendererOutput : RendererOutput;

    using windowTargetImpl : WindowTargetImpl;
}

// Allocate, init and register a new window target.
create_window_target :: (engine : *Engine, windowHandle : Chamber.WindowHandle, options := Target.Options.{}) -> *WindowTarget {
    windowTarget := cast(*WindowTarget) Basic.New(WindowTarget);
    Basic.remember_allocators(windowTarget);
    window_target_init(windowTarget, engine, windowHandle, options);
    engine_register(engine, windowTarget);
    return windowTarget;
}

window_target_init :: (windowTarget : *WindowTarget, engine : *Engine, windowHandle : Chamber.WindowHandle, options := Target.Options.{}) {
    Basic.assert(cast(bool) engine.options.features & .Window);
    _target_init(windowTarget, engine, options);
    impl_window_target_init(windowTarget, windowHandle);
}

window_target_cleanup :: (windowTarget : *WindowTarget, resetMemory := true) {
    impl_window_target_cleanup(windowTarget);

    if resetMemory {
        windowTarget.* = WindowTarget.{};
    }
}

window_target_update :: (windowTarget : *WindowTarget) -> bool {
    // Nothing to do
    return true;
}

window_target_bind :: (windowTarget : *WindowTarget, rendererOutput : RendererOutput, bindIndex : u8) {
    windowTarget.rendererOutput = rendererOutput;
}

// -----

#if VR_ENABLED {
    #load "openxr/vr-target.jai";
} else {
    #load "dummy/vr-target.jai";
}

_target_init :: (target : *Target, engine : *Engine, options : Target.Options) {
    target.options = options;
    target.engine = engine;
}
