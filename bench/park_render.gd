extends SceneTree
## Pixels of documents with hidden subtrees, parked against not parked
## (UxmlDocument.park_hidden), with a real renderer (run WITHOUT
## --headless):
##
##   Godot --path <project> -s res://bench/park_render.gd
##
## Loads each document twice (parked / every control in the tree), steps
## both through the same sequence of shows and hides (tabs, pages, a
## Foldout, hidden first/last children), captures the viewport after each
## step and compares the images pixel for pixel. Prints one line per step
## and PARK_RENDER: <n>/<n> identical.

const SIZE := Vector2i(800, 600)

var _same := 0
var _total := 0


func _initialize() -> void:
	DisplayServer.window_set_size(SIZE)
	root.size = SIZE
	for k in 5:
		await process_frame
	await _case("parking fixture", "Assets/UI/parking.uxml", "res://tests/fixtures/parking", [
		func(d): pass,
		func(d): _page(d, 1),
		func(d): _page(d, 2),
		func(d): _page(d, 0),
		func(d): _fold(d),
		func(d): _show_all_hidden(d),
		func(d): _page(d, 1),
		func(d): d.get_element("deep-button"),
		func(d): _page(d, 2),
	])
	await _case("settings workload", "Assets/UI/wl_settings.uxml", "user://godot_uxml_bench", [
		func(d): pass,
		func(d): _settings_tab(d, 1),
		func(d): _settings_tab(d, 3),
		func(d): _settings_tab(d, 2),
		func(d): _settings_tab(d, 0),
	])
	print("PARK_RENDER: %d/%d identical" % [_same, _total])
	quit()


func _load(path: String, root_dir: String, park: bool) -> UxmlDocument:
	UxmlDocument.park_hidden = park
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = Vector2(SIZE)
	d.load_document(path, root_dir)
	UxmlDocument.park_hidden = true
	return d


func _capture() -> Image:
	for k in 3:
		await process_frame
	return root.get_texture().get_image()


func _case(label: String, path: String, root_dir: String, steps: Array) -> void:
	if not FileAccess.file_exists(root_dir.path_join(path)):
		print("%s: %s missing (run bench/workloads.gd once)" % [label, path])
		return
	var shots := {}
	for park in [true, false]:
		var d := _load(path, root_dir, park)
		var imgs: Array = []
		for s in steps:
			(s as Callable).call(d)
			d._restyle_now()
			imgs.append(await _capture())
		shots[park] = imgs
		root.remove_child(d)
		d.free()
	for k in steps.size():
		var a: Image = shots[true][k]
		var b: Image = shots[false][k]
		var same := a.get_data() == b.get_data()
		_total += 1
		if same:
			_same += 1
		# The hash shows the steps really draw different screens.
		print("%s step %d: %s (image %s)" % [label, k, "identical" if same else "DIFFERENT",
			String.num_int64(hash(a.get_data()), 16)])


func _page(d: UxmlDocument, p: int) -> void:
	for t in 3:
		d.set_class("page-%d" % t, "page" + ("" if t == p else " hidden"))


func _fold(d: UxmlDocument) -> void:
	var t: UxmlToggle = d._controls[UxmlParts.find_part(d.get_element_model("opts"), "toggle")]
	t._activate()


func _show_all_hidden(d: UxmlDocument) -> void:
	d.get_element_model("hidden-first").set_attribute("class", "")
	d.get_element_model("hidden-last").set_attribute("class", "")
	d.get_element_model("inline-hidden").set_attribute("style", "")


func _settings_tab(d: UxmlDocument, i: int) -> void:
	for t in 4:
		d.set_class("page-%d" % t, "page" + ("" if t == i else " hidden"))
		d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i else ""))
