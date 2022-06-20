UiComponent :: struct {
    using component : Component;
    transform : *TransformComponent; // @todo Should be used to mark componentsDepthDirty

    // Main configuration.
    anchor := Anchor.Center;
    extent := Chamber.vec2.{1, 1}; // Renderered extent, after all transform applied.
    disabled := false;

    // Updated each input.
    hovered : bool;
    relativeMousePointerPosition : Chamber.vec2;

    // Handlers allow to customize the default behaviors.
    // - checkHoveredHandler is called whenever the entity is considered hovered.
    //   One can use iUi.relativeMousePointerPosition to get the mouse position within the entity.
    //   One can therefore return whether it is really hovered or not.
    checkHoveredHandler : CheckHoveredHandlerType;
    checkHoveredHandlerUserData : *void;

    CheckHoveredHandlerType :: #type (userData : *void) -> bool;

    // Updates are called after each user inputs.
    // While trigger callbacks are called when it changes.
    updateCallbacks : [..]Callback(UpdateCallbackType);
    triggerCallbacks : [..]Callback(TriggerCallbackType);

    UpdateCallbackType :: #type (update : UiUpdate, userData : *void);
    TriggerCallbackType :: #type (trigger : UiTrigger, userData : *void);

    Callback :: struct($CallbackType : Type) {
        function : CallbackType;
        userData : *void;
        flags : UiCallbackFlags;
    }

    Anchor :: enum {
        Center :: 0;
        Top; Bottom;
        Left; Right;
        TopLeft; TopRight;
        BottomLeft; BottomRight;
    }
}

UiCallbackFlags :: enum_flags {
    Hover;
    NoHover;    // Trigger only. @fixme We could send an update with the status, but it seems overkill.
    Child;      // @fixme Does not feel like our job.
    Click;      // Trigger only. Why trigger only?
    NoClick;    // Trigger only. Why trigger only?
    Key;        // Trigger only. Why trigger only?
    Text;       // Trigger only.
    Focus;      // Trigger only.
    NoFocus;    // Trigger only.
}

UiTrigger :: struct {
    flags : UiCallbackFlags;
    event : Crater.Event;
    stopPropagation : *bool;
}

UiUpdate :: struct {
    flags : UiCallbackFlags;
    stopPropagation : *bool;
}

component_init :: (iUi : *UiComponent) {
    ui_register_component(*iUi.entity.engine.ui, iUi);
}

component_cleanup :: (iUi : *UiComponent) {
    ui_unregister_component(*iUi.entity.engine.ui, iUi);
    Basic.array_reset(*iUi.updateCallbacks);
    Basic.array_reset(*iUi.triggerCallbacks);
}

component_update :: (iUi : *UiComponent, dt : float64) {
    if iUi.entity.childrenChanged {
        ui_send_update(iUi, .Child, null);
    }
}

ui_on_update :: (iUi : *UiComponent, function : (update : UiUpdate, userData : *$T), flags : UiCallbackFlags = 0xFF, userData : *T = null) {
    callback := Basic.array_add(*iUi.updateCallbacks);
    callback.function = cast(UiComponent.UpdateCallbackType)  function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_on_trigger :: (iUi : *UiComponent, function : (trigger : UiTrigger, userData : *$T), flags : UiCallbackFlags = 0xFF, userData : *T = null)
{
    callback := Basic.array_add(*iUi.triggerCallbacks);
    callback.function = cast(UiComponent.TriggerCallbackType) function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_check_hovered_handler :: (iUi : *UiComponent, function : (userData : *$T) -> bool, userData : *T = null) {
    iUi.checkHoveredHandler = cast(UiComponent.CheckHoveredHandlerType) function;
    iUi.checkHoveredHandlerUserData = userData;
}

ui_set_focused :: (iUi : *UiComponent, focused := true) {
    if focused {
        _ui_set_focused(*iUi.entity.engine.ui, iUi);
    } else {
        _ui_set_focused(*iUi.entity.engine.ui, null);
    }
}

ui_send_trigger :: (iUi : *UiComponent, flags : UiCallbackFlags, event : Crater.Event, stopPropagation : *bool) {
    trigger : UiTrigger = ---;
    trigger.flags = flags;
    trigger.event = event;
    trigger.stopPropagation = stopPropagation;
    for callback : iUi.triggerCallbacks {
        if callback.flags & flags {
            callback.function(trigger, callback.userData);
        }
    }
}

ui_send_update :: (iUi : *UiComponent, flags : UiCallbackFlags, stopPropagation : *bool) {
    update : UiUpdate = ---;
    update.flags = flags;
    update.stopPropagation = stopPropagation;
    for callback : iUi.updateCallbacks {
        if callback.flags & flags {
            callback.function(update, callback.userData);
        }
    }
}

ui_check_hovered :: (iUi : *UiComponent, position : Chamber.vec2, event : Crater.Event, stopPropagation : *bool) -> bool {
    if iUi.disabled then return false;

    // @todo No notion of flats and 2D in the engine for now.
    relativePosition : Chamber.vec3;
    relativePosition.xy = position;

    // Transform the position into the screen space.
    relativePosition.x -= iUi.entity.engine.options.windowExtent.width / 2.0; // @todo Should it depend on the renderer?
    relativePosition.y -= iUi.entity.engine.options.windowExtent.height / 2.0;

    unscaledTransform := iUi.transform.worldTransform;
    unscaledTransform.factor = 1.0;
    unscaledTransform = Chamber.inverse(unscaledTransform);

    relativePosition = Chamber.multiply(unscaledTransform, relativePosition);
    iUi.relativeMousePointerPosition.std = relativePosition.xy;

    // Make the hover check as if it was a center anchor.
    if iUi.anchor == {
        case .Left;         relativePosition.x -= iUi.extent.x / 2.0;
        case .Right;        relativePosition.x += iUi.extent.x / 2.0;
        case .Top;          relativePosition.y -= iUi.extent.y / 2.0;
        case .Bottom;       relativePosition.y += iUi.extent.y / 2.0;
        case .TopLeft;      relativePosition.x -= iUi.extent.x / 2.0; relativePosition.y -= iUi.extent.y / 2.0;
        case .TopRight;     relativePosition.x += iUi.extent.x / 2.0; relativePosition.y -= iUi.extent.y / 2.0;
        case .BottomLeft;   relativePosition.x -= iUi.extent.x / 2.0; relativePosition.y += iUi.extent.y / 2.0;
        case .BottomRight;  relativePosition.x += iUi.extent.x / 2.0; relativePosition.y += iUi.extent.y / 2.0;
    }

    hovered := relativePosition.x >= -iUi.extent.x / 2.0 &&
               relativePosition.x <  iUi.extent.x / 2.0 &&
               relativePosition.y >= -iUi.extent.y / 2.0 &&
               relativePosition.y <  iUi.extent.y / 2.0;

    if hovered && iUi.checkHoveredHandler != null {
        hovered = iUi.checkHoveredHandler(iUi.checkHoveredHandlerUserData);
    }

    if hovered {
        ui_send_update(iUi, .Hover, stopPropagation);
    }

    return hovered;
}
