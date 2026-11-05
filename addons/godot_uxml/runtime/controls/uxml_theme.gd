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
## attached ahead of the theme, also when the theme is disabled, so these
## controls work without the Unity look (unity-structure.uss).
const STRUCTURE := "res://addons/godot_uxml/themes/unity-structure.uss"

static var _cache := {}  # path -> [source, items, warnings]


## The look of the container controls in the default theme
## (unity-default-containers.uss).
const DEFAULT_CONTAINERS := "res://addons/godot_uxml/themes/unity-default-containers.uss"
## Tags whose part trees need STRUCTURE (UxmlContainerParts).
const CONTAINER_TAGS := {"ScrollView": true, "Scroller": true, "ListView": true,
	"TreeView": true, "MultiColumnListView": true, "MultiColumnTreeView": true,
	"TabView": true, "Tab": true, "TwoPaneSplitView": true}
const META_CONTAINERS := &"uxml_container_sheets"


## Splice the theme sheet at `path` ahead of `doc`'s sheets. An empty path
## attaches no theme. A missing theme is a diagnostic. A document with a
## container control also gets the container sheets (attach_containers).
static func attach(doc: UxmlDocumentModel, path: String) -> void:
	if doc == null:
		return
	if not path.is_empty():
		_attach_sheet(doc, path)
	doc.set_meta(&"uxml_theme_path", path)
	attach_containers(doc)


## The structure sheet (and, with the default theme, the container look)
## for a document that has a container control; nothing for other
## documents, so they do not compile these rules. Run again after a later
## step adds elements (collection item templates); attaches once.
static func attach_containers(doc: UxmlDocumentModel) -> void:
	if doc == null or doc.root == null or doc.has_meta(META_CONTAINERS):
		return
	var found := false
	for el in doc.root.walk():
		if CONTAINER_TAGS.has(el.local) or UxmlInputParts.has_inner_scroll_view(el):
			found = true
			break
	if not found:
		return
	doc.set_meta(META_CONTAINERS, true)
	var path: String = doc.get_meta(&"uxml_theme_path", "")
	# Cascade order: structure, theme, container look (each insert goes
	# first, so the look goes in first).
	var at := _theme_roots(doc)
	if path == DEFAULT:
		_attach_sheet(doc, DEFAULT_CONTAINERS, at)
	_attach_sheet(doc, STRUCTURE, 0)


## Number of theme sheets at the start of the cascade order.
static func _theme_roots(doc: UxmlDocumentModel) -> int:
	var n := 0
	for r in doc.style_roots:
		if bool(doc.sheets[r["sheet"]].get("theme", false)):
			n += 1
		else:
			break
	return n


static func _attach_sheet(doc: UxmlDocumentModel, path: String, at: int = 0) -> void:
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
	doc.style_roots.insert(at, {"sheet": index, "scope": null})


## Drop cached parses (after editing a theme file at runtime).
static func clear_cache() -> void:
	_cache.clear()
