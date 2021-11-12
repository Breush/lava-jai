Hash :: #import "Hash_Table";
for_expansion :: Hash.for_expansion;

#load "engine-vr.jai";

#scope_module

EngineImpl :: struct {
    instance : Vk.Instance;
    physicalDevice : Vk.PhysicalDevice;
    device : Vk.Device;

    physicalDeviceMemoryProperties : Vk.PhysicalDeviceMemoryProperties;

    queueIndices : QueueIndices;
    graphicsQueue : Vk.Queue;
    transferQueue : Vk.Queue;
    presentQueue : Vk.Queue;

    samplerDefault : Vk.Sampler;
    textureWhite : Texture; // @note Won't be registered within engine

    // General purpose commandPool, for one-time submits.
    graphicsCommandPool : Vk.CommandPool;

    debugReportCallback : Vk.DebugReportCallbackEXT;
    debugUtilsEnabled : bool; // For settings names to Vulkan object

    shaderModuleMap : ShaderModuleMap;

    // Per frame state
    FRAME_INDEX_COUNT : u8 : 2;
    frameIndex : u8;

    validationErrorsAreBlocking : bool;
}

QueueIndices :: struct {
    graphics : int = -1;
    transfer : int = -1;
    present : int = -1;
}

ShaderModule :: struct {
    vk : Vk.ShaderModule;
    using spv : Chamber.Spv;
}

ShaderModuleMap :: Hash.Table(string, ShaderModule);

impl_engine_init :: (engine : *Engine) {
    engine.validationErrorsAreBlocking = !engine.vr.enabled;

    _init_instance(engine);
    _init_physical_device(engine);
}

impl_engine_cleanup :: (engine : *Engine) {
    texture_cleanup(*engine.textureWhite);

    Vk.destroy_sampler(engine.device, engine.samplerDefault, null);

    for shaderModule : engine.shaderModuleMap {
        Vk.destroy_shader_module(engine.device, shaderModule.vk, null);
        for *uniformFrame, uniformName : shaderModule.uniformsFrame {
            Basic.free(uniformName);
        }
        Hash.uninit(*shaderModule.uniformsFrame);
    }

    Vk.destroy_command_pool(engine.device, engine.graphicsCommandPool, null);
    Vk.destroy_device(engine.device, null);

    if engine.debugReportCallback {
        Vk.destroy_debug_report_callback_ext(engine.instance, engine.debugReportCallback, null);
    }

    // :SteamVrHanging Can't destroy the instance with OpenXR and SteamVR, for some reason...
    // https://github.com/ValveSoftware/SteamVR-for-Linux/issues/422
    if !engine.vr.enabled {
        Vk.destroy_instance(engine.instance, null);
    }

    Hash.uninit(*engine.shaderModuleMap);
}

impl_engine_register :: (engine : *Engine, target : *Target) {
    registeredResourcesNeedPostInit := (engine.device == null);

    if target.kind == Target.Kind.Window {
        _init_device(engine, (cast(*WindowTarget) target).surface);
    } else {
        _init_device(engine, null);
    }

    // @note Objects that are registered should be called for "post_init"
    // but that only makes sense if we have a valid device.
    // For that reason, post init might be delayed until here.
    if registeredResourcesNeedPostInit && engine.device != null {
        for scene : engine.scenes {
            _scene_post_init(scene);
        }
        for target : engine.targets {
            _target_post_init(target);
        }
    } else if engine.device != null {
        _target_post_init(target);
    }
}

impl_engine_draw :: (engine : *Engine) -> bool {
    if engine.device == null then return true;
    if engine.targets.count == 0 then return true;

    engine.frameIndex = (engine.frameIndex + 1) % Engine.FRAME_INDEX_COUNT;

    for target : engine.targets {
        if !_target_draw(target, engine.frameIndex) {
            return false;
        }
    }

    return true;
}

