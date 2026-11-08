extends SceneTree
func _t(label: String, make: Callable) -> void:
	var rootc := Control.new()
	var t0 := Time.get_ticks_usec()
	var parent := rootc
	for i in 2000:
		var c: Control = make.call()
		parent.add_child(c)
		if i % 5 == 0: parent = c
	var t1 := Time.get_ticks_usec()
	print("%-22s %.2f us/add" % [label, (t1 - t0) / 2000.0])
	rootc.free()
func _initialize() -> void:
	await process_frame
	_t("Control", func(): return Control.new())
	_t("UxmlBox", func(): return UxmlBox.new())
	_t("Label", func(): return Label.new())
	_t("Button", func(): return Button.new())
	_t("UxmlBox (create only)", func(): return UxmlBox.new())
	var t0 := Time.get_ticks_usec()
	var arr := []
	for i in 2000: arr.append(UxmlBox.new())
	print("UxmlBox.new only %.2f us" % ((Time.get_ticks_usec() - t0) / 2000.0))
	for a in arr: a.free()
	quit(0)
