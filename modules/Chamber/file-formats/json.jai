/*
 * Freely inspired by https://github.com/rluba/jason
 * - Most of code stolen from it. Thanks rluba!
 * - Some quality-of-life improvements (one-file, operator[] overloads, INVALID type).
 * - Removal of write functions.
 * - Some functions/structs renamed.
 */

JsonType :: enum u8 {
    INVALID :: 0;
    NULL;
    BOOLEAN;
    NUMBER;
    STRING;
    ARRAY;
    OBJECT;
}

JsonValue :: struct {
    type: JsonType;
    union {
        boolean: bool;
        number: float64;
        str: string;
        array: [..] JsonValue;
        object: *JSON_Object;
    };
}

json_parse_string :: (content: string) -> JsonValue, success: bool {
    result, remainder, success := parse_value(content);
    if !success        return result, false;

    remainder = trim_whitespaces(remainder);
    if remainder.count {
        report_error("Unexpected trailing characters: %", remainder);
        return result, false;
    }

    return result, true;
}

json_parse_file :: (filename: string) -> JsonValue, success: bool {
    file, success := file_open(filename, log_errors = false);
    result: JsonValue;
    if !success {
        report_error("Couldn’t open file %", filename);
        return result, false;
    }
    defer file_close(*file);

    fileData : string;
    fileData, success = read_entire_file(file);
    if !success {
        report_error("Couldn’t read file %", filename);
        return result, false;
    }

    defer free(fileData);
    result, success = json_parse_string(fileData);
    return result, success;
}

json_free :: (using val: JsonValue) {
    if #complete type == {
        case .INVALID;
        case .NULL;
        case .BOOLEAN;
        case .NUMBER;

        case .STRING;
            free(str);
        case .ARRAY;
            for array {
                json_free(it);
            }
            array_free(array);
        case .OBJECT;
            for object {
                free(it_index);
                json_free(it);
            }
            deinit(object);

            free(object);
    }
}

operator [] :: (json_val: JsonValue, key: string) -> JsonValue {
    assert(json_val.type == .OBJECT);
    table := <<json_val.object;
    val, success := table_find(*table, key);
    if !success then {
        val.type = .INVALID;
    }
    return val;
}

operator [] :: (json_val: JsonValue, i: u64) -> JsonValue {
    assert(json_val.type == .ARRAY);
    return json_val.array[i];
}

#scope_file

WHITESPACE_CHARS :: " \t\r\n";

get_array_stride :: (size: s64) -> s64 {
    // @Robustness: We assume 8-byte alignment for now.
    return (size + 7) & ~7;
}

parse_value :: (to_parse: string, slot: *u8, info: *Type_Info, ignore_unknown: bool) -> remainder: string, success: bool {
    remainder := trim_left(to_parse, WHITESPACE_CHARS);
    success := true;

    prepare_slot :: (expected_type: Type_Info_Tag, info: *Type_Info, slot: *u8) -> *u8, success: bool, info: *Type_Info {
        value_info := info;
        if info.type == .POINTER {
            pointer_info := cast(*Type_Info_Pointer) info;
            assert(pointer_info.relative_pointer_size == 0, "Relative pointers are not yet supported"); // @Incomplete
            value_info = pointer_info.pointer_to;
        }
        if value_info.type != expected_type {
            report_error("Cannot parse % value into type type %", expected_type, <<info);
            return null, false, value_info;
        }
        if info.type == .POINTER {
            value_slot := alloc(value_info.runtime_size);
            <<cast(**u8)slot = value_slot;
            return value_slot, true, value_info;
        } else {
            return slot, true, value_info;
        }
    }

    if remainder[0] == {
        case #char "n";
            remainder, success = expect_and_slice(remainder, "null");
            if !success        return remainder, false;
            if slot {
                // @ToDo, @Incomplete: Handle null properly
                if info.type != .POINTER {
                    report_error("Got NULL value for non-pointer type %. Assigning default value instead.", <<info);
                }
            }
            return remainder, true;
        case #char "t";
            remainder, success = expect_and_slice(remainder, "true");
            if !success        return remainder, false;
            if slot {
                value_slot: *u8;
                value_slot, success = prepare_slot(.BOOL, info, slot);
                if success {
                    <<cast(*bool)value_slot = true;
                }
            }
        case #char "f";
            remainder, success = expect_and_slice(remainder, "false");
            if !success        return remainder, false;
            if slot {
                value_slot: *u8;
                value_slot, success = prepare_slot(.BOOL, info, slot);
                if success {
                    <<cast(*bool)value_slot = false;
                }
            }
        case #char "\"";
            value: string;
            value, remainder, success = parse_string(remainder);
            stored := false;
            defer if !stored    free(value);
            if success && slot {
                value_slot: *u8;
                value_slot, success = prepare_slot(.STRING, info, slot);
                if success {
                    <<cast(*string)value_slot = value;
                    stored = true;
                }
            }
        case #char "[";
            value_slot: *u8;
            value_info: *Type_Info;
            if slot {
                value_slot, success, value_info = prepare_slot(.ARRAY, info, slot);
            }
            if success {
                remainder, success = parse_array(remainder, value_slot, cast(*Type_Info_Array) value_info, ignore_unknown);
            }
        case #char "{";
            value_slot: *u8;
            value_info: *Type_Info;
            if slot {
                value_slot, success, value_info = prepare_slot(.STRUCT, info, slot);
            }
            if success {
                remainder, success = parse_object(remainder, value_slot, cast(*Type_Info_Struct) value_info, ignore_unknown);
            }
        case;
            // @ToDo, @Incomplete: Check the slot type and parse as float, if needed! (…or if the slot is null)
            int_value: s64;
            int_value, success, remainder = to_integer(remainder);
            if success && slot {
                value_slot: *u8;
                value_info: *Type_Info;
                value_slot, success, value_info = prepare_slot(.INTEGER, info, slot);
                if success {
                    info_int := cast(*Type_Info_Integer) value_info;
                    success = write_integer(info_int, value_slot, int_value);
                }
            }
    }

    return remainder, success;
}