_engine_get_shader_module :: (engine : *Engine, shaderId : string, kind : Chamber.ShaderKind, $parseUniforms := false) -> *ShaderModule {
    macroDefinition : string;
    if kind == .Vertex {
        macroDefinition = "VERTEX";
    } else if kind == .Fragment {
        macroDefinition = "FRAGMENT";
    }

    shaderModuleId := Basic.tprint("%.%", shaderId, macroDefinition);
    shaderModule := Hash.table_find_pointer(engine.shaderModuleMap, shaderModuleId);
    if shaderModule != null then return shaderModule;
    shaderModule = Hash.table_add(*engine.shaderModuleMap, shaderModuleId, .{});

    // @note By convention, things that start with "$" are refering to the internal
    // shaders of Magma.
    shaderPath : string;
    if shaderId[0] == #char "$" {
        shaderPath = Basic.tprint("%/%.glsl\0", DOLLAR_SHADERS_PATH, Basic.advance(shaderId, 1));
    } else {
        shaderPath = Basic.tprint("./%.glsl\0", shaderId);
    }

    spvCode := Chamber.spirv_compile_from_glsl(shaderPath, kind, macroDefinition, DOLLAR_SHADERS_PATH);
    defer Basic.array_free(spvCode);

    shaderModule.spv = Chamber.spirv_parse(spvCode, parseUniforms);

    shaderModuleCI : Vk.ShaderModuleCreateInfo;
    shaderModuleCI.sType = .ShaderModuleCreateInfo;
    shaderModuleCI.codeSize = cast(u64) spvCode.count;
    shaderModuleCI.pCode = cast(*u32) spvCode.data;

    _CHECK(Vk.create_shader_module(engine.device, *shaderModuleCI, null, *shaderModule.vk), null,
           "Unable to create shader module.");

    return shaderModule;
}

#scope_file

