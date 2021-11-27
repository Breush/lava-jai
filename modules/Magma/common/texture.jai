Texture :: struct {
    engine : *Engine;

    using textureImpl : TextureImpl;

    allocator : Allocator;
}

// Allocate, init and register a new texture.
create_texture :: (engine : *Engine) -> *Texture {
    texture := cast(*Texture) Basic.New(Texture);
    Basic.remember_allocators(texture);
    texture_init(texture, engine);
    engine_register(engine, texture);
    return texture;
}

destroy_texture :: (texture : *Texture) {
    texture_cleanup(texture, resetMemory = false);

    if texture.allocator.proc != null {
        Basic.free(texture, texture.allocator);
    }
}

texture_init :: (texture : *Texture, engine : *Engine) {
    texture.engine = engine;
}

texture_cleanup :: (texture : *Texture, resetMemory := true) {
    impl_texture_cleanup(texture);

    if resetMemory {
        <<texture = Texture.{};
    }
}

// Channel count will be deduced from pixels array size and extent.
texture_load_from_memory :: (texture : *Texture, pixels : []u8, extent : Chamber.uvec2) {
    impl_texture_load_from_memory(texture, pixels, extent);
}
