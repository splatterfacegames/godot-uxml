extends SceneTree
## Rendered check of USS filters (needs a display, not --headless): draws
## the Unity probe cells through UxmlDocument and compares pixels with the
## colors Unity 6000.3.24f1 rendered for the same USS (gamma, 8-bit).
##
##   Godot --path <project> -s res://bench/render_filters.gd
##
## Prints one line per cell and RENDER_FILTERS OK | FAIL.

const CELLS := [
	# [filter, opaque cell, half-alpha cell, cell with a transparent gap]
	["invert(100%)", [55, 155, 205, 255], [128, 128, 128, 128]],
	["contrast(50%)", [164, 114, 89, 255], [114, 89, 76, 128]],
	["contrast(200%)", [255, 72, 0, 255], [72, 0, 0, 128]],
	["grayscale(100%)", [118, 118, 118, 255], [59, 59, 59, 128]],
	["sepia(1)", [165, 147, 114, 255], [82, 73, 57, 128]],
	["hue-rotate(90deg)", [50, 146, 35, 255], [25, 73, 18, 128]],
	["tint(#00ff99)", [0, 100, 30, 255], [0, 50, 15, 128]],
	["opacity(0.5)", [100, 50, 25, 127], [50, 25, 12, 64]],
	["grayscale(100%) invert(100%)", [137, 137, 137, 255], [128, 128, 128, 128]],
	["invert(100%) opacity(50%)", [27, 77, 102, 127], [64, 64, 64, 64]],
	["none", [200, 100, 50, 255], [100, 50, 25, 128]],
]
## Unity blur(3px) on a 10x10 white square, alpha along its middle row.
const BLUR_ROW := [0, 0, 0, 0, 0, 0, 0, 1, 4, 7, 15, 28, 46, 70, 100, 130, 159, 182, 199, 207, 207,
	199, 182, 159, 130, 100, 70, 46, 28, 15, 7, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0]


func _initialize() -> void:
	var body := ""
	var uss := ".cell { position: absolute; width: 40px; height: 40px; }\n"
	uss += ".fill { background-color: rgb(200, 100, 50); }\n.half { background-color: rgba(200, 100, 50, 0.5); }\n"
	uss += ".blurbox { position: absolute; left: 30px; top: 330px; width: 10px; height: 10px; background-color: white; filter: blur(3px); }\n"
	for i in CELLS.size():
		uss += ".f%d { filter: %s; }\n" % [i, CELLS[i][0]]
		body += '<ui:VisualElement class="cell fill f%d" style="left: %dpx; top: 10px;" />' % [i, 10 + i * 55]
		body += '<ui:VisualElement class="cell half f%d" style="left: %dpx; top: 60px;" />' % [i, 10 + i * 55]
		body += '<ui:VisualElement class="cell f%d" style="left: %dpx; top: 110px;"><ui:VisualElement class="cell fill" style="left: 10px; top: 10px; width: 20px; height: 20px;" /></ui:VisualElement>' % [i, 10 + i * 55]
	body += '<ui:VisualElement class="blurbox" />'
	DirAccess.make_dir_recursive_absolute("user://render_filters")
	var f := FileAccess.open("user://render_filters/f.uss", FileAccess.WRITE)
	f.store_string(uss)
	f.close()
	f = FileAccess.open("user://render_filters/f.uxml", FileAccess.WRITE)
	f.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="f.uss" />%s</ui:UXML>' % body)
	f.close()
	root.size = Vector2i(700, 400)
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
	root.transparent_bg = true
	var doc := UxmlDocument.new()
	root.add_child(doc)
	doc.size = Vector2(700, 400)
	doc.load_document("user://render_filters/f.uxml", "user://")
	for k in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.save_png("user://render_filters/out.png")
	var ok := true
	for i in CELLS.size():
		var x := 10 + i * 55 + 20
		var got := [_px(img, x, 30), _px(img, x, 80), _px(img, x, 130), _px(img, 10 + i * 55 + 3, 113)]
		var want := [CELLS[i][1], CELLS[i][2], CELLS[i][1], [0, 0, 0, 0]]
		var good := true
		for j in 4:
			if not _near(got[j], want[j], 3):
				good = false
		ok = ok and good
		print("%s %-30s got %s want %s" % ["ok  " if good else "FAIL", CELLS[i][0], got, want])
	var worst := 0
	var row := []
	for x in range(15, 56):
		row.append(_px(img, x, 335)[3])
		worst = maxi(worst, absi(_px(img, x, 335)[3] - BLUR_ROW[x - 15]))
	print("blur row: ", row)
	for c in doc._applier._filters:
		var fm = (doc._applier._filters[c] as UxmlFilter).get_material()
		if fm is ShaderMaterial and float(fm.get_shader_parameter("sigma")) > 0.0:
			print("blur sigma %s scale %s final %s" % [fm.get_shader_parameter("sigma"), UxmlStyleApplier._pixel_scale(c), root.get_final_transform()])
	print("%s blur(3px) row: worst alpha difference %d" % ["ok  " if worst <= 3 else "FAIL", worst])
	ok = ok and worst <= 3
	print("RENDER_FILTERS %s (image: %s)" % ["OK" if ok else "FAIL", ProjectSettings.globalize_path("user://render_filters/out.png")])
	quit(0 if ok else 1)


## The target as stored (blending onto a transparent target stores
## premultiplied color, as in the Unity probe).
func _px(img: Image, x: int, y: int) -> Array:
	var c := img.get_pixel(x, y)
	return [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0), roundi(c.a * 255.0)]


func _near(a: Array, b: Array, tol: int) -> bool:
	for k in 4:
		if absi(int(a[k]) - int(b[k])) > tol:
			return false
	return true