_init_instance :: (engine : *Engine) -> bool {
    // Application info
    applicationInfo : Vk.ApplicationInfo;
    applicationInfo.sType = .ApplicationInfo;
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

    // Debug utils
    engine.debugUtilsEnabled = _is_extension_available(Vk.EXT_DEBUG_UTILS_EXTENSION_NAME, availableExtensions);
    if engine.debugUtilsEnabled {
        Basic.array_add(*enabledExtensions, Vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    // Surface extensions
    if engine.options.targetFlags & .Window {
        Basic.array_add(*enabledExtensions, Vk.KHR_SURFACE_EXTENSION_NAME);
        #if OS == .LINUX {
            Basic.array_add(*enabledExtensions, Vk.KHR_XCB_SURFACE_EXTENSION_NAME);
        }
    }

    // VR extensions
    if engine.vr.enabled {
        extensions := vr_vulkan_required_instance_extensions(*engine.vr);
        for extension : extensions {
            Basic.array_add(*enabledExtensions, extension.data);
        }
    }

    // For debugging
    // Chamber.debug("Available instance extensions:");
    // for extension : availableExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension.extensionName));
    // }
    // Chamber.debug("Activated instance extensions:");
    // for extension : enabledExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension));
    // }

    // Instance
    instanceCI : Vk.InstanceCreateInfo;
    instanceCI.sType = .InstanceCreateInfo;
    instanceCI.pApplicationInfo = *applicationInfo;
    instanceCI.enabledLayerCount = cast(u32) enabledLayers.count;
    instanceCI.ppEnabledLayerNames = enabledLayers.data;
    instanceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    instanceCI.ppEnabledExtensionNames = enabledExtensions.data;

    _CHECK(Vk.create_instance(*instanceCI, null, *engine.instance),
           "Unable to create instance.");

    // Debug report callback
    if validationLayersEnabled {
        Vk.load_instance_proc(engine.instance, *Vk.create_debug_report_callback_ext, "vkCreateDebugReportCallbackEXT");
        Vk.load_instance_proc(engine.instance, *Vk.destroy_debug_report_callback_ext, "vkDestroyDebugReportCallbackEXT");

        debugReportCI : Vk.DebugReportCallbackCreateInfoEXT;
        debugReportCI.sType = .DebugReportCallbackCreateInfoExt;
        debugReportCI.flags = cast(u32) Vk.DebugReportFlagBitsEXT.Error | Vk.DebugReportFlagBitsEXT.Warning /* | Vk.DebugReportFlagBitsEXT.PerformanceWarning */;
        debugReportCI.pfnCallback = cast(*void) _debug_message_callback;
        debugReportCI.pUserData = engine;

        _CHECK(Vk.create_debug_report_callback_ext(engine.instance, *debugReportCI, null, *engine.debugReportCallback),
               "Unable to create debug report callback.");
    }

    return true;
}

_init_physical_device :: (engine : *Engine) -> bool {
    physicalDevices : [..]Vk.PhysicalDevice;
    Vk.array_fill(*physicalDevices, Vk.enumerate_physical_devices, engine.instance);
    defer Basic.array_free(physicalDevices);

    requiredPhysicalDevice : Vk.PhysicalDevice;
    if engine.vr.enabled {
        requiredPhysicalDevice = _vr_vulkan_required_physical_device(engine);
    }

    // Chamber.debug("Found ", physicalDevices.count, " physical devices.\n");
    engine.physicalDevice = null;
    for physicalDevice : physicalDevices {
        // For debug
        // physicalDeviceProperties : Vk.PhysicalDeviceProperties;
        // Vk.get_physical_device_properties(physicalDevice, *physicalDeviceProperties);
        // Chamber.debug("-> ", Basic.to_string(physicalDeviceProperties.deviceName), "\n");

        validPhysicalDevice : bool;
        if requiredPhysicalDevice != null {
            validPhysicalDevice = (physicalDevice == requiredPhysicalDevice);
        } else {
            validPhysicalDevice = _is_valid_physical_device(engine, physicalDevice);
        }

        if validPhysicalDevice {
            engine.physicalDevice = physicalDevice;
            Vk.get_physical_device_memory_properties(physicalDevice, *engine.physicalDeviceMemoryProperties);
            break;
        }
    }

    if engine.physicalDevice == null {
        _CHECK(false, false, "Unable to find valid physical device.");
    }

    return true;
}

_init_device :: (engine : *Engine, surface : Vk.SurfaceKHR) -> bool {
    enabledExtensions : [..]*u8;
    defer Basic.array_free(enabledExtensions);
    Basic.array_add(*enabledExtensions, Vk.KHR_SWAPCHAIN_EXTENSION_NAME);

    if engine.device != null {
        // If we already had a initialized device, check that it is compatible.
        if !_is_valid_queue_index_for_surface(cast(u32) engine.queueIndices.present, engine.physicalDevice, surface) {
            _CHECK(false, false, "Unable to reuse existing logical device for surface. Be sure to register complex targets like WindowTarget before others. And if it is already the case, you may need to create another Engine as the Vulkan devices do not seem compatible between them..");
        }
        // Reusing pre-existing device.
        return true;
    }

    queueIndices := _find_queue_indices(engine.physicalDevice, surface);
    if queueIndices.graphics == -1 || queueIndices.transfer == -1 || queueIndices.present == -1 {
        _CHECK(false, false, "Unable to find valid logical device queues.");
    }
    engine.queueIndices = queueIndices;

    uniqueQueueIndices : [..]int;
    defer Basic.array_free(uniqueQueueIndices);
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.graphics);
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.transfer);
    Basic.array_add_if_unique(*uniqueQueueIndices, engine.queueIndices.present);

    queuePriority : float32 = 1.;
    queueCreateInfos : [..]Vk.DeviceQueueCreateInfo;
    defer Basic.array_free(queueCreateInfos);
    for queueFamily : uniqueQueueIndices {
        queueCI : Vk.DeviceQueueCreateInfo;
        queueCI.sType = .DeviceQueueCreateInfo;
        queueCI.queueFamilyIndex = cast(u32) queueFamily;
        queueCI.queueCount = 1;
        queueCI.pQueuePriorities = *queuePriority;
        Basic.array_add(*queueCreateInfos, queueCI);
    }

    // VR extensions
    if engine.vr.enabled {
        extensions := vr_vulkan_required_device_extensions(*engine.vr);
        for extension : extensions {
            Basic.array_add(*enabledExtensions, extension.data);
        }
    }

    // For debugging
    // availableExtensions : [..]Vk.ExtensionProperties;
    // Vk.array_fill(*availableExtensions, Vk.enumerate_device_extension_properties, engine.physicalDevice, null);
    // Chamber.debug("Available device extensions:");
    // for extension : availableExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension.extensionName));
    // }
    // Chamber.debug("Activated device extensions:");
    // for extension : enabledExtensions {
    //     Chamber.debug("    - ", Basic.to_string(extension));
    // }

    deviceCI : Vk.DeviceCreateInfo;
    deviceCI.sType = .DeviceCreateInfo;
    deviceCI.pQueueCreateInfos = queueCreateInfos.data;
    deviceCI.queueCreateInfoCount = cast(u32) queueCreateInfos.count;
    deviceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    deviceCI.ppEnabledExtensionNames = enabledExtensions.data;

    _CHECK(Vk.create_device(engine.physicalDevice, *deviceCI, null, *engine.device),
           "Unable to create logical device.");

    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.graphics, 0, *engine.graphicsQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.transfer, 0, *engine.transferQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.present, 0, *engine.presentQueue);

    if engine.debugUtilsEnabled {
        Vk.load_device_proc(engine.device, *Vk.set_debug_utils_object_name_ext, "vkSetDebugUtilsObjectNameEXT");
    }

    _init_global_resources(engine);

    return true;
}