parse_array :: (str: string, slot: *u8, info: *Type_Info_Array, ignore_unknown: bool) -> remainder: string, success: bool {
    element_size: int;
    stride: int;
    if slot {
        assert(info.array_count == -1, "Fixed array are not implemented yet");
        assert(info.relative_pointer_size == 0, "Relative pointers are not yet supported");  // @Incomplete

        element_size = info.element_type.runtime_size;
        assert(element_size != -1, "Unknown element size");  // @Robustness @Incomplete: Right now, this might fail.
        stride = get_array_stride(element_size);
    }

    assert(str[0] == #char "[", "Invalid object start %", str);
    remainder := advance(str);
    remainder = trim_whitespaces(remainder);
    if remainder[0] == #char "]" {
        remainder = advance(remainder);
        // @Robustness: Do we need to zero out the array?
        return remainder, true;
    }

    if slot {
        array := cast(*Resizable_Array) slot;
        element_data := alloc(element_size);
        defer free(element_data);

        while true {
            memset(element_data, 0, element_size);
            success: bool;
            remainder, success = parse_value(remainder, element_data, info.element_type, ignore_unknown);
            if !success    return remainder, false;

            maybe_grow(array, element_size);
            memcpy(array.data + array.count * stride, element_data, stride);
            array.count += 1;

            remainder = trim_whitespaces(remainder);
            if remainder[0] != #char ","    break;
            remainder = advance(remainder);
            remainder = trim_whitespaces(remainder);
        }
    } else {
        while true {
            success: bool;
            remainder, success = parse_value(remainder, null, null, ignore_unknown);
            if !success    return remainder, false;

            remainder = trim_whitespaces(remainder);
            if remainder[0] != #char ","    break;
            remainder = advance(remainder);
            remainder = trim_whitespaces(remainder);
        }
    }

    if remainder[0] != #char "]"    return remainder, false;
    remainder = advance(remainder);
    return remainder, true;
}

maybe_grow :: (array: *Resizable_Array, element_size: s64) {
    if array.count >= array.allocated {
        reserve := 2 * array.allocated;
        if reserve < 8  reserve = 8;

        if !array.allocator {
            if context.allocator {
                array.allocator      = context.allocator;
                array.allocator_data = context.allocator_data;
            } else {
                array.allocator      = context.default_allocator;
            }
        }

        array.data = realloc(array.data, reserve * element_size, array.allocated * element_size, array.allocator, array.allocator_data);
        assert(array.data != null); // Program will die if we couldn't get memory. We can think about an alternative strategy, but it's hard to know what would be reasonable.

        array.allocated = reserve;
    }
}

