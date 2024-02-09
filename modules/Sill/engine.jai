EngineBase :: struct {
    window : *Crater.Window;
    renderEngine : *Magma.Engine;
    scene : *Magma.Scene;

    windowTarget : *Magma.WindowTarget;
    renderer : *Magma.Renderer;
    // @todo Make post processes registerable through the engine.
    postProcessRenderer : *Magma.PostProcessRenderer;

#if VR_ENABLED {
    vrTarget : *Magma.VrTarget;
    vrLeftRenderer : *Magma.Renderer;
    vrRightRenderer : *Magma.Renderer;
}

    // :AsProblem Using #as here causes runtime errors if we pass *engine later one.
    fonts : Fonts;
    input : Input;
    message : Message;
    ui : Ui;

    // User control.
    options : EngineOptions;
    closingMainWindow : bool;           // Set to true to close the main window.
    windowSizeChangedTimer : float64;   // We also delay the Event.WindowSizeChanged so that only one is sent through the event handler.

    // @note We delay entity destruction so that other entities updates
    // can schedule destruction of any entity.
    pendingDestroyedEntities : [..]*Entity;
}

Engine :: struct ($_Meta : Type) {
    using #as base : EngineBase;

    Meta :: _Meta;
    entities : _Meta.Entities;

    allocator : Allocator;
}

EngineOptions :: struct {
    windowTitle := "sill";
    windowExtent := Chamber.uvec2.{1600, 900};
    eventHandler : #type (event : Crater.Event);
    logFps := false;
    fpsLimit := 0;  // Use 0 to disable.

    // Features, create renderers/targets accordingly.
    postProcessing := false;

    renderEngine : Magma.Engine.Options;
}

create_engine :: ($_Meta : Type, options := EngineOptions.{}) -> *Engine(_Meta) {
    engine := Basic.New(Engine(_Meta));
    engine.options = options;
    Basic.remember_allocators(engine);
    engine_init(engine);
    return engine;
}

destroy_engine :: (engine : *Engine) {
    engine_cleanup(engine, resetMemory = false);

    Magma.destroy_engine(engine.renderEngine);

    if engine.allocator.proc != null {
        Basic.free(engine,, engine.allocator);
    }
}

// @todo Enable VR on option, currently doing so as long as available.
engine_init :: (engine : *EngineBase) {
    Basic.log("Engine init.", flags = .VERBOSE_ONLY);

    // Windowing
    videoMode : Crater.VideoMode;
    videoMode.width = cast(u16) engine.options.windowExtent.width;
    videoMode.height = cast(u16) engine.options.windowExtent.height;
    engine.window = Crater.create_window(videoMode, engine.options.windowTitle);

    // Rendering
    engine.renderEngine = Magma.create_engine(engine.options.renderEngine);
    engine.windowTarget = Magma.create_window_target(engine.renderEngine, Crater.window_get_handle(engine.window));
    engine.scene = Magma.create_scene(engine.renderEngine);

    classicRendererRequired := true;
    #if VR_ENABLED {
        if engine.renderEngine.vr.enabled {
            classicRendererRequired = false;
            engine.vrTarget = Magma.create_vr_target(engine.renderEngine);

            leftEyeExtent := Magma.vr_recommended_eye_extent(*engine.renderEngine.vr, .Left);
            rightEyeExtent := Magma.vr_recommended_eye_extent(*engine.renderEngine.vr, .Right);
            engine.vrLeftRenderer = Magma.create_forward_renderer(engine.scene, leftEyeExtent);
            engine.vrRightRenderer = Magma.create_forward_renderer(engine.scene, rightEyeExtent);

            // @todo Currently post-processing only the left eye, do we need two renderers or is there a trick?
            engine.postProcessRenderer = Magma.create_post_process_renderer(engine.scene, Magma.renderer_get_output(engine.vrLeftRenderer));
            Magma.target_bind(engine.vrTarget, Magma.renderer_get_output(engine.postProcessRenderer),  Magma.VrTarget.LEFT_EYE_BIND_INDEX);
            Magma.target_bind(engine.vrTarget, Magma.renderer_get_output(engine.vrRightRenderer), Magma.VrTarget.RIGHT_EYE_BIND_INDEX);

            // @todo Companion window, probably with own renderer.
            engine.renderer = engine.vrLeftRenderer;
        }
    }

    if classicRendererRequired {
        if engine.options.renderEngine.features & .RayTracing {
            engine.renderer = Magma.create_ray_tracing_renderer(engine.scene, engine.options.windowExtent);
        } else {
            engine.renderer = Magma.create_forward_renderer(engine.scene, engine.options.windowExtent);
        }

        if engine.options.postProcessing {
            engine.postProcessRenderer = Magma.create_post_process_renderer(engine.scene, Magma.renderer_get_output(engine.renderer));
            Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.postProcessRenderer));
        } else {
            Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.renderer));
        }
    }

    _fonts_init(*engine.fonts, engine.renderEngine);
}