_init_global_resources :: (engine : *Engine) -> bool {
    if !_create_graphics_command_pool(engine, *engine.graphicsCommandPool, false) {
        return false;
    }

    samplerCI : Vk.SamplerCreateInfo;
    samplerCI.sType = .SamplerCreateInfo;
    samplerCI.magFilter = .Linear;
    samplerCI.minFilter = .Linear;
    samplerCI.addressModeU = .Repeat;
    samplerCI.addressModeV = .Repeat;
    samplerCI.addressModeW = .Repeat;
    samplerCI.anisotropyEnable = Vk.FALSE; // @todo Disabled for now, but we kind of want that!
    samplerCI.unnormalizedCoordinates = Vk.FALSE; // @todo Can be useful for full-screen effects.
    samplerCI.compareEnable = Vk.FALSE;
    samplerCI.mipmapMode = .Linear;
    samplerCI.maxLod = 10; // @todo What is this, exactly?

    _CHECK(Vk.create_sampler(engine.device, *samplerCI, null, *engine.samplerDefault),
           "Unable to create sampler.");

    texture_init(*engine.textureWhite, engine);
    texture_load_from_memory(*engine.textureWhite, .[0xFF, 0xFF, 0xFF, 0xFF], .{1, 1});

    return true;
}

_find_queue_indices :: (physicalDevice : Vk.PhysicalDevice, surface : Vk.SurfaceKHR) -> QueueIndices {
    queueIndices : QueueIndices;

    queueFamilyProperties : [..]Vk.QueueFamilyProperties;
    defer Basic.array_free(queueFamilyProperties);
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
            presentSupport = _is_valid_queue_index_for_surface(cast(u32) queueFamilyIndex, physicalDevice, surface);
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

_is_valid_queue_index_for_surface :: (queueIndex : u32, physicalDevice : Vk.PhysicalDevice, surface : Vk.SurfaceKHR) -> Vk.Bool32 {
    if surface == null then return Vk.TRUE;

    presentSupport : Vk.Bool32;
    Vk.get_physical_device_surface_support_khr(physicalDevice, queueIndex, surface, *presentSupport);
    return presentSupport;
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
        messageString := Basic.to_string(message);
        linkParts := String.split(messageString, "(https://");
        specParts := String.split(linkParts[0], " The Vulkan spec states:");
        sentences := String.split(specParts[0], "|");
        errorParts := String.split(sentences[0], "Object ");

        Chamber.debug("===== Vulkan Debug Message =====");
        Chamber.debug(errorParts[0]);
        for i : 1..errorParts.count-1 {
            Chamber.debug("  | Object ", errorParts[i]);
        }
        for i : 1..sentences.count-1 {
            Chamber.debug("  |", sentences[i]);
        }
        if specParts.count == 2 {
            Chamber.debug("  >", specParts[1]);
        }
        if linkParts.count == 2 {
            Chamber.debug("  (https://", linkParts[1]);
        }

        // @note SteamVR has inconsistent SPIRV, so we still need to continue...
        engine := cast(*Engine) userData;
        if engine.validationErrorsAreBlocking {
            Basic.assert(false);
        }
    }
    return Vk.FALSE;
}

_is_valid_physical_device :: (engine : *Engine, physicalDevice : Vk.PhysicalDevice) -> bool {
    features : Vk.PhysicalDeviceFeatures2;
    features.sType = .PhysicalDeviceFeatures2;

    timelineSemaphoreFeatures : Vk.PhysicalDeviceTimelineSemaphoreFeatures;
    timelineSemaphoreFeatures.sType = .PhysicalDeviceTimelineSemaphoreFeatures;
    features.pNext = *timelineSemaphoreFeatures;

    Vk.get_physical_device_features2(physicalDevice, *features);

    // Checking that timeline semaphores are supported.
    if !timelineSemaphoreFeatures.timelineSemaphore {
        return false;
    }

    return true;
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

String :: #import "String";
