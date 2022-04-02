#scope_module

Ui :: struct {
    uiComponents : [..]*UiComponent;

    focusedUiComponent : *UiComponent;
    hoveredUiComponents : [..]*UiComponent;

    mousePointerPosition : Chamber.vec2;
}

ui_register_component :: (ui : *Ui, uiComponent : *UiComponent) {
    Basic.array_add(*ui.uiComponents, uiComponent);
}

ui_unregister_component :: (ui : *Ui, uiComponent : *UiComponent) {
    Basic.array_unordered_remove_by_value(*ui.uiComponents, uiComponent, stop_after_first = true);
}

_ui_handle_event :: (ui : *Ui, event : Crater.Event, stopPropagation : *bool) {
    if event.kind == .MousePointerMoved {
        ui.mousePointerPosition.x = cast(float) event.mousePointer.x;
        ui.mousePointerPosition.y = cast(float) event.mousePointer.y;

        // @todo Handle dragging.

        // Check if we're hovering anything
        // @note Will update all hovered components,
        // setting false to no-more hovered and keeping true
        // if already hovered.
        ui.hoveredUiComponents.count = 0; // @fixme Not warning them about being NoHover, this can be an issue, because we break.
        for uiComponent : ui.uiComponents {
            if ui_check_hovered(uiComponent, ui.mousePointerPosition, event, stopPropagation) {
                Basic.array_add(*ui.hoveredUiComponents, uiComponent);
            }
            if <<stopPropagation then break;
        }
    } else if event.kind == .MouseButtonPressed {
        ui.focusedUiComponent = null;
        for hoveredUiComponent : ui.hoveredUiComponents {
            ui_trigger(hoveredUiComponent, UiComponent.CallbackFlags.Click, event, stopPropagation);
        }
    } else if event.kind == .TextEntered {
        if ui.focusedUiComponent {
            ui_trigger(ui.focusedUiComponent, UiComponent.CallbackFlags.Text, event, stopPropagation);
        }
    } else if event.kind == .KeyPressed {
        if ui.focusedUiComponent {
            ui_trigger(ui.focusedUiComponent, UiComponent.CallbackFlags.Key, event, stopPropagation);
        }
    }
}

_ui_set_focused :: (ui : *Ui, uiComponent : *UiComponent) {
    ui.focusedUiComponent = uiComponent;
}
