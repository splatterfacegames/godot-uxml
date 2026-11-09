extends SceneTree
## The runtime each benchmark document loads on with runtime = 2, and why
## a document stays on runtime v1 (UxmlDocument.runtime_fallback).
##   Godot --path . -s res://bench/v2/probe.gd
const ROOT := "user://godot_uxml_ucmp"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	for doc in ["big-static", "hud", "big", "wl_settings", "wl_inventory", "wl_dialog"]:
		var d := UxmlDocument.new()
		d.runtime = 2
		root.add_child(d)
		d.size = Vector2(1280, 800)
		d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
		print("%s: runtime %d %s" % [doc, d.get_runtime(), d.runtime_fallback])
		d.free()
	print("PROBE_DONE")
	quit(0)
