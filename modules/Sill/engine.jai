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

    #as input : Input; // @fixme Spread these #as, they are awesome. One could just care about the engine afterwards...
    ui : Ui;

    windowExtent : Chamber.uvec2;
    closingMainWindow : bool; // Set to true to close the main window.

    // @note We delay entity destruction so that other entities updates
    // can schedule destruction of any entity.
    pendingDestroyedEntities : [..]*Entity;
}

Engine :: struct ($_Meta : Type) {
    using base : EngineBase;

    Meta :: _Meta;
    entities : _Meta.Entities;

    allocator : Allocator;
}

create_engine :: ($_Meta : Type, postProcessing := false, rayTracing := false) -> *Engine(_Meta) {
    engine := Basic.New(Engine(_Meta));
    Basic.remember_allocators(engine);
    engine_init(engine, postProcessing, rayTracing);
    return engine;
}

destroy_engine :: (engine : *Engine) {
    Magma.destroy_engine(engine.renderEngine);

    engine_cleanup(engine, resetMemory = false);

    if engine.allocator.proc != null {
        Basic.free(engine, engine.allocator);
    }
}

// @todo Enable VR on option, currently doing so as long as available.
engine_init :: (engine : *EngineBase, postProcessing := false, rayTracing := false) {
    Basic.log("Engine init.", flags=.VERBOSE_ONLY);

    // Windowing
    engine.window = Crater.create_window(.{width=1600, height=900}, "sill");
    engine.windowExtent = Crater.window_get_extent(engine.window);

    // Rendering
    renderEngineOptions : Magma.Engine.Options;
    renderEngineOptions.features |= .Vr;
    if rayTracing {
        renderEngineOptions.features |= .RayTracing;
    }

    engine.renderEngine = Magma.create_engine(renderEngineOptions);
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
        if rayTracing {
            engine.renderer = Magma.create_ray_tracing_renderer(engine.scene, engine.windowExtent);
        } else {
            engine.renderer = Magma.create_forward_renderer(engine.scene, engine.windowExtent);
        }

        if postProcessing {
            engine.postProcessRenderer = Magma.create_post_process_renderer(engine.scene, Magma.renderer_get_output(engine.renderer));
            Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.postProcessRenderer));
        } else {
            Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.renderer));
        }
    }
}

engine_cleanup :: (engine : *Engine, resetMemory := true) {
    _input_cleanup(*engine.input);
    engine.Meta._cleanup_entities(engine);

    if resetMemory {
        <<engine = Engine(engine.Meta).{};
    }
}

engine_run :: (engine : *Engine) {
    previousTime := Basic.get_time();
    updateTimeLag : float64 = 0;
    updateTime : float64 : 1.0/90.0 * 0.7854; // A bit faster than 90 FPS

    fpsFrameRenderedCount := 0;
    fpsElapsedTime : float64 = 0;
    fpsAverageElapsedTime : float64 = 0;

    while !engine.closingMainWindow {
        currentTime := Basic.get_time();
        elapsedTime := currentTime - previousTime;
        previousTime = currentTime;

        if false { // @todo Make it available on option
            fpsFrameRenderedCount += 1;
            fpsElapsedTime += elapsedTime;
            fpsAverageElapsedTime += elapsedTime;
            if fpsElapsedTime >= 1.0 {
                Basic.print("RenderTime: %ms | FPS: %\n", cast(u32) (fpsAverageElapsedTime / fpsFrameRenderedCount * 10000) / 10.0, fpsFrameRenderedCount);
                fpsFrameRenderedCount = 0;
                fpsAverageElapsedTime = 0;
                fpsElapsedTime = 0;
            }
        }

        // We play logic at a constant rate.
        updateTimeLag += elapsedTime;
        while (updateTimeLag >= updateTime) {
            Basic.reset_temporary_storage();
            _input_reset(*engine.input);
            _engine_handle_input_events(engine);
            _engine_update_entities(engine, updateTime);
            _ui_update(*engine.ui);
            updateTimeLag -= updateTime;
        }

        // But we draw as fast as we can.
        Magma.engine_update(engine.renderEngine);
        Magma.engine_draw(engine.renderEngine);
    }

    Crater.destroy_window(engine.window);
}

#scope_file

_engine_update_entities :: (engine : *Engine, updateTime : float64) {
    engine.Meta._update_entities(engine, updateTime);

    // Remove pending entities
    if (engine.pendingDestroyedEntities.count != 0) {
        // Some entities might remove others, so we copy everything before-hand.
        pendingDestroyedEntities := Basic.array_copy(engine.pendingDestroyedEntities);
        engine.pendingDestroyedEntities.count = 0;

        for entity : pendingDestroyedEntities {
            engine.Meta._destroy_entity(entity);
        }
    }
}

_engine_handle_input_events :: (engine : *EngineBase) {
    event := Crater.window_poll_event(engine.window);

    while event.kind != Crater.Event.Kind.None {
        if event.kind == Crater.Event.Kind.WindowClosed {
            engine.closingMainWindow = true;
            return;
        }
        else if event.kind == Crater.Event.Kind.KeyPressed &&
                event.key.which == Crater.Key.Escape {
            engine.closingMainWindow = true;
            return;
        }

        stopPropagation := false;
        _ui_handle_event(*engine.ui, event, *stopPropagation);
        if !stopPropagation then _input_handle_event(*engine.input, event);

        event = Crater.window_poll_event(engine.window);
    }

    #if VR_ENABLED {
        if (engine.renderEngine.vr.enabled) {
            _input_handle_vr_events(*engine.input, engine.vrTarget);
        }
    }
}
