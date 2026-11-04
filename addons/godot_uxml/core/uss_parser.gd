class_name UssParser
extends RefCounted
## USS text -> stylesheet items + diagnostics. Never fails hard.
##
## Ported from vendor/uxml-preview/src/parser/uss.ts (Apache-2.0). Selector
## syntax USS does not support is stored as an `unknown` simple selector
## rather than rejected, so the cascade can drop the whole rule with a clear
## diagnostic instead of silently treating it as a universal match.
##
## Item shapes:
##   {"kind": "rule",    "rule": {selectors, declarations, span, selector_span}}
##   {"kind": "import",  "url": String, "span": {start,end}, "resolved_sheet": int}
##   {"kind": "unknown", "span": {start,end}}
##
## Selector:    {parts: [{combinator: "descendant"|"child", simple: [...]}], span}
## Simple:      {kind: "universal"}
##              {kind: "type"|"class"|"name"|"pseudo", name: String}
##              {kind: "unknown", text: String}
## Declaration: {property: String, value: String, span: {start,end}}

var _src: String = ""
var _file: String = ""
var _pos: int = 0
var _warnings: Array = []


## Returns {items: Array, warnings: Array}.
func parse(source: String, file: String = "") -> Dictionary:
	_src = source
	_file = file
	_pos = 0
	_warnings = []
	var items: Array = []
	while true:
		_skip_trivia()
		if _pos >= _src.length():
			break
		items.append(_parse_at_rule() if _char(_pos) == 64 else _parse_rule())
	return {"items": items, "warnings": _warnings}


## Parses a standalone `property: value; ...` list — the grammar shared by
## rule blocks and the inline `style` attribute.
## Returns {declarations: Array, problems: [{message, start, end}]}.
static func parse_declarations(text: String) -> Dictionary:
	var p := UssParser.new()
	p._src = text
	var problems: Array = []
	var decls := p._parse_declaration_list(0, text.length(), problems)
	return {"declarations": decls, "problems": problems}


## Parses a selector group on its own (used for `states` option keys).
## Returns {selectors: Array, ok: bool}.
static func parse_selectors(text: String) -> Dictionary:
	var p := UssParser.new()
	p._src = text
	var end := text.length()
	var s := 0
	var e := end
	while s < e and _is_space(text.unicode_at(s)):
		s += 1
	while e > s and _is_space(text.unicode_at(e - 1)):
		e -= 1
	var selectors := p._parse_selector_group(s, e)
	return {"selectors": selectors, "ok": p._warnings.is_empty()}


func _char(at: int) -> int:
	if at < 0 or at >= _src.length():
		return -1
	return _src.unicode_at(at)


static func _is_space(c: int) -> bool:
	return c == 32 or c == 9 or c == 10 or c == 13 or c == 12


