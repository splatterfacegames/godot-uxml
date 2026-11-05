class_name UxmlTheme
extends RefCounted
## The default theme: a USS sheet spliced in AHEAD of every author sheet
## and marked `"theme": true`. Unity ranks default-theme matches below every
## author match, whatever the specificity (an author `Button { margin: 0 }`
## beats the theme's `.unity-button { margin: 1px 3px }` — measured, see
## docs/parity.md); UssCascade.AUTHOR_LAYER implements that rank.
##
## The sheet has no scope (it reaches every element, parts included) and
## its url()s resolve inside the theme folder (UxmlResourceResolver
## TRUSTED_DIRS). Parsed sheets are cached per path; the parsed items are
## read-only for the cascade, so loads share them.
##
## `themes/unity-default.uss` is written by godot-uxml from values measured
## in Unity 6000.3 with tools/unity-dump; it is not Unity's file.

const DEFAULT := "res://addons/godot_uxml/themes/unity-default.uss"
## The geometry of the container and collection parts (ScrollView,
## Scroller, ListView, TreeView, MultiColumn*, TabView, TwoPaneSplitView):
## attached ahead of the theme, and also when the theme is disabled, so
## these controls work without the Unity look (unity-structure.uss).
const STRUCTURE := "res://addons/godot_uxml/themes/unity-structure.uss"

static var _cache := {}  # path -> [source, items, warnings]


## Splice the structure sheet and the theme sheet at `path` ahead of
## `doc`'s sheets. An empty path attaches the structure sheet only (theme
## disabled). A missing theme is a diagnostic.
static func attach(doc: UxmlDocumentModel, path: String) -> void:
	if doc == null:
		return
	if not path.is_empty():
		_attach_sheet(doc, path)
	_attach_sheet(doc, STRUCTURE)


static func _attach_sheet(doc: UxmlDocumentModel, path: String) -> void:
	var hit = _cache.get(path)
	if hit == null:
		if not FileAccess.file_exists(path):
			doc.warnings.append(UxmlDiagnostic.make(
				"missing-file", 'theme stylesheet "%s" does not exist; no theme applied' % path,
				"", 0, path))
			return
		var text := FileAccess.get_file_as_string(path)
		var parsed := UssParser.new().parse(text, path)
		hit = [text, parsed["items"], parsed["warnings"]]
		_cache[path] = hit
	var index := doc.sheets.size()
	doc.sheets.append({
		"index": index,
		"source": hit[0],
		"origin": path,
		"items": hit[1],
		"scope": null,
		"theme": true,
	})
	doc.warnings.append_array(hit[2])
	doc.style_roots.insert(0, {"sheet": index, "scope": null})


## Drop cached parses (after editing a theme file at runtime).
static func clear_cache() -> void:
	_cache.clear()
