UiComponent :: struct {
    using #as component : Component;
    transform : *TransformComponent; // @todo Should be used to mark componentsDepthDirty

    // Main configuration.
    anchor := Anchor.Center;
    extent := Chamber.vec2.{1, 1}; // Renderered extent, after all transform applied.
    disabled := false;
    draggable := false;

    // Updated each input.
    hovered : bool;

    // Handlers allow to customize the default behaviors.
    // - checkHoveredHandler is always called, with the evaluation of whenever the entity is considered hovered or not.
    //   One can use ui_relative_mouse_pointer_position() to get the mouse position within the entity.
    //   One can therefore return whether it is really hovered or not.
    checkHoveredHandler : CheckHoveredHandlerType;
    checkHoveredHandlerUserData : *void;

    CheckHoveredHandlerType :: #type (hovered : bool, relativeMousePointerPosition : Chamber.vec2, userData : *void) -> bool;
    TriggerCallbackType :: #type (trigger : UiTrigger, userData : *void);
    triggerCallbacks : [..]Callback(TriggerCallbackType);

    Callback :: struct($CallbackType : Type) {
        function : CallbackType;
        userData : *void;
        flags : UiCallbackFlags;
    }
}

UiCallbackFlags :: enum_flags u16 {
    HoverStart;
    Hovering;
    HoverStop;
    ClickStart; // Next event related to the mouse button is either a ClickStop or a DragStart.
    ClickStop;  // Emitted while released a mouse button, when an element is draggable, this occurs only if the user did not move the mouse since the ClickStart.
    Key;
    Text;
    FocusStart;
    FocusStop;
    DragStart;  // User started moving the mouse while holding a click on a draggable ui-component.
    Dragging;   // On each mouse move after a DragStart and before a DragStop.
    DragDrop;   // User dropped the draggable element that was dragged. Always called before DragStop.
    DragStop;   // User stopped dragging, either by canceling it with another mouse button or by dropping.
    Scrolling;
    MousePasting;

    Stop :: HoverStop | ClickStop | FocusStop | DragStop;
}

UiTrigger :: struct {
    flags : UiCallbackFlags;
    event : Crater.Event;
    stopPropagation : *bool;
}

component_init :: (iUi : *UiComponent) {
    ui_register_component(*iUi.entity.engine.ui, iUi);
}

component_cleanup :: (iUi : *UiComponent) {
    ui_unregister_component(*iUi.entity.engine.ui, iUi);
    Basic.array_reset(*iUi.triggerCallbacks);
}

component_update :: (iUi : *UiComponent, dt : float64) {
    if iUi.entity.flags & .DisabledChanged {
        _ui_set_hovered_components_dirty(*iUi.entity.engine.ui);
    }
}

ui_on_trigger :: (iUi : *UiComponent, function : (trigger : UiTrigger, userData : *$T), flags : UiCallbackFlags = 0xFFFF, userData : *T = null) {
    callback := Basic.array_add(*iUi.triggerCallbacks);
    callback.function = cast(UiComponent.TriggerCallbackType) function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_check_hovered_handler :: (iUi : *UiComponent, function : (hovered : bool, relativeMousePointerPosition : Chamber.vec2, userData : *$T) -> bool, userData : *T = null) {
    iUi.checkHoveredHandler = cast(UiComponent.CheckHoveredHandlerType) function;
    iUi.checkHoveredHandlerUserData = userData;
    _ui_set_hovered_components_dirty(*iUi.entity.engine.ui);
}

ui_set_focused :: (iUi : *UiComponent, focused := true) {
    if focused {
        _ui_set_focused(*iUi.entity.engine.ui, iUi);
    } else {
        _ui_set_focused(*iUi.entity.engine.ui, null);
    }
}

ui_send_trigger :: (iUi : *UiComponent, flags : UiCallbackFlags, event : Crater.Event, stopPropagation : *bool) {
    // When an entity is disabled, just send the stop events.
    if iUi.entity.flags & .Disabled || iUi.disabled {
        flags &= UiCallbackFlags.Stop;
    }

    if flags == 0 then return;

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

ui_relative_mouse_pointer_position :: (iUi : *UiComponent) -> Chamber.vec2 {
    relativePosition : Chamber.vec3;
    relativePosition.x = cast(float) iUi.entity.engine.window.mousePosition.x;
    relativePosition.y = cast(float) iUi.entity.engine.window.mousePosition.y;

    // Note: We consider the screen to start on the top-left,
    // thus reflecting that in-world.

    inverseTransform := iUi.transform.worldTransform;
    inverseTransform = Chamber.inverse(inverseTransform);
    relativePosition = Chamber.multiply(inverseTransform, relativePosition);
    return relativePosition.xy;
}

ui_check_hovered :: (iUi : *UiComponent, event : Crater.Event) -> bool {
    if iUi.entity.flags & .Disabled || iUi.disabled then return false;

    relativePosition := ui_relative_mouse_pointer_position(iUi);
    centeredRelativePosition := relativePosition;

    // Make the hover check as if it was a center anchor.
    if iUi.anchor == {
        case .Left;         centeredRelativePosition.x -= iUi.extent.x / 2.0;
        case .Right;        centeredRelativePosition.x += iUi.extent.x / 2.0;
        case .Top;          centeredRelativePosition.y -= iUi.extent.y / 2.0;
        case .Bottom;       centeredRelativePosition.y += iUi.extent.y / 2.0;
        case .TopLeft;      centeredRelativePosition.x -= iUi.extent.x / 2.0; centeredRelativePosition.y -= iUi.extent.y / 2.0;
        case .TopRight;     centeredRelativePosition.x += iUi.extent.x / 2.0; centeredRelativePosition.y -= iUi.extent.y / 2.0;
        case .BottomLeft;   centeredRelativePosition.x -= iUi.extent.x / 2.0; centeredRelativePosition.y += iUi.extent.y / 2.0;
        case .BottomRight;  centeredRelativePosition.x += iUi.extent.x / 2.0; centeredRelativePosition.y += iUi.extent.y / 2.0;
    }

    hovered := centeredRelativePosition.x >= -iUi.extent.x / 2.0 &&
               centeredRelativePosition.x <  iUi.extent.x / 2.0 &&
               centeredRelativePosition.y >= -iUi.extent.y / 2.0 &&
               centeredRelativePosition.y <  iUi.extent.y / 2.0;

    if iUi.checkHoveredHandler != null {
        hovered = iUi.checkHoveredHandler(hovered, relativePosition, iUi.checkHoveredHandlerUserData);
    }

    return hovered;
}
