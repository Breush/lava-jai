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

    CheckHoveredHandlerType :: #type (hovered : bool, userData : *void) -> bool;
    TriggerCallbackType :: #type (trigger : UiTrigger, userData : *void);
    triggerCallbacks : [..]Callback(TriggerCallbackType);

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
    Child;      // @fixme Does not feel like our job.
}

UiTrigger :: struct {
    flags : UiCallbackFlags;
    event : Crater.Event;
    stopPropagation : *bool;
}

component_init :: (iUi : *UiComponent) {
    ui_register_component(iUi.entity.engine, iUi);
}

component_cleanup :: (iUi : *UiComponent) {
    ui_unregister_component(iUi.entity.engine, iUi);
    Basic.array_reset(*iUi.triggerCallbacks);
}

component_update :: (iUi : *UiComponent, dt : float64) {
    if iUi.entity.childrenChanged {
        ui_send_trigger(iUi, .Child, .{}, null);
    }
}

ui_on_trigger :: (iUi : *UiComponent, function : (trigger : UiTrigger, userData : *$T), flags : UiCallbackFlags = 0xFF, userData : *T = null)
{
    callback := Basic.array_add(*iUi.triggerCallbacks);
    callback.function = cast(UiComponent.TriggerCallbackType) function;
    callback.flags = flags;
    callback.userData = userData;
}

ui_check_hovered_handler :: (iUi : *UiComponent, function : (hovered : bool, userData : *$T) -> bool, userData : *T = null) {
    iUi.checkHoveredHandler = cast(UiComponent.CheckHoveredHandlerType) function;
    iUi.checkHoveredHandlerUserData = userData;
}

ui_set_focused :: (iUi : *UiComponent, focused := true) {
    if focused {
        _ui_set_focused(iUi.entity.engine, iUi);
    } else {
        _ui_set_focused(iUi.entity.engine, null);
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

ui_relative_mouse_pointer_position :: (iUi : *UiComponent) -> Chamber.vec2 {
    relativePosition : Chamber.vec3;
    relativePosition.x = cast(float) iUi.entity.engine.window.mousePosition.x;
    relativePosition.y = cast(float) iUi.entity.engine.window.mousePosition.y;

    // Transform the position into the screen space.
    relativePosition.x -= iUi.entity.engine.options.windowExtent.width / 2.0; // @todo Should it depend on the renderer?
    relativePosition.y -= iUi.entity.engine.options.windowExtent.height / 2.0;

    inverseTransform := iUi.transform.worldTransform;
    inverseTransform = Chamber.inverse(inverseTransform);
    relativePosition = Chamber.multiply(inverseTransform, relativePosition);
    return relativePosition.xy;
}

ui_check_hovered :: (iUi : *UiComponent, position : Chamber.vec2, event : Crater.Event, stopPropagation : *bool) -> bool {
    if iUi.entity.disabled || iUi.disabled then return false;

    relativePosition := ui_relative_mouse_pointer_position(iUi);

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

    if iUi.checkHoveredHandler != null {
        hovered = iUi.checkHoveredHandler(hovered, iUi.checkHoveredHandlerUserData);
    }

    if hovered {
        ui_send_trigger(iUi, .Hovering, event, stopPropagation);
    }

    return hovered;
}
