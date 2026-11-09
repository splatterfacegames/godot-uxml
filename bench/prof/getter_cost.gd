extends SceneTree
class A:
	var children: Array = []
class B:
	var _children: Array = []
	var _h = null
	var children: Array:
		get:
			if _h != null:
				pass
			return _children
		set(v):
			_children = v
func _walk_a(e, out):
	out.append(e)
	for c in e.children:
		_walk_a(c, out)
func _walk_b(e, out):
	out.append(e)
	for c in e.children:
		_walk_b(c, out)
func _initialize() -> void:
	for rep in 3:
		var ra := A.new(); var rb := B.new()
		var la := [ra]; var lb := [rb]
		for i in 2000:
			var a := A.new(); la[i / 4].children.append(a); la.append(a)
			var b := B.new(); lb[i / 4].children.append(b); lb.append(b)
		var t0 := Time.get_ticks_usec()
		for k in 10: _walk_a(ra, [])
		var t1 := Time.get_ticks_usec()
		for k in 10: _walk_b(rb, [])
		var t2 := Time.get_ticks_usec()
		var o1 := Time.get_ticks_usec()
		var s := 0
		for k in 10:
			for e in la: s += e.children.size()
		var o2 := Time.get_ticks_usec()
		for k in 10:
			for e in lb: s += e.children.size()
		var o3 := Time.get_ticks_usec()
		print("walk x10: plain %.2f ms getter %.2f ms | size reads x10: plain %.2f getter %.2f" % [(t1-t0)/1000.0, (t2-t1)/1000.0, (o2-o1)/1000.0, (o3-o2)/1000.0])
	quit(0)
