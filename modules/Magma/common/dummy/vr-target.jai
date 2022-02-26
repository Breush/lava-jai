VrTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Vr;

    // LEFT_EYE_BIND_INDEX :: 0;
    // RIGHT_EYE_BIND_INDEX :: 1;
    // rendererOutputs : [2]RendererOutput;
}

create_vr_target :: (engine : *Engine, options := Target.Options.{}) -> *VrTarget {
    vr_target_init(null, engine, options);
    return nullptr;
}

vr_target_init :: (vrTarget : *VrTarget, engine : *Engine, options := Target.Options.{}) -> bool {
    Basic.assert(false, "VR not enabled at module scope.");
    return false;
}

vr_target_cleanup :: (vrTarget : *VrTarget, resetMemory := true) {
}

vr_target_update :: (vrTarget : *VrTarget) -> bool {
    return false;
}

vr_target_bind :: (vrTarget : *VrTarget, rendererOutput : RendererOutput, bindIndex : u8) {
}
