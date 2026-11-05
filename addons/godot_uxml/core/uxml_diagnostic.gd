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
