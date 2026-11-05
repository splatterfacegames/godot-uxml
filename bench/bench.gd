extends SceneTree
## godot-uxml benchmark harness (headless).
##
##   Godot --headless --path <project> -s res://bench/bench.gd [-- --quick] [-- --only=<substr>]
##
## Generates a large synthetic document (nested flex rows/columns, many
## classes, three stylesheets with @import, descendant/child selectors,
## var(), pseudo-classes, inline styles) under user://, plus a small HUD
## document, and times:
##   * the load pipeline stages (UXML parse, USS parse, loader, cascade,
##     full UxmlDocument.load_document incl. instantiate + apply + layout)
##   * the existing fixtures end to end
##   * steady-state interaction: hover/focus toggles, set_class churn,
##     set_text + refresh, window resize relayout
##   * per-frame cost of a HUD whose labels change every frame
##
## Only public API is used, plus UxmlDocument._restyle_now() as the
## synchronous flush of the coalesced (deferred) restyle — so the same
## script measures any revision of the addon. Each op reports median /
## p95 / mean ms over N iterations (adaptive: stops at max_iters or when
## the time budget for that op is spent).

const BENCH_ROOT := "user://godot_uxml_bench"
const CARDS := 150
const LIST_ITEMS := 60

var _quick := false
var _only := ""
var _results: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--quick":
			_quick = true
		elif a.begins_with("--only="):
			_only = a.substr(7)
	_write_fixtures()
	print("godot-uxml bench — Godot %s, %s, %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("large document: %d elements" % _count_elements())
	await _run()
	_print_table()
	quit(0)


# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------

func _want(op: String) -> bool:
	return _only.is_empty() or op.find(_only) >= 0


## Times `fn` (a Callable returning nothing). `setup`, when valid, runs
## untimed before every iteration. Returns nothing; records a row.
func _time(op: String, fn: Callable, max_iters: int, budget_ms: float, setup: Callable = Callable()) -> void:
	if not _want(op):
		return
	if _quick:
		max_iters = maxi(3, max_iters / 5)
		budget_ms /= 4.0
	# warmup
	if setup.is_valid():
		setup.call()
	fn.call()
	var samples: PackedFloat64Array = []
	var spent := 0.0
	while samples.size() < max_iters and (spent < budget_ms or samples.size() < 3):
		if setup.is_valid():
			setup.call()
		var t0 := Time.get_ticks_usec()
		fn.call()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		samples.append(dt)
		spent += dt
	_record(op, samples)


## Like _time, but each iteration may await (frame draining between ops).
## `fn` returns the elapsed ms of the timed region itself.
func _time_async(op: String, fn: Callable, max_iters: int, budget_ms: float) -> void:
	if not _want(op):
		return
	if _quick:
		max_iters = maxi(3, max_iters / 5)
		budget_ms /= 4.0
	await fn.call()
	var samples: PackedFloat64Array = []
	var spent := 0.0
	while samples.size() < max_iters and (spent < budget_ms or samples.size() < 3):
		var dt: float = await fn.call()
		samples.append(dt)
		spent += dt
	_record(op, samples)


func _record(op: String, samples: PackedFloat64Array) -> void:
	var s := samples.duplicate()
	s.sort()
	var n := s.size()
	var med := s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) / 2.0
	var p95 := s[mini(n - 1, int(ceil(n * 0.95)) - 1)]
	var mean := 0.0
	for v in s:
		mean += v
	mean /= n
	_results.append({"op": op, "n": n, "median": med, "p95": p95, "mean": mean})
	print("  %-34s n=%-4d median %9.3f ms  p95 %9.3f ms" % [op, n, med, p95])


func _print_table() -> void:
	print("")
	print("| op | n | median ms | p95 ms | mean ms |")
	print("| --- | ---: | ---: | ---: | ---: |")
	for r in _results:
		print("| %s | %d | %.3f | %.3f | %.3f |" % [r["op"], r["n"], r["median"], r["p95"], r["mean"]])
	print("BENCH_COMPLETE")


# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

