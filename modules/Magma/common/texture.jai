Texture :: struct {
    engine : *Engine;

    using textureImpl : TextureImpl;

    allocator : Allocator;

    srgb : bool;
    id : u32;
}

// Allocate, init and register a new texture.
create_texture :: (engine : *Engine, srgb := true) -> *Texture {
    texture := cast(*Texture) Basic.New(Texture);
    Basic.remember_allocators(texture);
    texture_init(texture, engine, srgb);
    engine_register(engine, texture);
    return texture;
}

destroy_texture :: (texture : *Texture, unregister := true) {
    texture_cleanup(texture, resetMemory = false);
    if unregister then engine_unregister(texture.engine, texture);

    if texture.allocator.proc != null {
        Basic.free(texture, texture.allocator);
    }
}

texture_init :: (texture : *Texture, engine : *Engine, srgb : bool) {
    texture.engine = engine;
    texture.srgb = srgb;
    texture.id = engine.nextTextureId;
    engine.nextTextureId += 1;

    // Basic.log("[Texture#%] Init", texture.id, flags = .VERBOSE_ONLY);
}

texture_cleanup :: (texture : *Texture, resetMemory := true) {
    impl_texture_cleanup(texture);

    // Basic.log("[Texture#%] Cleanup", texture.id, flags = .VERBOSE_ONLY);

    if resetMemory {
        texture.* = Texture.{};
    }
}

texture_load_from_file :: (texture : *Texture, filename : string) -> bool {
    fileBytes, readOk := File.read_entire_file(filename);
    defer Basic.free(fileBytes);
    _CHECK(readOk, "Unable to read texture file: %", filename);

    extent : Chamber.uvec2;
    pixelsRaw := stbi_load_from_memory(fileBytes.data, xx fileBytes.count, xx *extent.width, xx *extent.height, null, 4);

    _CHECK(extent.width != 0 && extent.height != 0, "Invalid texture file: %", filename);

    pixels : []u8;
    pixels.data = pixelsRaw;
    pixels.count = extent.width * extent.height * 4;

    texture_load_from_memory(texture, pixels, extent);
    stbi_image_free(pixelsRaw);

    return true;
}

// Channel count will be deduced from pixels array size and extent.
texture_load_from_memory :: (texture : *Texture, pixels : []u8, extent : Chamber.uvec2) {
    impl_texture_load_from_memory(texture, pixels, extent);
}

#scope_file

#import "stb_image";
