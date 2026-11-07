class_name UxmlResourceResolver
extends RefCounted
## Turns the path spellings UXML/USS authors use into Godot file paths inside
## one declared project root, and reads them.
##
## Accepted reference forms (matching the editor's PathResolver):
##   project://database/Assets/UI/x.uss  -> <root>/Assets/UI/x.uss
##   project://database/Packages/p/x.uss -> <root>/Packages/p/x.uss
##   /Assets/UI/x.uss                    -> <root>/Assets/UI/x.uss
##   Assets/UI/x.uss, Packages/p/x.uss   -> relative to `from`'s directory
##                                        (Unity), else <root>/<same>
##   res://ui/x.uss, user://x.uss        -> as written, must stay under <root>
##   absolute filesystem path            -> as written, must stay under <root>
##   anything else                       -> relative to `from`'s directory,
##                                        or to <root> when `from` is empty
##
## `from` is the canonical path the resolver previously returned for the file
## containing the reference (a stylesheet's own path for @import, the UXML
## path for <Style src>). Nothing is resolved outside the project root: a
## reference that escapes produces a `path-outside-root` diagnostic instead
## of a file read.
##
## Canonicalization (collapse_path) normalizes "\" to "/", preserves URI
## schemes (res://, user://), Unix roots and UNC prefixes, and collapses "."
## and ".." segments BEFORE containment checks and file reads. A ".." that
## would climb above the path's own anchor is retained so resolve() can
## reject it. Path containment compares case-insensitively only on platforms
## whose filesystems are conventionally case-insensitive (Windows, macOS).
##
## resolve() never throws and never guesses: every failure is a Dictionary
## diagnostic the caller reports.

var project_root: String = "res://"
var _root_abs: String = ""

## resource("name") lookup (Unity Resources.Load): the file extensions tried
## per asset kind, in order. Unity looks up a Resources path without an
## extension; the Godot file is the first file with one of these
## extensions. Godot resource files (.tres, .res) come after the source
## formats, so a Unity project keeps its own files.
const RESOURCE_EXTENSIONS := {
	"texture": ["png", "jpg", "jpeg", "tga", "psd", "gif", "bmp", "tif", "tiff",
		"exr", "hdr", "webp", "svg", "ktx", "dds", "tres", "res"],
	"font": ["ttf", "otf", "ttc", "otc", "woff2", "woff", "pfb", "pfm", "fnt", "font",
		"tres", "res", "fontsettings"],
	"material": ["tres", "res", "material", "gdshader", "mat"],
	"filter": ["tres", "res", "gdshader", "asset"],
	"stylesheet": ["uss", "tss"],
	"uxml": ["uxml"],
}
## Kind "" (any): the union of the lists above, textures first.
static var _any_extensions: Array = []
## Every `Resources` folder of the project (canonical paths), found once per
## resolver on the first resource() lookup.
var _resource_dirs: Array = []
var _resource_dirs_scanned := false
## "kind|name" -> resolve() result Dictionary (hits and misses).
var _resource_cache: Dictionary = {}
## Built-in theme folders. A reference made FROM a file inside one of these
## (the default theme's url()s) may resolve inside the same folder even
## though it lies outside the project root; nothing else is exempt.
const TRUSTED_DIRS := ["res://addons/godot_uxml/themes/"]


func _init(root: String = "res://") -> void:
	project_root = _normalize_root(root)
	_root_abs = _canon(_abs(project_root))
	while _root_abs.length() > 1 and _root_abs.ends_with("/"):
		_root_abs = _root_abs.substr(0, _root_abs.length() - 1)


