#scope_module

Xr :: #import "OpenXr";

// @note Currently, we have an explicit dependency to OpenXr,
// and I don't feel like it needs to be hidden.
Vr :: struct {
    EyeKind :: enum {
        Left :: 0;  // @note These indices follow OpenXR conventions.
        Right :: 1;
    }

    enabled : bool;

    instance : Xr.Instance;
    systemId : Xr.SystemId;

    debugUtilsMessenger : Xr.DebugUtilsMessengerEXT;
    debugUtilsEnabled : bool;

    vulkanInstanceExtensions : *u8;
    vulkanDeviceExtensions : *u8;
}

engine_vr_init :: (engine : *Engine) -> bool {
    vr := *engine.vr;

    availableApiLayers : [..]Xr.ApiLayerProperties;
    enabledApiLayers : [..]*u8;
    defer Basic.array_free(availableApiLayers);
    defer Basic.array_free(enabledApiLayers);
    Xr.array_fill_stype(*availableApiLayers, Xr.enumerate_api_layer_properties, .TypeApiLayerProperties);
    if _is_api_layer_available("XR_APILAYER_LUNARG_core_validation", availableApiLayers) {
        Basic.array_add(*enabledApiLayers, "XR_APILAYER_LUNARG_core_validation");
    }

    availableExtensions : [..]Xr.ExtensionProperties;
    enabledExtensions : [..]*u8;
    defer Basic.array_free(availableExtensions);
    defer Basic.array_free(enabledExtensions);
    Xr.array_fill_stype(*availableExtensions, Xr.enumerate_instance_extension_properties, null, .TypeExtensionProperties);
    vr.debugUtilsEnabled = _is_extension_available("XR_EXT_debug_utils", availableExtensions);
    if vr.debugUtilsEnabled {
        Basic.array_add(*enabledExtensions, "XR_EXT_debug_utils");
    }
    impl_engine_vr_fill_extensions(*enabledExtensions);

    // For debug
    // Chamber.debug("OpenXR available extensions:");
    // for extension : availableExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension.extensionName));
    // }
    // Chamber.debug("OpenXR available extensions:");
    // for extension : availableExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension.extensionName));
    // }

    // Chamber.debug("OpenXR available API layers:");
    // for apiLayer : availableApiLayers {
    //     Chamber.debug("    - ", Basic.to_string(apiLayer.layerName));
    // }

    instanceCI : Xr.InstanceCreateInfo;
    instanceCI.type = .TypeInstanceCreateInfo;
    instanceCI.applicationInfo.apiVersion = 1 << 48; // @todo Ugly, we should just export the API_VERSION_1_0 in module.
    instanceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    instanceCI.enabledExtensionNames = enabledExtensions.data;
    instanceCI.enabledApiLayerCount = cast(u32) enabledApiLayers.count;
    instanceCI.enabledApiLayerNames = enabledApiLayers.data;
    memcpy(*instanceCI.applicationInfo.applicationName[0], "lava".data, "lava".count);
    memcpy(*instanceCI.applicationInfo.engineName[0], "magma".data, "magma".count);

    _CHECK(Xr.create_instance(*instanceCI, *vr.instance),
           "Unable to create OpenXR instance.");

    Xr.load_instance_proc(vr.instance, *Xr.get_vulkan_instance_extensions_khr, "xrGetVulkanInstanceExtensionsKHR");
    Xr.load_instance_proc(vr.instance, *Xr.get_vulkan_device_extensions_khr, "xrGetVulkanDeviceExtensionsKHR");
    Xr.load_instance_proc(vr.instance, *Xr.get_vulkan_graphics_requirements_khr, "xrGetVulkanGraphicsRequirementsKHR");
    Xr.load_instance_proc(vr.instance, *Xr.get_vulkan_graphics_device_khr, "xrGetVulkanGraphicsDeviceKHR");

    // System
    systemGI : Xr.SystemGetInfo;
    systemGI.type = .TypeSystemGetInfo;
    systemGI.formFactor = .HeadMountedDisplay;
    _CHECK(Xr.get_system(vr.instance, *systemGI, *vr.systemId),
           "Unable to get OpenXR system.");

    // Debug report callback
    if vr.debugUtilsEnabled {
        Xr.load_instance_proc(vr.instance, *Xr.create_debug_utils_messenger_ext, "xrCreateDebugUtilsMessengerEXT");
        Xr.load_instance_proc(vr.instance, *Xr.destroy_debug_utils_messenger_ext, "xrDestroyDebugUtilsMessengerEXT");

        debugMessengerCI : Xr.DebugUtilsMessengerCreateInfoEXT;
        debugMessengerCI.type = .TypeDebugUtilsMessengerCreateInfoExt;
        debugMessengerCI.messageSeverities = Xr.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                                             Xr.DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
                                             Xr.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                             Xr.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        debugMessengerCI.messageTypes = Xr.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                                        Xr.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                                        Xr.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
                                        Xr.DEBUG_UTILS_MESSAGE_TYPE_CONFORMANCE_BIT_EXT;
        debugMessengerCI.userCallback = _debug_messenger_callback;

        _CHECK(Xr.create_debug_utils_messenger_ext(vr.instance, *debugMessengerCI, *vr.debugUtilsMessenger),
               "Unable to create OpenXR debug utils messenger.");
    }

    vr.enabled = true;
    return true;
}

