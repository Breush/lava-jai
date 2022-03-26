UiComponent :: struct {
    using component : Component;
    transform : *TransformComponent;

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

    UpdateCallbackType :: #type (flags : CallbackFlags, userData : *void);
    TriggerCallbackType :: #type (flags : CallbackFlags, event : Crater.Event, stopPropagation : *bool, userData : *void);

    CallbackFlags :: enum_flags {
        Hover;
        NoHover;
        Click;      // Trigger only.
        NoClick;    // Trigger only.
        Key;        // Trigger only.
        Text;       // Trigger only.
    }

    Callback :: struct($CallbackType : Type) {
        function : CallbackType;
        userData : *void;
        flags : CallbackFlags;
    }

    Anchor :: enum {
        Center :: 0;
        Top; Bottom;
        Left; Right;
        TopLeft; TopRight;
        BottomLeft; BottomRight;
    }
}

component_init :: (iUi : *UiComponent) {
    ui_register_component(*iUi.entity.engine.ui, iUi);
}

component_cleanup :: (iUi : *UiComponent) {
}

component_update :: (iUi : *UiComponent, dt : float64) {
}

ui_on_update :: (iUi : *UiComponent, function : UiComponent.UpdateCallbackType, flags : UiComponent.CallbackFlags = 0xFF, userData : *void = null) {
    Basic.array_add(*iUi.updateCallbacks, .{});
    callback := Basic.peek_pointer(iUi.updateCallbacks);
    callback.function = function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_on_trigger :: (iUi : *UiComponent, function : UiComponent.TriggerCallbackType, flags : UiComponent.CallbackFlags = 0xFF, userData : *void = null) {
    Basic.array_add(*iUi.triggerCallbacks, .{});
    callback := Basic.peek_pointer(iUi.triggerCallbacks);
    callback.function = function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_set_focused :: (iUi : *UiComponent) {
    _ui_set_focused(*iUi.entity.engine.ui, iUi);
}

ui_trigger :: (iUi : *UiComponent, flag : UiComponent.CallbackFlags, event : Crater.Event, stopPropagation : *bool) {
    for callback : iUi.triggerCallbacks {
        if callback.flags & flag {
            callback.function(flag, event, stopPropagation, callback.userData);
        }
    }
}

ui_check_hovered :: (iUi : *UiComponent, position : Chamber.vec2, event := Crater.Event.{}, stopPropagation : *bool) -> bool {
    // @todo No notion of anchor here, we assume it is always centered.

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

    if iUi.hovered != hovered {
        iUi.hovered = hovered;
        flags := ifx hovered then UiComponent.CallbackFlags.Hover else .NoHover;
        for callback : iUi.triggerCallbacks {
            if callback.flags & flags {
                callback.function(flags, event, stopPropagation, callback.userData);
            }
        }
    }

    for callback : iUi.updateCallbacks {
        if hovered && callback.flags & .Hover {
            callback.function(.Hover, callback.userData);
        } else if !hovered && callback.flags & .NoHover {
            callback.function(.NoHover, callback.userData);
        }
    }

    return iUi.hovered;
}
