Hash :: #import "Hash_Table";
using Hash; // @fixme For for_expansion to work... Compiler issue?

#scope_module

EngineImpl :: struct {
    instance : Vk.Instance;
    physicalDevice : Vk.PhysicalDevice;
    device : Vk.Device;

    queueIndices : QueueIndices;
    graphicsQueue : Vk.Queue;
    transferQueue : Vk.Queue;
    presentQueue : Vk.Queue;

    debugReportCallback : Vk.DebugReportCallbackEXT;

    shaderModuleMap : ShaderModuleMap;

    // Per frame state
    FRAME_INDEX_COUNT : u8 : 3;
    frameIndex : u8;
}

QueueIndices :: struct {
    graphics : int = -1;
    transfer : int = -1;
    present : int = -1;
}

ShaderModuleMap :: Hash.Table(Key_Type=string, Value_Type=Vk.ShaderModule);

impl_engine_init :: (engine : *Engine) {
    _init_instance(engine);
    _init_physical_device(engine);
}

impl_engine_cleanup :: (engine : *Engine) {
    for shaderModule : engine.shaderModuleMap {
        Vk.destroy_shader_module(engine.device, shaderModule, null);
    }

    Vk.destroy_device(engine.device, null);

    if engine.debugReportCallback {
        Vk.destroy_debug_report_callback_ext(engine.instance, engine.debugReportCallback, null);
    }

    Vk.destroy_instance(engine.instance, null);

    // Reset memory
    <<engine = Engine.{};
}

impl_engine_register :: (engine : *Engine, target : *Target) {
    if target.kind == Target.Kind.Window {
        _init_device(engine, (cast(*WindowTarget) target).surface);
    }
}

impl_engine_register :: (engine : *Engine, scene : *Scene) {
    // Nothing to do yet.
}

impl_engine_update :: (engine : *Engine) {
    // Nothing to do yet.
}

impl_engine_draw :: (engine : *Engine) -> bool {
    if engine.targets.count == 0 then return true;

    engine.frameIndex = (engine.frameIndex + 1) % Engine.FRAME_INDEX_COUNT;

    for target : engine.targets {
        if target.kind == Target.Kind.Window {
            _impl_window_target_draw(cast(*WindowTarget) target, engine.frameIndex);
        }
    }

    return true;
}

_impl_engine_get_shader_module :: (engine : *Engine, shaderPath : string) -> Vk.ShaderModule {
    shaderModule, ok := Hash.table_find(engine.shaderModuleMap, shaderPath);
    if ok then return shaderModule;

    shaderCode, readOk := File.read_entire_file(shaderPath);
    CHECK(readOk, null, "Unable to read shader file.");

    shaderModuleCI : Vk.ShaderModuleCreateInfo;
    shaderModuleCI.sType = Vk.StructureType.ShaderModuleCreateInfo;
    shaderModuleCI.codeSize = cast(u64) shaderCode.count;
    shaderModuleCI.pCode = cast(*u32) shaderCode.data;

    RESULT_CHECK(Vk.create_shader_module(engine.device, *shaderModuleCI, null, *shaderModule), null,
                 "Unable to create shader module.");

    Hash.table_add(*engine.shaderModuleMap, key=shaderPath, value=shaderModule);
    return shaderModule;
}

#scope_file

