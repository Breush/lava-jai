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
    allocator_data : *void;
}

destroy_target :: (target : *Target) {
    if target.kind == .Window {
        window_target_cleanup(cast(*WindowTarget) target, resetMemory = false);
    }
    else if target.kind == .Vr {
        vr_target_cleanup(cast(*VrTarget) target, resetMemory = false);
    }

    if target.allocator != null {
        Basic.free(target, target.allocator, target.allocator_data);
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

window_target_init :: (windowTarget : *WindowTarget, engine : *Engine, windowHandle : Chamber.WindowHandle, options := Target.Options.{}) {
    Basic.assert(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Window);
    _target_init(windowTarget, engine, options);
    impl_window_target_init(windowTarget, windowHandle);
}

window_target_cleanup :: (windowTarget : *WindowTarget, resetMemory := true) {
    impl_window_target_cleanup(windowTarget);

    if resetMemory {
        <<windowTarget = WindowTarget.{};
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

VrTarget :: struct {
    using target : Target;
    target.kind = Target.Kind.Vr;

    LEFT_EYE_BIND_INDEX :: 0;
    RIGHT_EYE_BIND_INDEX :: 1;
    rendererOutputs : [2]RendererOutput;

    sessionRunning : bool;
    sessionFocused : bool;
    session : Xr.Session;
    views : [2]Xr.View;
    eventDataBuffer : Xr.EventDataBuffer;
    stageReferenceSpace : Xr.Space;
    viewReferenceSpace : Xr.Space;
    frameState : Xr.FrameState;

    headInfo : struct {
        spaceLocation : Xr.SpaceLocation;
        transform : Chamber.trf;
    };

    handInfos : [2]struct {
        transform : Chamber.trf;
        poseSpace : Xr.Space;
        poseActionState : Xr.ActionStatePose;
        poseActionStateGI : Xr.ActionStateGetInfo;
        poseSpaceLocation : Xr.SpaceLocation;

        selectActionState : Xr.ActionStateFloat;
        selectActionStateGI : Xr.ActionStateGetInfo;
    };

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

vr_target_init :: (vrTarget : *VrTarget, engine : *Engine, options := Target.Options.{}) -> bool {
    _target_init(vrTarget, engine, options);

    _CHECK(cast(bool) engine.options.targetFlags & Engine.Options.TargetFlags.Vr, false,
           "Unable to init VR target: VR is not enabled. Be sure to have TargetFlags.Vr set in engine options.");
    _CHECK(engine.vr.enabled, false,
           "Unable to init VR target: VR is not available.");

    if !_init_vr(vrTarget) then return false;

    return impl_vr_target_init(vrTarget);
}

vr_target_cleanup :: (vrTarget : *VrTarget, resetMemory := true) {
    if vrTarget.engine.vr.enabled {
        _cleanup_vr(vrTarget);
    }

    impl_vr_target_cleanup(vrTarget);

    if resetMemory {
        <<vrTarget = VrTarget.{};
    }
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
                } else if sessionState == .Focused {
                    vrTarget.sessionFocused = true;
                }
                // @todo Check for IDLE too, in order to not render
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

vr_target_pre_render :: (vrTarget : *VrTarget) -> bool {
    if !vrTarget.sessionRunning then return false;

    frameWI : Xr.FrameWaitInfo;
    frameWI.type = .TypeFrameWaitInfo;
    _CHECK(Xr.wait_frame(vrTarget.session, *frameWI, *vrTarget.frameState),
           "Unable to wait for OpenXR frame.");

    frameBI : Xr.FrameBeginInfo;
    frameBI.type = .TypeFrameBeginInfo;
    _CHECK(Xr.begin_frame(vrTarget.session, *frameBI),
           "Unable to begin OpenXR frame.");

    return true;
}

vr_target_post_render :: (vrTarget : *VrTarget, compositionLayers : []*Xr.CompositionLayerBaseHeader) -> bool {
    frameEI : Xr.FrameEndInfo;
    frameEI.type = .TypeFrameEndInfo;
    frameEI.displayTime = vrTarget.frameState.predictedDisplayTime;
    frameEI.environmentBlendMode = Xr.EnvironmentBlendMode.Opaque;
    frameEI.layerCount = cast(u32) compositionLayers.count;
    frameEI.layers = compositionLayers.data;

    _CHECK(Xr.end_frame(vrTarget.session, *frameEI),
           "Unable to end OpenXR frame.");

    return true;
}

vr_target_sync :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    if vrTarget.sessionFocused {
        activeActionSet : Xr.ActiveActionSet;
        activeActionSet.actionSet = vr.actionSet;

        actionsSI : Xr.ActionsSyncInfo;
        actionsSI.type = .TypeActionsSyncInfo;
        actionsSI.countActiveActionSets = 1;
        actionsSI.activeActionSets = *activeActionSet;

        _CHECK(Xr.sync_actions(vrTarget.session, *actionsSI),
               "Unable to sync OpenXR actions.");

        _CHECK(Xr.locate_space(vrTarget.viewReferenceSpace, vrTarget.stageReferenceSpace, vrTarget.frameState.predictedDisplayTime, *vrTarget.headInfo.spaceLocation),
               "Unable to locate OpenXR space for hand.");
        _space_location_to_trf(vrTarget.headInfo.spaceLocation, *vrTarget.headInfo.transform);

        for *handInfo : vrTarget.handInfos {
            _CHECK(Xr.get_action_state_pose(vrTarget.session, *handInfo.poseActionStateGI, *handInfo.poseActionState),
                   "Unable to get OpenXR action state pose.");

            if handInfo.poseActionState.isActive {
                _CHECK(Xr.locate_space(handInfo.poseSpace, vrTarget.stageReferenceSpace, vrTarget.frameState.predictedDisplayTime, *handInfo.poseSpaceLocation),
                       "Unable to locate OpenXR space for hand.");
                _space_location_to_trf(handInfo.poseSpaceLocation, *handInfo.transform);
            }

            _CHECK(Xr.get_action_state_float(vrTarget.session, *handInfo.selectActionStateGI, *handInfo.selectActionState),
                   "Unable to get OpenXR action state select.");
        }
    }

    // Views
    viewLI : Xr.ViewLocateInfo;
    viewLI.type = .TypeViewLocateInfo;
    viewLI.viewConfigurationType = .PrimaryStereo;
    viewLI.displayTime = vrTarget.frameState.predictedDisplayTime;
    viewLI.space = vrTarget.stageReferenceSpace;

    viewState : Xr.ViewState;
    viewState.type = .TypeViewState;
    viewCount : u32;

    _CHECK(Xr.locate_views(vrTarget.session, *viewLI, *viewState, cast(u32) vrTarget.views.count, *viewCount, vrTarget.views.data),
            "Unable to locate OpenXR views.");

    for *view, viewIndex : vrTarget.views {
        eye := renderer_get_eye(vrTarget.rendererOutputs[viewIndex].renderer, 0);

        // Going from right-handed Y up, -Z forward coordinate system
        // to ours, right-handed Z up, X forward.
        orientation : Chamber.quat = ---;
        orientation.x = -view.pose.orientation.z;
        orientation.y = -view.pose.orientation.x;
        orientation.z = view.pose.orientation.y;
        orientation.w = view.pose.orientation.w;

        matrix := make_rotation_matrix4(orientation);
        matrix.coef[0][3] = -view.pose.position.z;
        matrix.coef[1][3] = -view.pose.position.x;
        matrix.coef[2][3] = view.pose.position.y;

        eye.viewMatrix = Chamber.inverse_and_prepare_for_projection(matrix);
        Chamber.infinite_perspective_projection(*eye.projectionMatrix, view.fov.angleLeft, view.fov.angleRight, view.fov.angleUp, view.fov.angleDown, 0.1);
        eye_commit(eye);
    }

    return true;
}

vr_target_bind :: (vrTarget : *VrTarget, rendererOutput : RendererOutput, bindIndex : u8) {
    vrTarget.rendererOutputs[bindIndex] = rendererOutput;
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
    for *view : vrTarget.views {
        view.type = .TypeView;
    }

    // Spaces
    referenceSpaceCI : Xr.ReferenceSpaceCreateInfo;
    referenceSpaceCI.type = .TypeReferenceSpaceCreateInfo;
    referenceSpaceCI.poseInReferenceSpace.orientation.w = 1; // Identity
    referenceSpaceCI.referenceSpaceType = .Stage;
    _CHECK(Xr.create_reference_space(vrTarget.session, *referenceSpaceCI, *vrTarget.stageReferenceSpace),
           "Unable to create OpenXR stage reference space.");

    referenceSpaceCI.referenceSpaceType = .View;
    _CHECK(Xr.create_reference_space(vrTarget.session, *referenceSpaceCI, *vrTarget.viewReferenceSpace),
           "Unable to create OpenXR view reference space.");

    // Actions
    vrTarget.headInfo.spaceLocation.type = .TypeSpaceLocation;

    for *handInfo, handIndex : vrTarget.handInfos {
        handInfo.poseSpaceLocation.type = .TypeSpaceLocation;
        handInfo.poseActionState.type = .TypeActionStatePose;
        handInfo.poseActionStateGI.type = .TypeActionStateGetInfo;
        handInfo.poseActionStateGI.action = vr.handInfos[handIndex].poseAction;
        handInfo.poseActionStateGI.subactionPath = vr.handInfos[handIndex].path;
        handInfo.selectActionState.type = .TypeActionStateFloat;
        handInfo.selectActionStateGI.type = .TypeActionStateGetInfo;
        handInfo.selectActionStateGI.action = vr.handInfos[handIndex].selectAction;
        handInfo.selectActionStateGI.subactionPath = vr.handInfos[handIndex].path;

        // @note We need a space for each pose
        actionSpaceCI : Xr.ActionSpaceCreateInfo;
        actionSpaceCI.type = .TypeActionSpaceCreateInfo;
        actionSpaceCI.action = vr.handInfos[handIndex].poseAction;
        actionSpaceCI.poseInActionSpace.orientation.w = 1; // Identity
        actionSpaceCI.subactionPath = vr.handInfos[handIndex].path;

        _CHECK(Xr.create_action_space(vrTarget.session, *actionSpaceCI, *handInfo.poseSpace),
               "Unable to create OpenXR hand pose space.");
    }

    sessionActionSetsAI : Xr.SessionActionSetsAttachInfo;
    sessionActionSetsAI.type = .TypeSessionActionSetsAttachInfo;
    sessionActionSetsAI.countActionSets = 1;
    sessionActionSetsAI.actionSets = *vr.actionSet;
    _CHECK(Xr.attach_session_action_sets(vrTarget.session, *sessionActionSetsAI),
           "Unable to attach OpenXR session action sets.");

    // Extra
    vrTarget.frameState.type = .TypeFrameState;

    return true;
}

_cleanup_vr :: (vrTarget : *VrTarget) -> bool {
    vr := *vrTarget.engine.vr;

    Xr.destroy_space(vrTarget.viewReferenceSpace);
    Xr.destroy_space(vrTarget.stageReferenceSpace);

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

_space_location_to_trf :: (spaceLocation : Xr.SpaceLocation, transform : *Chamber.trf) {
    transform.translation.x = -spaceLocation.pose.position.z;
    transform.translation.y = -spaceLocation.pose.position.x;
    transform.translation.z = spaceLocation.pose.position.y;
    transform.rotation.x = -spaceLocation.pose.orientation.z;
    transform.rotation.y = -spaceLocation.pose.orientation.x;
    transform.rotation.z = spaceLocation.pose.orientation.y;
    transform.rotation.w = spaceLocation.pose.orientation.w;
}
