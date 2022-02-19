Font :: struct {
    info : Info;

    // Image-related
    extent : uvec2;
    pixels : [..]u8;
    nextGlyphStartPosition : u32 = 1;

    glyphInfos : Hash.Table(CodePoint, GlyphInfo);

    Info :: struct {
        stb : StbTrueType.Fontinfo;
        filename : string;
        content : string;
        glyphMaxExtent : uvec2;
        glyphScale : float = 1.0;
        glyphAscent : s32;
    }

    MAX_GLYPH_COUNT :: 32; // @todo Why? Better make a new pixel array if no more space.
}

CodePoint :: u32;

GlyphInfo :: struct {
    blank := true;
    minUv, maxUv : vec2;

    // Position, relative to previous glyph, and extent
    offset : vec2;
    extent : vec2;

    // Horizontal offset to position the next glyph, when getting the list of extented glyph infos
    // for a text, this is already baked in the offset of the next glyph.
    advance : float;

    index : s32;
}

font_load :: (filename : string, size : float) -> Font {
    font : Font;
    font.info.filename = filename;
    fileBytes, readOk := File.read_entire_file(filename);
    _CHECK(readOk, font, Basic.tprint("Unable to read font file: %", filename));
    font.info.content = fileBytes;

    StbTrueType.init_font(*font.info.stb, font.info.content.data, 0);

    font.info.glyphScale = StbTrueType.scale_for_pixel_height(*font.info.stb, size);
    StbTrueType.get_font_v_metrics(*font.info.stb, *font.info.glyphAscent, null, null);

    x0, y0, x1, y1 : s32;
    StbTrueType.get_font_bounding_box(*font.info.stb, *x0, *y0, *x1, *y1);
    font.info.glyphMaxExtent.width = cast(u32) Math.ceil((x1 - x0) * font.info.glyphScale);
    font.info.glyphMaxExtent.height = cast(u32) Math.ceil((y1 - y0) * font.info.glyphScale);

    font.extent.width = font.info.glyphMaxExtent.width * Font.MAX_GLYPH_COUNT;
    font.extent.height = font.info.glyphMaxExtent.height;

    Basic.array_resize(*font.pixels, font.extent.width * font.extent.height);

    return font;
}

// @note We're not considering subpixel for now, which would require to redraw each letter
// on a new buffer. This is definitely possible, but require much more work.
font_glyph_infos :: (font : *Font, str : string) -> [..]GlyphInfo {
    glyphInfos : [..]GlyphInfo;

    advance : float;

    s := str;
    while s.count != 0 {
        codePoint := Unicode.character_utf8_to_utf32(s.data, s.count);
        Unicode.utf8_next_character(*s);
        nextCodePoint := Unicode.character_utf8_to_utf32(s.data, s.count);

        glyphInfo := <<font_glyph_info(font, codePoint);

        glyphInfo.offset.x += advance;
        kernAdvance := StbTrueType.get_codepoint_kern_advance(*font.info.stb, cast,no_check(s32) codePoint, cast,no_check(s32) nextCodePoint);
        advance += (glyphInfo.advance + kernAdvance * font.info.glyphScale);

        // @todo This pseudo-subpixel clean on option?
        glyphInfo.offset.x = Math.floor(glyphInfo.offset.x + 0.5);
        glyphInfo.offset.y = Math.floor(glyphInfo.offset.y + 0.5);

        Basic.array_add(*glyphInfos, glyphInfo);
    }

    return glyphInfos;
}

font_glyph_info :: (font : *Font, codePoint : CodePoint) -> *GlyphInfo {
    glyphInfo := Hash.table_find_pointer(font.glyphInfos, codePoint);
    if glyphInfo != null then return glyphInfo;

    glyphInfo = Hash.table_add(*font.glyphInfos, codePoint, .{});
    glyphInfo.index = StbTrueType.find_glyph_index(*font.info.stb, cast,no_check(s32) codePoint);
    if glyphInfo.index == 0 then return glyphInfo; // Glyph does not exist in font.

    // Basic glyph advance
    advance, lsb : s32;
    x0, y0, x1, y1 : s32;
    StbTrueType.get_glyph_h_metrics(*font.info.stb, glyphInfo.index, *advance, *lsb);
    StbTrueType.get_glyph_bitmap_box(*font.info.stb, glyphInfo.index, font.info.glyphScale, font.info.glyphScale, *x0, *y0, *x1, *y1);

    glyphInfo.advance = advance * font.info.glyphScale;

    // Glyph is blank
    width := x1 - x0;
    height := y1 - y0;
    if width == 0 || height == 0 return glyphInfo;

    glyphInfo.blank = false;
    glyphInfo.extent.width = cast(float) width;
    glyphInfo.extent.height = cast(float) height;
    glyphInfo.offset.x = cast(float) x0;
    glyphInfo.offset.y = cast(float) (font.info.glyphAscent * font.info.glyphScale + y0);

    // Draw the bitmap to the pixels
    glyphStartPosition := cast(s32) font.nextGlyphStartPosition;
    StbTrueType.make_glyph_bitmap(*font.info.stb, font.pixels.data + glyphStartPosition,
                                  width, height, cast,no_check(s32) font.extent.width, font.info.glyphScale, font.info.glyphScale, glyphInfo.index);
    font.nextGlyphStartPosition += cast,no_check(u32) width + 1;
    Basic.assert(font.nextGlyphStartPosition < font.extent.width);

    // Stores the uv informations.
    glyphInfo.minUv.x = cast(float) glyphStartPosition / cast(float) font.extent.width;
    glyphInfo.minUv.y = 0;
    glyphInfo.maxUv.x = cast(float) (glyphStartPosition + width) / cast(float) font.extent.width;
    glyphInfo.maxUv.y = cast(float) height / cast(float) font.extent.height;

    return glyphInfo;
}

#scope_file

Math :: #import "Math";
File :: #import "File";
Hash :: #import "Hash_Table";
Unicode :: #import "Unicode";
StbTrueType :: #import "StbTrueType";