_init_instance :: (engine : *Engine) -> bool {
    // Application info
    applicationInfo : Vk.ApplicationInfo;
    applicationInfo.sType = Vk.StructureType.ApplicationInfo;
    applicationInfo.pApplicationName = "lava-magma";
    applicationInfo.pEngineName = "lava-magma";
    applicationInfo.apiVersion = Vk.API_VERSION_1_2;

    enabledLayers : [..]*u8;
    enabledExtensions : [..]*u8;
    defer Basic.array_free(enabledLayers);
    defer Basic.array_free(enabledExtensions);

    availableLayers : [..]Vk.LayerProperties;
    availableExtensions : [..]Vk.ExtensionProperties;
    Vk.array_fill(*availableLayers, Vk.enumerate_instance_layer_properties);
    Vk.array_fill(*availableExtensions, Vk.enumerate_instance_extension_properties, null);
    defer Basic.array_free(availableLayers);
    defer Basic.array_free(availableExtensions);

    // Validation layers
    validationLayersEnabled := false;
    if !_is_layer_available("VK_LAYER_KHRONOS_validation", availableLayers) {
        Chamber.debug("Instance layer VK_LAYER_KHRONOS_validation is not available. Disabling validation layers.\n");
    } else if  !_is_extension_available(Vk.EXT_DEBUG_REPORT_EXTENSION_NAME, availableExtensions) {
        Chamber.debug("Instance extension ", Vk.EXT_DEBUG_REPORT_EXTENSION_NAME, " is not available. Disabling validation layers.\n");
    } else {
        Basic.array_add(*enabledLayers, "VK_LAYER_KHRONOS_validation");
        Basic.array_add(*enabledExtensions, Vk.EXT_DEBUG_REPORT_EXTENSION_NAME);
        validationLayersEnabled = true;
    }

    // Surface extensions
    if engine.options.targetFlags & Engine.Options.TargetFlags.Window {
        Basic.array_add(*enabledExtensions, Vk.KHR_SURFACE_EXTENSION_NAME);
        #if OS == .LINUX {
            Basic.array_add(*enabledExtensions, Vk.KHR_XCB_SURFACE_EXTENSION_NAME);
        }
    }

    // Instance
    instanceCI : Vk.InstanceCreateInfo;
    instanceCI.sType = Vk.StructureType.InstanceCreateInfo;
    instanceCI.pApplicationInfo = *applicationInfo;
    instanceCI.enabledLayerCount = cast(u32) enabledLayers.count;
    instanceCI.ppEnabledLayerNames = enabledLayers.data;
    instanceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    instanceCI.ppEnabledExtensionNames = enabledExtensions.data;

    RESULT_CHECK(Vk.create_instance(*instanceCI, null, *engine.instance),
                 "Unable to create instance.");

    // Debug report callback
    if validationLayersEnabled {
        Vk.load_instance_proc(engine.instance, *Vk.create_debug_report_callback_ext, "vkCreateDebugReportCallbackEXT");
        Vk.load_instance_proc(engine.instance, *Vk.destroy_debug_report_callback_ext, "vkDestroyDebugReportCallbackEXT");

        debugReportCI : Vk.DebugReportCallbackCreateInfoEXT;
        debugReportCI.sType = Vk.StructureType.DebugReportCallbackCreateInfoExt;
        debugReportCI.flags = cast(u32) Vk.DebugReportFlagBitsEXT.Error | Vk.DebugReportFlagBitsEXT.Warning;
        debugReportCI.pfnCallback = cast(*void) _debug_message_callback;

        RESULT_CHECK(Vk.create_debug_report_callback_ext(engine.instance, *debugReportCI, null, *engine.debugReportCallback),
                     "Unable to create debug report callback.");
    }

    return true;
}

_init_physical_device :: (engine : *Engine) {
    physicalDevices : [..]Vk.PhysicalDevice;
    Vk.array_fill(*physicalDevices, Vk.enumerate_physical_devices, engine.instance);
    defer Basic.array_free(physicalDevices);

    // Chamber.debug("Found ", physicalDevices.count, " physical devices.\n");
    // for physicalDevice : physicalDevices {
    //     physicalDeviceProperties : Vk.PhysicalDeviceProperties;
    //     Vk.get_physical_device_properties(physicalDevice, *physicalDeviceProperties);
    //     Chamber.debug("-> ", Basic.to_string(physicalDeviceProperties.deviceName), "\n");
    // }

    engine.physicalDevice = physicalDevices[0];
}

