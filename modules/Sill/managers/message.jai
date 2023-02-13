#scope_module

Message :: struct {
    listenerComponents : [..]*ListenerComponent;

    messages : [..]*void;
    messagesPool : Pool.Pool;
}

message_register_component :: (message : *Message, listenerComponent : *ListenerComponent) {
    Basic.array_add(*message.listenerComponents, listenerComponent);
}

message_unregister_component :: (message : *Message, listenerComponent : *ListenerComponent) {
    Basic.array_unordered_remove_by_value(*message.listenerComponents, listenerComponent, stop_after_first = true);
}

message_send :: (message : *Message, data : $T) {
    messageContent := cast(*T) Pool.get(*message.messagesPool, size_of(T));
    << messageContent = data;
    Basic.array_add(*message.messages, messageContent);
}

_message_cleanup :: (using message : *Message) {
    Basic.array_free(listenerComponents);
    Basic.array_free(messages);
    Pool.release(*messagesPool);
}

_message_update :: (using message : *Message) {
    lastIndex := messages.count - 1;
    for messageIndex : 0 .. lastIndex {
        messageContent := messages[messageIndex];
        for listenerComponent : message.listenerComponents {
            listener_forward_message(listenerComponent, messageContent);
        }
        lastIndex = messages.count - 1;
    }
    messages.count = 0;
    Pool.reset(*messagesPool);
}

#scope_file

Pool :: #import "Pool";