## Resolve a reference to a canonical path. Returns
## {ok: bool, path: String, diagnostic: Dictionary}.
## `resource("name")` is a Unity Resources lookup (see resolve_resource);
## `kind` selects its extension list ("" tries every kind).
func resolve(reference: String, from: String = "", kind: String = "") -> Dictionary:
	var ref := reference.strip_edges().replace("\\", "/")
	if ref.begins_with("resource("):
		var name := resource_name(ref)
		if name.is_empty():
			return _fail("malformed-reference", reference, "resource() needs a quoted Resources path")
		return resolve_resource(name, kind)
	# Unity asset references carry a query and a sub-asset fragment
	# (UI Builder: `x.uss?fileID=7433441132597879392&guid=...&type=3#x`).
	# The file is the part before them.
	var cut := ref.find("?")
	var frag := ref.find("#")
	if frag >= 0 and (cut < 0 or frag < cut):
		cut = frag
	if cut >= 0:
		ref = ref.substr(0, cut)
	if ref.is_empty():
		return _fail("malformed-reference", reference, "empty file reference")

	var candidate := ""
	if ref.begins_with("project://"):
		var rel := ref.substr(10)
		if rel.begins_with("database/"):
			rel = rel.substr(9)
		candidate = project_root + "/" + rel
	elif ref.begins_with("/Assets/") or ref.begins_with("/Packages/"):
		candidate = project_root + ref
	elif (ref.begins_with("Assets/") or ref.begins_with("Packages/")) and not from.is_empty():
		# Unity reads `Assets/x` and `Packages/x` without a leading slash as
		# relative to the referencing file (measured: absolute-import-packages,
		# imp-assets-noslash, imp-style-noslash). When no such file exists
		# the project-rooted file is used.
		candidate = from.get_base_dir() + "/" + ref
		if not FileAccess.file_exists(collapse_path(candidate)):
			candidate = project_root + "/" + ref
	elif ref.begins_with("Assets/") or ref.begins_with("Packages/"):
		candidate = project_root + "/" + ref
	elif ref.begins_with("res://") or ref.begins_with("user://"):
		candidate = ref
	elif _is_absolute_fs(ref):
		candidate = ref
	elif not from.is_empty():
		candidate = from.get_base_dir() + "/" + ref
	else:
		candidate = project_root + "/" + ref

	candidate = collapse_path(candidate)
	if candidate.split("/").has(".."):
		return _fail(
			"path-outside-root",
			reference,
			"reference climbs above its root: %s -> %s" % [reference, candidate]
		)
	if not _is_within_root(candidate) and not _trusted(candidate, from):
		return _fail(
			"path-outside-root",
			reference,
			"reference resolves outside the project root: %s -> %s" % [reference, candidate]
		)
	return {"ok": true, "path": candidate, "diagnostic": {}}


static func _trusted(candidate: String, from: String) -> bool:
	for d in TRUSTED_DIRS:
		if from.begins_with(d) and candidate.begins_with(d):
			return true
	return false


## Resolve and read a reference as text. Returns
## {ok, path, text, diagnostic}.
func resolve_text(reference: String, from: String = "") -> Dictionary:
	var r := resolve(reference, from)
	if not r["ok"]:
		r["text"] = ""
		return r
	var f := FileAccess.open(r["path"], FileAccess.READ)
	if f == null:
		return _fail(
			"missing-file",
			reference,
			"project file does not exist: %s" % r["path"]
		)
	return {"ok": true, "path": r["path"], "text": f.get_as_text(), "diagnostic": {}}


## The Resources path inside `resource("name")`, `resource('name')` or
## `resource(name)`; "" when the text is not a well-formed resource().
static func resource_name(text: String) -> String:
	var t := text.strip_edges()
	if not t.begins_with("resource(") or not t.ends_with(")"):
		return ""
	var inner := t.substr(9, t.length() - 10).strip_edges()
	if inner.length() >= 2:
		var q := inner.unicode_at(0)
		if (q == 34 or q == 39) and inner.unicode_at(inner.length() - 1) == q:
			inner = inner.substr(1, inner.length() - 2).strip_edges()
	return inner.replace("\\", "/")


## Unity `Resources.Load(name)`: `name` is a path relative to any folder
## named `Resources` (under Assets/, at any depth, or inside a package),
## without a file extension. The first Resources folder (Assets/ before
## Packages/, then path order) that holds `name` with one of the extensions
## of `kind` (RESOURCE_EXTENSIONS, in order) wins. When no Resources folder
## has the file and `name` has an extension, `name` is also tried as a
## project path, as Unity's stylesheet importer does with
## AssetDatabase.LoadMainAssetAtPath. Results (and misses) are cached per
## resolver.
func resolve_resource(name: String, kind: String = "") -> Dictionary:
	var key := kind + "|" + name
	var hit = _resource_cache.get(key)
	if hit != null:
		return hit
	var out := _resolve_resource_uncached(name, kind)
	_resource_cache[key] = out
	return out


func _resolve_resource_uncached(name: String, kind: String) -> Dictionary:
	var rel := collapse_path(name)
	while rel.begins_with("/"):
		rel = rel.substr(1)
	if rel.is_empty():
		return _fail("malformed-reference", 'resource("%s")' % name, "empty Resources path")
	if rel.split("/").has(".."):
		return _fail("path-outside-root", 'resource("%s")' % name,
			"Resources path climbs above its Resources folder: %s" % name)
	var exts: Array = _extensions(kind)
	for dir in _resources_dirs():
		for ext in exts:
			var cand: String = dir + "/" + rel + "." + ext
			if FileAccess.file_exists(cand) or ResourceLoader.exists(cand):
				return {"ok": true, "path": cand, "diagnostic": {}}
		# An explicit extension (not Resources.Load syntax, but accepted by
		# Unity's importer through the asset database).
		if not rel.get_extension().is_empty():
			var exact: String = dir + "/" + rel
			if FileAccess.file_exists(exact) or ResourceLoader.exists(exact):
				return {"ok": true, "path": exact, "diagnostic": {}}
	if not rel.get_extension().is_empty():
		var r := resolve(rel)
		if r["ok"] and (FileAccess.file_exists(r["path"]) or ResourceLoader.exists(r["path"])):
			return r
	return _fail("missing-file", 'resource("%s")' % name,
		'no Resources folder holds "%s" (tried %s)' % [name, ", ".join(PackedStringArray(exts))])


