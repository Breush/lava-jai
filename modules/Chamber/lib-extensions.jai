// Standard library extensions

table_find_entry :: (table : Table, key : table.Key_Type) -> *table.Value_Type, *table.Key_Type {
    if !table.allocated  return null, null;

    hash := table.hash_function(key);
    if hash < FIRST_VALID_HASH  hash += FIRST_VALID_HASH;

    index := hash & (table.allocated - 1);
    probe_increment: u32 = 1;

    while table.entries[index].hash {
        entry := *table.entries[index];
        if entry.hash == hash {
            if table.compare_function(entry.key, key)  return *entry.value, *entry.key;
        }

        index += probe_increment;
        probe_increment += 1;
        while index >= table.allocated  index -= table.allocated;
    }

    return null, null;
}

table_find_or_add :: (table : *Table, key : table.Key_Type) -> *table.Value_Type {
    value := table_find_pointer(<<table, key);
    if value == null {
        _value : table.Value_Type;
        value = table_add(table, key, _value);
    }
    return value;
}

#scope_file

#import "Hash_Table";
