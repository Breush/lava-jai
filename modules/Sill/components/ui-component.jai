UiComponent :: struct {
    using component : Component;
    transform : *TransformComponent;

    // Main configuration.
    extent := Chamber.vec2.{1, 1}; // Renderered extent, after all transform applied.

    // Custom configuration for
    hoveringOffset : Chamber.vec2;
    hoveringExtent := Chamber.vec2.{1, 1};

    // Updated each input.
    hovered : bool;
    relativeMousePointerPosition : Chamber.vec2;

    // Updates are called after each user inputs.
    // While trigger callbacks are called when it changes.
    updateCallbacks : [..]Callback(UpdateCallbackType);
    triggerCallbacks : [..]Callback(TriggerCallbackType);

    UpdateCallbackType :: #type (flags : CallbackFlags, userData : *void);
    TriggerCallbackType :: #type (flags : CallbackFlags, userData : *void);

    CallbackFlags :: enum_flags {
        Hover;
        NoHover;
    }

    Callback :: struct($CallbackType : Type) {
        function : CallbackType;
        userData : *void;
        flags : CallbackFlags;
    };
}

component_init :: (iUi : *UiComponent) {
    ui_register_component(*iUi.entity.engine.ui, iUi);
}

component_cleanup :: (iUi : *UiComponent) {
}

component_update :: (iUi : *UiComponent, dt : float64) {
}

ui_extent :: (iUi : *UiComponent, _extent : Chamber.vec2) {
    iUi.extent = _extent;
    iUi.hoveringExtent = _extent; // @todo Currently not really use.
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

ui_check_hovered :: (iUi : *UiComponent, position : Chamber.vec2) -> bool {
    // @todo No notion of anchor here, we assume it is always centered.

    // @todo No notion of flats and 2D in the engine for now.
    relativePosition : Chamber.vec3;
    relativePosition.xy = position - iUi.hoveringOffset;

    // Transform the position into the screen space.
    relativePosition.x -= iUi.entity.engine.windowExtent.width / 2.0; // @todo Should it depend on the renderer?
    relativePosition.y -= iUi.entity.engine.windowExtent.height / 2.0;

    unscaledTransform := iUi.transform.worldTransform;
    unscaledTransform.factor = 1.0;
    unscaledTransform = Chamber.inverse(unscaledTransform);

    relativePosition = Chamber.multiply(unscaledTransform, relativePosition);
    hovered := relativePosition.x >= -iUi.hoveringExtent.x / 2.0 &&
               relativePosition.x <=  iUi.hoveringExtent.x / 2.0 &&
               relativePosition.y >= -iUi.hoveringExtent.y / 2.0 &&
               relativePosition.y <=  iUi.hoveringExtent.y / 2.0;

    iUi.relativeMousePointerPosition.std = relativePosition.xy;

    if iUi.hovered != hovered {
        iUi.hovered = hovered;
        flags := ifx hovered then UiComponent.CallbackFlags.Hover else .NoHover;
        for callback : iUi.triggerCallbacks {
            if callback.flags & flags {
                callback.function(flags, callback.userData);
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