parse_object :: (str: string, slot: *u8, info: *Type_Info_Struct, ignore_unknown: bool) -> remainder: string, success: bool {
    assert(str[0] == #char "{", "Invalid object start %", str);
    remainder := advance(str);
    remainder = trim_whitespaces(remainder);
    if remainder[0] == #char "}" {
        remainder = advance(remainder);
        return remainder, true;
    }

    while true {
        if remainder[0] != #char "\""    return remainder, false;

        key: string;
        success: bool;
        key, remainder, success = parse_string(remainder);
        if !success        return remainder, false;
        defer free(key);

        member: *Type_Info_Struct_Member;
        member_slot: *u8;
        member_info: *Type_Info;
        if info {
            member = get_field(info, key);
        }
        if member {
            member_slot = slot + member.offset_in_bytes;
            member_info = member.type;
        } else if !ignore_unknown {
            report_error("Missing member % in %", key, <<info);
            return remainder, false;
        }

        remainder = trim_whitespaces(remainder);
        if remainder[0] != #char ":"    return remainder, false;
        remainder = advance(remainder);
        remainder = trim_whitespaces(remainder);
        remainder, success = parse_value(remainder, member_slot, member_info, ignore_unknown);
        if !success        return remainder, false;

        remainder = trim_whitespaces(remainder);
        if remainder[0] != #char ","    break;
        remainder = advance(remainder);
        remainder = trim_whitespaces(remainder);
    }

    if remainder[0] != #char "}"    return remainder, false;
    remainder = advance(remainder);
    return remainder, true;
}

expect_and_slice :: (str: string, expected: string) -> remainder: string, success: bool {
    if str.count < expected.count || !equal(slice(str, 0, expected.count), expected) {
        report_error("Unexpected token. Expected \"%\" but got: %", expected, str);
        return str, false;
    }
    remainder := advance(str, expected.count);
    return remainder, true;
}

parse_string :: (str: string) -> result: string, remainder: string, success: bool {
    assert(str[0] == #char "\"", "Invalid string start %", str);
    inside := advance(str);
    needsUnescape := false;
    while inside[0] != #char "\"" {
        if inside.count < 2     return "", str, false;
        if inside[0] == #char "\\" {
            needsUnescape = true;
            if inside.count < 2    return "", str, false;
            advance(*inside);
        }
        advance(*inside);
    }

    length := inside.data - str.data - 1;
    result := slice(str, 1, length);
    if needsUnescape {
        success: bool;
        result, success = unescape(result);
        if !success        return "", str, false;
    } else {
        result = copy_string(result);
    }

    remainder := slice(str, length + 2, str.count - length - 2);
    return result, remainder, true;
}

report_error :: (format: string, args: .. Any) {
    log(format, .. args);
}

JSON_Object :: Table(string, JsonValue);

// Generic JSON parsing/writing functions. Result is always a JsonValue,
// which is awful to read and even more awful to create for complex structures.
// But it’s useful for some cases where re-creating the whole JSON structure as
// custom Jai struct types is inconvenient or not possible.
parse_value :: (to_parse: string) -> JsonValue, remainder: string, success: bool {
    result: JsonValue;
    remainder := trim_left(to_parse, WHITESPACE_CHARS);
    success := false;
    if remainder[0] == {
        case #char "n";
            remainder, success = expect_and_slice(remainder, "null");
            if !success        return result, remainder, false;
            result.type = JsonType.NULL;
            return result, remainder, true;
        case #char "t";
            remainder, success = expect_and_slice(remainder, "true");
            if !success        return result, remainder, false;
            result.type = JsonType.BOOLEAN;
            result.boolean = true;
            return result, remainder, true;
        case #char "f";
            remainder, success = expect_and_slice(remainder, "false");
            if !success        return result, remainder, false;
            result.type = JsonType.BOOLEAN;
            return result, remainder, true;
        case #char "\"";
            str: string;
            str, remainder, success = parse_string(remainder);
            result.type = .STRING;
            result.str = str;
        case #char "[";
            result.type = JsonType.ARRAY;
            result.array, remainder, success = parse_array(remainder);
        case #char "{";
            obj := cast(*JSON_Object) alloc(size_of(JSON_Object));
            <<obj, remainder, success = parse_object(remainder);
            result.type = .OBJECT;
            result.object = obj;
        case;
            result.type = JsonType.NUMBER;
            result.number, success, remainder = string_to_float64(remainder);
    }

    return result, remainder, success;
}

