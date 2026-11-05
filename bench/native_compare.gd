extends SceneTree
## The bench's "big" screen built the way you would hand-author it in Godot:
## native Containers (VBox/HBox/HFlow/Scroll/PanelContainer), StyleBoxFlat
## panels and theme overrides — no USS, no UXML. Compared against the same
## operations through UxmlDocument.
##
##   Godot --headless --path <project> -s res://bench/native_compare.gd
##
## Native containers re-sort in a deferred pass, so layout-triggering ops are
## timed as (frame with the change) - (median idle frame).

const CARDS := 150
const ITEMS := 60

var _rows: Array = []


func _initialize() -> void:
	# No frame pacing: an idle headless frame must cost ~nothing so
	# (frame with change) - (idle frame) is the change's real cost.
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	await _native()
	await _uxml()
	print("")
	print("| op | native Godot | godot-uxml |")
	print("| --- | ---: | ---: |")
	for r in _rows:
		print("| %s | %s | %s |" % r)
	quit()


func _median(a: PackedFloat64Array) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]


## Median over n of (frame containing f's change) - (adjacent idle frame):
## the engine's per-frame cost for a big tree cancels out.
func _frame_ms(f: Callable, n: int) -> float:
	var out := PackedFloat64Array()
	for i in n:
		var t0 := Time.get_ticks_usec()
		await process_frame
		var idle := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		f.call(i)
		await process_frame
		out.append((Time.get_ticks_usec() - t0) / 1000.0 - idle)
	return _median(out)


func _sync_ms(f: Callable, n := 40) -> float:
	var out := PackedFloat64Array()
	for i in n:
		var t0 := Time.get_ticks_usec()
		f.call(i)
		out.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
	return _median(out)


func _frame_only_ms(n := 40) -> float:
	var out := PackedFloat64Array()
	for i in n:
		var t0 := Time.get_ticks_usec()
		await process_frame
		out.append((Time.get_ticks_usec() - t0) / 1000.0)
	return _median(out)


