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

#scope_file

Basic :: #import "Basic";
