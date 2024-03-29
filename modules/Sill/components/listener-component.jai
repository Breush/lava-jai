// All entities having a listener component will
// be notified when engine.send() is called.
ListenerComponent :: struct {
    using #as component : Component;

    MessageCallbackType :: #type (entity : *Entity, message : *void);
    messageCallbacks : [..]MessageCallbackType;
}

component_init :: (iListener : *ListenerComponent) {
    message_register_component(*iListener.entity.engine.message, iListener);
}

component_cleanup :: (iListener : *ListenerComponent, resetMemory := true) {
    message_unregister_component(*iListener.entity.engine.message, iListener);
    Basic.array_reset(*iListener.messageCallbacks);
    if resetMemory {
        iListener.* = .{};
    }
}

component_update :: (iListener : *ListenerComponent, dt : float64) {
}

listener_on_message :: (iListener : *ListenerComponent, function : (entity : *$E, userData : *$T))
#modify {
    // Check that the entity does inherit.
    typeInfo := cast(*Type_Info_Struct) E;
    if typeInfo == type_info(Entity) then return true;
    if typeInfo.type != .STRUCT then return false, "First argument of callback must be a struct.";
    if typeInfo.members.count == 0 then return false, "First argument of callback must have at least one member.";
    if typeInfo.members[0].type != type_info(Entity) then return false, "First argument of callback must be an Entity.";
    return true;
}
{
    Basic.array_add(*iListener.messageCallbacks, xx function);
}

listener_forward_message :: (iListener : *ListenerComponent, message : *void) {
    for callback : iListener.messageCallbacks {
        callback(iListener.entity, message);
    }
}