engine_cleanup :: (engine : *Engine, resetMemory := true) {
    _ui_cleanup(*engine.ui);
    _input_cleanup(*engine.input);
    _fonts_cleanup(*engine.fonts);
    _message_cleanup(*engine.message);
    engine.Meta._cleanup_entities(engine);

    Basic.array_free(engine.pendingDestroyedEntities);

    if resetMemory {
        engine.* = Engine(engine.Meta).{};
    }
}

engine_run :: (engine : *Engine) {
    previousTime := Basic.seconds_since_init();
    previousSleepTime : float64;
    updateTime : float64 : 1.0/90.0 * 0.7854; // A bit faster than 90 FPS
    updateTimeLag := updateTime; // Force an initial update.

    fpsData : struct {
        elapsedTime : float64;
        renderTime : float64;
        renderCount : s64;
        updateCount : s64;
        updateTime : float64;
        sleepCount : s64;
        sleepTime : float64;
    };

    while !engine.closingMainWindow {
        currentTime := Basic.seconds_since_init();
        elapsedTime := currentTime - previousTime;
        elapsedTimeWithoutSleep := elapsedTime - previousSleepTime;
        previousTime = currentTime;

        if engine.options.logFps {
            fpsData.elapsedTime += elapsedTime;
            if fpsData.elapsedTime >= 1.0 {
                renderTimeMs := ifx fpsData.renderCount != 0 then cast(u32) (fpsData.renderTime / fpsData.renderCount * 10000) / 10.0 else 0.0;
                updateTimeMs := ifx fpsData.updateCount != 0 then cast(u32) (fpsData.updateTime / fpsData.updateCount * 10000) / 10.0 else 0.0;
                sleepTimeMs := ifx fpsData.sleepCount != 0 then cast(u32) (fpsData.sleepTime / fpsData.sleepCount * 10000) / 10.0 else 0.0;
                Basic.log("FPS: % | Render: %ms [% DrawCalls] | Update: %ms | Sleep: %ms\n",
                          fpsData.renderCount, renderTimeMs, engine.renderEngine.stats.drawCalls,
                          updateTimeMs, sleepTimeMs);
                fpsData = .{};
            }
        }

        if engine.options.fpsLimit > 0 && elapsedTimeWithoutSleep < 1.0 / engine.options.fpsLimit {
            sleepTime := (1.0 / engine.options.fpsLimit - elapsedTimeWithoutSleep);
            Basic.sleep_milliseconds(cast(s32) (sleepTime * 1000.0));
            previousSleepTime = sleepTime;
            if engine.options.logFps then _update_fps_counter(*fpsData.sleepTime, *fpsData.sleepCount, *currentTime);
        }

        if _engine_check_window_resized(engine, elapsedTime) {
            // Force an update after a resize.
            updateTimeLag = updateTime;
        } else {
            // We play logic at a constant rate.
            updateTimeLag += elapsedTime;
            // @fixme If rendering is slow and updates are fast, it would be better
            // to have a while loop here.
            // However, if updates are slow, better just do one round of updates here.
            if (updateTimeLag >= updateTime) {
                Basic.reset_temporary_storage();
                _input_reset(*engine.input);
                _engine_handle_events(engine, updateTime);
                _message_update(*engine.message);
                _engine_update_entities(engine, updateTime);
                _ui_update(*engine.ui);
                _message_update(*engine.message);
                updateTimeLag -= updateTime;
                if engine.options.logFps then _update_fps_counter(*fpsData.updateTime, *fpsData.updateCount, *currentTime);
            }

            // But we draw as fast as we can.
            Magma.engine_update(engine.renderEngine);
            Magma.engine_draw(engine.renderEngine);
            if engine.options.logFps then _update_fps_counter(*fpsData.renderTime, *fpsData.renderCount, *currentTime);
        }
    }

    Crater.destroy_window(engine.window);
}

