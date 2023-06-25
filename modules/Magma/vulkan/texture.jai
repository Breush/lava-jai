TextureImpl :: struct {
    imageHolder : ImageHolder;
    imageView : Vk.ImageView;
    imageLayout : Vk.ImageLayout;
}

impl_texture_cleanup :: (texture : *Texture) {
    _image_holder_cleanup(*texture.imageHolder);

    Vk.destroy_image_view(texture.engine.device, texture.imageView, null);
    texture.imageView = null;
}

impl_texture_load_from_memory :: (texture : *Texture, pixels : []u8, extent : Chamber.uvec2) {
    channelsCount := pixels.count / (extent.x * extent.y);

    kind := ifx texture.srgb then ImageHolder.Kind.Texture else .TextureMap;
    _image_holder_init(*texture.imageHolder, texture.engine, Basic.tprint("texture#%.imageHolder", texture.id), kind, extent, cast(u8) channelsCount);
    _image_holder_copy(*texture.imageHolder, pixels, .FragmentInput);

    if texture.imageView == null {
        texture.imageView = _image_holder_create_view(*texture.imageHolder);
        texture.imageLayout = .ShaderReadOnlyOptimal;
    }
}
