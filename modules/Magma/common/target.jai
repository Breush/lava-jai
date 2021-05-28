#scope_module

/*
    A Target is the final presenter of a rendered image.

    For instance, WindowTarget displays an image to an OS window.
    Not available yet, but FileTarget would be able to write a rendered
    image to a PNG file.

    To display anything to a target, you need to bind a renderer
    to the target. For instance, a Camera or a PostProcess.
*/

Target :: struct {
    Kind :: enum {
        None :: 0;
        Window;
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

    extent : Chamber.uvec2;
    renderer : *Renderer;
    rendererOutputIndex : u8;

    allocator : Allocator;
    allocator_data : *void;
}

WindowTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Window;

    using windowTargetImpl : WindowTargetImpl;
}

destroy_target :: (target : *Target) {
    if target.kind == Target.Kind.Window {
        destroy_window_target(cast(*WindowTarget) target);
    }
}

target_cleanup :: (target : *Target) {
    if target.kind == Target.Kind.Window {
        window_target_cleanup(cast(*WindowTarget) target);
    }
}

target_bind :: (target : *Target, renderer : *Renderer, outputIndex : u8 = 0) {
    target.renderer = renderer;
    target.rendererOutputIndex = outputIndex;
}

// Allocate, init and register a new target.
create_window_target :: (engine : *Engine, windowHandle : Chamber.WindowHandle, options := Target.Options.{}) -> *WindowTarget {
    windowTarget := cast(*WindowTarget) Basic.New(WindowTarget);
    Basic.remember_allocators(windowTarget);
    window_target_init(windowTarget, engine, windowHandle, options);
    engine_register(engine, windowTarget);
    return windowTarget;
}

destroy_window_target :: (windowTarget : *WindowTarget) {
    window_target_cleanup(windowTarget);

    // @todo :AutoUnregister
}

window_target_init :: (windowTarget : *WindowTarget, engine : *Engine, windowHandle : Chamber.WindowHandle, options := Target.Options.{}) {
    Basic.assert(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Window);
    _target_init(windowTarget, engine, options);
    impl_window_target_init(windowTarget, windowHandle);
}

window_target_cleanup :: (windowTarget : *WindowTarget) {
    impl_window_target_cleanup(windowTarget);

    // Reset memory
    <<windowTarget = WindowTarget.{};
}

#scope_file

_target_init :: (target : *Target, engine : *Engine, options : Target.Options) {
    target.options = options;
    target.engine = engine;
}
