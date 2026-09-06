package config

// Parsing and tree operations for the SJSON configuration files, on top
// of core:encoding/json with Specification.SJSON. This file also owns
// two guards the core parser lacks: an empty or comment-only document
// is an empty object instead of an error, and an unterminated string
// is reported instead of silently parsing as "".

import "core:encoding/json"
import "core:slice"
import "core:strings"

Parse_Error :: struct {
	line:    int, // 1-based, 0 when there is no position
	column:  int, // 1-based
	message: string, // static
}

// Parses one document into its root object. Keys and strings are
// allocated with `allocator`; free the result with json.destroy_value.
parse_document :: proc(source: string, allocator := context.allocator) -> (root: json.Object, error: Parse_Error, ok: bool) {
	if line, column, unterminated := find_unterminated_string(source); unterminated {
		return nil, Parse_Error{line = line, column = column, message = "unterminated string"}, false
	}
	parser := json.make_parser_from_string(source, .SJSON, true, allocator)
	if parser.curr_token.kind == .EOF {
		return json.Object(make(map[string]json.Value, allocator)), {}, true
	}
	value: json.Value
	parse_error: json.Error
	#partial switch parser.curr_token.kind {
	case .Ident, .String:
		object, object_error := json.parse_object_body(&parser, .EOF)
		value, parse_error = object, object_error
	case:
		value, parse_error = json.parse_value(&parser)
	}
	if parse_error != .None {
		// parse_object_body frees what it had built before returning an
		// error, so there is nothing left to destroy here.
		return nil, Parse_Error{line = parser.curr_token.line, column = parser.curr_token.column, message = describe(parse_error)}, false
	}
	object, is_object := value.(json.Object)
	if !is_object {
		json.destroy_value(value, allocator)
		return nil, Parse_Error{line = 1, column = 1, message = "the document must consist of key = value pairs"}, false
	}
	return object, {}, true
}

@(private)
describe :: proc(error: json.Error) -> string {
	#partial switch error {
	case .Duplicate_Object_Key:
		return "duplicate key"
	case .Expected_Colon_After_Key:
		return "expected '=' after the key"
	case .Expected_String_For_Object_Key:
		return "expected a key"
	case .String_Not_Terminated:
		return "unterminated string"
	case .Invalid_String:
		return "invalid string"
	case .Invalid_Number:
		return "invalid number"
	case .Illegal_Character:
		return "illegal character"
	case .Unexpected_Token:
		return "unexpected token"
	case .EOF:
		return "unexpected end of file"
	}
	return "syntax error"
}

// Scans for a quoted string that ends at a newline or at the end of
// the input, skipping comments so quotes inside them do not count.
find_unterminated_string :: proc(source: string) -> (line: int, column: int, found: bool) {
	line = 1
	column = 1
	index := 0
	for index < len(source) {
		current := source[index]
		switch current {
		case '\n':
			line += 1
			column = 0
		case '/':
			if index + 1 < len(source) && source[index + 1] == '/' {
				for index < len(source) && source[index] != '\n' {
					index += 1
				}
				continue
			}
			if index + 1 < len(source) && source[index + 1] == '*' {
				index += 2
				column += 2
				for index + 1 < len(source) && !(source[index] == '*' && source[index + 1] == '/') {
					if source[index] == '\n' {
						line += 1
						column = 0
					}
					index += 1
					column += 1
				}
				index += 2
				column += 2
				continue
			}
		case '"', '\'':
			quote := current
			start_line, start_column := line, column
			index += 1
			column += 1
			for {
				if index >= len(source) || source[index] == '\n' {
					return start_line, start_column, true
				}
				if source[index] == '\\' && index + 1 < len(source) {
					if source[index + 1] == '\n' {
						line += 1
						column = 0
					}
					index += 2
					column += 2
					continue
				}
				if source[index] == quote {
					break
				}
				index += 1
				column += 1
			}
		}
		index += 1
		column += 1
	}
	return 0, 0, false
}

clone_value :: proc(value: json.Value, allocator := context.allocator) -> json.Value {
	switch inner in value {
	case json.Null:
		return inner
	case json.Integer:
		return inner
	case json.Float:
		return inner
	case json.Boolean:
		return inner
	case json.String:
		return json.String(strings.clone(string(inner), allocator))
	case json.Array:
		items := make([dynamic]json.Value, 0, len(inner), allocator)
		for item in inner {
			append(&items, clone_value(item, allocator))
		}
		return json.Array(items)
	case json.Object:
		object := json.Object(make(map[string]json.Value, allocator))
		for key, item in inner {
			object[strings.clone(key, allocator)] = clone_value(item, allocator)
		}
		return object
	}
	return nil
}

// Deep merge: every key in `source` is copied into `destination`.
// Objects on both sides merge recursively; anything else in `source`
// replaces what `destination` had. `source` is left untouched.
merge :: proc(destination: ^json.Object, source: json.Object, allocator := context.allocator) {
	for key, source_value in source {
		if existing, found := destination[key]; found {
			existing_object, destination_is_object := existing.(json.Object)
			source_object, source_is_object := source_value.(json.Object)
			if destination_is_object && source_is_object {
				merge(&existing_object, source_object, allocator)
				// The nested map may have grown, so store its header back.
				destination[key] = existing_object
				continue
			}
			json.destroy_value(existing, allocator)
			destination[key] = clone_value(source_value, allocator)
			continue
		}
		destination[strings.clone(key, allocator)] = clone_value(source_value, allocator)
	}
}

// Stores `value` under `key`, taking ownership of the value and
// destroying any previous value stored under the same key.
set_value :: proc(object: ^json.Object, key: string, value: json.Value, allocator := context.allocator) {
	if existing, found := object[key]; found {
		json.destroy_value(existing, allocator)
		object[key] = value
		return
	}
	object[strings.clone(key, allocator)] = value
}

remove_key :: proc(object: ^json.Object, key: string, allocator := context.allocator) {
	if _, found := object[key]; !found {
		return
	}
	stored_key, value := delete_key(object, key)
	delete(stored_key, allocator)
	json.destroy_value(value, allocator)
}

// Keys in a stable order, for error messages and dumps.
sorted_keys :: proc(object: json.Object, allocator := context.allocator) -> []string {
	keys, _ := slice.map_keys(object, allocator)
	slice.sort(keys)
	return keys
}

