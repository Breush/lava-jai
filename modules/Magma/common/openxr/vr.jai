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

    configurationViews : [2]Xr.ViewConfigurationView;
    actionSet : Xr.ActionSet;

    handInfos : [2]struct {
        name : string;
        path : Xr.Path;
        selectPath : Xr.Path;
        gripPosePath : Xr.Path;

        poseAction : Xr.Action;
        selectAction : Xr.Action;
    };
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
    Basic.log("OpenXR available extensions:", flags=.VERY_VERBOSE_ONLY);
    for extension : availableExtensions {
        Basic.log("  - %", Basic.to_string(extension.extensionName), flags=.VERY_VERBOSE_ONLY);
    }
    Basic.log("OpenXR enabled extensions:", flags=.VERBOSE_ONLY);
    for extensionName : enabledExtensions {
        Basic.log("  - %", Basic.to_string(extensionName), flags=.VERBOSE_ONLY);
    }

    Basic.log("OpenXR available API layers:", flags=.VERY_VERBOSE_ONLY);
    for apiLayer : availableApiLayers {
        Basic.log("  - %", Basic.to_string(apiLayer.layerName), flags=.VERY_VERBOSE_ONLY);
    }

    Basic.log("OpenXR enabled API layers:", flags=.VERBOSE_ONLY);
    for apiLayerName : enabledApiLayers {
        Basic.log("  - %", Basic.to_string(apiLayerName), flags=.VERBOSE_ONLY);
    }

    instanceCI : Xr.InstanceCreateInfo;
    instanceCI.type = .TypeInstanceCreateInfo;
    instanceCI.applicationInfo.apiVersion = 1 << 48; // @todo Ugly, we should just export the API_VERSION_1_0 in module.
    instanceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    instanceCI.enabledExtensionNames = enabledExtensions.data;
    instanceCI.enabledApiLayerCount = cast(u32) enabledApiLayers.count;
    instanceCI.enabledApiLayerNames = enabledApiLayers.data;
    memcpy(*instanceCI.applicationInfo.applicationName[0], "lava".data, "lava".count);
    memcpy(*instanceCI.applicationInfo.engineName[0], "magma".data, "magma".count);

    _CHECK_NON_FATAL(Xr.create_instance(*instanceCI, *vr.instance),
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

    // Views
    viewConfigurations : [..]Xr.ViewConfigurationType;
    defer Basic.array_free(viewConfigurations);
    Xr.array_fill(*viewConfigurations, Xr.enumerate_view_configurations, vr.instance, vr.systemId);
    _CHECK(Basic.array_find(viewConfigurations, .PrimaryStereo),
           "Unable to find a valid OpenXR view configuration.");

    viewConfigurationProperties : Xr.ViewConfigurationProperties;
    viewConfigurationProperties.type = .TypeViewConfigurationProperties;
    Xr.get_view_configuration_properties(vr.instance, vr.systemId, .PrimaryStereo, *viewConfigurationProperties);

    Xr.array_fill_stype(vr.configurationViews, Xr.enumerate_view_configuration_views, vr.instance, vr.systemId, viewConfigurationProperties.viewConfigurationType, .TypeViewConfigurationView);

    // Actions
    _init_actions(vr);

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

        // :ContextBug
        #assert(type_info(Context_Base).members[0].name == "thread_index");
        debugMessengerCI.userData = *context.thread_index;

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
    Basic.log("Hard quitting with SegFault because of SteamVR hanging otherwise...", flags=.WARNING);
    <<(cast(*u8)0) = 1;
    Xr.destroy_instance(vr.instance);
}