func _run() -> void:
	var big_path := "Assets/UI/big.uxml"
	var big_src := FileAccess.get_file_as_string(BENCH_ROOT + "/" + big_path)
	var sheet_srcs: Array = []
	for f in ["base.uss", "components.uss", "theme.uss"]:
		sheet_srcs.append(FileAccess.get_file_as_string(BENCH_ROOT + "/Assets/UI/" + f))

	print("[load pipeline]")
	_time("parse_uxml(big)", func():
		UxmlParser.new().parse(big_src, "big.uxml"), 30, 3000.0)
	_time("parse_uss(3 sheets)", func():
		for s in sheet_srcs:
			UssParser.new().parse(s, "x.uss"), 30, 3000.0)
	_time("loader(big)", func():
		UxmlLoader.load_file(big_path, BENCH_ROOT), 30, 3000.0)
	var model := UxmlLoader.load_file(big_path, BENCH_ROOT)
	_time("cascade resolve(big)", func():
		UssStyleResolver.resolve(model), 20, 6000.0)
	_time("cascade resolve(big, hover)", func():
		UssStyleResolver.resolve(model, {"states": {"#card-3": ["hover"]}}), 10, 4000.0)
	_time("load_document(big) full", func():
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = Vector2(1280, 800)
		d.load_document(big_path, BENCH_ROOT)
		root.remove_child(d)
		d.free(), 10, 8000.0)

	print("[fixtures]")
	for fx in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/menu", "Assets/UI/Menu.uxml"],
	]:
		var fx_root: String = fx[0]
		var fx_path: String = fx[1]
		_time("load_document(%s)" % fx_path.get_file(), func():
			var d := UxmlDocument.new()
			root.add_child(d)
			d.size = Vector2(400, 600)
			d.load_document(fx_path, fx_root)
			root.remove_child(d)
			d.free(), 40, 3000.0)

	print("[steady state, big document]")
	var doc := UxmlDocument.new()
	root.add_child(doc)
	doc.size = Vector2(1280, 800)
	doc.load_document(big_path, BENCH_ROOT)
	await process_frame
	await _steady(doc)
	root.remove_child(doc)
	doc.free()

	print("[HUD per-frame]")
	var hud := UxmlDocument.new()
	root.add_child(hud)
	hud.size = Vector2(640, 360)
	hud.load_document("Assets/UI/hud.uxml", BENCH_ROOT)
	await process_frame
	var labels: Array = []
	for i in 8:
		labels.append(hud.get_native("val-%d" % i))
	var frame := [0]
	await _time_async("hud frame (8 labels + refresh)", func() -> float:
		frame[0] += 1
		var t0 := Time.get_ticks_usec()
		for i in labels.size():
			(labels[i] as Label).text = str((frame[0] * 37 + i * 101) % 100000)
		hud.refresh()
		hud._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
		return dt, 300, 3000.0)
	if hud.has_method("relayout"):
		await _time_async("hud frame (8 labels + relayout)", func() -> float:
			frame[0] += 1
			var t0 := Time.get_ticks_usec()
			for i in labels.size():
				(labels[i] as Label).text = str((frame[0] * 37 + i * 101) % 100000)
			hud.relayout()
			hud._restyle_now()
			var dt := (Time.get_ticks_usec() - t0) / 1000.0
			await process_frame
			return dt, 300, 3000.0)
	await _time_async("hud frame (8 labels, no refresh)", func() -> float:
		frame[0] += 1
		var t0 := Time.get_ticks_usec()
		for i in labels.size():
			(labels[i] as Label).text = str((frame[0] * 37 + i * 101) % 100000)
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
		return dt, 300, 3000.0)
	await _time_async("hud hover toggle", func() -> float:
		frame[0] += 1
		var t0 := Time.get_ticks_usec()
		hud.set_element_state("bar-0", "hover", frame[0] % 2 == 0)
		hud._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
		return dt, 300, 3000.0)
	root.remove_child(hud)
	hud.free()


