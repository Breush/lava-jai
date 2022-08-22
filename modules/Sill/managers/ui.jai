#scope_module

Ui :: struct {
    uiComponents : [..]*UiComponent;

    focusedUiComponent : *UiComponent;
    hoveredUiComponents : [..]*UiComponent;
    draggedUiComponents : [..]*UiComponent;

    draggingState : DraggingState;
    draggingMouseButton : Crater.MouseButton;

    setFocusedLocked : bool;
    focusedUiComponentDuringLock : *UiComponent;

    mousePointerPosition : Chamber.vec2;

    componentsDepthDirty : bool;
}

DraggingState :: enum {
    None :: 0;
    Pending; // Button is pressed, mouse has not moved yet.
    Moving;  // Button is pressed, mouse has moved.
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
    Basic.array_free(ui.draggedUiComponents);
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
        _update_dragged_ui_components(ui, event, stopPropagation);
        if ui.draggingState == .Moving then return;
        _update_hovered_ui_components(ui, event, stopPropagation);
    } else if event.kind == .MouseButtonPressed {
        if ui.draggingState != .None then return;

        // @note Will go in dragging state only if at least one the hovered component
        // is draggable.
        ui.draggingMouseButton = event.mouseButton.which;
        ui.draggedUiComponents.count = 0;
        for uiComponent : ui.hoveredUiComponents {
            if !uiComponent.draggable then continue;
            ui.draggingState = .Pending;
            Basic.array_add(*ui.draggedUiComponents, uiComponent);
        }
    } else if event.kind == .MouseButtonReleased {
        wasDragging := ui.draggingState == .Moving;
        if ui.draggingState != .None {
            if ui.draggingMouseButton != event.mouseButton.which then return;
            ui.draggingState = .None;
        }

        if wasDragging {
            for uiComponent : ui.draggedUiComponents {
                ui_send_trigger(uiComponent, .NoDrag, event, stopPropagation);
                if <<stopPropagation then break;
            }
            _update_hovered_ui_components(ui, event, stopPropagation);
            return;
        }

        _ui_lock_set_focused(ui);
        for uiComponent : ui.hoveredUiComponents {
            ui_send_trigger(uiComponent, .Click, event, stopPropagation);
            if <<stopPropagation then break;
        }
        _ui_lock_set_focused(ui, false);
        _ui_do_set_focused(ui, ui.focusedUiComponentDuringLock);
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
    if !ui.setFocusedLocked {
        _ui_do_set_focused(ui, uiComponent);
    } else {
        ui.focusedUiComponentDuringLock = uiComponent;
    }
}

#scope_file

_update_dragged_ui_components :: (ui : *Ui, event : Crater.Event, stopPropagation : *bool) {
    if ui.draggingState == .Pending {
        ui.draggingState = .Moving;
        for uiComponent : ui.draggedUiComponents {
            ui_send_trigger(uiComponent, .Drag, event, stopPropagation);
            if <<stopPropagation then break;
        }
    }

    if ui.draggingState == .Moving {
        for uiComponent : ui.draggedUiComponents {
            ui_send_trigger(uiComponent, .Dragging, event, stopPropagation);
            if <<stopPropagation then break;
        }
    }
}

// Check if we're hovering anything
// @note Will update all hovered components,
// setting false to no-more hovered and keeping true
// if already hovered.
_update_hovered_ui_components :: (ui : *Ui, event : Crater.Event, stopPropagation : *bool) {
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
}

_ui_lock_set_focused :: (ui : *Ui, locked := true) {
    ui.setFocusedLocked = locked;
    if ui.setFocusedLocked then ui.focusedUiComponentDuringLock = null;
}

_ui_do_set_focused :: (ui : *Ui, uiComponent : *UiComponent) {
    if ui.focusedUiComponent == uiComponent then return;

    stopPropagation : bool;
    if ui.focusedUiComponent then ui_send_trigger(ui.focusedUiComponent, .NoFocus, .{}, *stopPropagation);
    ui.focusedUiComponent = uiComponent;
    if ui.focusedUiComponent then ui_send_trigger(ui.focusedUiComponent, .Focus, .{}, *stopPropagation);
}