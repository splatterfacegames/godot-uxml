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


## The editor theme (UnityEditor.UIElements controls, Unity's editor skin):
## the geometry sheet and one colour sheet per skin. With the default theme
## they replace unity-default.uss (see `attach`).
const EDITOR := "res://addons/godot_uxml/themes/unity-editor.uss"
const EDITOR_DARK := "res://addons/godot_uxml/themes/unity-editor-dark.uss"
const EDITOR_LIGHT := "res://addons/godot_uxml/themes/unity-editor-light.uss"
const META_EDITOR := &"uxml_editor_skin"


## Splice the theme sheet at `path` ahead of `doc`'s sheets. An empty path
## attaches no theme. A missing theme is a diagnostic. A document with a
## container control also gets the container sheets (attach_containers).
##
## Editor theme: with the default theme, `editor_theme` "auto" gives a
## document with an editor control (UxmlEditorParts.TAGS) Unity's editor
## look in place of the runtime look, as Unity styles every control of an
## editor panel with the editor skin; "always" does so for every document,
## "never" for none. `editor_skin` is "dark" or "light". Other documents
## pay one dictionary lookup per element in the walk that finds container
## controls, and compile no editor rules.
static func attach(doc: UxmlDocumentModel, path: String, editor_theme: String = "auto",
		editor_skin: String = "dark") -> void:
	if doc == null:
		return
	var want_editor := path == DEFAULT and editor_theme == "auto"
	var scan := _scan(doc, want_editor)
	var editor: bool = path == DEFAULT and (editor_theme == "always" or (want_editor and bool(scan[1])))
	if editor:
		# Cascade order: editor geometry, then the skin colours. The editor
		# sheets replace the runtime theme.
		_attach_sheet(doc, EDITOR, 0)
		_attach_sheet(doc, EDITOR_LIGHT if editor_skin == "light" else EDITOR_DARK, 1)
		doc.set_meta(META_EDITOR, "light" if editor_skin == "light" else "dark")
	elif not path.is_empty():
		_attach_sheet(doc, path)
	doc.set_meta(&"uxml_theme_path", path)
	if bool(scan[0]):
		_attach_container_sheets(doc)


## The editor skin of a document with the editor theme ("dark", "light"),
## or "" for the runtime look.
static func editor_skin_of(doc: UxmlDocumentModel) -> String:
	return "" if doc == null else String(doc.get_meta(META_EDITOR, ""))


## [has a container control, has an editor control] in one walk.
static func _scan(doc: UxmlDocumentModel, editor: bool) -> Array:
	var containers := false
	var editors := false
	if doc.root == null or doc.has_meta(META_CONTAINERS):
		return [false, false] if not editor else [false, _has_editor(doc)]
	for el in doc.root.walk():
		if not containers and CONTAINER_TAGS.has(el.local):
			containers = true
			if not editor or editors:
				break
		if editor and not editors and UxmlEditorParts.TAGS.has(el.local):
			editors = true
			if containers:
				break
	return [containers, editors]


static func _has_editor(doc: UxmlDocumentModel) -> bool:
	if doc.root == null:
		return false
	for el in doc.root.walk():
		if UxmlEditorParts.TAGS.has(el.local):
			return true
	return false


## The structure sheet (and, with the default theme, the container look)
## for a document that has a container control; nothing for other
## documents, so they do not compile these rules. Run again after a later
## step adds elements (collection item templates); attaches once.
static func attach_containers(doc: UxmlDocumentModel) -> void:
	if doc == null or doc.root == null or doc.has_meta(META_CONTAINERS):
		return
	var found := false
	for el in doc.root.walk():
		if CONTAINER_TAGS.has(el.local):
			found = true
			break
	if not found:
		return
	_attach_container_sheets(doc)


static func _attach_container_sheets(doc: UxmlDocumentModel) -> void:
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
