extends SceneTree
func _initialize() -> void:
	var n := 1531
	for rep in 3:
		var t0 := Time.get_ticks_usec()
		var a := []
		for i in n:
			var e := UxmlElement.new()
			e.id = i
			e.local = "VisualElement"
			a.append(e)
		var t1 := Time.get_ticks_usec()
		for e in a:
			e.attributes.append({"name": "class", "value": "x y", "offset": 3})
			e.attributes.append({"name": "name", "value": "x y", "offset": 3})
		var t2 := Time.get_ticks_usec()
		var b := []
		for i in n:
			b.append(RefCounted.new())
		var t3 := Time.get_ticks_usec()
		print("objects %.2f ms, 2 attr dicts each %.2f ms, bare RefCounted %.2f" % [(t1-t0)/1000.0, (t2-t1)/1000.0, (t3-t2)/1000.0])
	quit(0)
