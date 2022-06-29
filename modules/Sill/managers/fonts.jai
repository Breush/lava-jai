Fonts :: struct {
    renderEngine : *Magma.Engine;
    infos : Hash.Table(string, Info);

    Info :: struct {
        font : Chamber.Font;
        texture : *Magma.Texture;
    }
}

fonts_register :: (iFont : *Fonts, fontId : string, filenames : []string, size : float) {
    fontInfo := Hash.table_add(*iFont.infos, fontId, .{});
    fontInfo.font = Chamber.font_load(filenames, size);
    fontInfo.texture = Magma.create_texture(iFont.renderEngine);
}

fonts_register :: (iFont : *Fonts, fontId : string, filename : string, size : float) {
    array : [1]string;
    array[0] = filename;
    fonts_register(iFont, fontId, array, size);
}

fonts_glyph_infos :: (iFont : *Fonts, fontId : string, text : string) -> [..]Chamber.GlyphInfo {
    fontInfo := table_find_pointer(iFont.infos, fontId);
    glyphInfos, pixelsChanged := Chamber.font_glyph_infos(*fontInfo.font, text);
    if pixelsChanged {
        Magma.texture_load_from_memory(fontInfo.texture, fontInfo.font.pixels, fontInfo.font.extent);
    }
    return glyphInfos;
}

fonts_info :: (iFont : *Fonts, fontId : string) -> *Fonts.Info {
    return table_find_pointer(iFont.infos, fontId);
}

#scope_module

_fonts_init :: (iFont : *Fonts, renderEngine : *Magma.Engine) {
    iFont.renderEngine = renderEngine;
}

_fonts_cleanup :: (iFont : *Fonts) {
    for *fontInfo : iFont.infos {
        Chamber.font_free(*fontInfo.font);
        Magma.destroy_texture(fontInfo.texture);
    }
}
