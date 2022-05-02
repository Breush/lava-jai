UiComponent :: struct {
    using component : Component;
    transform : *TransformComponent; // @todo Should be used to mark componentsDepthDirty

    // Main configuration.
    anchor := Anchor.Center;
    extent := Chamber.vec2.{1, 1}; // Renderered extent, after all transform applied.

    // Updated each input.
    hovered : bool;
    relativeMousePointerPosition : Chamber.vec2;

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
    NoHover;
    Child;
    Click;      // Trigger only. Why trigger only?
    NoClick;    // Trigger only. Why trigger only?
    Key;        // Trigger only. Why trigger only?
    Text;       // Trigger only.
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

ui_set_focused :: (iUi : *UiComponent) {
    _ui_set_focused(*iUi.entity.engine.ui, iUi);
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
    // @todo No notion of flats and 2D in the engine for now.
    relativePosition : Chamber.vec3;
    relativePosition.xy = position;

    // Transform the position into the screen space.
    relativePosition.x -= iUi.entity.engine.windowExtent.width / 2.0; // @todo Should it depend on the renderer?
    relativePosition.y -= iUi.entity.engine.windowExtent.height / 2.0;

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
               relativePosition.x <=  iUi.extent.x / 2.0 &&
               relativePosition.y >= -iUi.extent.y / 2.0 &&
               relativePosition.y <=  iUi.extent.y / 2.0;

    // @fixme That's getting messy... We're triggering unhovered above.
    if iUi.hovered != hovered {
        iUi.hovered = hovered;
        flags := ifx hovered then UiCallbackFlags.Hover else .NoHover;
        ui_send_trigger(iUi, flags, event, stopPropagation);
    }

    if hovered {
        ui_send_update(iUi, .Hover, stopPropagation);
    } else {
        ui_send_update(iUi, .NoHover, stopPropagation);
    }

    return iUi.hovered;
}
