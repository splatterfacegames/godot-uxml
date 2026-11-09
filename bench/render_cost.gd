extends SceneTree
## Per-frame cost with a real renderer (run WITHOUT --headless):
##
##   Godot --path <project> -s res://bench/render_cost.gd
##
## Vsync off, no fps cap; reports the engine's own measured viewport render
## time (CPU and GPU) and the process time per frame for an empty scene,
## the godot-uxml stress document, and the same screen hand-built from
## native containers (bench/native_compare.gd's builder). Headless frame
## times are dominated by frame pacing and cannot show this.

const NativeCompare := preload("res://bench/native_compare.gd")


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	root.size = Vector2i(1280, 800)
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for k in 30:
		await process_frame
	var rows: Array = []
	rows.append(["empty scene"] + await _measure(vp))

	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = Vector2(1280, 800)
	d.load_document("Assets/UI/big.uxml", UxmlBenchDir.of("godot_uxml_bench"))
	for k in 30:
		await process_frame
	rows.append(["godot-uxml big doc (%d controls)" % d._controls.size()] + await _measure(vp))
	root.remove_child(d)
	d.free()

	var nc = NativeCompare.new()
	var host := Control.new()
	host.size = Vector2(1280, 800)
	root.add_child(host)
	host.add_child(nc._build())
	for k in 30:
		await process_frame
	rows.append(["native containers, same screen"] + await _measure(vp))

	print("| scene | frame ms | process ms | render CPU ms | render GPU ms |")
	print("| --- | ---: | ---: | ---: | ---: |")
	for r in rows:
		print("| %s | %.2f | %.2f | %.2f | %.2f |" % r)
	print("RENDER_COST_COMPLETE")
	quit()


func _measure(vp: RID) -> Array:
	var fr := PackedFloat64Array()
	var pr := PackedFloat64Array()
	var cpu := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	for k in 120:
		var t0 := Time.get_ticks_usec()
		await process_frame
		fr.append((Time.get_ticks_usec() - t0) / 1000.0)
		pr.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	return [_med(fr), _med(pr), _med(cpu), _med(gpu)]


func _med(a: PackedFloat64Array) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]
