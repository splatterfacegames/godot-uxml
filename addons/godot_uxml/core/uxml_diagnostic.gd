class_name UxmlDiagnostic
extends RefCounted
## A diagnostic is a plain Dictionary; this class only builds and formats them.
##
## Keys:
##   kind    - machine-readable category (see below)
##   message - human-readable explanation
##   file    - document or stylesheet path the diagnostic belongs to ("" if none)
##   line    - 1-based line in that file's source text
##   column  - 1-based column
##   offset  - character offset the line/column were computed from
##   end_offset - character offset past the end of the range the diagnostic
##             is about: past the `>` of an element's open tag, past the
##             closing quote of an attribute value, the end of a USS
##             declaration or rule head (before `;`, `{`, `}` or the line
##             end). Equal to `offset` when there is no source text.
##
## Kinds emitted by milestone 1:
##   malformed             - broken UXML/USS syntax that was recovered from
##   unsupported-control   - element tag with no Godot mapping (children kept)
##   unsupported-feature   - known USS/UXML machinery out of scope (@media, ...)
##   unsupported-selector  - a selector form the cascade cannot honor; the whole
##                           rule is ignored rather than treated as universal
##   unsupported-property  - a declaration property outside the supported subset
##   unsupported-attribute - an element attribute the addon does not consume
##   unresolved-var        - var() reference with no usable fallback / a cycle
##   import-unresolved     - a <Style src> or @import that could not be loaded
##   import-cycle          - an @import cycle (already-loaded sheets dedupe)
##   missing-file          - a referenced file does not exist under the root
##   path-outside-root     - a reference that escapes the project root
##   malformed-reference   - a reference that is not a usable path at all
##   version-dependent     - behavior Unity defines but versions may shift (:root)
##   template-not-declared - <Instance template="X"> with no <Template name="X">
##   template-cycle        - an <Instance> that refers back to a template on
##                           the current expansion path (left empty)
##   template-depth-exceeded - <Instance> nesting deeper than 32 (left empty)
##   override-ignored      - AttributeOverrides class/name/style (Unity ignores)
##   override-target-missing - AttributeOverrides element-name matched nothing
##   binding-failed        - a data binding that cannot run: unknown property,
##                           unresolved path, a target the control does not
##                           have, an unknown converter group (runtime)

static func make(
	kind: String,
	message: String,
	source: String = "",
	offset: int = 0,
	file: String = "",
	end_offset: int = -1
) -> Dictionary:
	var lc := line_col(source, offset)
	return {
		"kind": kind,
		"message": message,
		"file": file,
		"offset": offset,
		"line": lc.x,
		"column": lc.y,
		"end_offset": end_offset if end_offset >= 0 else end_of(source, offset),
	}


## The end of the range that starts at `offset` in `source` (see
## `end_offset`): an open tag, an attribute `name="value"`, or the USS text
## up to `;`, `{`, `}` or the line end.
static func end_of(source: String, offset: int) -> int:
	var n := source.length()
	if offset < 0 or offset >= n:
		return clampi(offset, 0, n)
	var c := source.unicode_at(offset)
	if c == 60:  # "<": the open tag, quotes skipped
		var i := offset + 1
		var q := 0
		while i < n:
			var d := source.unicode_at(i)
			if q != 0:
				if d == q:
					q = 0
			elif d == 34 or d == 39:
				q = d
			elif d == 62:
				return i + 1
			i += 1
		return n
	var j := offset
	while j < n:
		var d2 := source.unicode_at(j)
		if d2 == 61:  # "=": an attribute; past its quoted value
			if j + 1 < n and (source.unicode_at(j + 1) == 34 or source.unicode_at(j + 1) == 39):
				var close := source.find(source[j + 1], j + 2)
				return n if close < 0 else close + 1
			return j
		if d2 == 59 or d2 == 123 or d2 == 125 or d2 == 10 or d2 == 13 or d2 == 60 or d2 == 62:
			break
		j += 1
	while j > offset + 1 and (source.unicode_at(j - 1) == 32 or source.unicode_at(j - 1) == 9):
		j -= 1
	return maxi(j, offset + 1)


## 1-based (line, column) of `offset` inside `source`.
## Native String.count/rfind instead of a per-character GDScript loop: the
## old scan was O(offset) interpreted steps per diagnostic, which dominated
## cascades that warn on many elements of a large document.
static func line_col(source: String, offset: int) -> Vector2i:
	var limit := mini(offset, source.length())
	if limit <= 0:
		return Vector2i(1, 1)
	var nl := source.rfind("\n", limit - 1)
	if nl < 0:
		return Vector2i(1, limit + 1)
	return Vector2i(source.count("\n", 0, limit) + 1, limit - nl)


static func format(diag: Dictionary) -> String:
	var where := diag.get("file", "")
	if where == "":
		where = "<source>"
	return "%s:%d:%d: %s: %s" % [where, diag.get("line", 0), diag.get("column", 0), diag.get("kind", "?"), diag.get("message", "")]
