@tool
class_name UxmlPanelSettings
extends Resource
## Unity's PanelSettings for a UxmlDocument: how the panel scales with the
## screen (UxmlDocument.panel_settings). The fields and their defaults are
## Unity 6000.3's (a new PanelSettings asset); the scale is
## UxmlPanelScale.resolve(), Unity's ResolveScale.
##
##   var ps := UxmlPanelSettings.new()
##   ps.scale_mode = UxmlPanelSettings.ScaleMode.SCALE_WITH_SCREEN_SIZE
##   ps.reference_resolution = Vector2i(1920, 1080)
##   ps.match_width_or_height = 0.5
##   doc.panel_settings = ps
##
## or a Unity asset: `UxmlPanelSettings.load_unity_asset("res://ui/Panel.asset")`
## (also `UxmlDocument.panel_settings_asset`), which reads the YAML Unity
## writes, and finds the theme style sheet (`.tss`) it references by the GUID
## in the `.meta` files beside the asset or under the project root.

## PanelScaleMode.
enum ScaleMode {
	## The panel is the screen's size in points; `scale` multiplies it.
	CONSTANT_PIXEL_SIZE = 0,
	## Points keep their physical size: pixels per point is the screen DPI
	## over `reference_dpi` (`fallback_dpi` when the DPI is unknown).
	CONSTANT_PHYSICAL_SIZE = 1,
	## The panel is `reference_resolution` points, fitted to the screen by
	## `screen_match_mode`.
	SCALE_WITH_SCREEN_SIZE = 2,
}

## PanelScreenMatchMode (SCALE_WITH_SCREEN_SIZE).
enum ScreenMatchMode {
	## Blend the width and the height ratio by `match_width_or_height`
	## (0: width, 1: height; a linear blend, as Unity's Mathf.Lerp).
	MATCH_WIDTH_OR_HEIGHT = 0,
	## The larger ratio: the panel is no larger than the reference.
	SHRINK = 1,
	## The smaller ratio: the panel is no smaller than the reference.
	EXPAND = 2,
}

@export var scale_mode: ScaleMode = ScaleMode.CONSTANT_PHYSICAL_SIZE:
	set(v):
		scale_mode = v
		emit_changed()
## Unity's Scale: the panel is drawn `scale` times larger (in every mode).
@export_range(0.01, 10.0, 0.01, "or_greater") var scale: float = 1.0:
	set(v):
		scale = v
		emit_changed()
## The screen size the UI is designed for, in pixels (SCALE_WITH_SCREEN_SIZE).
@export var reference_resolution := Vector2i(1200, 800):
	set(v):
		reference_resolution = v
		emit_changed()
@export var screen_match_mode: ScreenMatchMode = ScreenMatchMode.MATCH_WIDTH_OR_HEIGHT:
	set(v):
		screen_match_mode = v
		emit_changed()
## Unity's Match (MATCH_WIDTH_OR_HEIGHT): 0 matches the width, 1 the height.
@export_range(0.0, 1.0, 0.01) var match_width_or_height: float = 0.0:
	set(v):
		match_width_or_height = v
		emit_changed()
## The DPI the UI is designed for (CONSTANT_PHYSICAL_SIZE). Values below 1
## are 96, as Unity's setter makes them.
@export var reference_dpi: float = 96.0:
	set(v):
		reference_dpi = v if v >= 1.0 else 96.0
		emit_changed()
## The DPI when the screen's is unknown (CONSTANT_PHYSICAL_SIZE).
@export var fallback_dpi: float = 96.0:
	set(v):
		fallback_dpi = v if v >= 1.0 else 96.0
		emit_changed()
## The theme style sheet (`.uss` or a Unity `.tss`) of the panel. Empty: the
## document's own `theme_path`. A `.tss` that imports
## `unity-theme://default` gets godot-uxml's default theme for that import.
@export_file("*.tss", "*.uss") var theme_style_sheet: String = "":
	set(v):
		theme_style_sheet = v
		emit_changed()

## Problems of the last load_unity_asset() (strings).
var import_warnings: PackedStringArray = PackedStringArray()


## The fields as UxmlPanelScale.resolve() and UxmlNative.panel_scale() read
## them.
func to_dict() -> Dictionary:
	return {
		"scale_mode": int(scale_mode),
		"scale": scale,
		"reference_resolution": reference_resolution,
		"screen_match_mode": int(screen_match_mode),
		"match": match_width_or_height,
		"reference_dpi": reference_dpi,
		"fallback_dpi": fallback_dpi,
	}


## The scale on a screen (the host Control's size) of `screen` pixels at
## `dpi` (0: unknown): {resolved_scale, pixels_per_point, panel_size}.
func resolve(screen: Vector2, dpi: float) -> Dictionary:
	return UxmlPanelScale.resolve(to_dict(), screen, dpi)


## Settings from a Unity PanelSettings asset (`.asset`, Unity's YAML).
## `project_root`: where to look for the theme style sheet's `.meta` when it
## is not beside the asset (default: the asset's folder and its parents up to
## res://). Returns null when the file is not a PanelSettings asset; the
## problems of a partial read are in `import_warnings`.
static func load_unity_asset(path: String, project_root: String = "res://") -> UxmlPanelSettings:
	if not FileAccess.file_exists(path):
		return null
	return from_unity_yaml(FileAccess.get_file_as_string(path), path, project_root)


