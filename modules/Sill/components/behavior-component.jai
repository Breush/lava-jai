BehaviorComponent :: struct {
    using #as component : Component;

    updateCallbacks : [..]struct {
        function : UpdateCallbackType;
        userData : *void;
    };

    UpdateCallbackType :: #type (dt : float64, userData : *void);
}

component_init :: (iBehavior : *BehaviorComponent) {
    // Nothing to do
}

component_cleanup :: (iBehavior : *BehaviorComponent, resetMemory := true) {
    Basic.array_free(iBehavior.updateCallbacks);

    if resetMemory {
        iBehavior.* = BehaviorComponent.{};
    }
}

component_update :: (iBehavior : *BehaviorComponent, dt : float64) {
    for callback : iBehavior.updateCallbacks {
        callback.function(dt,  callback.userData);
    }
}

behavior_on_update :: (iBehavior : *BehaviorComponent, function : (dt : float64, userData : *T), userData : *$T) {
    Basic.array_add(*iBehavior.updateCallbacks, .{});
    callback := Basic.peek_pointer(iBehavior.updateCallbacks);
    callback.function = xx function;
    callback.userData = userData;
}