#scope_file

_update_fps_counter :: (time : *float64, count : *s64, sinceTime : *float64) {
    newTime := Basic.seconds_since_init();
    time.* += newTime - sinceTime.*;
    sinceTime.* = newTime;
    count.* += 1;
}

_engine_update_entities :: (engine : *Engine, updateTime : float64) {
    engine.Meta._update_entities(engine, updateTime);

    // Remove pending entities
    if (engine.pendingDestroyedEntities.count != 0) {
        // Some entities might remove others, so we store everything before-hand.
        pendingDestroyedEntities := engine.pendingDestroyedEntities;
        defer Basic.array_free(pendingDestroyedEntities);
        engine.pendingDestroyedEntities.data = null;
        engine.pendingDestroyedEntities.count = 0;
        engine.pendingDestroyedEntities.allocated = 0;

        for entity : pendingDestroyedEntities {
            engine.Meta._destroy_entity(entity);
        }
    }
}

_engine_handle_events :: (engine : *EngineBase, updateTime : float64) {
    event := Crater.window_poll_event(engine.window, squash = true);

    startTime := Basic.seconds_since_init();
    while event.kind != .None {
        if event.kind == .WindowSizeChanged {
            engine.windowSizeChangedTimer = 0.150;
            engine.options.windowExtent = Crater.window_get_extent(engine.window);
            return;
        }

        stopPropagation := false;
        _ui_handle_event(*engine.ui, event, *stopPropagation);
        if !stopPropagation {
            _input_handle_event(*engine.input, event);
            if engine.options.eventHandler then engine.options.eventHandler(event);
        }

        // Just hop out if we're taking too long.
        if Basic.seconds_since_init() - startTime > updateTime * 0.5 {
            break;
        }

        event = Crater.window_poll_event(engine.window, squash = true);
    }

    #if VR_ENABLED {
        if (engine.renderEngine.vr.enabled) {
            _input_handle_vr_events(engine, engine.vrTarget);
        }
    }
}

_engine_check_window_resized :: (engine : *Engine, elapsedTime : float64) -> bool {
    if engine.windowSizeChangedTimer <= 0.0 then return false;

    // Eat all events (and reset the window size timer if needed.)
    event := Crater.window_poll_event(engine.window, squash = true);
    while event.kind != .None {
        if event.kind == .WindowSizeChanged {
            engine.windowSizeChangedTimer = 0.150;
            engine.options.windowExtent = Crater.window_get_extent(engine.window);
            break;
        }
        event = Crater.window_poll_event(engine.window, squash = true);
    }

    // Craft a delayed WindowSizeChanged event, so that the user handler only gets one.
    engine.windowSizeChangedTimer -= elapsedTime;
    if engine.options.eventHandler && engine.windowSizeChangedTimer <= 0.0 {
        event : Crater.Event;
        event.kind = .WindowSizeChanged;
        event.windowSize.width = cast(u16) engine.options.windowExtent.width;
        event.windowSize.height = cast(u16) engine.options.windowExtent.height;
        Magma.engine_wait_idle(engine.renderEngine);
        engine.options.eventHandler(event);
    }

    return true;
}
