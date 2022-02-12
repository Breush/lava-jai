# lava

This project is a port of [lava](https://github.com/Breush/lava/) to Jai language.<br/>
I'm not creating bindings to it, I'm rewritting it completely in Jai.

**Still a work in progress!**<br/>
Focusing on linux support so far, so it's probably useless for other platforms right now.

**NOTE:** There is no example in this repository to try out. If you're interested in the project, better have a look at:
- https://github.com/Breush/lava-jai-examples (compilation of simple examples demonstrating the different *lava* modules)
- https://github.com/Breush/hell-is-other-yourselves (VR game in development using *lava*)

## Project's composition

The **lava** project is in fact a bundle of multiple projects. The image below describes what's the **goal**.

![](doc/images/lava.jpg)

The core principles of **lava** are:
- Provide cross-platform redistribuable modules.
- Keep in mind [essentials in designing API](https://caseymuratori.com/blog_0024).
- Be simple. Document using clever examples.

## Current status

- [40%] **Crater** (windowing system)
    - Linux support OK using generated Xcb/Xkb bindings.
    - Windows support using DWM not started.
    - Missing fullscreen option.
- [70%] **Magma** (real-time 3D engine)
    - Linux support OK using Vulkan.
    - Using Vulkan for all platforms is the goal, but currently untested.
- [0%] **Dike** (physics engine)
    - Port not started. Goal is to use Bullet as BE for all platforms.
- [0%] **Flow** (sound engine)
    - Port not started.
- [40%] **Sill** (game engine - Jai API)
    - Basic support for now.
- [0%] **Caldera** (game engine - drag&drop editor)
    - Not started.

## About module design

There are two pairs of words used to make objects of modules.
- `create`/`destroy` to allocate and free memory, will automatically call the `init` and `cleanup`. Allocation will use the `context.allocator` and remember it.
- `init`/`cleanup` to be low-level, these functions suppose that the memory have already been allocated. If you go this path, `cleanup` is expected to be called before you free your memory.

This design has been chosen to let people express things as they want. One can use the fast path to quickly try out things, and one can use the explicit path to manage memory even more precisely.

Here's a quick example:

```jai
#import "Magma"; // The rendering library

// This...
implicit :: () {
    engine := create_engine();
    target := create_window_target(engine, handle);
    // ...
    destroy_engine(engine); // Will destroy registered target too by default.
}

// ... is equivalent to this:
explicit :: () {
    engine := New(Engine);
    engine_init(engine);

    target := New(WindowTarget);
    window_target_init(target, engine, handle);
    engine_register(engine, target);

    // ...

    target_cleanup(target);
    free(target);
    engine_cleanup(engine); // Won't cleanup registered resources.
    free(engine);
}
```

The convention used here is that if a function starts with `engine_` or similar, it expects a pointer to an allocated `Engine` as first argument.

Have a look at the *examples* folder if you want to see all that in practice.

## Note about bindings

Bindings have been generated from C header files of the corresponding libs.
This might be out-of-sync with what you have on your system and can cause issues.
But this what I want to go for as long as the project is not more advanced.
Later, effective pre-compiled binaries may be shipped alongside bindings' modules.
For now, you just have to cross your fingers that there are compatible.

__NOTE__: Vulkan's binaries (and validation layers) are currently shipped.
They are big, so I am sad.
