class_name UxmlBenchDir
extends RefCounted
## The user:// folders of the benchmarks and tests, one set per checkout.
##
## Every checkout of the repository is the same Godot project ("godot-uxml"),
## so they share one user:// directory: two scripts of different checkouts
## (or two runs of one script) writing the same folder at once read each
## other's files. Each checkout gets its own folder under user://, named by a
## hash of the checkout's path (of the executable for an exported build);
## GODOT_UXML_BENCH_SLOT names another one (a run of its own).
##   UxmlBenchDir.of("godot_uxml_bench") -> "user://co-1a2b3c4d/godot_uxml_bench"

static var _slot := ""


static func slot() -> String:
	if _slot.is_empty():
		var env := OS.get_environment("GODOT_UXML_BENCH_SLOT")
		if not env.is_empty():
			_slot = env.validate_filename()
		else:
			var key := ProjectSettings.globalize_path("res://")
			if OS.has_feature("template"):
				key = OS.get_executable_path().get_base_dir()
			_slot = "co-%08x" % (hash(key.simplify_path().to_lower()) & 0xffffffff)
	return _slot


## The folder `name` of this checkout (or run): user://<slot>/<name>.
static func of(name: String) -> String:
	return "user://%s/%s" % [slot(), name]
