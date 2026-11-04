extends SceneTree
## Runnable minimal godot-uxml example.
##
##   Godot --path <project> --script res://examples/minimal/minimal.gd
##
## Windowed, the panel is live: click buttons, Tab through controls,
## navigate and activate with a controller (d-pad + A), drag the slider.
## Headless, it verifies the document loads and exits 0.

func _initialize() -> void:
	var doc := UxmlDocument.new()
	doc.name = "uxml"
	root.add_child(doc)
	doc.set_anchors_preset(Control.PRESET_FULL_RECT)

	# project_root contains every reference the document can reach:
	# <Style src>, url(), images, fonts.
	var err := doc.load_document("ui.uxml", "res://examples/minimal")
	if err != OK:
		printerr("minimal example failed to load:")
		for d in doc.diagnostics:
			printerr("  ", UxmlDiagnostic.format(d))
		quit(1)
		return

	# Document-level convenience signals carry the authored `name`.
	doc.button_pressed.connect(_on_button)
	doc.value_changed.connect(_on_value)

	# Native controls keep their own signals — connect them directly.
	var play := doc.get_element("play") as Button
	play.pressed.connect(func(): print("[native] play.pressed"))

	print("minimal example loaded; %d diagnostics" % doc.diagnostics.size())
	for d in doc.diagnostics:
		print("  ", UxmlDiagnostic.format(d))

	root.close_requested.connect(func(): quit(0))
	if DisplayServer.get_name() == "headless":
		print("headless run: load verified, exiting")
		quit(0)


func _on_button(element_name: String) -> void:
	print("[doc] button_pressed: %s" % element_name)
	if element_name == "quit":
		quit(0)


func _on_value(element_name: String, value: Variant) -> void:
	print("[doc] value_changed: %s = %s" % [element_name, value])
