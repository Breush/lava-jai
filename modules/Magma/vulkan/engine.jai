Hasher :: #import "Hash";
Hash :: #import "Hash_Table";
for_expansion :: Hash.for_expansion;

#load "engine-vr.jai";

#scope_module

// @note By convention, things that start with "$" are refering to the internal
// shaders of Magma. These things are all packed into one giant array.
// Generate the DOLLAR_SHADERS array that add to the binary all the shipped shaders.
#insert #run (path : string) -> string {
    sb : Basic.String_Builder;
    Basic.init_string_builder(*sb);

    files := FileUtilities.file_list(path, recursive = true, follow_directory_symlinks = false);
    Basic.append(*sb, "DOLLAR_SHADERS : [");
    Basic.print_item_to_builder(*sb, files.count);
    Basic.append(*sb, "]Chamber.DollarFile : .[");
    for file : files {
        fileContent, ok := File.read_entire_file(file);
        Basic.assert(ok, "Could not load $ file '%'.", file);

        // :JaiMissing Why is there no easy way to manipulate paths? (relative to absolute etc.)
        // The thing below is kind of a hack to get the relative path.
        Basic.advance(*file, path.count - 1);
        file[0] = #char "$";

        hash := Hasher.get_hash(file);
        hash ^= Hasher.get_hash(fileContent);

        Basic.append(*sb, Basic.tprint(".{ \"%\", #string __HERE_STRING__\n%\n__HERE_STRING__, % }, ", file, fileContent, hash));
    }
    Basic.append(*sb, "];");

    return Basic.builder_to_string(*sb);
}(DOLLAR_SHADERS_PATH);

EngineImpl :: struct {
    instance : Vk.Instance;
    physicalDevice : Vk.PhysicalDevice;
    device : Vk.Device;
    alloc : Vma.Allocator;

    physicalDeviceMemoryProperties : Vk.PhysicalDeviceMemoryProperties;
    physicalDeviceRayTracingPipelineProperties : Vk.PhysicalDeviceRayTracingPipelinePropertiesKHR;
    physicalDeviceDescriptorBufferProperties : Vk.PhysicalDeviceDescriptorBufferPropertiesEXT;

    queueIndices : QueueIndices;
    graphicsQueue : Vk.Queue;
    transferQueue : Vk.Queue;
    presentQueue : Vk.Queue;

    samplerDefault : Vk.Sampler;
    textureInvisible : Texture; // @note Won't be registered within engine
    textureWhite : Texture; // @note Won't be registered within engine

    // General purpose commandPool, for one-time submits.
    graphicsCommandPool : Vk.CommandPool;

    debugReportCallback : Vk.DebugReportCallbackEXT;
    debugUtilsEnabled : bool; // For settings names to Vulkan object

    shaderModuleMap : ShaderModuleMap;
    shaderFileWatcher : FileWatcher.File_Watcher(Engine);

    // Per frame state
    FRAME_INDEX_COUNT : u8 : 2;
    frameIndex : u8;
}

QueueIndices :: struct {
    graphics : int = -1;
    transfer : int = -1;
    present : int = -1;
}

ShaderModule :: struct {
    vk : Vk.ShaderModule;
    id : string;
    path : string;
    dirty : bool;
    using spv : Chamber.Spv;
}

ShaderModuleMap :: Hash.Table(string, ShaderModule);

impl_engine_init :: (engine : *Engine) {
    oldLayerPath := Chamber.os_get_environment_variable("VK_LAYER_PATH");
    newLayerPath := Basic.tprint("%0%:%\0", String.path_strip_filename(System.get_path_of_running_executable()), ifx OS == .WINDOWS then "" else "lib", oldLayerPath);
    Chamber.os_set_environment_variable("VK_LAYER_PATH", newLayerPath);

    _init_instance(engine);
    _init_physical_device(engine);

    if engine.options.watchShaderFiles {
        FileWatcher.init(*engine.shaderFileWatcher, _shader_file_watcher_callback, engine, .MODIFIED, watch_recursively = false);
    }
}

