#scope_module

Vr :: struct {
    EyeKind :: enum {
        Left :: 0;
        Right :: 1;
    }

    enabled := false;
}

engine_vr_init :: (engine : *Engine) -> bool {
    Basic.log("Module parameter VR_ENABLED is not set to true.", flags=.ERROR);
    return false;
}

engine_vr_cleanup :: (engine : *Engine) {
}

vr_recommended_eye_extent :: (vr : *Vr, eyeKind : Vr.EyeKind) -> Chamber.uvec2 {
    return .{};
}

vr_vulkan_required_instance_extensions :: (vr : *Vr) -> []string {
    return .[];
}

vr_vulkan_required_device_extensions :: (vr : *Vr) -> []string {
    return .[];
}

_vr_vulkan_required_physical_device :: (engine : *Engine) -> *void {
    return null;
}

