EngineBase :: struct {
    window : *Crater.Window;
    renderEngine : *Magma.Engine;
    windowTarget : *Magma.WindowTarget;
    scene : *Magma.Scene;
    renderer : *Magma.Renderer;
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

// :CameraInEngineTBR
camera : Magma.OrbitCamera;

engine_init :: (engine : *EngineBase) {
    // Windowing
    engine.window = Crater.create_window(.{width=1600, height=900}, "sill");

    // Rendering
    engine.renderEngine = Magma.create_engine();
    engine.windowTarget = Magma.create_window_target(engine.renderEngine, Crater.window_get_handle(engine.window));
    engine.scene = Magma.create_scene(engine.renderEngine);
    engine.renderer = Magma.create_forward_renderer(engine.scene, Crater.window_get_extent(engine.window));
    Magma.target_bind(engine.windowTarget, Magma.renderer_get_output(engine.renderer));

    // :CameraInEngineTBR
    camera = Magma.renderer_make_orbit_camera(engine.renderer);
    Magma.orbit_camera_origin_target(*camera, .{2, 0, 0.5}, .{0, 0, 0.5});
}

engine_cleanup :: (engine : *Engine, resetMemory := true) {
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

    while engine.window.opened {
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
            _engine_handle_input(engine);
            engine.Meta._update_entities(engine, updateTime);
            updateTimeLag -= updateTime;
        }

        // But we draw as fast as we can.
        Magma.engine_update(engine.renderEngine);
        Magma.engine_draw(engine.renderEngine);
    }
}

#scope_file

_engine_handle_input :: (engine : *EngineBase) {
    event := Crater.window_poll_event(engine.window);

    while event.kind != Crater.Event.Kind.None {
        if event.kind == Crater.Event.Kind.WindowClosed {
            Crater.destroy_window(engine.window);
            return;
        }
        else if event.kind == Crater.Event.Kind.KeyPressed &&
                event.key.which == Crater.Key.Escape {
            Crater.destroy_window(engine.window);
            return;
        }
        // @fixme :CameraInEngineTBR Have actions and BehaviorComponent to
        // allow that code to be outside the engine.
        else if event.kind == .MousePointerMoved {
            dx := cast(float) event.mousePointer.dx / 100.;
            dy := cast(float) event.mousePointer.dy / 100.;
            Magma.orbit_camera_rotate_around_target(*camera, -dx, dy);
        }
        else if event.kind == .MouseWheelScrolled {
            Magma.orbit_camera_add_to_radius(*camera, -Magma.orbit_camera_radius(*camera) * event.mouseWheel.delta / 10.);
        }

        event = Crater.window_poll_event(engine.window);
    }
}
