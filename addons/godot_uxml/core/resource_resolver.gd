class_name UxmlResourceResolver
extends RefCounted
## Turns the path spellings UXML/USS authors use into Godot file paths inside
## one declared project root, and reads them.
##
## Accepted reference forms (matching the editor's PathResolver):
##   project://database/Assets/UI/x.uss  -> <root>/Assets/UI/x.uss
##   project://database/Packages/p/x.uss -> <root>/Packages/p/x.uss
##   /Assets/UI/x.uss                    -> <root>/Assets/UI/x.uss
##   Assets/UI/x.uss, Packages/p/x.uss   -> <root>/<same>
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
func resolve(reference: String, from: String = "") -> Dictionary:
	var ref := reference.strip_edges().replace("\\", "/")
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


func _fail(kind: String, reference: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"path": "",
		"text": "",
		"diagnostic": {
			"kind": kind,
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
