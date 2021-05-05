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

    kind := Kind.None;
    engine : *Engine;
    extent : Chamber.uvec2;

    renderer : *Renderer;

    allocator : Allocator;
    allocator_data : *void;
}

WindowTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Window;

    using windowTargetImpl : WindowTargetImpl;
}

target_cleanup :: (target : *Target) {
    if target.kind == Target.Kind.Window {
        _window_target_cleanup(cast(*WindowTarget) target);
    }
}

target_bind :: (target : *Target, renderer : *Renderer) {
    target.renderer = renderer;
}

// Allocate, init and register a new target.
create_window_target :: (engine : *Engine, windowHandle : Chamber.WindowHandle) -> *WindowTarget {
    windowTarget := cast(*WindowTarget) Basic.New(WindowTarget);
    Basic.remember_allocators(windowTarget);
    window_target_init(windowTarget, engine, windowHandle);
    engine_register(engine, windowTarget);
    return windowTarget;
}

window_target_init :: (windowTarget : *WindowTarget, engine : *Engine, windowHandle : Chamber.WindowHandle) {
    Basic.assert(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Window);
    _target_init(windowTarget, engine);
    impl_window_target_init(windowTarget, windowHandle);
}

#scope_file

_target_init :: (target : *Target, engine : *Engine) {
    target.engine = engine;
}

_window_target_cleanup :: (windowTarget : *WindowTarget) {
    impl_window_target_cleanup(windowTarget);

    // Reset memory
    <<windowTarget = WindowTarget.{};
}
