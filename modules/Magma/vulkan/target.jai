#scope_module

_target_post_init :: (target : *Target) -> bool {
    if target.kind == Target.Kind.Window {
        return _window_target_post_init(cast(*WindowTarget) target);
    }

    // Issue: unknown target.
    return false;
}

_target_draw :: (target : *Target, frameIndex : u8) -> bool {
    if target.renderer == null {
        // Nothing is bound to this target, skip it.
        return true;
    }

    if target.kind == Target.Kind.Window {
        return _window_target_draw(cast(*WindowTarget) target, frameIndex);
    }

    // Issue: unknown target.
    return false;
}

#load "window-target.jai";
