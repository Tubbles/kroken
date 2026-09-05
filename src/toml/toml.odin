package toml

// A TOML subset parser producing an ordered tree, plus a writer and a
// deep merge. Supported: tables, dotted keys, inline tables, bare and
// quoted keys, basic and literal strings (single and multi-line),
// decimal integers, floats, booleans, arrays. Rejected with a clear
// error: arrays of tables, date and time values, non-decimal integers,
// inf and nan. This package knows nothing about kroken.
//
// Every allocation in a tree uses the allocator given to `parse` (or
// `new_table`); pass the same allocator to `destroy_table`.

import "core:strings"

Value :: union {
	i64,
	f64,
	bool,
	string,
	^Array,
	^Table,
}

Array :: struct {
	items: [dynamic]Value,
}

Table :: struct {
	keys:   [dynamic]string,
	values: [dynamic]Value,
	// Set once a `[header]` or an inline table `{}` defined the table
	// explicitly. A second header for an explicit table is an error, and
	// an inline table can never be extended, per the TOML specification.
	explicit: bool,
	inline:   bool,
}

Error :: struct {
	line:    int, // 1-based, 0 when the error has no position
	column:  int, // 1-based
	message: string,
}

new_table :: proc(allocator := context.allocator) -> ^Table {
	table := new(Table, allocator)
	table.keys = make([dynamic]string, allocator)
	table.values = make([dynamic]Value, allocator)
	return table
}

new_array :: proc(allocator := context.allocator) -> ^Array {
	array := new(Array, allocator)
	array.items = make([dynamic]Value, allocator)
	return array
}

destroy_table :: proc(table: ^Table, allocator := context.allocator) {
	if table == nil {
		return
	}
	for key in table.keys {
		delete(key, allocator)
	}
	for value in table.values {
		destroy_value(value, allocator)
	}
	delete(table.keys)
	delete(table.values)
	free(table, allocator)
}

destroy_value :: proc(value: Value, allocator := context.allocator) {
	#partial switch inner in value {
	case string:
		delete(inner, allocator)
	case ^Array:
		for item in inner.items {
			destroy_value(item, allocator)
		}
		delete(inner.items)
		free(inner, allocator)
	case ^Table:
		destroy_table(inner, allocator)
	}
}

clone_value :: proc(value: Value, allocator := context.allocator) -> Value {
	switch inner in value {
	case i64:
		return inner
	case f64:
		return inner
	case bool:
		return inner
	case string:
		return strings.clone(inner, allocator)
	case ^Array:
		array := new_array(allocator)
		for item in inner.items {
			append(&array.items, clone_value(item, allocator))
		}
		return array
	case ^Table:
		return clone_table(inner, allocator)
	}
	return nil
}

clone_table :: proc(table: ^Table, allocator := context.allocator) -> ^Table {
	clone := new_table(allocator)
	clone.explicit = table.explicit
	clone.inline = table.inline
	for key, index in table.keys {
		append(&clone.keys, strings.clone(key, allocator))
		append(&clone.values, clone_value(table.values[index], allocator))
	}
	return clone
}

table_index :: proc(table: ^Table, key: string) -> (index: int, found: bool) {
	for existing, position in table.keys {
		if existing == key {
			return position, true
		}
	}
	return -1, false
}

table_get :: proc(table: ^Table, key: string) -> (value: Value, found: bool) {
	index, key_found := table_index(table, key)
	if !key_found {
		return nil, false
	}
	return table.values[index], true
}

// Stores `value` under `key`, taking ownership of the value and
// destroying any previous value stored under the same key.
table_set :: proc(table: ^Table, key: string, value: Value, allocator := context.allocator) {
	if index, found := table_index(table, key); found {
		destroy_value(table.values[index], allocator)
		table.values[index] = value
		return
	}
	append(&table.keys, strings.clone(key, allocator))
	append(&table.values, value)
}

table_remove :: proc(table: ^Table, key: string, allocator := context.allocator) -> (removed: bool) {
	index, found := table_index(table, key)
	if !found {
		return false
	}
	delete(table.keys[index], allocator)
	destroy_value(table.values[index], allocator)
	ordered_remove(&table.keys, index)
	ordered_remove(&table.values, index)
	return true
}

// Looks up a dotted path such as "claude.model". Path segments must not
// themselves contain dots.
get_path :: proc(root: ^Table, path: string) -> (value: Value, found: bool) {
	table := root
	remaining := path
	for {
		dot := strings.index_byte(remaining, '.')
		if dot < 0 {
			return table_get(table, remaining)
		}
		child, child_found := table_get(table, remaining[:dot])
		if !child_found {
			return nil, false
		}
		child_table, is_table := child.(^Table)
		if !is_table {
			return nil, false
		}
		table = child_table
		remaining = remaining[dot + 1:]
	}
}

get_string :: proc(root: ^Table, path: string) -> (result: string, found: bool) {
	value := get_path(root, path) or_return
	return value.(string)
}

get_i64 :: proc(root: ^Table, path: string) -> (result: i64, found: bool) {
	value := get_path(root, path) or_return
	return value.(i64)
}

// Accepts an integer where a float is expected, as TOML users write
// `max = 1` as readily as `max = 1.0`.
get_f64 :: proc(root: ^Table, path: string) -> (result: f64, found: bool) {
	value := get_path(root, path) or_return
	#partial switch inner in value {
	case f64:
		return inner, true
	case i64:
		return f64(inner), true
	}
	return 0, false
}

get_bool :: proc(root: ^Table, path: string) -> (result: bool, found: bool) {
	value := get_path(root, path) or_return
	return value.(bool)
}

get_table :: proc(root: ^Table, path: string) -> (result: ^Table, found: bool) {
	value := get_path(root, path) or_return
	return value.(^Table)
}

get_array :: proc(root: ^Table, path: string) -> (result: ^Array, found: bool) {
	value := get_path(root, path) or_return
	return value.(^Array)
}

// Deep merge: every key in `source` is copied into `destination`. Tables
// on both sides merge recursively; anything else in `source` replaces
// what `destination` had. `source` is left untouched.
merge :: proc(destination: ^Table, source: ^Table, allocator := context.allocator) {
	for key, index in source.keys {
		source_value := source.values[index]
		if destination_index, found := table_index(destination, key); found {
			destination_table, destination_is_table := destination.values[destination_index].(^Table)
			source_table, source_is_table := source_value.(^Table)
			if destination_is_table && source_is_table {
				merge(destination_table, source_table, allocator)
				continue
			}
		}
		table_set(destination, key, clone_value(source_value, allocator), allocator)
	}
}

format_error :: proc(error: Error, path: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, path)
	if error.line > 0 {
		strings.write_byte(&builder, ':')
		strings.write_int(&builder, error.line)
		strings.write_byte(&builder, ':')
		strings.write_int(&builder, error.column)
	}
	strings.write_string(&builder, ": ")
	strings.write_string(&builder, error.message)
	return strings.to_string(builder)
}