## Every op mutates, flushes synchronously (timed), then drains a frame
## (untimed) so any deferred restyle the mutation queued runs outside the
## measurement.
func _steady(doc: UxmlDocument) -> void:
	var flip := [false]
	var op := func(mutate: Callable) -> float:
		var t0 := Time.get_ticks_usec()
		mutate.call()
		doc._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
		return dt

	await _time_async("hover toggle (button)", func() -> float:
		flip[0] = not flip[0]
		return await op.call(func(): doc.set_element_state("card-7-ok", "hover", flip[0])), 60, 6000.0)
	await _time_async("hover toggle (card, desc sel)", func() -> float:
		flip[0] = not flip[0]
		return await op.call(func(): doc.set_element_state("card-12", "hover", flip[0])), 60, 6000.0)
	await _time_async("hover move (card i -> i+1)", func() -> float:
		flip[0] = not flip[0]
		var i := Time.get_ticks_usec() % CARDS
		return await op.call(func():
			doc.set_element_state("card-%d" % i, "hover", false)
			doc.set_element_state("card-%d" % ((i + 1) % CARDS), "hover", true)), 60, 6000.0)
	await _time_async("focus toggle (list item)", func() -> float:
		flip[0] = not flip[0]
		return await op.call(func(): doc.set_element_state("item-5", "focus", flip[0])), 60, 6000.0)
	await _time_async("set_class churn (card)", func() -> float:
		flip[0] = not flip[0]
		return await op.call(func():
			doc.set_class("card-20", "card card--selected" if flip[0] else "card")), 60, 6000.0)
	await _time_async("set_text + refresh", func() -> float:
		flip[0] = not flip[0]
		return await op.call(func():
			(doc.get_native("card-30-body") as Label).text = "short" if flip[0] else "a much longer body text that wraps over lines"
			doc.refresh()), 60, 6000.0)
	if doc.has_method("relayout"):
		await _time_async("set_text + relayout", func() -> float:
			flip[0] = not flip[0]
			return await op.call(func():
				(doc.get_native("card-30-body") as Label).text = "short" if flip[0] else "a much longer body text that wraps over lines"
				doc.relayout()), 60, 6000.0)
	await _time_async("resize relayout", func() -> float:
		flip[0] = not flip[0]
		var t0 := Time.get_ticks_usec()
		doc.size = Vector2(1280, 800) if flip[0] else Vector2(1024, 720)
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
		return dt, 60, 6000.0)
	await _time_async("idle restyle (no change)", func() -> float:
		return await op.call(func(): pass), 60, 6000.0)
	# Leave the document clean.
	doc.size = Vector2(1280, 800)


# ---------------------------------------------------------------------------
# Synthetic documents
# ---------------------------------------------------------------------------

func _count_elements() -> int:
	var m := UxmlLoader.load_file("Assets/UI/big.uxml", BENCH_ROOT)
	return m.root.walk().size()


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_fixtures() -> void:
	var ui := BENCH_ROOT + "/Assets/UI/"
	_write(ui + "big.uxml", _big_uxml())
	_write(ui + "base.uss", _base_uss())
	_write(ui + "components.uss", _components_uss())
	_write(ui + "theme.uss", _theme_uss())
	_write(ui + "hud.uxml", _hud_uxml())
	_write(ui + "hud.uss", _hud_uss())