vr_recommended_eye_extent :: (vr : *Vr, eyeKind : Vr.EyeKind) -> Chamber.uvec2 {
    extent : Chamber.uvec2;
    extent.width = vr.configurationViews[eyeKind].recommendedImageRectWidth;
    extent.height = vr.configurationViews[eyeKind].recommendedImageRectHeight;
    return extent;
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
    // :ContextBug
    ctx := <<cast(*Context) userData;
    push_context ctx {
        flags : Log_Flags;
        if messageSeverity & Xr.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT {
            flags |= .VERBOSE_ONLY;
        } else if messageSeverity & Xr.DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT {
            flags |= .CONTENT;
        } else if messageSeverity & Xr.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT {
            flags |= .WARNING;
        } else if messageSeverity & Xr.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT {
            flags |= .ERROR;
        }
        Basic.log("[OpenXR] % % ", Basic.to_string(callbackData.functionName), Basic.to_string(callbackData.message), flags=flags);
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

_init_actions :: (vr : *Vr) -> bool {
    actionSetCI : Xr.ActionSetCreateInfo;
    actionSetCI.type = .TypeActionSetCreateInfo;
    memcpy(*actionSetCI.actionSetName[0], "lava.magma.gameplay".data, "lava.magma.gameplay".count);
    memcpy(*actionSetCI.localizedActionSetName[0], "Gameplay".data, "Gameplay".count);
    _CHECK(Xr.create_action_set(vr.instance, *actionSetCI, *vr.actionSet),
           "Unable to create OpenXR action set.");

    vr.handInfos[0].name = "left";
    vr.handInfos[1].name = "right";

    Xr.string_to_path(vr.instance, "/user/hand/left", *vr.handInfos[0].path);
    Xr.string_to_path(vr.instance, "/user/hand/right", *vr.handInfos[1].path);

    Xr.string_to_path(vr.instance, "/user/hand/left/input/select/click", *vr.handInfos[0].selectPath);
    Xr.string_to_path(vr.instance, "/user/hand/right/input/select/click", *vr.handInfos[1].selectPath);

    Xr.string_to_path(vr.instance, "/user/hand/left/input/grip/pose", *vr.handInfos[0].gripPosePath);
    Xr.string_to_path(vr.instance, "/user/hand/right/input/grip/pose", *vr.handInfos[1].gripPosePath);

    for *handInfo : vr.handInfos {
        actionCI : Xr.ActionCreateInfo;
        actionCI.type = .TypeActionCreateInfo;
        actionCI.actionType = .PoseInput;
        actionCI.countSubactionPaths = 1;
        actionCI.subactionPaths = *handInfo.path;
        _set(*actionCI.actionName[0], Basic.tprint("hand.pose.%", handInfo.name));
        _set(*actionCI.localizedActionName[0], Basic.tprint("Hand pose (%)", handInfo.name));
        _CHECK(Xr.create_action(vr.actionSet, *actionCI, *handInfo.poseAction),
               "Unable to create OpenXR 'hand.pose' action.");

        actionCI.actionType = .FloatInput;
        _set(*actionCI.actionName[0], Basic.tprint("hand.select.%", handInfo.name));
        _set(*actionCI.localizedActionName[0], Basic.tprint("Hand select (%)", handInfo.name));
        _CHECK(Xr.create_action(vr.actionSet, *actionCI, *handInfo.selectAction),
               "Unable to create OpenXR 'hand.select' action.");
    }

    interactionProfilePath : Xr.Path;
    _CHECK(Xr.string_to_path(vr.instance, "/interaction_profiles/khr/simple_controller", *interactionProfilePath),
           "Unable to get OpenXR interaction profile.");

    actionSuggestedBindings : [4]Xr.ActionSuggestedBinding;
    bindingIndex := 0;
    for handInfo : vr.handInfos {
        actionSuggestedBindings[bindingIndex].action = handInfo.poseAction;
        actionSuggestedBindings[bindingIndex].binding = handInfo.gripPosePath;
        actionSuggestedBindings[bindingIndex + 1].action = handInfo.selectAction;
        actionSuggestedBindings[bindingIndex + 1].binding = handInfo.selectPath;
        bindingIndex += 2;
    }

    interactionProfileSuggestedBindings : Xr.InteractionProfileSuggestedBinding;
    interactionProfileSuggestedBindings.type = .TypeInteractionProfileSuggestedBinding;
    interactionProfileSuggestedBindings.interactionProfile = interactionProfilePath;
    interactionProfileSuggestedBindings.countSuggestedBindings = actionSuggestedBindings.count;
    interactionProfileSuggestedBindings.suggestedBindings = actionSuggestedBindings.data;

    _CHECK(Xr.suggest_interaction_profile_bindings(vr.instance, *interactionProfileSuggestedBindings),
           "Unable to suggest OpenXR interaction profile bindings.");

    return true;
}

_set :: (dest : *u8, src : string) {
    memcpy(dest, src.data, src.count);
}

String :: #import "String";
