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
    allocator_data : *void;
}

destroy_target :: (target : *Target) {
    if target.kind == .Window {
        destroy_window_target(cast(*WindowTarget) target);
    }
    else if target.kind == .Vr {
        destroy_vr_target(cast(*VrTarget) target);
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
    using target : Target;
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

window_target_update :: (windowTarget : *WindowTarget) -> bool {
    // Nothing to do
    return true;
}

window_target_bind :: (windowTarget : *WindowTarget, rendererOutput : RendererOutput, bindIndex : u8) {
    windowTarget.rendererOutput = rendererOutput;
}

// -----

VrTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Vr;

    LEFT_EYE_BIND_INDEX :: 0;
    RIGHT_EYE_BIND_INDEX :: 1;
    rendererOutputs : [2]RendererOutput;

    sessionRunning : bool;
    session : Xr.Session;
    configurationViews : [2]Xr.ViewConfigurationView;
    views : [2]Xr.View;
    eventDataBuffer : Xr.EventDataBuffer;
    referenceSpace : Xr.Space;

    using vrTargetImpl : VrTargetImpl;
}

// Allocate, init and register a new vr target.
create_vr_target :: (engine : *Engine, options := Target.Options.{}) -> *VrTarget {
    vrTarget := cast(*VrTarget) Basic.New(VrTarget);
    Basic.remember_allocators(vrTarget);
    vr_target_init(vrTarget, engine, options);
    engine_register(engine, vrTarget);
    return vrTarget;
}

destroy_vr_target :: (vrTarget : *VrTarget) {
    vr_target_cleanup(vrTarget);

    // @todo :AutoUnregister
}

vr_target_init :: (vrTarget : *VrTarget, engine : *Engine, options := Target.Options.{}) -> bool {
    _target_init(vrTarget, engine, options);

    _CHECK(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Vr, false,
           "Unable to init VR target: VR is not enabled. Be sure to have TargetFlags.Vr set in engine options.");
    _CHECK(engine.vr.enabled, false,
           "Unable to init VR target: VR is not available.");

    if !_init_vr(vrTarget) then return false;

    return impl_vr_target_init(vrTarget);
}

vr_target_cleanup :: (vrTarget : *VrTarget) {
    if vrTarget.engine.vr.enabled {
        _cleanup_vr(vrTarget);
    }

    impl_vr_target_cleanup(vrTarget);

    // Reset memory
    <<vrTarget = VrTarget.{};
}

vr_target_update :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    if !vr.enabled then return true;

    while true {
        vrTarget.eventDataBuffer.type = .TypeEventDataBuffer;
        result := Xr.poll_event(vr.instance, *vrTarget.eventDataBuffer);

        if result == .Success {
            if vrTarget.eventDataBuffer.type == .TypeEventDataSessionStateChanged {
                eventDataSessionStateChanged := cast(*Xr.EventDataSessionStateChanged) *vrTarget.eventDataBuffer;
                sessionState := eventDataSessionStateChanged.state;

                if sessionState == .Ready {
                    sessionBI : Xr.SessionBeginInfo;
                    sessionBI.type = .TypeSessionBeginInfo;
                    sessionBI.primaryViewConfigurationType = .PrimaryStereo;
                    _CHECK(Xr.begin_session(vrTarget.session, *sessionBI),
                        "Unable to begin OpenXR session.");

                    vrTarget.sessionRunning = true;
                }
            }
        } else if result == .EventUnavailable {
            // Nothing to do
            break;
        } else {
            _CHECK(result, "Unable to poll OpenXr event.");
        }
    }

    return true;
}

vr_target_bind :: (vrTarget : *VrTarget, rendererOutput : RendererOutput, bindIndex : u8) {
    vrTarget.rendererOutputs[bindIndex] = rendererOutput;
}

vr_target_recommended_eye_extent :: (vrTarget : *VrTarget, eyeKind : Vr.EyeKind) -> Chamber.uvec2 {
    extent : Chamber.uvec2;
    extent.width = vrTarget.configurationViews[eyeKind].recommendedImageRectWidth;
    extent.height = vrTarget.configurationViews[eyeKind].recommendedImageRectHeight;
    return extent;
}

#scope_file

_target_init :: (target : *Target, engine : *Engine, options : Target.Options) {
    target.options = options;
    target.engine = engine;
}

_init_vr :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    graphicsBinding := impl_vr_target_get_graphics_binding(vrTarget);

    // Session
    sessionCI : Xr.SessionCreateInfo;
    sessionCI.type = .TypeSessionCreateInfo;
    sessionCI.systemId = vr.systemId;
    sessionCI.next = *graphicsBinding;

    _CHECK(Xr.create_session(vr.instance, *sessionCI, *vrTarget.session),
           "Unable to create OpenXR session.");

    // Eyes (named views here)
    viewConfigurations : [..]Xr.ViewConfigurationType;
    defer Basic.array_free(viewConfigurations);
    Xr.array_fill(*viewConfigurations, Xr.enumerate_view_configurations, vr.instance, vr.systemId);
    _CHECK(Basic.array_find(viewConfigurations, .PrimaryStereo),
           "Unable to find a valid OpenXR view configuration.");

    viewConfigurationProperties : Xr.ViewConfigurationProperties;
    viewConfigurationProperties.type = .TypeViewConfigurationProperties;
    Xr.get_view_configuration_properties(vr.instance, vr.systemId, .PrimaryStereo, *viewConfigurationProperties);

    Xr.array_fill_stype(vrTarget.configurationViews, Xr.enumerate_view_configuration_views, vr.instance, vr.systemId, viewConfigurationProperties.viewConfigurationType, .TypeViewConfigurationView);
    for *view : vrTarget.views {
        view.type = .TypeView;
    }

    // Space
    referenceSpaceCI : Xr.ReferenceSpaceCreateInfo;
    referenceSpaceCI.type = .TypeReferenceSpaceCreateInfo;
    referenceSpaceCI.poseInReferenceSpace.orientation.w = 1; // Identity
    referenceSpaceCI.referenceSpaceType = .Stage;
    _CHECK(Xr.create_reference_space(vrTarget.session, *referenceSpaceCI, *vrTarget.referenceSpace),
           "Unable to create OpenXR reference space.");

    return true;
}

_cleanup_vr :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    Xr.destroy_space(vrTarget.referenceSpace);

    // Stopping session
    // @todo Could be nice to expose this functionnality to the end user.
    Xr.request_exit_session(vrTarget.session);

    result : Xr.Result;
    while true {
        vrTarget.eventDataBuffer.type = .TypeEventDataBuffer;
        result = Xr.poll_event(vr.instance, *vrTarget.eventDataBuffer);
        if result == .Success {
            if vrTarget.eventDataBuffer.type == .TypeEventDataSessionStateChanged {
                eventDataSessionStateChanged := cast(*Xr.EventDataSessionStateChanged) *vrTarget.eventDataBuffer;
                sessionState := eventDataSessionStateChanged.state;

                if sessionState == .Stopping {
                    vrTarget.sessionRunning = false;
                    _CHECK(Xr.end_session(vrTarget.session),
                           "Unable to end OpenXR session.");
                } else if sessionState == .Exiting {
                    break;
                }
            }
        }
    }

    Xr.destroy_session(vrTarget.session);

    return true;
}
