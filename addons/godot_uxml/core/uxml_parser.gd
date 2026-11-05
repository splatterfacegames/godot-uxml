class_name UxmlParser
extends RefCounted
## UXML text -> UxmlElement tree + diagnostics. Never fails hard.
##
## Ported from vendor/uxml-preview/src/parser/uxml.ts (Apache-2.0, see
## THIRD-PARTY-NOTICES.md), with deliberate deltas for a runtime consumer:
##
##   * attribute values are XML-entity decoded here, not at point of use —
##     godot-uxml never re-serializes UXML
##   * a close tag that names a different element is warned about
##     ("malformed", kind) and still closes the open element — the upstream
##     policy of "an end tag always closes the innermost open element" is
##     kept, it is just no longer silent
##   * duplicate attributes warn; the first wins, matching get_attribute
##
## Text between tags is ignored (Unity UXML has no text nodes). Comments,
## CDATA, DOCTYPE and processing instructions are skipped.

var _src: String = ""
var _file: String = ""
var _pos: int = 0
var _next_id: int = 0
var _warnings: Array = []


## Scan with the native core (UxmlNativeParser) when the extension is
## loaded; this GDScript scanner stays the reference and the fallback.
static var use_native := true


## Returns {root: UxmlElement, warnings: Array[Dictionary]}.
func parse(source: String, file: String = "") -> Dictionary:
	_src = source
	_file = file
	_pos = 0
	_next_id = 0
	_warnings = []
	if use_native and ClassDB.class_exists("UxmlNativeParser"):
		return _parse_native(source)

	_seek_tag()
	var root: UxmlElement
	if _pos < _src.length() and _is_name_start(_char(_pos + 1)):
		root = _parse_element()
	else:
		_warn("no root element", 0, 0)
		root = UxmlElement.new()
		root.id = _alloc_id()

	# Anything after the document root element is malformed XML. Diagnose each
	# stray tag; recovery keeps the first root and discards the rest.
	while true:
		_seek_tag()
		if _pos >= _src.length():
			break
		var next := _char(_pos + 1)
		if next == 47: # '/'
			var gt := _src.find(">", _pos)
			var end := _src.length() if gt < 0 else gt + 1
			_warn("closing tag after the document root element", _pos, end)
			_pos = end
		elif _is_name_start(next):
			_warn("element after the document root element", _pos, _pos + 1)
			_parse_element() # consume and discard
		else:
			_pos += 1
	return {"root": root, "warnings": _warnings}


## The native scanner returns the kept tree as flat preorder arrays and the
## problems in order; objects and diagnostics are built here exactly as the
## GDScript scanner builds them. Values with '&' come back raw and are
## decoded by decode_entities.
func _parse_native(source: String) -> Dictionary:
	var d: Dictionary = ClassDB.class_call_static("UxmlNativeParser", "scan_uxml", source)
	var local: PackedStringArray = d["local"]
	var prefix: PackedStringArray = d["prefix"]
	var parent: PackedInt32Array = d["parent"]
	var ids: PackedInt32Array = d["id"]
	var os: PackedInt32Array = d["open_start"]
	var oe: PackedInt32Array = d["open_end"]
	var se: PackedInt32Array = d["source_end"]
	var els: Array = []
	els.resize(local.size())
	for k in local.size():
		var e := UxmlElement.new()
		e.id = ids[k]
		e.prefix = prefix[k]
		e.local = local[k]
		e.open_tag_start = os[k]
		e.open_tag_end = oe[k]
		e.source_end = se[k]
		els[k] = e
		if parent[k] >= 0:
			(els[parent[k]] as UxmlElement).children.append(e)
	var ael: PackedInt32Array = d["attr_el"]
	var an: PackedStringArray = d["attr_name"]
	var av: PackedStringArray = d["attr_value"]
	var ar: PackedByteArray = d["attr_raw"]
	var ao: PackedInt32Array = d["attr_offset"]
	for a in ael.size():
		var v: String = av[a]
		if ar[a] != 0:
			v = decode_entities(v)
		(els[ael[a]] as UxmlElement).attributes.append({"name": an[a], "value": v, "offset": ao[a]})
	var wm: PackedStringArray = d["w_msg"]
	var ws: PackedInt32Array = d["w_start"]
	var we: PackedInt32Array = d["w_end"]
	for w in wm.size():
		_warn(wm[w], ws[w], we[w])
	var root: UxmlElement
	if d["synth_root"]:
		root = UxmlElement.new()
		root.id = 0
	else:
		root = els[0]
	return {"root": root, "warnings": _warnings}


