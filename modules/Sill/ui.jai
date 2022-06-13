#scope_module

Ui :: struct {
    uiComponents : [..]*UiComponent;

    focusedUiComponent : *UiComponent;
    hoveredUiComponents : [..]*UiComponent;

    mousePointerPosition : Chamber.vec2;

    componentsDepthDirty : bool;
}

ui_register_component :: (ui : *Ui, uiComponent : *UiComponent) {
    Basic.array_add(*ui.uiComponents, uiComponent);
    ui.componentsDepthDirty = true;
}

ui_unregister_component :: (ui : *Ui, uiComponent : *UiComponent) {
    // An unregistred UI component that was hovered should call the no-hover callback.
    if uiComponent.hovered {
        stopPropagation : bool;
        uiComponent.hovered = false;
        ui_send_update(uiComponent, UiCallbackFlags.NoHover, *stopPropagation);
        ui_send_trigger(uiComponent, UiCallbackFlags.NoHover, .{}, *stopPropagation);
    }

    Basic.array_unordered_remove_by_value(*ui.uiComponents, uiComponent, stop_after_first = true);
}

_ui_cleanup :: (ui : *Ui) {
    Basic.array_free(ui.uiComponents);
    Basic.array_free(ui.hoveredUiComponents);
}

_ui_update :: (ui : *Ui) {
    if ui.componentsDepthDirty {
        ui.componentsDepthDirty = false;

        Sort.quick_sort(ui.uiComponents, (a : *UiComponent, b : *UiComponent) -> int {
            if a.transform.translation.z < b.transform.translation.z then return -1;
            if a.transform.translation.z > b.transform.translation.z then return 1;
            return 0;
        });
    }
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
        oldHoveredUiComponents : [..]*UiComponent;
        oldHoveredUiComponents.allocator = Basic.temp;
        Basic.array_copy(*oldHoveredUiComponents, ui.hoveredUiComponents);

        ui.hoveredUiComponents.count = 0;
        for uiComponent : ui.uiComponents {
            if ui_check_hovered(uiComponent, ui.mousePointerPosition, event, stopPropagation) {
                Basic.array_add(*ui.hoveredUiComponents, uiComponent);
            }
            if <<stopPropagation then break;
        }

        // Triggering no-hover + hover callbacks.
        // We want no-hover first.
        for uiComponent : oldHoveredUiComponents {
            if Basic.array_find(ui.hoveredUiComponents, uiComponent) then continue;
            uiComponent.hovered = false;
            ui_send_trigger(uiComponent, .NoHover, event, stopPropagation);
        }
        for uiComponent : ui.hoveredUiComponents {
            if uiComponent.hovered then continue;
            uiComponent.hovered = true;
            ui_send_trigger(uiComponent, .Hover, event, stopPropagation);
        }
    } else if event.kind == .MouseButtonPressed {
        ui.focusedUiComponent = null;
        for uiComponent : ui.hoveredUiComponents {
            ui_send_trigger(uiComponent, .Click, event, stopPropagation);
            if <<stopPropagation then break;
        }
    } else if event.kind == .TextEntered {
        if ui.focusedUiComponent {
            ui_send_trigger(ui.focusedUiComponent, .Text, event, stopPropagation);
        }
    } else if event.kind == .KeyPressed {
        if ui.focusedUiComponent {
            ui_send_trigger(ui.focusedUiComponent, .Key, event, stopPropagation);
        }
    }
}

_ui_set_focused :: (ui : *Ui, uiComponent : *UiComponent) {
    ui.focusedUiComponent = uiComponent;
}
