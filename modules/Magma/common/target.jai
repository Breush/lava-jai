#scope_module

/*
    A Target is the final presenter of a rendered image.

    For instance, WindowTarget displays an image to an OS window.
    Not available yet, but FileTarget would be able to write a rendered
    image to a PNG file.

    To display anything to a target, you need to get it's ImageHandle.
    These are provided by Cameras or by PostProcesses.
*/

Target :: struct {
    Kind :: enum {
        None :: 0;
        Window;
    }

    kind := Kind.None;
    engine : *Engine;
    extent : Chamber.uvec2;

    allocator : Allocator;
    allocator_data : *void;
}

WindowTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Window;

    using impl : WindowTargetImpl;
}

target_cleanup :: (target : *Target) {
    if target.kind == Target.Kind.Window {
        window_target_cleanup(cast(*WindowTarget) target);
    }
}

// Allocate, init and register a new target.
create_window_target :: (engine : *Engine, windowHandle : Chamber.WindowHandle) -> *WindowTarget {
    windowTarget := cast(*WindowTarget) Basic.New(WindowTarget);
    Basic.remember_allocators(windowTarget);
    window_target_init_pre_register(windowTarget, engine, windowHandle);
    engine_register(engine, windowTarget);
    window_target_init_post_register(windowTarget);
    return windowTarget;
}

window_target_init_pre_register :: (windowTarget : *WindowTarget, engine : *Engine, windowHandle : Chamber.WindowHandle) {
    Basic.assert(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Window);
    _target_init(windowTarget, engine);
    impl_window_target_init_pre_register(windowTarget, windowHandle);
}

// Finish init of the target, windowTarget.extent should be known afterwards.
window_target_init_post_register :: (windowTarget : *WindowTarget) {
    impl_window_target_init_post_register(windowTarget);
}

// This cleans back-end allocations, but does not unregister the target
// from the engine's internal list.
window_target_cleanup :: (windowTarget : *WindowTarget) {
    impl_window_target_cleanup(windowTarget);
}

#scope_file

_target_init :: (target : *Target, engine : *Engine) {
    target.engine = engine;
}
