extends SceneTree
## Profiling driver: runs one operation of bench/unity_compare.gd many times
## between gdprof markers (tools/gdprof.py --marked).
##   Godot --path . -s res://bench/prof/ops.gd -- --op=<op> [--n=N]
const ROOT := "user://godot_uxml_ucmp"
var _n := 30
var _noprof := false

func _mark(on: bool) -> void:
	if _noprof:
		return
	if ClassDB.class_exists("UxmlNative"):
		if on:
			ClassDB.class_call_static("UxmlNative", "prof_take")
		ClassDB.class_call_static("UxmlNative", "prof_enable", on)
		if not on:
			var p: Dictionary = ClassDB.class_call_static("UxmlNative", "prof_take")
			var ks := p.keys()
			ks.sort_custom(func(a, b): return p[a][0] > p[b][0])
			for k in ks:
				print("  native %-28s %9.2f ms %8d calls" % [k, p[k][0] / _n, p[k][1] / _n])
			print("  (per iteration)")
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gdprof:on" if on else "gdprof:off", [])

func _initialize() -> void:
	var op := "big-load"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--op="): op = a.substr(5)
		elif a.begins_with("--n="): _n = int(a.substr(4))
		elif a == "--noprof": _noprof = true
		elif a.begins_with("--runtime="): UxmlDocument.default_runtime = int(a.substr(10))
		elif a == "--gdscript":
			UxmlParser.use_native = false
			UssParser.use_native = false
			UssCascade.use_native = false
	for k in 3: await process_frame
	var t0 := Time.get_ticks_usec()
	match op:
		"big-load": await _load("Assets/UI/big.uxml", Vector2(1280, 800))
		"settings-load": await _load("Assets/UI/wl_settings.uxml", Vector2(1280, 720))
		"inventory-load": await _load("Assets/UI/wl_inventory.uxml", Vector2(1280, 720))
		"dialog-load": await _load("Assets/UI/wl_dialog.uxml", Vector2(1280, 720))
		"lv-load": await _load("Assets/UI/wl_listview.uxml", Vector2(1280, 720), true)
		"big-steps":
			var steps := {}
			for i in _n:
				_profile_load("Assets/UI/big.uxml", steps)
				await process_frame
			for k in steps:
				var a: Array = steps[k]
				a.sort()
				print("  step %-40s %8.2f ms" % [k, a[a.size() / 2]])
		"load-steps", "settings-steps", "inventory-steps", "dialog-steps":
			# The steps of UxmlDocument._finish_load as the document times
			# them (UxmlDocument.profile), the rest of the load as "parse".
			var doc := "big" if op == "load-steps" else "wl_" + op.get_slice("-", 0)
			var steps := {}
			for i in _n + 2:
				var d := UxmlDocument.new()
				root.add_child(d)
				d.size = Vector2(1280, 800) if doc == "big" else Vector2(1280, 720)
				UxmlDocument.profile = {}
				var t := Time.get_ticks_usec()
				d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
				var total := (Time.get_ticks_usec() - t) / 1000.0
				var p: Dictionary = UxmlDocument.profile
				UxmlDocument.profile = null
				var rest := total
				for k in p:
					rest -= float(p[k])
				p["parse, theme attach, rest"] = rest
				p["TOTAL"] = total
				if i >= 2:
					for k in p:
						if not steps.has(k): steps[k] = []
						steps[k].append(float(p[k]))
				root.remove_child(d)
				d.free()
				await process_frame
			for k in steps:
				var a: Array = steps[k]
				a.sort()
				print("  step %-40s %8.2f ms" % [k, a[a.size() / 2]])
		_:
			await _op(op)
	print("PROF_DONE %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	quit(0)

func _bind(row, i):
	var ln := row.get_native("lname") as Label
	if ln == null:
		row.set_text("lname", "Entry %d" % i)
		row.set_text("lval", str(i * 3))
	else:
		ln.text = "Entry %d" % i
		(row.get_native("lval") as Label).text = str(i * 3)

func _load(path: String, size: Vector2, lv := false) -> void:
	var s := PackedFloat64Array()
	for i in _n + 2:
		if i == 2: _mark(true)
		var t0 := Time.get_ticks_usec()
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = size
		d.load_document(path, ROOT)
		if lv: d.set_list_source("list", 10000, _bind)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		root.remove_child(d)
		d.free()
		await process_frame
	_mark(false)
	s.sort()
	print("median %.3f ms" % s[s.size() / 2])

func _op(op: String) -> void:
	var path := "Assets/UI/big.uxml"
	var size := Vector2(1280, 800)
	if op.begins_with("settings"): path = "Assets/UI/wl_settings.uxml"; size = Vector2(1280, 720)
	if op.begins_with("inv"): path = "Assets/UI/wl_inventory.uxml"; size = Vector2(1280, 720)
	if op.begins_with("dialog"): path = "Assets/UI/wl_dialog.uxml"; size = Vector2(1280, 720)
	if op.begins_with("lv"): path = "Assets/UI/wl_listview.uxml"; size = Vector2(1280, 720)
	if op.begins_with("hud"): path = "Assets/UI/hud.uxml"; size = Vector2(640, 360)
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = size
	d.load_document(path, ROOT)
	if op.begins_with("lv"): d.set_list_source("list", 10000, _bind)
	for k in 3: await process_frame
	var f: Callable
	match op:
		"noop": f = func(_i): pass
		"hover-button": f = func(i): d.set_element_state("card-7-ok", "hover", i % 2 == 0)
		"hover-card": f = func(i): d.set_element_state("card-12", "hover", i % 2 == 0)
		"class": f = func(i): d.set_class("card-20", "card card--selected" if i % 2 == 0 else "card")
		"text":
			var body := d.get_native("card-30-body") as Label
			f = func(i):
				var t := "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
				if body == null:
					d.set_text("card-30-body", t)
				else:
					body.text = t
				d.relayout()
		"resize": f = func(i): d.size = Vector2(1024, 720) if i % 2 == 0 else Vector2(1280, 800)
		"hud-frame":
			var labels: Array = []
			for i in 8: labels.append(d.get_native("val-%d" % i))
			f = func(i):
				for k in labels.size(): (labels[k] as Label).text = str((i * 37 + k * 101) % 100000)
				d.relayout()
		"settings-tab": f = func(i):
			for t in 4:
				d.set_class("page-%d" % t, "page" + ("" if t == i % 4 else " hidden"))
				d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i % 4 else ""))
		"settings-hover": f = func(i): d.set_element_state("row-0-%d" % (i % 12), "hover", i % 2 == 0)
		"inv-select": f = func(i):
			d.set_class("slot-%d" % (i % 80), "slot rarity-%d slot--selected" % (i % 4))
			d.set_class("slot-%d" % ((i + 79) % 80), "slot rarity-%d" % ((i + 79) % 4))
		"inv-count": f = func(i):
			(d.get_native("count-%d" % (i % 80)) as Label).text = str(i * 7 % 999)
			d.relayout()
		"dialog-type":
			var body := d.get_native("body") as Label
			var t := "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said."
			f = func(i):
				body.text = t.substr(0, 1 + (i * 3) % t.length())
				d.relayout()
		"lv-scroll": f = func(i): d.set_scroll_offset("list", Vector2(0, ((i + 1) * 72) % 200000))
		"lv-rebind": f = func(_i): d.refresh_list("list")
	var s := PackedFloat64Array()
	for i in _n + 4:
		if i == 4: _mark(true)
		var t0 := Time.get_ticks_usec()
		f.call(i)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
	_mark(false)
	s.sort()
	print("median %.3f ms" % s[s.size() / 2])


