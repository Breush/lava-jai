Input :: struct {
    // @todo Better have keys designated as u32? (Compile-time hash of strings?)
    actions : Table(string, Action);
    axes : Table(string, Axis);

    Action :: struct {
        activeness : u8; // How many buttons/keys are currently down.
        keys : [..]Crater.Key; // @todo These are "OR". But we will need to express "AND" somehow.
    };

    Axis :: struct {
        value : float32;
        kinds : [..]AxisKind;
    }

    AxisKind :: enum {
        Unknown;
        MousePointerX;
        MousePointerY;
        // MouseWheelX; @todo Not yet implemented
        MouseWheelY; // Classical mouse wheel
    }
}

input_action_bind :: (input : *Input, actionName : string, key : Crater.Key) {
    action := Chamber.table_find_or_add(*input.actions, actionName);
    Basic.array_add_if_unique(*action.keys, key);
}

input_action_active :: (input : *Input, actionName : string) -> bool {
    action := table_find_pointer(input.actions, actionName);
    if action == null then return false;
    return action.activeness != 0;
}

input_axis_bind :: (input : *Input, axisName : string, kind : Input.AxisKind) {
    axis := Chamber.table_find_or_add(*input.axes, axisName);
    Basic.array_add_if_unique(*axis.kinds, kind);
}

input_axis_changed :: (input : *Input, axisName : string) -> bool {
    axis := table_find_pointer(input.axes, axisName);
    if axis == null then return false;
    return axis.value != 0.;
}

// Will return 0. if axis has not changed.
input_axis_value :: (input : *Input, axisName : string) -> float32 {
    axis := table_find_pointer(input.axes, axisName);
    if axis == null then return 0.;
    return axis.value;
}

#scope_module

_input_cleanup :: (input : *Input) {
    for *action : input.actions {
        Basic.array_free(action.keys);
    }
    for *axis : input.axes {
        Basic.array_free(axis.kinds);
    }

    uninit(*input.actions);
    uninit(*input.axes);
}

_input_reset :: (input : *Input) {
    for *axis : input.axes {
        axis.value = 0.;
    }
}

_input_handle_event :: (input : *Input, event : Crater.Event) {
    if event.kind == .KeyPressed {
        for *action : input.actions {
            keyFound, _ := Basic.array_find(action.keys, event.key.which);
            if keyFound {
                action.activeness += 1;
                break;
            }
        }
    }
    else if event.kind == .KeyReleased {
        for *action : input.actions {
            if action.activeness == 0 then continue;
            keyFound, _ := Basic.array_find(action.keys, event.key.which);
            if keyFound {
                action.activeness -= 1;
                break;
            }
        }
    }
    else if event.kind == .MousePointerMoved {
        for *axis : input.axes {
            for kind : axis.kinds {
                if kind == .MousePointerX {
                    axis.value += event.mousePointer.dx;
                } else if kind == .MousePointerY {
                    axis.value += event.mousePointer.dy;
                }
            }
        }
    }
    else if event.kind == .MouseWheelScrolled {
        for *axis : input.axes {
            for kind : axis.kinds {
                if kind == .MouseWheelY {
                    axis.value += event.mouseWheel.dy;
                }
            }
        }
    }
}
