extends SceneTree
## Load time of documents on runtime v1 and v2, interleaved, with the
## steps of a v2 load (UxmlDocument.profile).
##   Godot --path . -s res://bench/v2/load_cost.gd [-- --n=15 --doc=big-static]
const ROOT := "user://godot_uxml_ucmp"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var n := 15
	var docs := ["big-static", "hud", "big"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--doc="): docs = a.substr(6).split(",")
	load("res://bench/unity_compare.gd")  # documents
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	for doc in docs:
		var t := {1: [], 2: []}
		var steps := {}
		var on := 0
		var rts := [2] if OS.get_cmdline_user_args().has("--v2-only") else [1, 2]
		for i in n + 2:
			for rt in rts:
				var d := UxmlDocument.new()
				d.runtime = rt
				root.add_child(d)
				d.size = Vector2(1280, 800)
				UxmlDocument.profile = {} if rt == 2 else null
				var t0 := Time.get_ticks_usec()
				d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
				var ms := (Time.get_ticks_usec() - t0) / 1000.0
				if rt == 2:
					on = d.get_runtime()
					if i >= 2:
						var p: Dictionary = UxmlDocument.profile
						var rest := ms
						for k in p:
							rest -= float(p[k])
							if not steps.has(k): steps[k] = []
							steps[k].append(float(p[k]))
						if not steps.has("v2: parse, theme, rest"): steps["v2: parse, theme, rest"] = []
						steps["v2: parse, theme, rest"].append(rest)
				UxmlDocument.profile = null
				if i >= 2:
					t[rt].append(ms)
				root.remove_child(d)
				d.free()
				await process_frame
		print("%s: v1 %.2f ms, v2 %.2f ms (runtime %d)" % [doc, _med(t[1]) if not t[1].is_empty() else 0.0, _med(t[2]), on])
		if OS.get_cmdline_user_args().has("--native"):
			UxmlNative.prof_enable(true)
			UxmlNative.prof_take()
			var d := UxmlDocument.new()
			d.runtime = 2
			root.add_child(d)
			d.size = Vector2(1280, 800)
			d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
			var pt: Dictionary = UxmlNative.prof_take()
			UxmlNative.prof_enable(false)
			for k in pt:
				print("    native %-24s %8.2f ms %6d calls" % [k, pt[k][0], pt[k][1]])
			d.free()
		for k in steps:
			print("    %-28s %8.2f ms" % [k, _med(steps[k])])
	print("LOAD_COST_DONE")
	quit(0)

func _med(a: Array) -> float:
	if a.is_empty(): return 0.0
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]
