Input :: struct {
    // @todo Better have keys designated as u32? (Compile-time hash of strings?)
    actions : Table(string, Action);
    axes : Table(string, Axis);

    keyStates : [#run type_info(Crater.Key).values.count]bool;

    Action :: struct {
        changed : bool;             // Action was updated since last reset.
        previousActiveness : u8;    // Activess at the last reset.
        activeness : u8;            // How many buttons/keys are currently down.
        keys : [..]Crater.Key;      // @todo These are "OR". But we will need to express "AND" somehow.
        triggers : [..]Trigger;

        Trigger :: struct {
            kind : VrTriggerKind;
            lastChangeTime : s64;
        };
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

    VrTriggerKind :: enum {
        LeftHandSelect;
        RightHandSelect;
    }
}

input_state :: (input : *Input, key : Crater.Key) -> bool {
    return input.keyStates[key];
}

input_action_bind :: (input : *Input, actionName : string, key : Crater.Key) {
    action := Chamber.table_find_or_add(*input.actions, actionName);
    Basic.array_add_if_unique(*action.keys, key);
}

input_action_bind :: (input : *Input, actionName : string, triggerKind : Input.VrTriggerKind) {
    action := Chamber.table_find_or_add(*input.actions, actionName);
    trigger : Input.Action.Trigger;
    trigger.kind = triggerKind;
    Basic.array_add(*action.triggers, trigger); // @todo operator== overload does not work for some reason, so no unique check.
}

input_action_active :: (input : *Input, actionName : string) -> bool {
    action := table_find_pointer(input.actions, actionName);
    if action == null then return false;
    return action.activeness != 0;
}

// Set alsoOnChanged to true to detect auto repeat for the OS.
input_action_just_activated :: (input : *Input, actionName : string, alsoOnChanged := false) -> bool {
    action := table_find_pointer(input.actions, actionName);
    if action == null then return false;
    if action.activeness == 0 then return false;
    if alsoOnChanged && action.changed then return true;
    return action.previousActiveness == 0;
}

input_axis_bind :: (input : *Input, axisName : string, kind : Input.AxisKind) {
    axis := Chamber.table_find_or_add(*input.axes, axisName);
    Basic.array_add_if_unique(*axis.kinds, kind);
}

input_axis_unbind :: (input : *Input, axisName : string) {
    Hash.table_remove(*input.axes, axisName);
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
        Basic.array_free(action.triggers);
    }
    for *axis : input.axes {
        Basic.array_free(axis.kinds);
    }

    uninit(*input.actions);
    uninit(*input.axes);
}

_input_reset :: (input : *Input) {
    for *action : input.actions {
        action.previousActiveness = action.activeness;
        action.changed = false;
    }
    for *axis : input.axes {
        axis.value = 0.;
    }
}

_input_handle_event :: (input : *Input, event : Crater.Event) {
    if event.kind == .KeyPressed {
        input.keyStates[event.key.which] = true;
        for *action : input.actions {
            keyFound, _ := Basic.array_find(action.keys, event.key.which);
            if keyFound {
                action.changed = true;
                action.activeness += 1;
            }
        }
    }
    else if event.kind == .KeyReleased {
        for *action : input.actions {
            input.keyStates[event.key.which] = false;
            if action.activeness == 0 then continue;
            keyFound, _ := Basic.array_find(action.keys, event.key.which);
            if keyFound {
                action.changed = true;
                action.activeness -= 1;
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

#if VR_ENABLED {
_input_handle_vr_events :: (input : *Input, vrTarget : *Magma.VrTarget) {
    // @fixme There might be a latent bug here.
    // As VR updates are done during render(), a very fast "select" might
    // change selectActionState.lastChangeTime but have the same currentState
    // as before. Therefore, dropping the activeness to an non-reparable status.

    for *action : input.actions {
        for *trigger : action.triggers {
            if trigger.kind == .LeftHandSelect {
                selectActionState := *vrTarget.handInfos[0].selectActionState;
                if selectActionState.lastChangeTime > 0 &&
                   trigger.lastChangeTime != selectActionState.lastChangeTime {
                    trigger.lastChangeTime = selectActionState.lastChangeTime;
                    if selectActionState.currentState == 1. {
                        action.activeness += 1;
                    } else {
                        action.activeness -= 1;
                    }
                }
            } else if trigger.kind == .RightHandSelect {
                selectActionState := *vrTarget.handInfos[1].selectActionState;
                if selectActionState.lastChangeTime > 0 &&
                   trigger.lastChangeTime != selectActionState.lastChangeTime {
                    trigger.lastChangeTime = selectActionState.lastChangeTime;
                    if selectActionState.currentState == 1. {
                        action.activeness += 1;
                    } else {
                        action.activeness -= 1;
                    }
                }
            }
        }
    }
}
}
