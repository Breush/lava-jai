#scope_module

#load "window-target.jai";
#load "vr-target.jai";

_target_post_init :: (target : *Target) -> bool {
    if target.kind == .Window {
        return _window_target_post_init(cast(*WindowTarget) target);
    }
    else if target.kind == .Vr {
        return _vr_target_post_init(cast(*VrTarget) target);
    }

    // Issue: unknown target.
    return false;
}

_target_draw :: (target : *Target, frameIndex : u8) -> bool {
    if target.kind == .Window {
        return _window_target_draw(cast(*WindowTarget) target, frameIndex);
    }
    else if target.kind == .Vr {
        return _vr_target_draw(cast(*VrTarget) target, frameIndex);
    }

    // Issue: unknown target.
    return false;
}
