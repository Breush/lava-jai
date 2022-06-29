TextureImpl :: struct {
    imageHolder : ImageHolder;
    imageView : Vk.ImageView;
    imageLayout : Vk.ImageLayout;
}

impl_texture_cleanup :: (texture : *Texture) {
    _image_holder_cleanup(*texture.imageHolder);

    Vk.destroy_image_view(texture.engine.device, texture.imageView, null);
}

impl_texture_load_from_memory :: (texture : *Texture, pixels : []u8, extent : Chamber.uvec2) {
    channelsCount := pixels.count / (extent.x * extent.y);

    _image_holder_init(*texture.imageHolder, texture.engine, "texture.imageHolder", .Texture, extent, cast(u8) channelsCount);
    _image_holder_copy(*texture.imageHolder, pixels, .FragmentInput);

    // @note We might be creating too many image views.
    texture.imageView = _image_holder_create_view(*texture.imageHolder);
    texture.imageLayout = .ShaderReadOnlyOptimal;
}
