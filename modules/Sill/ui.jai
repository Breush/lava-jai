#scope_module

Ui :: struct {
    uiComponents : [..]*UiComponent;

    hoveredUiComponents : [..]*UiComponent;

    mousePointerPosition : Chamber.vec2;
}

ui_register_component :: (ui : *Ui, uiComponent : *UiComponent) {
    Basic.array_add(*ui.uiComponents, uiComponent);
}

_ui_handle_event :: (ui : *Ui, event : Crater.Event) {
    if (event.kind == .MousePointerMoved) {
        ui.mousePointerPosition.x = cast(float) event.mousePointer.x;
        ui.mousePointerPosition.y = cast(float) event.mousePointer.y;

        // @todo Handle dragging.

        // Check if we're hovering anything
        // @note Will update all hovered components,
        // setting false to no-more hovered and keeping true
        // if already hovered.
        ui.hoveredUiComponents.count = 0;
        for uiComponent : ui.uiComponents {
            if ui_check_hovered(uiComponent, ui.mousePointerPosition) {
                Basic.array_add(*ui.hoveredUiComponents, uiComponent);
            }
        }
    }
}