func _sb(c: Color, r := 4, bw := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(r)
	s.set_border_width_all(bw)
	s.border_color = Color(0.27, 0.27, 0.27)
	s.set_content_margin_all(6)
	return s


func _label(t: String, size := 13, col := Color(0.86, 0.86, 0.86)) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _button(t: String, primary := false) -> Button:
	var b := Button.new()
	b.text = t
	b.add_theme_stylebox_override("normal", _sb(Color(0.23, 0.48, 0.84) if primary else Color(0.24, 0.24, 0.24)))
	b.add_theme_stylebox_override("hover", _sb(Color(0.33, 0.33, 0.33)))
	b.add_theme_stylebox_override("pressed", _sb(Color(0.13, 0.13, 0.13)))
	return b


func _build() -> Control:
	var screen := VBoxContainer.new()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 40
	header.add_child(_label("Benchmark", 20))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	for i in 5:
		var b := _button("Nav %d" % i)
		b.custom_minimum_size.x = 70
		header.add_child(b)
	screen.add_child(header)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sc := ScrollContainer.new()
	sc.custom_minimum_size.x = 220
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in ITEMS:
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 28
		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(16, 16)
		row.add_child(icon)
		var l := _label("Item %d" % i)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var t := CheckBox.new()
		t.button_pressed = i % 3 == 0
		row.add_child(t)
		list.add_child(row)
	sc.add_child(list)
	body.add_child(sc)
	var grid := HFlowContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in CARDS:
		var card := PanelContainer.new()
		card.name = "card-%d" % i
		card.custom_minimum_size.x = 200
		card.add_theme_stylebox_override("panel", _sb(Color(0.16, 0.16, 0.16), 4, 1))
		var col := VBoxContainer.new()
		var h := HBoxContainer.new()
		var title := _label("Card %d" % i, 15)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(title)
		h.add_child(_label("new", 10, Color(0.23, 0.48, 0.84)))
		col.add_child(h)
		var bodyl := _label("Body text for card %d with a few words" % i, 13, Color(0.78, 0.78, 0.78, 0.6))
		bodyl.name = "body"
		bodyl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(bodyl)
		var acts := HBoxContainer.new()
		for k in 2:
			var b2 := _button("OK" if k == 0 else "Cancel", k == 0)
			b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			acts.add_child(b2)
		col.add_child(acts)
		if i % 4 == 0:
			var s := HSlider.new()
			s.max_value = 10
			col.add_child(s)
		if i % 5 == 0:
			var le := LineEdit.new()
			le.text = "card %d" % i
			col.add_child(le)
		card.add_child(col)
		grid.add_child(card)
	body.add_child(grid)
	screen.add_child(body)
	var footer := HBoxContainer.new()
	for i in 6:
		footer.add_child(_label("Status %d" % i, 11))
	screen.add_child(footer)
	return screen


func _own_all(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_own_all(c, owner)


func _native() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 800)
	root.add_child(host)
	# Build in code (+ first layout frame).
	var builds := PackedFloat64Array()
	var ui: Control
	for i in 5:
		var t0 := Time.get_ticks_usec()
		ui = _build()
		host.add_child(ui)
		await process_frame
		builds.append((Time.get_ticks_usec() - t0) / 1000.0)
		if i < 4:
			host.remove_child(ui)
			ui.free()
	var nodes := 0
	var stack: Array = [ui]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		stack.append_array(n.get_children())
	print("native nodes: %d" % nodes)
	# PackedScene (what a .tscn load instantiates).
	host.remove_child(ui)
	_own_all(ui, ui)
	var ps := PackedScene.new()
	ps.pack(ui)
	ui.free()
	var insts := PackedFloat64Array()
	for i in 5:
		var t0 := Time.get_ticks_usec()
		ui = ps.instantiate()
		host.add_child(ui)
		await process_frame
		insts.append((Time.get_ticks_usec() - t0) / 1000.0)
		if i < 4:
			host.remove_child(ui)
			ui.free()
	for k in 5:
		await process_frame
	var containers: Array = []
	var st: Array = [ui]
	while not st.is_empty():
		var n: Node = st.pop_front()
		if n is Container:
			containers.append(n)
		st.append_array(n.get_children())
	var grid: Control = ui.get_child(1).get_child(1)
	var card: PanelContainer = grid.get_child(12)
	var panel: StyleBoxFlat = card.get_theme_stylebox("panel")
	var bodyl: Label = card.find_child("body", true, false)
	# Synchronous: force every container to re-sort, top-down (an upper
	# bound — the engine's deferred sort only touches containers whose
	# size or children's minimum size changed).
	var sort_all := func():
		for c in containers:
			c.notification(Container.NOTIFICATION_SORT_CHILDREN)
	var hover := await _sync_ms(func(i):
		panel.bg_color = Color(0.2, 0.2, 0.2) if i % 2 == 0 else Color(0.16, 0.16, 0.16))
	var resize := await _sync_ms(func(i):
		host.size = Vector2(1280, 800) if i % 2 == 0 else Vector2(1024, 720)
		sort_all.call())
	# Text change: the engine re-sorts only the label's container chain.
	var chain: Array = []
	var a2: Node = bodyl.get_parent()
	while a2 != null and a2 != host:
		if a2 is Container:
			chain.push_front(a2)
		a2 = a2.get_parent()
	var text := await _sync_ms(func(i):
		bodyl.text = "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
		for c in chain:
			c.notification(Container.NOTIFICATION_SORT_CHILDREN))
	var frame := await _frame_only_ms()
	_rows.append(["build in code + first layout (big)", "%.1f ms" % _median(builds), ""])
	_rows.append(["instantiate .tscn + first layout (big)", "%.1f ms" % _median(insts), ""])
	_rows.append(["hover-like recolor", "%.3f ms" % hover, ""])
	_rows.append(["resize relayout (native: all containers forced)", "%.2f ms" % resize, ""])
	_rows.append(["one Label text change + relayout", "%.3f ms" % text, ""])
	_rows.append(["engine idle frame, same tree size", "%.1f ms" % frame, ""])
	root.remove_child(host)
	host.free()


func _uxml() -> void:
	var path := "Assets/UI/big.uxml"
	var proj := "user://godot_uxml_bench"
	if not FileAccess.file_exists(proj + "/" + path):
		print("run bench/bench.gd once first")
		return
	var loads := PackedFloat64Array()
	var d: UxmlDocument
	for i in 5:
		var t0 := Time.get_ticks_usec()
		d = UxmlDocument.new()
		root.add_child(d)
		d.size = Vector2(1280, 800)
		d.load_document(path, proj)
		await process_frame
		loads.append((Time.get_ticks_usec() - t0) / 1000.0)
		if i < 4:
			root.remove_child(d)
			d.free()
	for k in 5:
		await process_frame
	var hover := await _sync_ms(func(i):
		d.set_element_state("card-12", "hover", i % 2 == 0)
		d._restyle_now())
	var resize := await _sync_ms(func(i):
		d.size = Vector2(1280, 800) if i % 2 == 0 else Vector2(1024, 720))
	var bodyl: Label = d.get_native("card-12-body")
	var text := await _sync_ms(func(i):
		bodyl.text = "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
		d.relayout()
		d._restyle_now())
	var frame := await _frame_only_ms()
	var u := [
		"%.1f ms" % _median(loads), "— (loads .uxml/.uss: %.1f ms)" % _median(loads),
		"%.3f ms" % hover, "%.2f ms" % resize, "%.3f ms (relayout())" % text,
		"%.1f ms" % frame,
	]
	for k in u.size():
		_rows[k][2] = u[k]
	root.remove_child(d)
	d.free()