static func _is_ident(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45


func _warn(message: String, start: int, end: int) -> void:
	var diag := UxmlDiagnostic.make("malformed", message, _src, start, _file)
	diag["end_offset"] = end
	_warnings.append(diag)


## Index just past the closing quote of the string literal starting at `i`
## (which is a ' or " character), honoring backslash escapes so \" or \' do
## not end the literal early. -1 when unterminated.
static func _find_quote_close(text: String, i: int) -> int:
	var q := text.unicode_at(i)
	var j := i + 1
	while j < text.length():
		var c := text.unicode_at(j)
		if c == 92: # '\'
			j += 2
			continue
		if c == q:
			return j + 1
		j += 1
	return -1


## Scan forward to the first character in `stops` that is not inside a string,
## a comment, or a bracket pair. Returns source length if none is found.
## `limit` (>= 0) bounds the scan: callers that clamp the result with
## mini(result, end) get the same answer without scanning past `end` — the
## unbounded scan made selector-group parsing quadratic in the sheet size.
## Stop characters are matched as code points (no per-char String alloc).
func _scan_to(from: int, stops: String, limit: int = -1) -> int:
	var n := _src.length()
	var lim := n if limit < 0 or limit > n else limit
	var s0 := stops.unicode_at(0)
	var s1 := stops.unicode_at(1) if stops.length() > 1 else -2
	var s2 := stops.unicode_at(2) if stops.length() > 2 else -2
	var i := from
	var depth := 0
	while i < lim:
		var c := _src.unicode_at(i)
		if c == 34 or c == 39: # '"' or '''
			var close := _find_quote_close(_src, i)
			i = n if close < 0 else close
			continue
		if c == 47 and i + 1 < n and _src.unicode_at(i + 1) == 42: # '/*'
			var close := _src.find("*/", i + 2)
			i = n if close < 0 else close + 2
			continue
		if c == 40 or c == 91: # '(' or '['
			depth += 1
		elif c == 41 or c == 93: # ')' or ']'
			if depth > 0:
				depth -= 1
		elif depth == 0 and (c == s0 or c == s1 or c == s2):
			return i
		i += 1
	return n if lim == n else lim


static func _trim_bounds(source: String, start: int, end: int) -> Dictionary:
	var s := start
	var e := end
	while s < e and _is_space(source.unicode_at(s)):
		s += 1
	while e > s and _is_space(source.unicode_at(e - 1)):
		e -= 1
	return {"start": s, "end": e}


## Whitespace and comments.
func _skip_trivia() -> void:
	while true:
		while _is_space(_char(_pos)):
			_pos += 1
		if _src.substr(_pos, 2) == "/*":
			var end := _src.find("*/", _pos + 2)
			_pos = _src.length() if end < 0 else end + 2
			continue
		return


## Requires: _src[from] is '{'. Returns index just past the matching '}'.
func _end_of_block(from: int) -> int:
	var i := from + 1
	var depth := 1
	while i < _src.length():
		var c := _src.unicode_at(i)
		if c == 34 or c == 39:
			var close := _find_quote_close(_src, i)
			i = _src.length() if close < 0 else close
			continue
		if c == 47 and _char(i + 1) == 42:
			var close := _src.find("*/", i + 2)
			i = _src.length() if close < 0 else close + 2
			continue
		if c == 123: # '{'
			depth += 1
		elif c == 125: # '}'
			depth -= 1
			if depth == 0:
				return i + 1
		i += 1
	return _src.length()


# ---------------------------------------------------------------------------
# Selectors
# ---------------------------------------------------------------------------

func _read_ident(i: int) -> int:
	var j := i
	while j < _src.length() and _is_ident(_src.unicode_at(j)):
		j += 1
	return j


## Requires: _src[i] is '(' or '['. Returns index just past its partner.
func _end_of_bracket(i: int) -> int:
	var open := _src.unicode_at(i)
	var close_c := 41 if open == 40 else 93
	var j := i + 1
	var depth := 1
	while j < _src.length():
		var c := _src.unicode_at(j)
		if c == 34 or c == 39:
			var q := _find_quote_close(_src, j)
			j = _src.length() if q < 0 else q
			continue
		if c == open:
			depth += 1
		elif c == close_c:
			depth -= 1
			if depth == 0:
				return j + 1
		j += 1
	return _src.length()


func _read_compound(i: int, limit: int) -> Dictionary:
	var simple: Array = []
	var j := i
	while j < limit:
		var c := _src.unicode_at(j)
		if _is_space(c) or c == 62 or c == 43 or c == 126 or c == 44: # '>' '+' '~' ','
			break

		if c == 42: # '*'
			simple.append({"kind": "universal"})
			j += 1
		elif c == 46 or c == 35: # '.' or '#'
			var end := _read_ident(j + 1)
			if c == 46:
				simple.append({"kind": "class", "name": _src.substr(j + 1, end - j - 1)})
			else:
				simple.append({"kind": "name", "name": _src.substr(j + 1, end - j - 1)})
			j = end
		elif c == 91: # '['
			var end := mini(_end_of_bracket(j), limit)
			simple.append({"kind": "unknown", "text": _src.substr(j, end - j)})
			j = end
		elif c == 58: # ':'
			if _char(j + 1) == 58: # '::'
				var end := _read_ident(j + 2)
				simple.append({"kind": "unknown", "text": _src.substr(j, end - j)})
				j = end
			else:
				var name_end := _read_ident(j + 1)
				if _char(name_end) == 40: # '('
					# Functional pseudo-classes are all unsupported in USS.
					var end := mini(_end_of_bracket(name_end), limit)
					simple.append({"kind": "unknown", "text": _src.substr(j, end - j)})
					j = end
				else:
					simple.append({"kind": "pseudo", "name": _src.substr(j + 1, name_end - j - 1)})
					j = name_end
		elif _is_ident(c):
			var end := _read_ident(j)
			simple.append({"kind": "type", "name": _src.substr(j, end - j)})
			j = end
		else:
			simple.append({"kind": "unknown", "text": _src.substr(j, 1)})
			j += 1
	return {"simple": simple, "next": j}


func _parse_selector(start: int, end: int) -> Dictionary:
	var span := _trim_bounds(_src, start, end)
	var parts: Array = []
	var combinator := "descendant"
	## Combinator text that cannot form a valid sequence poisons the selector
	## instead of being dropped — dropping it would broaden the match
	## ("Label +" must not become "Label"). Sibling combinators, a leading or
	## repeated '>', and anything left dangling at the end all poison.
	var poison := ""
	var i: int = span["start"]

	while i < span["end"]:
		var c := _src.unicode_at(i)
		if _is_space(c):
			i += 1
			continue
		if c == 62: # '>'
			if parts.is_empty() or combinator == "child":
				poison += ">"
			else:
				combinator = "child"
			i += 1
			continue
		if c == 43 or c == 126: # '+' or '~'
			poison += char(c)
			i += 1
			continue
		var res := _read_compound(i, span["end"])
		var next: int = res["next"]
		if next == i:
			i += 1
			continue
		var simple: Array = res["simple"]
		if poison != "":
			simple.push_front({"kind": "unknown", "text": poison})
			poison = ""
		parts.append({"combinator": combinator, "simple": simple})
		combinator = "descendant"
		i = next

	if poison != "" or combinator == "child":
		# A dangling combinator at the end of the selector.
		var text := poison if poison != "" else ">"
		parts.append({"combinator": "descendant", "simple": [{"kind": "unknown", "text": text}]})
	return {"parts": parts, "span": span}


func _parse_selector_group(start: int, end: int) -> Array:
	var selectors: Array = []
	var from := start
	while true:
		var comma := mini(_scan_to(from, ",", end), end)
		selectors.append(_parse_selector(from, comma))
		if comma >= end:
			break
		from = comma + 1
	return selectors


# ---------------------------------------------------------------------------
# Declarations
# ---------------------------------------------------------------------------

## Read `property: value` pairs out of [start, end). Problems are appended to
## `problems` as {message, start, end} and warned here too when _file is set.
func _parse_declaration_list(start: int, end: int, problems: Array) -> Array:
	var declarations: Array = []
	var pos := start

	while pos < end:
		while pos < end and (_is_space(_char(pos)) or _src.substr(pos, 2) == "/*"):
			if _src.substr(pos, 2) == "/*":
				var close := _src.find("*/", pos + 2)
				pos = end if close < 0 else close + 2
			else:
				pos += 1
		if pos >= end:
			break
		if _char(pos) == 59: # ';'
			pos += 1
			continue

		var from := pos
		var colon := _scan_to(from, ":;}")
		if colon >= end or _char(colon) != 58: # ':'
			var to := mini(colon, end)
			problems.append({"message": "declaration without a value", "start": from, "end": to})
			pos = to + 1
			continue
		var stop := mini(_scan_to(colon + 1, ";}", end), end)
		var value := _trim_bounds(_src, colon + 1, stop)

		declarations.append({
			"property": _src.substr(from, colon - from).strip_edges(),
			"value": _strip_comments(
				_src.substr(value["start"], value["end"] - value["start"]),
				problems,
				value["start"]
			),
			"span": {"start": from, "end": value["end"]},
		})
		pos = stop + 1

	return declarations


## Remove /* ... */ comments from a declaration value so they cannot leak
## into computed styles ("red /*note*/" computes "red"). Quoted strings are
## copied verbatim; a comment standing alone leaves a single space so
## "a/**/b" does not fuse into "ab". An unterminated comment truncates the
## value and records a problem.
static func _strip_comments(text: String, problems: Array, base: int) -> String:
	# No comment opener anywhere: the scan below would copy every character
	# verbatim (quoted or not), so the result is just the trimmed text.
	if text.find("/*") < 0:
		return text.strip_edges()
	var out := ""
	var i := 0
	while i < text.length():
		var c := text.unicode_at(i)
		if c == 34 or c == 39:
			var close := _find_quote_close(text, i)
			if close < 0:
				return (out + text.substr(i)).strip_edges()
			out += text.substr(i, close - i)
			i = close
			continue
		if c == 47 and i + 1 < text.length() and text.unicode_at(i + 1) == 42: # '/*'
			var close := text.find("*/", i + 2)
			if close < 0:
				problems.append({
					"message": "unterminated comment in declaration",
					"start": base + i,
					"end": base + text.length(),
				})
				return out.strip_edges()
			out += " "
			i = close + 2
			continue
		out += char(c)
		i += 1
	return out.strip_edges()


# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

func _parse_at_rule() -> Dictionary:
	var start := _pos
	var name_end := _read_ident(_pos + 1)
	var at_name := _src.substr(_pos + 1, name_end - _pos - 1)
	var brace := _scan_to(name_end, "{;")

	if brace < _src.length() and _char(brace) == 123: # '{'
		# A block at-rule. @media/@supports and friends are unsupported: the
		# block is skipped, and the `at_rule` tag lets the loader emit an
		# unsupported-feature diagnostic. Its contents never apply.
		var end := _end_of_block(brace)
		_pos = end
		return {"kind": "unknown", "at_rule": at_name, "span": {"start": start, "end": end}}

	var end := brace + 1 if brace < _src.length() else _src.length()
	_pos = end

	if at_name == "import":
		var text := _src.substr(name_end, end - name_end)
		var quoted := _first_quoted(text)
		if quoted == null:
			_warn("@import without a quoted path", start, end)
			return {"kind": "unknown", "span": {"start": start, "end": end}}
		return {
			"kind": "import",
			"url": quoted,
			"span": {"start": start, "end": end},
			"resolved_sheet": -1,
		}
	return {"kind": "unknown", "at_rule": at_name, "span": {"start": start, "end": end}}


## First 'single' or "double" quoted string inside `text`, or null.
func _first_quoted(text: String) -> Variant:
	for i in text.length():
		var c := text.unicode_at(i)
		if c == 34 or c == 39:
			var close := _find_quote_close(text, i)
			if close < 0:
				return null
			return text.substr(i + 1, close - i - 2)
	return null


func _parse_rule() -> Dictionary:
	var start := _pos
	var brace := _scan_to(start, "{")
	if brace >= _src.length():
		_warn("rule without a block", start, _src.length())
		_pos = _src.length()
		return {"kind": "unknown", "span": {"start": start, "end": _src.length()}}
	var selector_span := _trim_bounds(_src, start, brace)
	var block_end := _end_of_block(brace)
	if block_end > _src.length() or _char(block_end - 1) != 125:
		_warn("unterminated rule block", start, block_end)

	var problems: Array = []
	var rule := {
		"selectors": _parse_selector_group(selector_span["start"], selector_span["end"]),
		"declarations": _parse_declaration_list(brace + 1, block_end - 1, problems),
		"span": {"start": selector_span["start"], "end": block_end},
		"selector_span": selector_span,
	}
	for problem in problems:
		_warn(problem["message"], problem["start"], problem["end"])
	_pos = block_end
	return {"kind": "rule", "rule": rule}