_init_device :: (engine : *Engine, surface : Vk.SurfaceKHR) -> bool {
    enabledExtensions : [..]*u8;
    Basic.array_add(*enabledExtensions, Vk.KHR_SWAPCHAIN_EXTENSION_NAME);

    queueIndices := _find_queue_indices(engine.physicalDevice, surface);
    if queueIndices.graphics == -1 || queueIndices.transfer == -1 || queueIndices.present == -1 {
        CHECK(false, false, "Unable to find valid logical device queues for surface.");
    }

    // If we already had a initialized device, check that it is compatible.
    // @todo A check on "present" could be enough.
    if engine.device {
        if queueIndices.graphics != engine.queueIndices.graphics ||
           queueIndices.transfer != engine.queueIndices.transfer ||
           queueIndices.present != engine.queueIndices.present {
            CHECK(false, false, "Unable to reuse existing logical device for surface. Be sure to register complex targets like WindowTarget before others. And if it is already the case, you may need to create another Engine as the Vulkan devices do not seem compatible between them..");
        }
        // Reusing pre-existing device.
        return true;
    }
    engine.queueIndices = queueIndices;

    uniqueQueueIndices : [..]int;
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.graphics);
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.transfer);
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.present);

    queuePriority : float32 = 1.;
    queueCreateInfos : [..]Vk.DeviceQueueCreateInfo;
    for queueFamily : uniqueQueueIndices {
        queueCI : Vk.DeviceQueueCreateInfo;
        queueCI.sType = Vk.StructureType.DeviceQueueCreateInfo;
        queueCI.queueFamilyIndex = cast(u32) queueFamily;
        queueCI.queueCount = 1;
        queueCI.pQueuePriorities = *queuePriority;
        Basic.array_add(*queueCreateInfos, queueCI);
    }

    deviceCI : Vk.DeviceCreateInfo;
    deviceCI.sType = Vk.StructureType.DeviceCreateInfo;
    deviceCI.pQueueCreateInfos = queueCreateInfos.data;
    deviceCI.queueCreateInfoCount = cast(u32) queueCreateInfos.count;
    deviceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    deviceCI.ppEnabledExtensionNames = enabledExtensions.data;

    RESULT_CHECK(Vk.create_device(engine.physicalDevice, *deviceCI, null, *engine.device),
                 "Unable to create logical device.");

    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.graphics, 0, *engine.graphicsQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.transfer, 0, *engine.transferQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.present, 0, *engine.presentQueue);

    return true;
}

_find_queue_indices :: (physicalDevice : Vk.PhysicalDevice, surface : Vk.SurfaceKHR) -> QueueIndices {
    queueIndices : QueueIndices;

    queueFamilyProperties : [..]Vk.QueueFamilyProperties;
    Vk.array_fill(*queueFamilyProperties, Vk.get_physical_device_queue_family_properties, physicalDevice);

    for queueFamilyProperty, queueFamilyIndex : queueFamilyProperties {
        if queueFamilyProperty.queueCount <= 0 continue;

        presentSupport : Vk.Bool32 = Vk.FALSE;

        if queueFamilyProperty.queueFlags & cast(u32) Vk.QueueFlagBits.Graphics {
            queueIndices.graphics = queueFamilyIndex;

            // If we don't need present support, the graphics one will do.
            if surface == null {
                presentSupport = Vk.TRUE;
            }
        }

        if surface != null {
            Vk.get_physical_device_surface_support_khr(physicalDevice, cast(u32) queueFamilyIndex, surface, *presentSupport);
        }

        if presentSupport == Vk.TRUE {
            queueIndices.present = queueFamilyIndex;
        }

        // For transfer, take one that is not graphics nor present if possible.
        if queueFamilyProperty.queueFlags & cast(u32) Vk.QueueFlagBits.Transfer &&
           queueIndices.graphics != queueFamilyIndex && queueIndices.present != queueFamilyIndex {
            queueIndices.transfer = queueFamilyIndex;
        }
    }

    // Fallback to the present queueIndices if no better.
    if queueIndices.transfer < 0 {
        queueIndices.transfer = queueIndices.present;
    }

    return queueIndices;
}

_debug_message_callback :: (
    flags : Vk.DebugReportFlagsEXT,
    objectType : Vk.DebugReportObjectTypeEXT,
    object : u64,
    location : u64,
    messageCode : s32,
    layerPrefix : *u8,
    message : *u8,
    userData : *void
) -> Vk.Bool32 #c_call {
    ctx: Context;
    push_context ctx {
        // @todo Better logging system
        Chamber.debug(Basic.to_string(message), "\n");
        Basic.exit(1);
    }
    return Vk.FALSE;
}

_is_layer_available :: (layerName : string, availableLayers : []Vk.LayerProperties) -> bool {
    for availableLayer : availableLayers {
        if layerName == Basic.to_string(*availableLayer.layerName[0]) {
            return true;
        }
    }
    return false;
}

_is_extension_available :: (extensionName : string, availableExtensions : []Vk.ExtensionProperties) -> bool {
    for availableExtension : availableExtensions {
        if extensionName == Basic.to_string(*availableExtension.extensionName[0]) {
            return true;
        }
    }
    return false;
}
