// Works only for ASCII, groups non-letters together followed by any lower-letters.
// ThisIsCRAZYBecause42And3dWork -> ["This", "Is", "CRAZY", "Because", "42", "And", "3d", "Work"]
split_from_pascal_or_camel_case :: (s : string) -> [..]string {
    words : [..]string;
    currentString : string;
    wordIsCapsOnly := false;
    wordIsSymbolsOnly := false;

    for i : 0 .. s.count - 1 {
        c := s[i];

        if (c >= #char "A" && c <= #char "Z") {
            if wordIsCapsOnly {
                currentString.count += 1;
            } else {
                if currentString.count != 0 {
                    Basic.array_add(*words, currentString);
                }

                currentString.data = s.data + i;
                currentString.count = 1;
            }

            wordIsCapsOnly = true;
            wordIsSymbolsOnly = false;
        }
        else if (c >= #char "a" && c <= #char "z") {
            // Hitting CAPSLowered, we split to CAPS/Lowered
            if wordIsCapsOnly && currentString.count > 1 {
                currentString.count -= 1;
                Basic.array_add(*words, currentString);
                currentString.data = s.data + i - 1;
                currentString.count = 2;
            } else {
                // This check is only to handle camelCase. Allowing a lower-letter in the first word.
                if currentString.count == 0 {
                    currentString.data = s.data + i;
                }

                currentString.count += 1;
            }

            wordIsCapsOnly = false;
            wordIsSymbolsOnly = false;
        }
        else {
            if wordIsSymbolsOnly {
                currentString.count += 1;
            } else {
                if currentString.count != 0 {
                    Basic.array_add(*words, currentString);
                }

                currentString.data = s.data + i;
                currentString.count = 1;
            }

            wordIsCapsOnly = false;
            wordIsSymbolsOnly = true;
        }
    }

    if currentString.count != 0 {
        Basic.array_add(*words, currentString);
    }

    return words;
}

join_as_snake_case :: (words : []string) -> string {
    if words.count == 0 then return "";

    builder : Basic.String_Builder;
    Basic.init_string_builder(*builder);
    defer Basic.reset(*builder);

    for i : 0 .. words.count - 2 {
        append_as_lower_case(*builder, words[i]);
        Basic.append(*builder, "_");
    }
    append_as_lower_case(*builder, Basic.peek(words));

    return Basic.builder_to_string(*builder);
}

join_as_camel_case :: (words : []string) -> string {
    if words.count == 0 then return "";

    builder : Basic.String_Builder;
    Basic.init_string_builder(*builder);
    defer Basic.reset(*builder);

    append_as_lower_case(*builder, words[0]);
    for i : 1 .. words.count - 1 {
        append_as_pascal_case(*builder, words[i]);
    }

    return Basic.builder_to_string(*builder);
}

append_as_lower_case :: (builder : *Basic.String_Builder, word : string) {
    for i : 0 .. word.count - 1 {
        if word[i] >= #char "A" && word[i] <= #char "Z" {
            Basic.append(builder, word[i] - #char "A" + #char "a");
        } else {
            Basic.append(builder, word[i]);
        }
    }
}

append_as_pascal_case :: (builder : *Basic.String_Builder, word : string) {
    if word.count == 0 then return;

    if word[0] >= #char "a" && word[0] <= #char "z" {
        Basic.append(builder, word[0] - #char "a" + #char "A");
    } else {
        Basic.append(builder, word[0]);
    }

    restOfWord := word;
    restOfWord.data += 1;
    restOfWord.count -= 1;
    append_as_lower_case(builder, restOfWord);
}

// @note We don't have that, not creating a string on the fly in the Unicode module.
// So this has been largely stolen.
utf32_to_utf8 :: (codepoint : u32, data : []u8) -> byteCount : s8 {
    UNI_MAX_LEGAL_UTF32 :: 0x0010FFFF;
    UNI_REPLACEMENT_CHAR :: 0x0000FFFD;
    FIRST_BYTE_MASK : [7] u8 : .[ 0x00, 0x00, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC ];

    ch := codepoint;
    byteCount : s8;
    if ch < 0x80                        byteCount = 1;
    else if ch < 0x800                  byteCount = 2;
    else if ch < 0x10000                byteCount = 3;
    else if ch <= UNI_MAX_LEGAL_UTF32   byteCount = 4;
    else {
        byteCount = 3;
        ch = UNI_REPLACEMENT_CHAR;
    }

    byteMask :: 0xBF;
    byteMark :: 0x80;

    if byteCount == {
        case 4; data[3] = cast(u8) ((ch | byteMark) & byteMask); ch = ch >> 6; #through;
        case 3; data[2] = cast(u8) ((ch | byteMark) & byteMask); ch = ch >> 6; #through;
        case 2; data[1] = cast(u8) ((ch | byteMark) & byteMask); ch = ch >> 6; #through;
        case 1; data[0] = cast(u8)  (ch | FIRST_BYTE_MASK[byteCount]);
    }

    return byteCount;
}

utf8_word_length_after_byte :: (s : string, byteIndex : u32) -> u8 {
    return 1 + Unicode.trailingBytesForUTF8[s[byteIndex]];
}

word_length_after_byte :: (s : string, byteIndex : u32) -> u32 {
    foundWord := false;
    for i : byteIndex + 1 .. cast(u32) s.count - 1 {
        if !foundWord {
            foundWord = s[i] != #char " ";
            continue;
        }
        if s[i] == #char " " then return i - byteIndex;
    }
    return cast(u32) s.count - byteIndex;
}

utf8_word_length_before_byte :: (s : string, byteIndex : u32) -> u8 {
    index := byteIndex - 1;
    while index >= 0 {
        // If a byte starts with 10xxxxxx, we're in the middle of a UTF8 word.
        if s[index] & 0b1100_0000 == 0b1000_0000 {
            index -= 1;
        } else {
            break;
        }
    }
    return cast(u8) (byteIndex - index);
}

word_length_before_byte :: (s : string, byteIndex : u32) -> u32 {
    foundWord := false;
    for < i : byteIndex - 1 .. cast(u32) 0 {
        if !foundWord {
            foundWord = s[i] != #char " ";
            continue;
        }
        if s[i] == #char " " then return byteIndex - i - 1;
    }
    return byteIndex;
}

delete_after_byte :: (s : *string, byteIndex : u32, bytesToDelete : u32) {
    s1 := <<s;
    s1.count = byteIndex;

    s2 := <<s;
    Basic.advance(*s2, byteIndex + bytesToDelete);

    memcpy(s1.data + s1.count, s2.data, s2.count); // :MissingMemmove
    s.count = s1.count + s2.count;
}

delete_before_byte :: (s : *string, byteIndex : u32, bytesToDelete : u32) {
    s1 := <<s;
    s1.count = byteIndex - bytesToDelete;

    s2 := <<s;
    Basic.advance(*s2, byteIndex);

    memcpy(s1.data + s1.count, s2.data, s2.count); // @todo :MissingMemmove Could be memmove, but the intrisics does not exist.
    s.count = s1.count + s2.count;
}

insert_after_byte :: (s : *string, byteIndex : u32, c : string) {
    s1 := <<s;
    s1.count = byteIndex;

    s2 := <<s;
    Basic.advance(*s2, byteIndex);

    // @todo Sometimes, we could prevent the reallocation, if the allocated space is known.
    // So maybe this should take a [..]u8?
    (<<s) = Basic.sprint("%1%2%3", s1, c, s2);
    Basic.free(s1);
}

#scope_file

Basic :: #import "Basic";
Unicode :: #import "Unicode";