## from the text of a PanelSettings asset (see load_unity_asset). `path`
## locates the theme style sheet ("" for none).
static func from_unity_yaml(text: String, path: String = "", project_root: String = "res://") -> UxmlPanelSettings:
	var fields := {}
	var in_doc := false
	var is_panel := false
	for raw in text.split("\n"):
		var line := raw.strip_edges(false, true)
		if line.begins_with("--- "):
			in_doc = true
			continue
		if not in_doc or not line.begins_with("  ") or line.begins_with("   "):
			continue
		var at := line.find(":")
		if at < 0:
			continue
		var key := line.substr(2, at - 2)
		var value := line.substr(at + 1).strip_edges()
		fields[key] = value
		if key == "m_EditorClassIdentifier" and value.ends_with("UnityEngine.UIElements.PanelSettings"):
			is_panel = true
		elif key == "m_Script" and value.contains("fileID: 19101") and value.contains("guid: 0000000000000000e000000000000000"):
			is_panel = true
	if not is_panel:
		return null
	var ps := UxmlPanelSettings.new()
	var warn := PackedStringArray()
	if fields.has("m_ScaleMode"):
		var m := int(fields["m_ScaleMode"])
		if m >= 0 and m <= 2:
			ps.scale_mode = m as ScaleMode
		else:
			warn.append("m_ScaleMode %s is not a PanelScaleMode" % fields["m_ScaleMode"])
	if fields.has("m_Scale"):
		ps.scale = float(fields["m_Scale"])
	if fields.has("m_ReferenceDpi"):
		ps.reference_dpi = float(fields["m_ReferenceDpi"])
	if fields.has("m_FallbackDpi"):
		ps.fallback_dpi = float(fields["m_FallbackDpi"])
	if fields.has("m_ReferenceResolution"):
		var v := _yaml_map(String(fields["m_ReferenceResolution"]))
		ps.reference_resolution = Vector2i(int(v.get("x", "1200")), int(v.get("y", "800")))
	if fields.has("m_ScreenMatchMode"):
		var mm := int(fields["m_ScreenMatchMode"])
		if mm >= 0 and mm <= 2:
			ps.screen_match_mode = mm as ScreenMatchMode
		else:
			warn.append("m_ScreenMatchMode %s is not a PanelScreenMatchMode" % fields["m_ScreenMatchMode"])
	if fields.has("m_Match"):
		ps.match_width_or_height = float(fields["m_Match"])
	if int(fields.get("m_RenderMode", "0")) != 0:
		warn.append("m_RenderMode %s: only screen space overlay panels are supported; laid out as one" % fields["m_RenderMode"])
	if fields.has("themeUss"):
		var ref := _yaml_map(String(fields["themeUss"]))
		var guid := String(ref.get("guid", ""))
		if not guid.is_empty() and guid != "0000000000000000f000000000000000":
			var tss := find_by_guid(guid, path.get_base_dir() if not path.is_empty() else project_root, project_root)
			if tss.is_empty():
				warn.append("themeUss: no .meta with guid %s under %s; the document's theme is used" % [guid, project_root])
			else:
				ps.theme_style_sheet = tss
	ps.import_warnings = warn
	return ps


## `{fileID: 1, guid: x, type: 3}` -> {"fileID": "1", "guid": "x", "type": "3"}.
static func _yaml_map(v: String) -> Dictionary:
	var out := {}
	var body := v.strip_edges().trim_prefix("{").trim_suffix("}")
	for part in body.split(","):
		var kv := part.split(":", true, 1)
		if kv.size() == 2:
			out[kv[0].strip_edges()] = kv[1].strip_edges()
	return out


## The asset whose `.meta` has `guid`: first in `start` and its parents up
## to `project_root`, then the whole of `project_root` (the files' folders
## are walked once each; at most 20000 files). "" when none.
static func find_by_guid(guid: String, start: String, project_root: String = "res://") -> String:
	var seen := {}
	var dir := start
	while not dir.is_empty():
		var hit := _guid_in(dir, guid)
		if not hit.is_empty():
			return hit
		seen[dir] = true
		if dir == project_root or dir.trim_suffix("/") == project_root.trim_suffix("/") or not dir.begins_with(project_root.trim_suffix("/")):
			break
		var up := dir.get_base_dir()
		if up == dir:
			break
		dir = up
	var budget := [20000]
	return _guid_walk(project_root, guid, seen, budget)


static func _guid_in(dir: String, guid: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	for f in d.get_files():
		if not f.ends_with(".meta"):
			continue
		var p := dir.path_join(f)
		var fa := FileAccess.open(p, FileAccess.READ)
		if fa == null:
			continue
		for i in 4:
			if fa.eof_reached():
				break
			var line := fa.get_line().strip_edges()
			if line.begins_with("guid:"):
				if line.substr(5).strip_edges() == guid:
					return p.trim_suffix(".meta")
				break
	return ""


static func _guid_walk(dir: String, guid: String, seen: Dictionary, budget: Array) -> String:
	if budget[0] <= 0:
		return ""
	if not seen.has(dir):
		seen[dir] = true
		var hit := _guid_in(dir, guid)
		if not hit.is_empty():
			return hit
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	budget[0] -= d.get_files().size()
	for sub in d.get_directories():
		if sub.begins_with(".") or sub == "Library" or sub == "Temp":
			continue
		var hit := _guid_walk(dir.path_join(sub), guid, seen, budget)
		if not hit.is_empty():
			return hit
	return ""