impl_engine_precleanup :: (engine : *Engine) {
    Vk.device_wait_idle(engine.device);

    if engine.options.watchShaderFiles then FileWatcher.deinit(*engine.shaderFileWatcher);
}

impl_engine_cleanup :: (engine : *Engine) {
    texture_cleanup(*engine.textureInvisible);
    texture_cleanup(*engine.textureWhite);

    Vk.destroy_sampler(engine.device, engine.samplerDefault, null);

    for shaderModule, shaderId : engine.shaderModuleMap {
        Vk.destroy_shader_module(engine.device, shaderModule.vk, null);
        for *uniformFrame, uniformName : shaderModule.uniformsFrame {
            Basic.free(uniformName);
        }
        Basic.free(shaderId);
        Basic.free(shaderModule.id);
        Basic.free(shaderModule.path);
        Hash.deinit(*shaderModule.uniformsFrame);
    }

    Vma.destroy_allocator(engine.alloc);
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

    Hash.deinit(*engine.shaderModuleMap);
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

impl_engine_wait_idle :: (engine : *Engine) {
    Vk.device_wait_idle(engine.device);
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

_engine_get_shader_module :: (engine : *Engine, id : string, kind : Chamber.ShaderKind, parseUniforms := false) -> *ShaderModule {
    macroDefinition := _shader_module_macro_definition(kind);
    shaderModuleId := Basic.tprint("%.%", id, macroDefinition);
    shaderModule := Hash.table_find_pointer(*engine.shaderModuleMap, shaderModuleId);

    Basic.log("Loading %.", shaderModuleId, flags = .VERY_VERBOSE_ONLY);
    if shaderModule != null {
        if !shaderModule.dirty then return shaderModule;

        Basic.log("Hot reloading %.", shaderModuleId, flags = .VERBOSE_ONLY);
        if shaderModule.vk != null {
            Vk.destroy_shader_module(engine.device, shaderModule.vk, null);
            for *uniformFrame, uniformName : shaderModule.uniformsFrame {
                Basic.free(uniformName);
            }
            Hash.table_reset(*shaderModule.uniformsFrame);
        }
    } else {
        shaderModule = Hash.table_add(*engine.shaderModuleMap, Basic.sprint("%", shaderModuleId), .{});
        shaderModule.id = Basic.copy_string(id);
        shaderModule.path = Basic.sprint("%.glsl\0", id);
        shaderModule.path.count -= 1;
    }

    shaderModule.dirty = false;

    if engine.options.watchShaderFiles && shaderModule.path[0] != #char "$" {
        directory := String.path_strip_filename(shaderModule.path);
        FileWatcher.add_directories(*engine.shaderFileWatcher, directory);
    }

    // Optimized SPIR-V, no symbols info inside.
    spvCode := Chamber.spirv_compile_from_glsl(shaderModule.path, kind, macroDefinition, DOLLAR_SHADERS, true, cacheFolder = engine.options.shaderCacheFolder);
    if spvCode.count == 0 {
        Basic.log("Unable to compile % to SPIR-V.", shaderModule.path, flags = .WARNING);
        return null;
    }
    defer Basic.array_free(spvCode);
    shaderModule.spv = Chamber.spirv_parse(spvCode, false);

    if parseUniforms {
        // @todo Currently forced to compile once a non-optimized version to get symbols name and such.
        nonOptimizedSpvCode := Chamber.spirv_compile_from_glsl(shaderModule.path, kind, macroDefinition, DOLLAR_SHADERS, false, cacheFolder = engine.options.shaderCacheFolder);
        defer Basic.array_free(nonOptimizedSpvCode);
        nonOptimizedSpv := Chamber.spirv_parse(nonOptimizedSpvCode, true);
        shaderModule.spv.uniformsFrame = nonOptimizedSpv.uniformsFrame;
    }

    shaderModuleCI : Vk.ShaderModuleCreateInfo;
    shaderModuleCI.sType = .ShaderModuleCreateInfo;
    shaderModuleCI.codeSize = cast(u64) spvCode.count;
    shaderModuleCI.pCode = cast(*u32) spvCode.data;

    _CHECK(Vk.create_shader_module(engine.device, *shaderModuleCI, null, *shaderModule.vk), null,
           "Unable to create shader module.");

    return shaderModule;
}

#scope_file

_shader_file_watcher_callback :: (watcher : *FileWatcher.File_Watcher(Engine), change : *FileWatcher.File_Change, engine : *Engine) {
    dirtyShaderModuleIds : [..]string;

    {
        Basic.push_allocator(Basic.temp);
        for *shaderModule, shaderModuleId : engine.shaderModuleMap {
            path1 := FileUtilities.parse_path(shaderModule.path);
            path2 := FileUtilities.parse_path(change.full_path);
            if path1.words.count == path2.words.count && FileUtilities.path_contains(path1, path2.words) {
                shaderModule.dirty = true;
                Basic.array_add_if_unique(*dirtyShaderModuleIds, shaderModule.id);
            }
        }
    }

    for scene : engine.scenes {
        _scene_on_shader_modules_changed(scene, dirtyShaderModuleIds);
    }
}

_init_instance :: (engine : *Engine) -> bool {
    // Application info
    applicationInfo : Vk.ApplicationInfo;
    applicationInfo.sType = .ApplicationInfo;
    applicationInfo.pApplicationName = "lava-magma";
    applicationInfo.pEngineName = "lava-magma";
    applicationInfo.apiVersion = Vk.API_VERSION_1_3;

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
    needValidationLayers := Chamber.BUILD_IS_DEBUG;
    validationLayersEnabled := false;
    if needValidationLayers {
        if !_is_layer_available("VK_LAYER_KHRONOS_validation", availableLayers) {
            Basic.log("Instance layer VK_LAYER_KHRONOS_validation is not available. Disabling validation layers.", flags=.WARNING);
        } else if !_is_extension_available(Vk.EXT_DEBUG_REPORT_EXTENSION_NAME, availableExtensions) {
            Basic.log("Instance extension ", Vk.EXT_DEBUG_REPORT_EXTENSION_NAME, " is not available. Disabling validation layers.", flags=.WARNING);
        } else {
            Basic.array_add(*enabledLayers, "VK_LAYER_KHRONOS_validation");
            Basic.array_add(*enabledExtensions, Vk.EXT_DEBUG_REPORT_EXTENSION_NAME);
            validationLayersEnabled = true;
        }
    }

    // // Shader object layer.
    // if !_is_layer_available("VK_LAYER_KHRONOS_shader_object", availableLayers) {
    //     Basic.log_error("Instance layer VK_LAYER_KHRONOS_shader_object is not available.");
    // }
    // Basic.array_add(*enabledLayers, "VK_LAYER_KHRONOS_shader_object");

    // Debug utils
    engine.debugUtilsEnabled = _is_extension_available(Vk.EXT_DEBUG_UTILS_EXTENSION_NAME, availableExtensions);
    if engine.debugUtilsEnabled {
        Basic.array_add(*enabledExtensions, Vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    // Surface extensions
    if engine.options.features & .Window {
        Basic.array_add(*enabledExtensions, Vk.KHR_SURFACE_EXTENSION_NAME);
        #if OS == .LINUX {
            Basic.array_add(*enabledExtensions, Vk.KHR_XCB_SURFACE_EXTENSION_NAME);
        } else #if OS == .WINDOWS {
            Basic.array_add(*enabledExtensions, Vk.KHR_WIN32_SURFACE_EXTENSION_NAME);
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
    Basic.log("Vulkan available instance extensions:", flags=.VERY_VERBOSE_ONLY);
    for extension : availableExtensions {
        Basic.log("  - %", cast(string) extension.extensionName, flags=.VERY_VERBOSE_ONLY);
    }
    Basic.log("Vulkan enabled instance extensions:", flags=.VERBOSE_ONLY);
    for extension : enabledExtensions {
        Basic.log("  - %", to_string(extension), flags=.VERBOSE_ONLY);
    }
    Basic.log("Vulkan available layers:", flags=.VERY_VERBOSE_ONLY);
    for layer : availableLayers {
        Basic.log("  - %", cast(string) layer.layerName, flags=.VERY_VERBOSE_ONLY);
    }
    Basic.log("Vulkan enabled layers:", flags=.VERY_VERBOSE_ONLY);
    for layer : enabledLayers {
        Basic.log("  - %", to_string(layer), flags=.VERY_VERBOSE_ONLY);
    }

    // Instance
    instanceCI : Vk.InstanceCreateInfo;
    instanceCI.sType = .InstanceCreateInfo;
    instanceCI.pApplicationInfo = *applicationInfo;
    instanceCI.enabledLayerCount = cast(u32) enabledLayers.count;
    instanceCI.ppEnabledLayerNames = enabledLayers.data;
    instanceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    instanceCI.ppEnabledExtensionNames = enabledExtensions.data;

    if validationLayersEnabled {
        validationFeaturesEnable := Vk.ValidationFeatureEnableEXT.[/*.GpuAssisted,*/
                                                                   .BestPractices,
                                                                   /*.DebugPrintf,*/
                                                                   .SynchronizationValidation];

        validationFeatures : Vk.ValidationFeaturesEXT;
        validationFeatures.sType = .ValidationFeaturesExt;
        validationFeatures.enabledValidationFeatureCount = validationFeaturesEnable.count;
        validationFeatures.pEnabledValidationFeatures = validationFeaturesEnable.data;
        instanceCI.pNext = *validationFeatures;
    }

    _CHECK(Vk.create_instance(*instanceCI, null, *engine.instance),
           "Unable to create instance.");

    // Debug report callback
    if validationLayersEnabled {
        Vk.load_instance_proc(engine.instance, *Vk.create_debug_report_callback_ext, "vkCreateDebugReportCallbackEXT");
        Vk.load_instance_proc(engine.instance, *Vk.destroy_debug_report_callback_ext, "vkDestroyDebugReportCallbackEXT");

        debugReportCI : Vk.DebugReportCallbackCreateInfoEXT;
        debugReportCI.sType = .DebugReportCallbackCreateInfoExt;
        debugReportCI.flags = cast(u32) Vk.DebugReportFlagBitsEXT.Error | Vk.DebugReportFlagBitsEXT.Warning /* | Vk.DebugReportFlagBitsEXT.PerformanceWarning */;
        debugReportCI.pfnCallback = _debug_message_callback;
        debugReportCI.pUserData = *context;

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

    Basic.log("Found % physical devices:", physicalDevices.count, flags=.VERBOSE_ONLY);
    for physicalDevice, physicalDeviceIndex : physicalDevices {
        physicalDeviceProperties : Vk.PhysicalDeviceProperties;
        Vk.get_physical_device_properties(physicalDevice, *physicalDeviceProperties);
        deviceName := to_string(*physicalDeviceProperties.deviceName[0]); // @note Not passing the object directly, because the full length of the array of char is used instead.
        Basic.log("  - #% '%'", physicalDeviceIndex, deviceName, flags=.VERBOSE_ONLY);
    }

    engine.physicalDevice = null;
    bestPhysicalDeviceIndex := 0;
    bestPhysicalDeviceScore := 0;
    for physicalDevice, physicalDeviceIndex : physicalDevices {
        if requiredPhysicalDevice != null {
            if physicalDevice == requiredPhysicalDevice {
                bestPhysicalDeviceIndex = physicalDeviceIndex;
                bestPhysicalDeviceScore = 1;
                break;
            }
        } else {
            score := _physical_device_score(engine, physicalDevice, cast(u8) physicalDeviceIndex);
            if score > bestPhysicalDeviceScore {
                bestPhysicalDeviceIndex = physicalDeviceIndex;
                bestPhysicalDeviceScore = score;
            }
        }
    }

    if bestPhysicalDeviceScore == 0 {
        _CHECK(false, false, "Unable to find valid physical device.");
    }

    Basic.log("Selecting physical device #%", bestPhysicalDeviceIndex, flags=.VERBOSE_ONLY);

    engine.physicalDevice = physicalDevices[bestPhysicalDeviceIndex];
    Vk.get_physical_device_memory_properties(engine.physicalDevice, *engine.physicalDeviceMemoryProperties);

    physicalDevicePropertiesPNext : *void;
    engine.physicalDeviceRayTracingPipelineProperties.sType = .PhysicalDeviceRayTracingPipelinePropertiesKhr;
    _chain_front(*physicalDevicePropertiesPNext, *engine.physicalDeviceRayTracingPipelineProperties);
    engine.physicalDeviceDescriptorBufferProperties.sType = .PhysicalDeviceDescriptorBufferPropertiesExt;
    _chain_front(*physicalDevicePropertiesPNext, *engine.physicalDeviceDescriptorBufferProperties);

    physicalDeviceProperties : Vk.PhysicalDeviceProperties2;
    physicalDeviceProperties.sType = .PhysicalDeviceProperties2;
    physicalDeviceProperties.pNext = physicalDevicePropertiesPNext;
    Vk.get_physical_device_properties2(engine.physicalDevice, *physicalDeviceProperties);

    return true;
}

_init_device :: (engine : *Engine, surface : Vk.SurfaceKHR) -> bool {
    enabledExtensions : [..]*u8;
    defer Basic.array_free(enabledExtensions);
    Basic.array_add(*enabledExtensions, Vk.KHR_SWAPCHAIN_EXTENSION_NAME);
    Basic.array_add(*enabledExtensions, Vk.EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME);
    // Basic.array_add(*enabledExtensions, Vk.EXT_SHADER_OBJECT_EXTENSION_NAME);

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

    // Features
    enabledFeatures : Vk.PhysicalDeviceFeatures;
    deviceCIPNext : *void;

    descriptorBufferFeatures : Vk.PhysicalDeviceDescriptorBufferFeaturesEXT;
    descriptorBufferFeatures.sType = .PhysicalDeviceDescriptorBufferFeaturesExt;
    descriptorBufferFeatures.descriptorBuffer = Vk.TRUE;
    _chain_front(*deviceCIPNext, *descriptorBufferFeatures);

    bufferDeviceAddressFeatures : Vk.PhysicalDeviceBufferDeviceAddressFeatures;
    bufferDeviceAddressFeatures.sType = .PhysicalDeviceBufferDeviceAddressFeatures;
    bufferDeviceAddressFeatures.bufferDeviceAddress = Vk.TRUE;
    _chain_front(*deviceCIPNext, *bufferDeviceAddressFeatures);

    timelineSemaphoreFeatures : Vk.PhysicalDeviceTimelineSemaphoreFeatures;
    timelineSemaphoreFeatures.sType = .PhysicalDeviceTimelineSemaphoreFeatures;
    timelineSemaphoreFeatures.timelineSemaphore = Vk.TRUE;
    _chain_front(*deviceCIPNext, *timelineSemaphoreFeatures);

    rayTracingPipelineFeatures : Vk.PhysicalDeviceRayTracingPipelineFeaturesKHR;
    accelerationStructureFeatures : Vk.PhysicalDeviceAccelerationStructureFeaturesKHR;
    _16BitStorageFeatures : Vk.PhysicalDevice16BitStorageFeatures;
    if engine.options.features & .RayTracing {
        Basic.array_add(*enabledExtensions, Vk.KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME);
        Basic.array_add(*enabledExtensions, Vk.KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME);
        Basic.array_add(*enabledExtensions, Vk.KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME);

        accelerationStructureFeatures.sType = .PhysicalDeviceAccelerationStructureFeaturesKhr;
        accelerationStructureFeatures.accelerationStructure = Vk.TRUE;
        _chain_front(*deviceCIPNext, *accelerationStructureFeatures);

        rayTracingPipelineFeatures.sType = .PhysicalDeviceRayTracingPipelineFeaturesKhr;
        rayTracingPipelineFeatures.rayTracingPipeline = Vk.TRUE;
        _chain_front(*deviceCIPNext, *rayTracingPipelineFeatures);

        _16BitStorageFeatures.sType = .PhysicalDevice16BitStorageFeatures;
        _16BitStorageFeatures.storageBuffer16BitAccess = Vk.TRUE;
        _chain_front(*deviceCIPNext, *_16BitStorageFeatures);

        enabledFeatures.shaderInt16 = Vk.TRUE;
        enabledFeatures.shaderInt64 = Vk.TRUE;
    }

    // For debugging
    availableExtensions : [..]Vk.ExtensionProperties;
    defer Basic.array_free(availableExtensions);
    Vk.array_fill(*availableExtensions, Vk.enumerate_device_extension_properties, engine.physicalDevice, null);
    Basic.log("Vulkan available device extensions:", flags=.VERY_VERBOSE_ONLY);
    for extension : availableExtensions {
        Basic.log("  - %", cast(string) extension.extensionName, flags=.VERY_VERBOSE_ONLY);
    }
    Basic.log("Vulkan enabled device extensions:", flags=.VERBOSE_ONLY);
    for extension : enabledExtensions {
        Basic.log("  - %", to_string(extension), flags=.VERBOSE_ONLY);
    }

    deviceCI : Vk.DeviceCreateInfo;
    deviceCI.sType = .DeviceCreateInfo;
    deviceCI.pNext = deviceCIPNext;
    deviceCI.pQueueCreateInfos = queueCreateInfos.data;
    deviceCI.queueCreateInfoCount = cast(u32) queueCreateInfos.count;
    deviceCI.enabledExtensionCount = cast(u32) enabledExtensions.count;
    deviceCI.ppEnabledExtensionNames = enabledExtensions.data;
    deviceCI.pEnabledFeatures = *enabledFeatures;

    _CHECK(Vk.create_device(engine.physicalDevice, *deviceCI, null, *engine.device),
           "Unable to create logical device.");

    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.graphics, 0, *engine.graphicsQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.transfer, 0, *engine.transferQueue);
    Vk.get_device_queue(engine.device, cast(u32) engine.queueIndices.present, 0, *engine.presentQueue);

    Vk.load_device_proc(engine.device, *Vk.get_descriptor_set_layout_size_ext, "vkGetDescriptorSetLayoutSizeEXT");
    Vk.load_device_proc(engine.device, *Vk.cmd_bind_descriptor_buffers_ext, "vkCmdBindDescriptorBuffersEXT");
    Vk.load_device_proc(engine.device, *Vk.cmd_set_descriptor_buffer_offsets_ext, "vkCmdSetDescriptorBufferOffsetsEXT");
    Vk.load_device_proc(engine.device, *Vk.get_descriptor_ext, "vkGetDescriptorEXT");
    Vk.load_device_proc(engine.device, *Vk.get_descriptor_set_layout_binding_offset_ext, "vkGetDescriptorSetLayoutBindingOffsetEXT");

    if engine.debugUtilsEnabled {
        Vk.load_device_proc(engine.device, *Vk.set_debug_utils_object_name_ext, "vkSetDebugUtilsObjectNameEXT");
    }

    if engine.options.features & .RayTracing {
        // @todo Make that clean by letting the binding do that (calling something like load_device_ray_tracing_procs).
        Vk.load_device_proc(engine.device, *Vk.cmd_trace_rays_khr, "vkCmdTraceRaysKHR");
        Vk.load_device_proc(engine.device, *Vk.create_ray_tracing_pipelines_khr, "vkCreateRayTracingPipelinesKHR");
        Vk.load_device_proc(engine.device, *Vk.get_ray_tracing_shader_group_handles_khr, "vkGetRayTracingShaderGroupHandlesKHR");
        Vk.load_device_proc(engine.device, *Vk.get_acceleration_structure_build_sizes_khr, "vkGetAccelerationStructureBuildSizesKHR");
        Vk.load_device_proc(engine.device, *Vk.create_acceleration_structure_khr, "vkCreateAccelerationStructureKHR");
        Vk.load_device_proc(engine.device, *Vk.destroy_acceleration_structure_khr, "vkDestroyAccelerationStructureKHR");
        Vk.load_device_proc(engine.device, *Vk.cmd_build_acceleration_structures_khr, "vkCmdBuildAccelerationStructuresKHR");
        Vk.load_device_proc(engine.device, *Vk.get_acceleration_structure_device_address_khr, "vkGetAccelerationStructureDeviceAddressKHR");
    }

    _init_global_resources(engine);

    return true;
}

_init_global_resources :: (engine : *Engine) -> bool {
    vulkanFunctions : Vma.VulkanFunctions;
    vulkanFunctions.vkGetInstanceProcAddr = xx Vk.get_instance_proc_addr;
    vulkanFunctions.vkGetDeviceProcAddr = xx Vk.get_device_proc_addr;

    allocatorCI : Vma.AllocatorCreateInfo;
    allocatorCI.physicalDevice = engine.physicalDevice;
    allocatorCI.device = engine.device;
    allocatorCI.instance = engine.instance;
    allocatorCI.pVulkanFunctions = *vulkanFunctions;
    allocatorCI.flags = cast(u32) Vma.AllocatorCreateFlagBits.BufferDeviceAddress;
    allocatorCI.vulkanApiVersion = Vk.API_VERSION_1_3;
    Vma.create_allocator(*allocatorCI, *engine.alloc);

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

    texture_init(*engine.textureInvisible, engine, false);
    texture_load_from_memory(*engine.textureInvisible, .[0, 0, 0, 0], .{1, 1});

    texture_init(*engine.textureWhite, engine, true);
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
    reportFlags : Vk.DebugReportFlagsEXT,
    objectType : Vk.DebugReportObjectTypeEXT,
    object : u64,
    location : u64,
    messageCode : s32,
    layerPrefix : *u8,
    message : *u8,
    userData : *void
) -> Vk.Bool32 #c_call {
    push_context << cast(*#Context) userData {
        flags : Log_Flags;
        if reportFlags & xx Vk.DebugReportFlagBitsEXT.Information {
            flags |= .VERY_VERBOSE_ONLY;
        } else if reportFlags & xx Vk.DebugReportFlagBitsEXT.Debug {
            flags |= .CONTENT;
        } else if reportFlags & xx Vk.DebugReportFlagBitsEXT.PerformanceWarning {
            flags |= .VERBOSE_ONLY;
        } else if reportFlags & xx Vk.DebugReportFlagBitsEXT.Warning {
            flags |= .WARNING;
        } else if reportFlags & xx Vk.DebugReportFlagBitsEXT.Error {
            flags |= .ERROR;
        }

        messageStr : string;
        Chamber.loggerPushNonFatalOnError();

        messageString := to_string(message);
        linkParts := String.split(messageString, "(https://");
        specParts := String.split(linkParts[0], " The Vulkan spec states:");
        sentences := String.split(specParts[0], "| ");
        errorParts := String.split(sentences[0], "Object ");

        // @todo Investigate why this happens when resizing the window,
        // but for now it cannot be a blocking error.
        if errorParts[0] == "Validation Error: [ VUID-VkSwapchainCreateInfoKHR-imageExtent-01274 ] " ||
           errorParts[0] == "Validation Error: [ UNASSIGNED-CoreValidation-DrawState-InvalidImageLayout ] " {
            flags = .WARNING;
        }

        Basic.log("===== Vulkan Debug Message =====", flags = flags);
        Basic.log(errorParts[0], flags = flags);
        for i : 1..errorParts.count-1 {
            Basic.log("  | Object %", errorParts[i], flags = flags);
        }
        for i : 1..sentences.count-1 {
            Basic.log("  | %", sentences[i], flags = flags);
        }
        if specParts.count == 2 {
            Basic.log("  >%", specParts[1], flags = flags);
        }
        if linkParts.count == 2 {
            Basic.log("  (https://%", linkParts[1], flags = flags);
        }

        Chamber.loggerPopNonFatalOnError();
        Basic.log("================================", flags = flags);
    }
    return Vk.FALSE;
}

_physical_device_score :: (engine : *Engine, physicalDevice : Vk.PhysicalDevice, physicalDeviceIndex : u8) -> s64 {
    features : Vk.PhysicalDeviceFeatures2;
    features.sType = .PhysicalDeviceFeatures2;

    timelineSemaphoreFeatures : Vk.PhysicalDeviceTimelineSemaphoreFeatures;
    timelineSemaphoreFeatures.sType = .PhysicalDeviceTimelineSemaphoreFeatures;
    _chain_front(*features.pNext, *timelineSemaphoreFeatures);

    accelerationStructureFeatures : Vk.PhysicalDeviceAccelerationStructureFeaturesKHR;
    accelerationStructureFeatures.sType = .PhysicalDeviceAccelerationStructureFeaturesKhr;
    _chain_front(*features.pNext, *accelerationStructureFeatures);

    Vk.get_physical_device_features2(physicalDevice, *features);

    score := 1;
    if accelerationStructureFeatures.accelerationStructure then score += 1;
    if features.features.shaderInt16 then score += 1;
    if features.features.shaderInt64 then score += 1;

    if engine.options.features & .RayTracing {
        if !accelerationStructureFeatures.accelerationStructure {
            Basic.log("Physical device #% does not support acceleration structures (ray-tracing requirement).", physicalDeviceIndex, flags = .WARNING);
            return 0;
        }

        if !features.features.shaderInt16 || !features.features.shaderInt64 {
            Basic.log("Physical device #% does not support both shader int16 and int64 (ray-tracing requirement).", physicalDeviceIndex, flags = .WARNING);
            return 0;
        }
    }

    // Checking that timeline semaphores are supported.
    if !timelineSemaphoreFeatures.timelineSemaphore {
        Basic.log("Physical device #% does not support timeline semaphores.", physicalDeviceIndex, flags = .WARNING);
        return 0;
    }

    return score;
}

_is_layer_available :: (layerName : string, availableLayers : []Vk.LayerProperties) -> bool {
    for availableLayer : availableLayers {
        if layerName == to_string(*availableLayer.layerName[0]) {
            return true;
        }
    }
    return false;
}

_is_extension_available :: (extensionName : string, availableExtensions : []Vk.ExtensionProperties) -> bool {
    for availableExtension : availableExtensions {
        if extensionName == to_string(*availableExtension.extensionName[0]) {
            return true;
        }
    }
    return false;
}

_chain_front :: (chain : **void, link : *void) {
    (cast(*Vk.BaseInStructure) link).pNext = chain.*;
    chain.* = link;
}

_shader_module_macro_definition :: (kind : Chamber.ShaderKind) -> string {
    if kind == .Vertex then return "VERTEX";
    else if kind == .Fragment then return "FRAGMENT";
    else if kind == .Raygen then return "RAYGEN";
    else if kind == .Miss then return "MISS";
    else if kind == .ClosestHit then return "CLOSEST_HIT";
    return "";
}

String :: #import "String";
FileUtilities :: #import "File_Utilities";
FileWatcher :: #import "File_Watcher";
