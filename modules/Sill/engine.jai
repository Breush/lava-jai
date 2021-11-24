EngineBase :: struct {
    window : *Crater.Window;
    renderEngine : *Magma.Engine;
    scene : *Magma.Scene;

    windowTarget : *Magma.WindowTarget;
    renderer : *Magma.Renderer;
    // @todo Make post processes registerable through the engine.
    postProcessRenderer : *Magma.PostProcessRenderer;

    vrTarget : *Magma.VrTarget;
    vrLeftRenderer : *Magma.Renderer;
    vrRightRenderer : *Magma.Renderer;

    input : Input;

    closingMainWindow : bool; // Set to true to close the main window.
}

Engine :: struct ($_Meta : Type) {
    Meta :: _Meta;
    entities : _Meta.Entities;

    using base : EngineBase;

    allocator : Allocator;
    allocator_data : *void;
}

create_engine :: ($_Meta : Type) -> *Engine(_Meta) {
    engine := Basic.New(Engine(_Meta));
    Basic.remember_allocators(engine);
    engine_init(engine);
    return engine;
}

destroy_engine :: (engine : *Engine) {
    Magma.destroy_engine(engine.renderEngine);

    engine_cleanup(engine, resetMemory = false);

    if engine.allocator != null {
        Basic.free(engine, engine.allocator, engine.allocator_data);
    }
}

// @todo Enable VR on option, currently doing so as long as available.
engine_init :: (engine : *EngineBase) {
    // Windowing
    engine.window = Crater.create_window(.{width=1600, height=900}, "sill");

    // Rendering
    renderEngineOptions : Magma.Engine.Options;
    renderEngineOptions.targetFlags |= .Vr;
    engine.renderEngine = Magma.create_engine(renderEngineOptions);
    engine.windowTarget = Magma.create_window_target(engine.renderEngine, Crater.window_get_handle(engine.window));
    engine.scene = Magma.create_scene(engine.renderEngine);

    if (engine.renderEngine.vr.enabled) {
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
    } else {
        engine.renderer = Magma.create_forward_renderer(engine.scene, Crater.window_get_extent(engine.window));
        engine.postProcessRenderer = Magma.create_post_process_renderer(engine.scene, Magma.renderer_get_output(engine.renderer));
        Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.postProcessRenderer));
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
            engine.Meta._update_entities(engine, updateTime);
            updateTimeLag -= updateTime;
        }

        // But we draw as fast as we can.
        Magma.engine_update(engine.renderEngine);
        Magma.engine_draw(engine.renderEngine);
    }

    Crater.destroy_window(engine.window);
}

#scope_file

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

        _input_handle_event(*engine.input, event);

        event = Crater.window_poll_event(engine.window);
    }

    // VR events
    if (engine.renderEngine.vr.enabled) {
        _input_handle_vr_events(*engine.input, engine.vrTarget);
    }
}