func _big_uxml() -> String:
	var o := PackedStringArray()
	o.append('<ui:UXML xmlns:ui="UnityEngine.UIElements">')
	o.append('  <Style src="base.uss" />')
	o.append('  <ui:VisualElement name="screen" class="screen col">')
	o.append('    <ui:VisualElement name="header" class="header row">')
	o.append('      <ui:Label name="title" class="title h1" text="Benchmark" />')
	o.append('      <ui:VisualElement class="spacer" />')
	for i in 5:
		o.append('      <ui:Button name="nav-%d" class="btn nav" text="Nav %d" />' % [i, i])
	o.append('    </ui:VisualElement>')
	o.append('    <ui:VisualElement name="body" class="body row">')
	o.append('      <ui:VisualElement name="sidebar" class="sidebar col">')
	o.append('        <ui:ScrollView name="list" class="list">')
	for i in LIST_ITEMS:
		o.append('          <ui:VisualElement name="item-%d" class="list-item row%s" focusable="true">' % [i, " list-item--odd" if i % 2 == 1 else ""])
		o.append('            <ui:VisualElement class="icon" />')
		o.append('            <ui:Label class="list-label" text="Item %d" />' % i)
		o.append('            <ui:Toggle class="list-toggle" value="%s" />' % ("true" if i % 3 == 0 else "false"))
		o.append('          </ui:VisualElement>')
	o.append('        </ui:ScrollView>')
	o.append('      </ui:VisualElement>')
	o.append('      <ui:VisualElement name="content" class="content col">')
	o.append('        <ui:VisualElement name="grid" class="grid row wrap">')
	for i in CARDS:
		var extra := ""
		if i % 7 == 3:
			extra = " card--alt"
		var inline := ' style="margin-left: %dpx;"' % (i % 5) if i % 9 == 0 else ""
		o.append('          <ui:VisualElement name="card-%d" class="card%s"%s>' % [i, extra, inline])
		o.append('            <ui:VisualElement class="card-header row">')
		o.append('              <ui:Label class="card-title title" text="Card %d" />' % i)
		o.append('              <ui:Label class="badge" text="new" />')
		o.append('            </ui:VisualElement>')
		o.append('            <ui:Label name="card-%d-body" class="card-body body-text" text="Body text for card %d with a few words" />' % [i, i])
		o.append('            <ui:VisualElement class="card-actions row">')
		o.append('              <ui:Button name="card-%d-ok" class="btn btn-primary" text="OK" />' % i)
		o.append('              <ui:Button class="btn" text="Cancel" />')
		o.append('            </ui:VisualElement>')
		if i % 4 == 0:
			o.append('            <ui:Slider class="card-slider" low-value="0" high-value="10" value="%d" />' % (i % 10))
		if i % 5 == 0:
			o.append('            <ui:TextField class="card-field" label="Name" value="card %d" />' % i)
		o.append('          </ui:VisualElement>')
	o.append('        </ui:VisualElement>')
	o.append('      </ui:VisualElement>')
	o.append('    </ui:VisualElement>')
	o.append('    <ui:VisualElement name="footer" class="footer row">')
	for i in 6:
		o.append('      <ui:Label class="footer-label" text="Status %d" />' % i)
	o.append('    </ui:VisualElement>')
	o.append('  </ui:VisualElement>')
	o.append('</ui:UXML>')
	return "\n".join(o)


func _base_uss() -> String:
	return """
@import "components.uss";
@import "theme.uss";

:root {
	--accent: #3a7bd5;
	--accent-hover: rgb(90, 150, 240);
	--text: rgb(220, 220, 220);
	--muted: rgba(200, 200, 200, 0.6);
	--bg: #202020;
	--panel: #2a2a2a;
	--pad: 4px 8px;
	--radius: 4px;
	--gap: 6px;
	--font: 13px;
}

Label { color: var(--text); font-size: var(--font); }
Button { color: var(--text); background-color: #3c3c3c; border-radius: var(--radius); padding: 2px 6px; }
Toggle { color: var(--muted); }
.screen { flex-grow: 1; background-color: var(--bg); }
.row { flex-direction: row; }
.col { flex-direction: column; }
.wrap { flex-wrap: wrap; }
"""