engine_vr_cleanup :: (engine : *Engine) {
    vr := *engine.vr;

    Basic.free(vr.vulkanInstanceExtensions);
    Basic.free(vr.vulkanDeviceExtensions);

    if vr.debugUtilsEnabled {
        Xr.destroy_debug_utils_messenger_ext(vr.debugUtilsMessenger);
    }

    // @fixme :SteamVrHanging SteamVR is hanging on a futex instead of quitting.
    // https://github.com/ValveSoftware/SteamVR-for-Linux/issues/422
    // So I prefer not to destroy the OpenXR instance and hard-exit instead...
    // But Basic.exit(0) still executes the registered handlers, so yeah,
    // just making a SegFault instead...
    Chamber.debug("Warning: Hard quitting with SegFault because of SteamVR hanging otherwise...");
    <<(cast(*u8)0) = 1;
    Xr.destroy_instance(vr.instance);
}

// The returned array should be freed.
vr_vulkan_required_instance_extensions :: (vr : *Vr) -> []string {
    if vr.vulkanInstanceExtensions == null {
        bufferSize : u32;
        Xr.get_vulkan_instance_extensions_khr(vr.instance, vr.systemId, 0, *bufferSize, null);
        if bufferSize > 0 {
            vr.vulkanInstanceExtensions = Basic.alloc(bufferSize);
            Xr.get_vulkan_instance_extensions_khr(vr.instance, vr.systemId, bufferSize, *bufferSize, vr.vulkanInstanceExtensions);
        }
    }
    if vr.vulkanInstanceExtensions != null {
        extensions := String.split(Basic.to_string(vr.vulkanInstanceExtensions), " "); // @note Temporary allocator
        // Forcing zero-terminated strings.
        for extension : extensions {
            extension.data[extension.count] = 0;
        }
        return extensions;
    }

    return .[];
}

// The returned array should be freed.
vr_vulkan_required_device_extensions :: (vr : *Vr) -> []string {
    if vr.vulkanDeviceExtensions == null {
        bufferSize : u32;
        Xr.get_vulkan_device_extensions_khr(vr.instance, vr.systemId, 0, *bufferSize, null);
        if bufferSize > 0 {
            vr.vulkanDeviceExtensions = Basic.alloc(bufferSize);
            Xr.get_vulkan_device_extensions_khr(vr.instance, vr.systemId, bufferSize, *bufferSize, vr.vulkanDeviceExtensions);
        }
    }
    if vr.vulkanDeviceExtensions != null {
        extensions := String.split(Basic.to_string(vr.vulkanDeviceExtensions), " "); // @note Temporary allocator
        // Forcing zero-terminated strings.
        for extension : extensions {
            extension.data[extension.count] = 0;
        }
        return extensions;
    }

    return .[];
}

_vr_vulkan_required_physical_device :: (engine : *Engine) -> *void {
    // @note Needs to be called before Xr.get_vulkan_device_extensions_khr is called because of SteamVR
    // just not caring and would give a lot of extensions otherwise.
    vkPhysicalDevice : *void;
    _CHECK(Xr.get_vulkan_graphics_device_khr(engine.vr.instance, engine.vr.systemId, engine.instance, *vkPhysicalDevice), null,
           "Unable to get OpenXR Vulkan graphics device.");
    return vkPhysicalDevice;
}

#scope_file

_debug_messenger_callback :: (messageSeverity : Xr.DebugUtilsMessageSeverityFlagsEXT,
                              messageTypes : Xr.DebugUtilsMessageTypeFlagsEXT,
                              callbackData : *Xr.DebugUtilsMessengerCallbackDataEXT,
                              userData : *void
) -> Xr.Bool32 #c_call {
    ctx: Context;
    push_context ctx {
        // @todo Have one channel for messages.
        Chamber.debug("[OpenXR]: ", Basic.to_string(callbackData.functionName), " ", Basic.to_string(callbackData.message));
    }
    return Xr.TRUE;
}

_is_api_layer_available :: (layerName : string, availableApiLayers : []Xr.ApiLayerProperties) -> bool {
    for availableApiLayer : availableApiLayers {
        if layerName == Basic.to_string(*availableApiLayer.layerName[0]) {
            return true;
        }
    }
    return false;
}

_is_extension_available :: (extensionName : string, availableExtensions : []Xr.ExtensionProperties) -> bool {
    for availableExtension : availableExtensions {
        if extensionName == Basic.to_string(*availableExtension.extensionName[0]) {
            return true;
        }
    }
    return false;
}

String :: #import "String";
