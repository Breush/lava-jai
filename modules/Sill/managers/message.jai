#scope_module

Message :: struct {
    listenerComponents : [..]*ListenerComponent;
}

message_register_component :: (message : *Message, listenerComponent : *ListenerComponent) {
    Basic.array_add(*message.listenerComponents, listenerComponent);
}

message_unregister_component :: (message : *Message, listenerComponent : *ListenerComponent) {
    Basic.array_unordered_remove_by_value(*message.listenerComponents, listenerComponent, stop_after_first = true);
}

message_send :: (message : *Message, data : $T) {
    message_send(message, *data);
}

message_send :: (message : *Message, data : *void) {
    for listenerComponent : message.listenerComponents {
        listener_forward_message(listenerComponent, data);
    }
}

_message_cleanup :: (message : *Message) {
    Basic.array_free(message.listenerComponents);
}
