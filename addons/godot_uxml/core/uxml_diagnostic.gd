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
##
## Kinds emitted by milestone 1:
##   malformed             - broken UXML/USS syntax that was recovered from
##   unsupported-control   - element tag with no Godot mapping (children kept)
##   unsupported-feature   - known UXML machinery out of scope (templates, ...)
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

static func make(
	kind: String,
	message: String,
	source: String = "",
	offset: int = 0,
	file: String = ""
) -> Dictionary:
	var lc := line_col(source, offset)
	return {
		"kind": kind,
		"message": message,
		"file": file,
		"offset": offset,
		"line": lc.x,
		"column": lc.y,
	}


## 1-based (line, column) of `offset` inside `source`.
static func line_col(source: String, offset: int) -> Vector2i:
	var line := 1
	var column := 1
	var i := 0
	var limit := mini(offset, source.length())
	while i < limit:
		if source.unicode_at(i) == 10:
			line += 1
			column = 1
		else:
			column += 1
		i += 1
	return Vector2i(line, column)


static func format(diag: Dictionary) -> String:
	var where := diag.get("file", "")
	if where == "":
		where = "<source>"
	return "%s:%d:%d: %s: %s" % [where, diag.get("line", 0), diag.get("column", 0), diag.get("kind", "?"), diag.get("message", "")]
