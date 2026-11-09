extends SceneTree
## Representative game-UI workloads (the stress document in bench.gd is far
## bigger than most shipped Godot screens):
##
##   settings   tabbed settings screen (~4 tabs x 12 rows: label + Slider /
##              Toggle / DropdownField), tab switch via set_class
##   inventory  8x10 slot grid (icon box, count Label, rarity border),
##              hover, select (set_class), count change + relayout
##   dialog     portrait, name, wrapping paragraph, 4 choices; typewriter
##              text growth + relayout per frame, choice hover
##   list1k     1000-row list in a ScrollView (not virtualized):
##              load, hover a row, update one row's text
##
##   Godot --headless --path <project> -s res://bench/workloads.gd [-- --quick] [-- --no-theme]
## Reports median / p95 ms; same timing helpers as bench.gd.

static var ROOT: String = UxmlBenchDir.of("godot_uxml_bench")

var _quick := false
var _rows: Array = []


func _initialize() -> void:
	_quick = OS.get_cmdline_user_args().has("--quick")
	_write_all()
	print("godot-uxml workloads — %s, native=%s" % [
		Engine.get_version_info()["string"], ClassDB.class_exists("UxmlNativeCascade")])
	await _settings()
	await _inventory()
	await _dialog()
	await _list()
	await _listview()
	print("")
	print("| workload | op | n | median ms | p95 ms |")
	print("| --- | --- | ---: | ---: | ---: |")
	for r in _rows:
		print("| %s | %s | %d | %.3f | %.3f |" % r)
	print("WORKLOADS_COMPLETE")
	quit()


# ---------------------------------------------------------------------------

func _stats(name: String, op: String, s: PackedFloat64Array) -> void:
	s.sort()
	var n := s.size()
	var med := s[n / 2]
	var p95 := s[mini(n - 1, int(ceil(n * 0.95)) - 1)]
	_rows.append([name, op, n, med, p95])
	print("  %-10s %-34s median %8.3f ms  p95 %8.3f ms" % [name, op, med, p95])


func _iters(n: int) -> int:
	return maxi(5, n / 5) if _quick else n


## Load timing: fresh document each iteration (incl. its first frame).
func _time_load(name: String, path: String, host: Vector2) -> UxmlDocument:
	var s := PackedFloat64Array()
	var d: UxmlDocument
	for i in _iters(15):
		var t0 := Time.get_ticks_usec()
		d = UxmlDocument.new()
		if OS.get_cmdline_user_args().has("--no-theme"):
			d.set("theme_path", "")  # default theme off (A/B cost of the theme)
		root.add_child(d)
		d.size = host
		d.load_document(path, ROOT)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		if i < _iters(15) - 1:
			root.remove_child(d)
			d.free()
	_stats(name, "load + first layout", s)
	for k in 3:
		await process_frame
	return d


## Mutate, flush synchronously (timed), drain a frame (untimed).
func _time_op(name: String, op: String, d: UxmlDocument, mutate: Callable, n := 60) -> void:
	var s := PackedFloat64Array()
	for i in _iters(n):
		var t0 := Time.get_ticks_usec()
		mutate.call(i)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
	_stats(name, op, s)


func _done(d: UxmlDocument) -> void:
	root.remove_child(d)
	d.free()


# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

func _settings() -> void:
	var d := await _time_load("settings", "Assets/UI/wl_settings.uxml", Vector2(1280, 720))
	await _time_op("settings", "switch tab (display none/flex)", d, func(i):
		for t in 4:
			d.set_class("page-%d" % t, "page" + ("" if t == i % 4 else " hidden"))
			d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i % 4 else "")))
	await _time_op("settings", "hover row", d, func(i):
		d.set_element_state("row-0-%d" % (i % 12), "hover", i % 2 == 0))
	_done(d)


func _inventory() -> void:
	var d := await _time_load("inventory", "Assets/UI/wl_inventory.uxml", Vector2(1280, 720))
	await _time_op("inventory", "hover slot", d, func(i):
		d.set_element_state("slot-%d" % (i % 80), "hover", true)
		d.set_element_state("slot-%d" % ((i + 79) % 80), "hover", false))
	await _time_op("inventory", "select slot (set_class)", d, func(i):
		d.set_class("slot-%d" % (i % 80), "slot slot--selected")
		d.set_class("slot-%d" % ((i + 79) % 80), "slot"))
	await _time_op("inventory", "count change + relayout", d, func(i):
		(d.get_native("count-%d" % (i % 80)) as Label).text = str(i * 7 % 999)
		d.relayout())
	_done(d)


func _dialog() -> void:
	var d := await _time_load("dialog", "Assets/UI/wl_dialog.uxml", Vector2(1280, 720))
	var full := "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said, \"not unless they are running from something, or towards it.\""
	var body := d.get_native("body") as Label
	await _time_op("dialog", "typewriter char + relayout", d, func(i):
		body.text = full.substr(0, 1 + (i * 3) % full.length())
		d.relayout(), 120)
	await _time_op("dialog", "hover choice", d, func(i):
		d.set_element_state("choice-%d" % (i % 4), "hover", i % 2 == 0))
	_done(d)