func _components_uss() -> String:
	return """
.header { height: 40px; padding: var(--pad); align-items: center; background-color: var(--panel); }
.header > .title { font-size: 20px; }
.spacer { flex-grow: 1; }
.nav { margin-left: 4px; width: 70px; }
.body { flex-grow: 1; }
.sidebar { width: 220px; padding: 4px; border-right-width: 1px; border-color: #444; }
.list { flex-grow: 1; }
.list-item { height: 28px; padding: 2px 4px; align-items: center; border-radius: var(--radius); }
.list-item--odd { background-color: rgba(255, 255, 255, 0.03); }
.list-item:hover { background-color: #333; }
.list-item:focus { background-color: var(--accent); }
.list-item:focus .list-label { color: white; }
.sidebar .list .list-item .list-label { flex-grow: 1; margin-left: 4px; }
.icon { width: 16px; height: 16px; background-color: var(--accent); border-radius: 8px; }
.content { flex-grow: 1; flex-shrink: 1; padding: 6px; }
.grid { justify-content: flex-start; align-content: flex-start; }
.card {
	width: 200px; margin: 4px; padding: var(--pad);
	background-color: var(--panel);
	border-width: 1px; border-color: #444; border-radius: var(--radius);
}
.card:hover { background-color: #333; border-color: var(--accent); }
.card:hover .card-title { color: var(--accent-hover); }
.card--alt { background-color: #2e2a33; }
.card--selected { border-color: yellow; border-width: 2px; }
.card--selected .card-title { color: yellow; }
.card > .card-header { justify-content: space-between; align-items: center; }
.card .title { font-size: 15px; }
.badge { font-size: 10px; color: var(--accent); padding: 0 4px; border-width: 1px; border-color: var(--accent); border-radius: 6px; }
.card-body { white-space: normal; margin-top: 4px; margin-bottom: 4px; }
.content .grid .card .card-body { color: var(--muted); }
.card-actions { justify-content: flex-end; }
.card-actions > .btn { flex-grow: 1; margin: 2px; height: 24px; }
.btn:hover { background-color: #555; }
.btn:active { background-color: #222; }
.btn:focus { border-width: 1px; border-color: var(--accent); }
Button.btn-primary { background-color: var(--accent); color: white; }
Button.btn-primary:hover { background-color: var(--accent-hover); }
.card-slider { margin-top: 4px; }
.card-field { margin-top: 4px; }
.footer { height: 24px; padding: 2px 8px; background-color: var(--panel); }
.footer Label { font-size: 11px; color: var(--muted); margin-right: 12px; }
#title { -unity-font-style: bold; }
"""


func _theme_uss() -> String:
	var o := PackedStringArray()
	o.append(".screen Label.title { -unity-text-align: middle-left; }")
	o.append(".body .content > .grid { padding: 2px; }")
	# A big theme: many rules for classes this document never uses, the way
	# a shared design system ships far more selectors than one screen needs.
	for i in 80:
		o.append(".theme-%d .widget-%d > .part-%d { color: #%02x%02x%02x; margin: %dpx; }" % [i, i, i, (i * 3) % 256, (i * 7) % 256, (i * 11) % 256, i % 6])
		o.append(".skin-%d:hover { background-color: var(--accent); }" % i)
	return "\n".join(o)


func _hud_uxml() -> String:
	var o := PackedStringArray()
	o.append('<ui:UXML xmlns:ui="UnityEngine.UIElements">')
	o.append('  <Style src="hud.uss" />')
	o.append('  <ui:VisualElement name="hud" class="hud">')
	o.append('    <ui:VisualElement class="stats">')
	for i in 8:
		o.append('      <ui:VisualElement class="stat">')
		o.append('        <ui:Label class="key" text="Stat %d" />' % i)
		o.append('        <ui:Label name="val-%d" class="val" text="0" />' % i)
		o.append('      </ui:VisualElement>')
	o.append('    </ui:VisualElement>')
	o.append('    <ui:VisualElement class="bars">')
	for i in 4:
		o.append('      <ui:VisualElement name="bar-%d" class="bar"><ui:VisualElement class="fill" style="width: %d%%;" /></ui:VisualElement>' % [i, 20 + i * 20])
	o.append('    </ui:VisualElement>')
	o.append('  </ui:VisualElement>')
	o.append('</ui:UXML>')
	return "\n".join(o)


func _hud_uss() -> String:
	return """
:root { --fg: rgb(240, 240, 240); --hud-pad: 6px; }
.hud { flex-grow: 1; padding: var(--hud-pad); justify-content: space-between; }
.stats { flex-direction: row; flex-wrap: wrap; }
.stat { flex-direction: row; width: 150px; margin: 2px; padding: 2px 4px; background-color: rgba(0, 0, 0, 0.5); border-radius: 3px; }
.key { color: rgba(255, 255, 255, 0.6); font-size: 12px; flex-grow: 1; }
.val { color: var(--fg); font-size: 12px; -unity-text-align: middle-right; }
.bars { flex-direction: column; width: 200px; }
.bar { height: 10px; margin: 2px; background-color: #333; border-radius: 2px; }
.bar:hover { background-color: #555; }
.fill { height: 100%; background-color: #4caf50; border-radius: 2px; }
"""