func _profile_load(path: String, steps: Dictionary) -> void:
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = Vector2(1280, 800)
	var t := Time.get_ticks_usec()
	d._clear()
	var res := d._resolver_for("user://godot_uxml_ucmp", null)
	d._resolver = res
	d._doc = UxmlLoader.load_file_with_resolver(path, res)
	d._last_text = null
	t = _add(steps, "parse (uxml, uss, imports)", t)
	d._loader_warnings = d._doc.warnings.size()
	UxmlTheme.attach(d._doc, d.theme_path, d.editor_theme, d.editor_skin)
	t = _add(steps, "theme attach", t)
	var collections := d._prepare_collections()
	UxmlParts.expand(d._doc)
	if collections:
		d._rt_warnings.append_array(UxmlBindings.extract(d._doc))
	t = _add(steps, "part trees", t)
	var stack: Array = [d._doc.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		for child in el.children:
			d._parents[child] = el
			stack.append(child)
	for el in d._doc.root.walk():
		if el.part_of != null:
			continue
		var n = el.get_attribute("name")
		if n != null and not d._by_name.has(String(n)):
			d._by_name[String(n)] = el
			d._el_names[el] = String(n)
	t = _add(steps, "index (parents, names)", t)
	var factory := UxmlControlFactory.new(d._resolver, d._doc.path, d._doc.source, d._rt_warnings)
	factory.element_paths = d._doc.element_paths
	var built: Array = []
	for child in d._doc.root.children:
		if UssControls.is_non_visual(child.local):
			continue
		built.append(factory.build(child))
	d._controls = factory.controls
	d._natives = factory.natives
	d._controls[d._doc.root] = d._root_box
	for el in d._controls:
		d._el_of[d._controls[el]] = el
	t = _add(steps, "control creation", t)
	d._park_hidden()
	t = _add(steps, "cascade (first resolve)", t)
	for c in built:
		if not c.has_meta(&"uxml_parked"):
			d._root_box.add_child(c)
	if "_first_pass" in d:
		d.set("_first_pass", true)
	t = _add(steps, "add_child (built controls)", t)
	var on_changed := d._on_model_changed
	for el in d._doc.root.walk():
		el.changed = on_changed
	for el in d._controls:
		if el == d._doc.root:
			continue
		d._wire(el, d._controls[el])
	t = _add(steps, "signal wiring", t)
	d._behaviors = UxmlBehaviors.attach_all(d)
	d._attrs.setup()
	d._binding.setup()
	t = _add(steps, "behaviors, attributes, bindings", t)
	var sc: GDScript = d.get_script()
	var has_profile := "profile" in sc
	if has_profile:
		sc.set("profile", {})
	d._restyle_now()
	if has_profile:
		var p: Dictionary = sc.get("profile")
		sc.set("profile", null)
		var rest := (Time.get_ticks_usec() - t) / 1000.0
		for k in ["apply", "layout"]:
			if not steps.has("first restyle: " + k):
				steps["first restyle: " + k] = []
			steps["first restyle: " + k].append(float(p.get(k, 0.0)))
			rest -= float(p.get(k, 0.0))
		if not steps.has("first restyle: cascade update, rest"):
			steps["first restyle: cascade update, rest"] = []
		steps["first restyle: cascade update, rest"].append(rest)
		t = Time.get_ticks_usec()
	else:
		t = _add(steps, "first restyle (apply + layout)", t)
	d._attrs.restore_view_data()
	d._force_layout = true
	d._placed_force = d._controls.keys()
	d._do_layout()
	d._placed_force = []
	_add(steps, "(a second full layout)", t)
	root.remove_child(d)
	d.free()


static func _add(steps: Dictionary, k: String, t0: int) -> int:
	var t := Time.get_ticks_usec()
	if not steps.has(k):
		steps[k] = []
	(steps[k] as Array).append((t - t0) / 1000.0)
	return t