func _alloc_id() -> int:
	var out := _next_id
	_next_id += 1
	return out


func _char(at: int) -> int:
	if at < 0 or at >= _src.length():
		return -1
	return _src.unicode_at(at)


static func _is_space(c: int) -> bool:
	return c == 32 or c == 9 or c == 10 or c == 13


static func _is_name_start(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


static func _is_name_char(c: int) -> bool:
	return _is_name_start(c) or (c >= 48 and c <= 57) or c == 46 or c == 58 or c == 45


## Index just past the run of name characters starting at `i` (inlined
## _is_name_char — this runs for every tag and attribute name).
func _name_end(i: int) -> int:
	var n := _src.length()
	while i < n:
		var c := _src.unicode_at(i)
		if not (
			(c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 58)
			or c == 95 or c == 46 or c == 45
		):
			return i
		i += 1
	return i


func _warn(message: String, start: int, end: int) -> void:
	var diag := UxmlDiagnostic.make("malformed", message, _src, start, _file)
	diag["end_offset"] = end
	_warnings.append(diag)


func _skip_space() -> void:
	var n := _src.length()
	while _pos < n:
		var c := _src.unicode_at(_pos)
		if c != 32 and c != 9 and c != 10 and c != 13:
			return
		_pos += 1


## Advance to the next `<` that opens an element or an end tag, stepping over
## comments, CDATA, doctypes and processing instructions.
func _seek_tag() -> void:
	while true:
		var lt := _src.find("<", _pos)
		if lt < 0:
			_pos = _src.length()
			return
		var next := _char(lt + 1)
		if next == 33: # '!'
			if _src.substr(lt, 4) == "<!--":
				var end := _src.find("-->", lt + 4)
				_pos = _src.length() if end < 0 else end + 3
			elif _src.substr(lt, 9) == "<![CDATA[":
				var end := _src.find("]]>", lt + 9)
				_pos = _src.length() if end < 0 else end + 3
			else:
				var end := _src.find(">", lt)
				_pos = _src.length() if end < 0 else end + 1
			continue
		if next == 63: # '?'
			var end := _src.find("?>", lt + 2)
			_pos = _src.length() if end < 0 else end + 2
			continue
		_pos = lt
		return


## Returns {prefix, local}.
func _read_name() -> Dictionary:
	var start := _pos
	_pos = _name_end(_pos)
	var raw := _src.substr(start, _pos - start)
	var colon := raw.find(":")
	if colon < 0:
		return {"prefix": "", "local": raw}
	return {"prefix": raw.substr(0, colon), "local": raw.substr(colon + 1)}


## Returns null when _pos is not on an attribute name so the caller recovers.
func _read_attribute() -> Variant:
	var start := _pos
	_pos = _name_end(_pos)
	if _pos == start:
		return null
	var attr_name := _src.substr(start, _pos - start)

	var after_name := _pos
	_skip_space()
	if _char(_pos) != 61: # '='
		# Valueless attribute. Invalid XML, but the text is kept.
		_pos = after_name
		_warn('attribute "%s" has no value' % attr_name, start, after_name)
		return {"name": attr_name, "value": "", "offset": start}
	_pos += 1
	_skip_space()

	var quote := _char(_pos)
	if quote != 34 and quote != 39: # '"' or '\''
		_warn('attribute "%s" has an unquoted value' % attr_name, start, _pos)
		return {"name": attr_name, "value": "", "offset": start}
	_pos += 1
	var value_start := _pos
	var close := _src.find(char(quote), _pos)
	if close < 0:
		_warn('attribute "%s" has an unterminated value' % attr_name, start, _src.length())
		_pos = _src.length()
		return {
			"name": attr_name,
			"value": decode_entities(_src.substr(value_start)),
			"offset": start,
		}
	_pos = close + 1
	return {
		"name": attr_name,
		"value": decode_entities(_src.substr(value_start, close - value_start)),
		"offset": start,
	}


## Requires: _src[_pos] is '<' and the next character starts a name.
func _parse_element() -> UxmlElement:
	var tag_start := _pos
	_pos += 1
	var name := _read_name()

	var element := UxmlElement.new()
	element.id = _alloc_id()
	element.prefix = name["prefix"]
	element.local = name["local"]

	var seen_attrs := {}
	var self_closing := false
	while true:
		_skip_space()
		var c := _char(_pos)
		if c < 0:
			_warn("unterminated open tag", tag_start, _src.length())
			break
		if c == 62: # '>'
			_pos += 1
			break
		if c == 47 and _char(_pos + 1) == 62: # '/>'
			_pos += 2
			self_closing = true
			break
		var attr = _read_attribute()
		if attr == null:
			# Unrecognized character inside the tag. Step over it.
			_pos += 1
			continue
		if seen_attrs.has(attr["name"]):
			_warn('duplicate attribute "%s"' % attr["name"], attr["offset"], _pos)
		seen_attrs[attr["name"]] = true
		element.attributes.append(attr)

	element.open_tag_start = tag_start
	element.open_tag_end = _pos

	if self_closing:
		element.source_end = _pos
		return element

	while true:
		_seek_tag()
		if _pos >= _src.length():
			_warn("unterminated element <%s>" % element.tag(), tag_start, _src.length())
			break
		var next := _char(_pos + 1)
		if next == 47: # '/'
			break
		if not _is_name_start(next):
			# A stray '<' in text. Not a tag; step over it.
			_pos += 1
			continue
		element.children.append(_parse_element())

	# An end tag always closes the innermost open element. When the name does
	# not match we say so, then still close — that is the documented policy.
	if _src.substr(_pos, 2) == "</":
		var close_start := _pos
		_pos += 2
		var close_name := _read_name()
		var close_text: String = close_name["local"] if close_name["prefix"].is_empty() else close_name["prefix"] + ":" + close_name["local"]
		_skip_space()
		var gt := _src.find(">", _pos)
		var end := _src.length() if gt < 0 else gt + 1
		if gt < 0:
			_warn("unterminated end tag", close_start, end)
		elif close_text != element.tag():
			_warn(
				'closing tag "</%s>" does not match open tag "<%s>"' % [close_text, element.tag()],
				close_start,
				end
			)
		_pos = end
	element.source_end = _pos
	return element


## Decode XML entities in stored attribute text. The scan is single-pass:
## replacements are looked up in the original input and emitted into the
## output, which is never re-scanned — so &#38;lt; becomes the literal text
## "&lt;", not "<". Numeric references outside the Unicode range (and
## surrogate halves) and unknown entity names are left as written.
static func decode_entities(text: String) -> String:
	if text.find("&") < 0:
		return text # nothing to decode — skip the regex scan entirely
	var out := ""
	var at := 0
	while true:
		var m := _re_entity.search(text, at)
		if m == null:
			break
		out += text.substr(at, m.get_start() - at) + _decode_entity(m.get_string(1), m.get_string())
		at = m.get_end()
	return out + text.substr(at)


static var _re_entity := RegEx.create_from_string("&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|quot|apos|amp);")


static func _decode_entity(body: String, raw: String) -> String:
	match body:
		"lt":
			return "<"
		"gt":
			return ">"
		"quot":
			return "\""
		"apos":
			return "'"
		"amp":
			return "&"
	var value := -1
	if body.begins_with("#x"):
		value = body.substr(2).hex_to_int()
	elif body.begins_with("#"):
		value = body.substr(1).to_int()
	if value >= 0 and value <= 0x10FFFF and not (value >= 0xD800 and value <= 0xDFFF):
		return char(value)
	return raw