func _list() -> void:
	var d := await _time_load("list1k", "Assets/UI/wl_list.uxml", Vector2(1280, 720))
	await _time_op("list1k", "hover row", d, func(i):
		d.set_element_state("row-%d" % (i * 13 % 1000), "hover", i % 2 == 0))
	await _time_op("list1k", "update one row + relayout", d, func(i):
		(d.get_native("val-%d" % (i * 17 % 1000)) as Label).text = str(i)
		d.relayout())
	_done(d)


func _listview() -> void:
	var name := "listview10k"
	var bind := func(row: UxmlListRow, i: int):
		(row.get_native("lname") as Label).text = "Entry %d" % i
		(row.get_native("lval") as Label).text = str(i * 3)
	var s := PackedFloat64Array()
	var d: UxmlDocument
	for i in _iters(15):
		var t0 := Time.get_ticks_usec()
		d = UxmlDocument.new()
		if OS.get_cmdline_user_args().has("--no-theme"):
			d.set("theme_path", "")  # default theme off (A/B cost of the theme)
		root.add_child(d)
		d.size = Vector2(1280, 720)
		d.load_document("Assets/UI/wl_listview.uxml", ROOT)
		d.set_list_source("list", 10000, bind)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		if i < _iters(15) - 1:
			root.remove_child(d)
			d.free()
	_stats(name, "load + 10k items + first layout", s)
	for k in 3:
		await process_frame
	await _time_op(name, "scroll 3 rows (rebind + relayout)", d, func(i):
		d.set_scroll_offset("list", Vector2(0, (i * 72) % 200000)), 120)
	await _time_op(name, "hover row", d, func(i):
		var rows: Array = d.get_list_rows("list")
		var row: UxmlListRow = rows[i % 20]
		row.element.set_attribute("class", "unity-collection-view__item unity-list-view__item" + (" hot" if i % 2 == 0 else "")))
	await _time_op(name, "update all visible items (refresh_list)", d, func(i):
		d.refresh_list("list"))
	_done(d)


# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_all() -> void:
	var ui := ROOT + "/Assets/UI/"
	_write(ui + "wl.uss", _uss())
	_write(ui + "wl_settings.uxml", _settings_uxml())
	_write(ui + "wl_inventory.uxml", _inventory_uxml())
	_write(ui + "wl_dialog.uxml", _dialog_uxml())
	_write(ui + "wl_list.uxml", _list_uxml())
	_write(ui + "wl_listview.uxml", _head() + '  <ui:VisualElement name="screen" class="screen">
    <ui:ListView name="list" class="list" fixed-item-height="24" item-template="wl_row.uxml" show-alternating-row-backgrounds="ContentOnly" />
  </ui:VisualElement>
</ui:UXML>')
	_write(ui + "wl_row.uxml", '<ui:UXML xmlns:ui="UnityEngine.UIElements">
  <ui:VisualElement class="lrow">
    <ui:Label name="lname" class="lname" text="" />
    <ui:Label name="lval" class="lval" text="" />
  </ui:VisualElement>
</ui:UXML>')


func _head() -> String:
	return '<ui:UXML xmlns:ui="UnityEngine.UIElements">\n  <Style src="wl.uss" />\n'


func _settings_uxml() -> String:
	var o := PackedStringArray([_head(), '  <ui:VisualElement name="screen" class="screen">'])
	o.append('    <ui:VisualElement class="tabs">')
	for t in 4:
		o.append('      <ui:Button name="tab-%d" class="tab%s" text="Tab %d" />' % [t, " tab--on" if t == 0 else "", t])
	o.append('    </ui:VisualElement>')
	for t in 4:
		o.append('    <ui:VisualElement name="page-%d" class="page%s">' % [t, "" if t == 0 else " hidden"])
		for r in 12:
			o.append('      <ui:VisualElement name="row-%d-%d" class="row">' % [t, r])
			o.append('        <ui:Label class="row-label" text="Option %d.%d" />' % [t, r])
			match r % 3:
				0:
					o.append('        <ui:Slider class="row-ctl" low-value="0" high-value="100" value="%d" />' % (r * 7))
				1:
					o.append('        <ui:Toggle class="row-ctl" value="true" />')
				_:
					o.append('        <ui:DropdownField class="row-ctl" choices="Low,Medium,High,Ultra" value="High" />')
			o.append('      </ui:VisualElement>')
		o.append('    </ui:VisualElement>')
	o.append('  </ui:VisualElement>\n</ui:UXML>')
	return "\n".join(o)


func _inventory_uxml() -> String:
	var o := PackedStringArray([_head(), '  <ui:VisualElement name="screen" class="screen">'])
	o.append('    <ui:Label class="title" text="Inventory" />')
	o.append('    <ui:VisualElement class="grid">')
	for i in 80:
		o.append('      <ui:VisualElement name="slot-%d" class="slot rarity-%d">' % [i, i % 4])
		o.append('        <ui:VisualElement class="icon" />')
		o.append('        <ui:Label name="count-%d" class="count" text="%d" />' % [i, i % 20 + 1])
		o.append('      </ui:VisualElement>')
	o.append('    </ui:VisualElement>')
	o.append('  </ui:VisualElement>\n</ui:UXML>')
	return "\n".join(o)


func _dialog_uxml() -> String:
	var o := PackedStringArray([_head(), '  <ui:VisualElement name="screen" class="screen dialog-screen">'])
	o.append('    <ui:VisualElement class="dialog">')
	o.append('      <ui:VisualElement class="portrait" />')
	o.append('      <ui:VisualElement class="dialog-main">')
	o.append('        <ui:Label class="speaker" text="Keeper" />')
	o.append('        <ui:Label name="body" class="body" text="" />')
	o.append('        <ui:VisualElement class="choices">')
	for c in 4:
		o.append('          <ui:Button name="choice-%d" class="choice" text="Choice %d" />' % [c, c + 1])
	o.append('        </ui:VisualElement>')
	o.append('      </ui:VisualElement>')
	o.append('    </ui:VisualElement>')
	o.append('  </ui:VisualElement>\n</ui:UXML>')
	return "\n".join(o)


func _list_uxml() -> String:
	var o := PackedStringArray([_head(), '  <ui:VisualElement name="screen" class="screen">'])
	o.append('    <ui:ScrollView name="list" class="list">')
	for i in 1000:
		o.append('      <ui:VisualElement name="row-%d" class="lrow%s">' % [i, " lrow--odd" if i % 2 else ""])
		o.append('        <ui:Label class="lname" text="Entry %d" />' % i)
		o.append('        <ui:Label name="val-%d" class="lval" text="%d" />' % [i, i * 3])
		o.append('      </ui:VisualElement>')
	o.append('    </ui:ScrollView>')
	o.append('  </ui:VisualElement>\n</ui:UXML>')
	return "\n".join(o)


func _uss() -> String:
	return """
:root { --fg: rgb(230, 230, 230); --muted: rgba(230, 230, 230, 0.6); --panel: #1e1e24; --accent: #4a90d9; --gap: 6px; }
.screen { flex-grow: 1; padding: 12px; background-color: #111; }
Label { color: var(--fg); font-size: 14px; }
.hidden { display: none; }
.tabs { flex-direction: row; margin-bottom: 8px; }
.tab { width: 120px; height: 32px; margin-right: 4px; background-color: var(--panel); }
.tab--on { background-color: var(--accent); }
.page { flex-grow: 1; }
.row { flex-direction: row; height: 36px; align-items: center; padding: 0 8px; border-radius: 4px; }
.row:hover { background-color: #26262e; }
.row-label { width: 240px; }
.row-ctl { flex-grow: 1; }
.title { font-size: 22px; margin-bottom: 8px; }
.grid { flex-direction: row; flex-wrap: wrap; }
.slot { width: 72px; height: 72px; margin: 3px; background-color: var(--panel); border-width: 2px; border-radius: 6px; justify-content: flex-end; align-items: flex-end; padding: 4px; }
.rarity-0 { border-color: #555; }
.rarity-1 { border-color: #2e7d32; }
.rarity-2 { border-color: #1565c0; }
.rarity-3 { border-color: #8e24aa; }
.slot:hover { background-color: #2a2a33; }
.slot--selected { border-color: gold; border-width: 3px; }
.icon { position: absolute; width: 40px; height: 40px; background-color: #444; border-radius: 4px; }
.count { font-size: 11px; color: var(--muted); }
.dialog-screen { justify-content: flex-end; }
.dialog { flex-direction: row; height: 220px; padding: 16px; background-color: rgba(0, 0, 0, 0.8); border-radius: 8px; }
.portrait { width: 160px; height: 160px; margin-right: 16px; background-color: #333; border-radius: 80px; }
.dialog-main { flex-grow: 1; flex-shrink: 1; }
.speaker { font-size: 18px; color: var(--accent); margin-bottom: 6px; }
.body { white-space: normal; flex-grow: 1; }
.choices { flex-direction: row; }
.choice { flex-grow: 1; height: 30px; margin-right: 6px; }
.choice:hover { background-color: var(--accent); }
.list { flex-grow: 1; }
.lrow { flex-direction: row; height: 24px; padding: 0 8px; align-items: center; }
.lrow--odd { background-color: rgba(255, 255, 255, 0.03); }
.lrow:hover { background-color: #2a2a33; }
.lname { flex-grow: 1; }
.lval { width: 80px; -unity-text-align: middle-right; color: var(--muted); }
"""
