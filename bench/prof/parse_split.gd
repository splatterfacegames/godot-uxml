extends SceneTree
## The UXML and USS parse of the big benchmark document, split (run
## bench/unity_compare.gd --write-docs first): the UXML parse is mostly the
## construction of the UxmlElement objects.
##   Godot --headless --path . -s res://bench/prof/parse_split.gd
func _initialize() -> void:
	var dir := ProjectSettings.globalize_path(UxmlBenchDir.of("godot_uxml_ucmp") + "/Assets/UI/")
	var ux := FileAccess.get_file_as_string(dir + "big.uxml")
	var sheets := []
	for f in ["base.uss", "theme.uss", "components.uss"]: sheets.append(FileAccess.get_file_as_string(dir + f))
	for rep in 3:
		var t0 := Time.get_ticks_usec()
		var p := UxmlParser.new().parse(ux, "res://big.uxml")
		var t1 := Time.get_ticks_usec()
		var items := []
		for s in sheets: items.append(UssParser.new().parse(s, "res://x.uss"))
		var t2 := Time.get_ticks_usec()
		for it in items: it["items"].duplicate(true)
		var t3 := Time.get_ticks_usec()
		var th := FileAccess.get_file_as_string("res://addons/godot_uxml/themes/unity-default.uss")
		UssParser.new().parse(th, "res://t.uss")
		var t4 := Time.get_ticks_usec()
		print("uxml %.1f uss %.1f uss-dup %.1f theme-uss %.1f ms" % [(t1-t0)/1000.0, (t2-t1)/1000.0, (t3-t2)/1000.0, (t4-t3)/1000.0])
	quit(0)
