Font :: struct {
    infos : [..]Info;
    size : float;

    // Image-related
    extent : uvec2;
    pixels : [..]u8;
    nextGlyphStartPosition : u32 = 1;

    glyphInfos : Hash.Table(Codepoint, GlyphInfo);

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

Codepoint :: u32;

GlyphInfo :: struct {
    blank := true;
    minUv, maxUv : vec2;

    // Position, relative to previous glyph, and extent
    offset : vec2;
    extent : vec2;

    // Horizontal offset to position the next glyph, when getting the list of extented glyph infos
    // for a text, this is already baked in the offset of the next glyph.
    advance : float;

    fontInfo : *Font.Info;
    codepoint : Codepoint;
    index : s32;
}

font_load :: (filenames : []string, size : float) -> Font {
    font : Font;
    font.size = size;

    for filename : filenames {
        Basic.array_add(*font.infos, .{});
        fontInfo := Basic.peek_pointer(font.infos);
        fontInfo.filename = filename;
        fileBytes, readOk := File.read_entire_file(filename);
        _CHECK(readOk, font, "Unable to read font file: %", filename);
        fontInfo.content = fileBytes;

        StbTrueType.init_font(*fontInfo.stb, fontInfo.content.data, 0);

        fontInfo.glyphScale = StbTrueType.scale_for_mapping_em_to_pixels(*fontInfo.stb, size);
        StbTrueType.get_font_v_metrics(*fontInfo.stb, *fontInfo.glyphAscent, null, null);

        x0, y0, x1, y1 : s32;
        StbTrueType.get_font_bounding_box(*fontInfo.stb, *x0, *y0, *x1, *y1);
        fontInfo.glyphMaxExtent.width = cast(u32) Math.ceil((x1 - x0) * fontInfo.glyphScale);
        fontInfo.glyphMaxExtent.height = cast(u32) Math.ceil((y1 - y0) * fontInfo.glyphScale);

        font.extent.width = Basic.max(font.extent.width, fontInfo.glyphMaxExtent.width * Font.MAX_GLYPH_COUNT);
        font.extent.height = Basic.max(font.extent.height, fontInfo.glyphMaxExtent.height);

    }

    Basic.array_resize(*font.pixels, font.extent.width * font.extent.height);

    return font;
}

font_free :: (font : *Font) {
    for info : font.infos {
        Basic.free(info.content);
    }
    Basic.array_free(font.infos);
    Basic.array_free(font.pixels);
    Hash.deinit(*font.glyphInfos);
}

// @note We're not considering subpixel for now, which would require to redraw each letter
// on a new buffer. This is definitely possible, but require much more work.
font_glyph_infos :: (font : *Font, str : string) -> [..]GlyphInfo, pixelsChanged : bool {
    glyphInfos : [..]GlyphInfo;
    pixelsChanged := false;

    advance : float;

    s := str;
    while s.count != 0 {
        codepoint := Unicode.character_utf8_to_utf32(s.data, s.count);
        Unicode.utf8_next_character(*s);

        pGlyphInfo, glyphInfoPixelsChanged := font_glyph_info(font, codepoint);
        pixelsChanged = pixelsChanged || glyphInfoPixelsChanged;
        glyphInfo := pGlyphInfo.*;

        glyphInfo.offset.x += advance;

        if glyphInfo.fontInfo != null && s.count != 0 {
            nextCodepoint := Unicode.character_utf8_to_utf32(s.data, s.count);
            kernAdvance := StbTrueType.get_codepoint_kern_advance(*glyphInfo.fontInfo.stb, cast,no_check(s32) codepoint, cast,no_check(s32) nextCodepoint);
            advance += (glyphInfo.advance + kernAdvance * glyphInfo.fontInfo.glyphScale);
        }

        Basic.array_add(*glyphInfos, glyphInfo);
    }

    return glyphInfos, pixelsChanged;
}

font_text_width :: (font : *Font, str : string) -> float {
    advance : float;

    lastGlyphInfo : *GlyphInfo;

    s := str;
    while s.count != 0 {
        codepoint := Unicode.character_utf8_to_utf32(s.data, s.count);
        Unicode.utf8_next_character(*s);

        lastGlyphInfo = font_glyph_info(font, codepoint, draw = false);

        if lastGlyphInfo.fontInfo != null && s.count != 0 {
            nextCodepoint := Unicode.character_utf8_to_utf32(s.data, s.count);
            kernAdvance := StbTrueType.get_codepoint_kern_advance(*lastGlyphInfo.fontInfo.stb, cast,no_check(s32) codepoint, cast,no_check(s32) nextCodepoint);
            advance += (lastGlyphInfo.advance + kernAdvance * lastGlyphInfo.fontInfo.glyphScale);
        }
    }

    return advance + lastGlyphInfo.offset.x + lastGlyphInfo.extent.x;
}

font_glyph_info :: (font : *Font, codepoint : Codepoint, draw := true) -> *GlyphInfo, pixelsChanged : bool {
    glyphInfo := Hash.table_find_pointer(*font.glyphInfos, codepoint);
    if glyphInfo == null {
        glyphInfo = Hash.table_add(*font.glyphInfos, codepoint, .{});
        glyphInfo.codepoint = codepoint;
        glyphInfo.fontInfo, glyphInfo.index = _find_glyph_index(font, codepoint);
        if glyphInfo.index == 0 then return glyphInfo, false; // Glyph does not exist in any font.

        // Basic glyph advance
        advance, lsb : s32;
        x0, y0, x1, y1 : s32;
        StbTrueType.get_glyph_h_metrics(*glyphInfo.fontInfo.stb, glyphInfo.index, *advance, *lsb);
        StbTrueType.get_glyph_bitmap_box(*glyphInfo.fontInfo.stb, glyphInfo.index, glyphInfo.fontInfo.glyphScale, glyphInfo.fontInfo.glyphScale, *x0, *y0, *x1, *y1);

        glyphInfo.advance = advance * glyphInfo.fontInfo.glyphScale;

        // Glyph is blank
        width := x1 - x0;
        height := y1 - y0;

        glyphInfo.blank = (width == 0 || height == 0);
        glyphInfo.extent.width = cast(float) width;
        glyphInfo.extent.height = cast(float) height;
        glyphInfo.offset.x = cast(float) x0;
        glyphInfo.offset.y = cast(float) (glyphInfo.fontInfo.glyphAscent * glyphInfo.fontInfo.glyphScale + y0);
    }

    if glyphInfo.blank return glyphInfo, false;

    // @todo Investigate signed distance fields (stbtt_GetCodepointSDF).

    // Draw the bitmap to the pixels
    if draw && glyphInfo.minUv.x == 0 && glyphInfo.maxUv.x == 0 {
        glyphStartPosition := cast(s32) font.nextGlyphStartPosition;
        StbTrueType.make_glyph_bitmap(*glyphInfo.fontInfo.stb, font.pixels.data + glyphStartPosition,
                                      cast,no_check(s32) glyphInfo.extent.width, cast,no_check(s32) glyphInfo.extent.height, cast,no_check(s32) font.extent.width, glyphInfo.fontInfo.glyphScale, glyphInfo.fontInfo.glyphScale, glyphInfo.index);
        font.nextGlyphStartPosition += cast,no_check(u32) glyphInfo.extent.width + 1;
        Basic.assert(font.nextGlyphStartPosition < font.extent.width);

        // Stores the uv informations.
        glyphInfo.minUv.x = cast(float) glyphStartPosition / cast(float) font.extent.width;
        glyphInfo.minUv.y = 0;
        glyphInfo.maxUv.x = (glyphStartPosition + glyphInfo.extent.width) / cast(float) font.extent.width;
        glyphInfo.maxUv.y = glyphInfo.extent.height / cast(float) font.extent.height;

        return glyphInfo, true;
    }

    return glyphInfo, false;
}

#scope_file

Math :: #import "Math";
File :: #import "File";
Hash :: #import "Hash_Table";
Unicode :: #import "Unicode";
StbTrueType :: #import "StbTrueType";

_find_glyph_index :: (font : *Font, codepoint : Codepoint) -> (*Font.Info, s32) {
    for *fontInfo : font.infos {
        index := StbTrueType.find_glyph_index(*fontInfo.stb, cast,no_check(s32) codepoint);
        if index != 0 then return fontInfo, index;
    }
    return null, 0;
}