parse_array:: (str: string) -> result: [..] JsonValue, remainder: string, success: bool {
    assert(str[0] == #char "[", "Invalid object start %", str);
    remainder := advance(str);
    result: [..] JsonValue;
    remainder = trim_whitespaces(remainder);
    if remainder[0] == #char "]" {
        remainder = advance(remainder);
        return result, remainder, true;
    }

    while true {
        value: JsonValue;
        success: bool;
        value, remainder, success = parse_value(remainder);
        if !success    return result, remainder, false;

        array_add(*result, value);

        remainder = trim_whitespaces(remainder);
        if remainder[0] != #char ","    break;
        remainder = advance(remainder);
        remainder = trim_whitespaces(remainder);
    }

    if remainder[0] != #char "]"    return result, remainder, false;
    remainder = advance(remainder);
    return result, remainder, true;
}

parse_object :: (str: string) -> result: JSON_Object, remainder: string, success: bool {
    assert(str[0] == #char "{", "Invalid object start %", str);
    remainder := advance(str);
    result: JSON_Object;
    remainder = trim_whitespaces(remainder);
    if remainder[0] == #char "}" {
        remainder = advance(remainder);
        return result, remainder, true;
    }

    init(*result, 32);
    while true {
        if remainder[0] != #char "\""    return result, remainder, false;

        key: string;
        value: JsonValue;
        success: bool;
        key, remainder, success = parse_string(remainder);
        if !success    return result, remainder, false;

        existing := table_find_pointer(*result, key);
        if existing        return result, remainder, false;

        remainder = trim_whitespaces(remainder);
        if remainder[0] != #char ":"    return result, remainder, false;
        remainder = advance(remainder);
        remainder = trim_whitespaces(remainder);
        value, remainder, success = parse_value(remainder);
        if !success    return result, remainder, false;

        table_add(*result, key, value);

        remainder = trim_whitespaces(remainder);
        if remainder[0] != #char ","    break;
        remainder = advance(remainder);
        remainder = trim_whitespaces(remainder);
    }

    if remainder[0] != #char "}"    return result, remainder, false;
    remainder = advance(remainder);
    return result, remainder, true;
}

trim_whitespaces :: (remainder : string) -> string {
    result := remainder;

    // Skipping comments too
    while true {
        result = trim_left(result, WHITESPACE_CHARS);
        if result.count > 2 && result[0] == #char "/" && result[1] == #char "/" {
            advance(*result, 2);
            while result.count > 0 && result[0] != #char "\n" {
                advance(*result);
            }
        } else {
            break;
        }
    }

    return result;
}

unescape :: (str: string) -> result: string, success: bool {
    result := alloc_string(str.count);
    rc := 0;
    for i: 0..str.count-1 {
        if str[i] != #char "\\" {
            // Check for invalid characters for JSON
            if str[i] < 0x20    return "", false;

            result[rc] = str[i];
            rc += 1;
        } else {
            if i == str.count - 1    return "", false;
            i += 1;
            if str[i] == {
                case #char "\""; #through;
                case #char "/"; #through;
                case #char "\\";
                    result[rc] = str[i];
                    rc += 1;
                case #char "b";
                    result[rc] = 0x08;
                    rc += 1;
                case #char "f";
                    result[rc] = 0x0c;
                    rc += 1;
                case #char "n";
                    result[rc] = #char "\n";
                    rc += 1;
                case #char "r";
                    result[rc] = #char "\r";
                    rc += 1;
                case #char "t";
                    result[rc] = #char "\t";
                    rc += 1;
                case #char "u";
                    if i + 4 >= str.count    return "", false;
                    unicode_char, success := parse_unicode(slice(str, i + 1, 4));
                    if !success        return "", false;
                    utf8_len := encode_utf8(unicode_char, *(result.data[rc]));
                    rc += utf8_len;
                    i += 4;
                case;
                    return "", false;
            }
        }
    }
    result.count = rc;
    return result, true;
}

parse_unicode :: (str: string) -> result: u16, success: bool {
    val, success, remainder := string_to_int(str, base = 16);
    if !success || val > 0xFFFF || remainder.count        return 0, false;
    return xx val, true;
}

encode_utf8 :: (val: u16, result: *u8) -> len: u8 {
    if val & 0xF800 {
        result[0] = xx (0xE0 | ((val & 0xF000) >> 12));
        result[1] = xx (0x80 | ((val & 0x0FC0) >> 6));
        result[2] = xx (0x80 | (val & 0x003F));
        return 3;
    } else if val & 0x0F80 {
        result[0] = xx (0xC0 | ((val & 0x0FC0) >> 6));
        result[1] = xx (0x80 | (val & 0x003F));
        return 2;
    } else {
        result[0] = xx (val & 0x7F);
        return 1;
    }
}

#scope_file

#import "Basic";
#import "File";
#import "String";
#import "Hash_Table";