static func _extensions(kind: String) -> Array:
	if RESOURCE_EXTENSIONS.has(kind):
		return RESOURCE_EXTENSIONS[kind]
	if _any_extensions.is_empty():
		for k in ["texture", "font", "material", "filter", "stylesheet", "uxml"]:
			for e in RESOURCE_EXTENSIONS[k]:
				if not _any_extensions.has(e):
					_any_extensions.append(e)
	return _any_extensions


## Every folder named `Resources` under <root>/Assets and <root>/Packages
## (found once; hidden folders and Godot's .godot cache are skipped).
func _resources_dirs() -> Array:
	if _resource_dirs_scanned:
		return _resource_dirs
	_resource_dirs_scanned = true
	for top in ["Assets", "Packages"]:
		var found: Array = []
		_scan_resources(project_root + "/" + top if not project_root.ends_with("/") else project_root + top, found, 0)
		found.sort()
		_resource_dirs.append_array(found)
	return _resource_dirs


static func _scan_resources(dir: String, found: Array, depth: int) -> void:
	if depth > 32:
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	da.include_hidden = false
	for sub in da.get_directories():
		if sub.begins_with("."):
			continue
		var p := dir + "/" + sub
		if sub == "Resources":
			found.append(p)
		_scan_resources(p, found, depth + 1)


func _fail(kind: String, reference: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"path": "",
		"text": "",
		"diagnostic": {
			"kind": kind,
			"severity": UxmlDiagnostic.severity_of(kind),
			"message": message,
			"file": "",
			"offset": 0,
			"line": 0,
			"column": 0,
			"reference": reference,
		},
	}


static func _is_absolute_fs(path: String) -> bool:
	if path.begins_with("//"):
		return true
	if path.length() >= 3:
		var c := path.unicode_at(0)
		if ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)) and path.substr(1, 2) == ":/":
			return true
	# Unix absolute that is not /Assets or /Packages.
	return path.begins_with("/")


## Canonicalize a path: normalize "\" to "/", preserve res:// and user://
## schemes, Unix "/" roots and UNC "//" prefixes, then collapse "." and ".."
## segments. A ".." that would climb above the path's anchor (scheme, drive
## letter, filesystem root or the path's own start) is retained so callers
## can reject it; it is never silently clamped away.
static func collapse_path(path: String) -> String:
	var rest := path.replace("\\", "/")
	var prefix := ""
	for scheme in ["res://", "user://"]:
		if rest.begins_with(scheme):
			prefix = scheme
			rest = rest.substr(scheme.length())
			break
	if prefix.is_empty():
		if rest.begins_with("//"):
			prefix = "//"
			rest = rest.substr(2)
		elif rest.begins_with("/"):
			prefix = "/"
			rest = rest.substr(1)

	var out: Array = []
	for seg in rest.split("/"):
		if seg.is_empty() or seg == ".":
			continue
		if seg == "..":
			# Never pop the drive letter itself: "C:/../x" must stay
			# visibly above its anchor so it can be rejected.
			if out.size() > 0 and out[-1] != ".." and not (out.size() == 1 and out[0].ends_with(":")):
				out.pop_back()
			else:
				out.append("..")
		else:
			out.append(seg)
	return prefix + "/".join(out)


## The project root spelling: canonicalized, without a trailing slash, but a
## bare scheme ("res://") or filesystem root ("/") keeps its anchor.
static func _normalize_root(root: String) -> String:
	var s := collapse_path(root)
	while s.length() > 1 and not s.ends_with("://") and s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	return s


static func _abs(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


## Comparison form: filesystems on Windows and macOS are conventionally
## case-insensitive; everywhere else case is significant.
static func _canon(path: String) -> String:
	var os_name := OS.get_name()
	if os_name == "Windows" or os_name == "macOS":
		return path.to_lower()
	return path


func _is_within_root(candidate: String) -> bool:
	var abs := _canon(_abs(candidate))
	if _root_abs == "/":
		return abs.begins_with("/")
	return abs == _root_abs or abs.begins_with(_root_abs + "/")
