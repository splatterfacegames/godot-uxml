class_name UxmlBoxStyle
extends StyleBox
## A USS box as Unity 6000.3 draws it (measured with bench/pixels.py,
## case px-border): the background fills the whole border box, under the
## border; each side has its own colour, and two sides meet on the line
## from the outer corner to the inner corner (a hard edge); a corner is an
## ellipse whose radii are the USS radius clamped to half the width and
## half the height (a radius over half the shorter side gives an elliptic
## corner, not CSS's scaled circle); the inner corner has the radii less
## the adjacent border widths. Curved edges are antialiased over one pixel
## across the edge (Unity's arc coverage, clamp(0.5 - distance)); straight
## edges on the pixel grid stay hard.
##
## The applier uses this StyleBox for a box with a radius, with sides of
## different colours or with a translucent border over a background;
## other boxes keep StyleBoxFlat, which draws them the same. An optional
## `image` StyleBox (a background image) draws between the background
## colour and the border, as Unity draws it.

var bg_color := Color(0, 0, 0, 0)
## Border widths: top, right, bottom, left (px, on the pixel grid).
var widths := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
## Border colours: top, right, bottom, left.
var colors: Array[Color] = [Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0)]
## Corner radii: top-left, top-right, bottom-right, bottom-left (px).
var radii := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
## Drawn over the background colour and under the border.
var image: StyleBox = null
## Fill the inside of the border only, in bg_color fading to opaque
## black over the antialiased edge, and draw no border: the mask of a
## rounded overflow clip (UxmlClip).
var fill_inner := false

var _key := Rect2()
var _img_points := PackedVector2Array()
var _img_cols := PackedColorArray()
var _img_uvs := PackedVector2Array()
var _img_idx := PackedInt32Array()
var _grow := 1.0
var _points := PackedVector2Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()

const _EPS := 0.001
## Sides of the segments of each corner, before and after its split:
## [first side, second side] in top/right/bottom/left order.
const _CORNER_SIDES := [[3, 0], [0, 1], [1, 2], [2, 3]]
const _NUDGE := [Vector2(-0.007, 0.007), Vector2(-0.007, -0.007), Vector2(-0.007, 0.007), Vector2(-0.007, -0.007)]


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	if rect != _key or _points.is_empty() and _idx.is_empty():
		_build(rect)
		_key = rect
	if image != null:
		# The image between the background colour and the border.
		if bg_color.a > 0.0:
			_draw_part(to_canvas_item, 0)
		if not _img_idx.is_empty():
			# A stretched image in a rounded box: clipped to the box's
			# outline, as Unity clips it.
			var tex: Texture2D = (image as StyleBoxTexture).texture
			RenderingServer.canvas_item_add_triangle_array(to_canvas_item, _img_idx, _img_points,
				_img_cols, _img_uvs, PackedInt32Array(), PackedFloat32Array(), tex.get_rid())
		else:
			image.draw(to_canvas_item, rect)
		_draw_part(to_canvas_item, 1)
	elif not _idx.is_empty():
		RenderingServer.canvas_item_add_triangle_array(to_canvas_item, _idx, _points, _cols)


## Background (0) or border (1) only: the triangles from _bg_end on are
## the border's.
var _bg_end := 0


func _draw_part(ci: RID, part: int) -> void:
	var from := 0 if part == 0 else _bg_end
	var to := _bg_end if part == 0 else _idx.size()
	if to <= from:
		return
	var idx := _idx.slice(from, to)
	RenderingServer.canvas_item_add_triangle_array(ci, idx, _points, _cols)


## One sample of the box outline: the outer point, its outward normal, the
## inner point and its normal, and the side of the segment that starts at
## the sample.
func _build(rect: Rect2) -> void:
	_points = PackedVector2Array()
	_cols = PackedColorArray()
	_idx = PackedInt32Array()
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.end.x
	var y1 := rect.end.y
	var w := rect.size.x
	var h := rect.size.y
	var bt := widths[0]
	var br := widths[1]
	var bb := widths[2]
	var bl := widths[3]
	# Unity clamps each radius to half the width and half the height.
	var rx := PackedFloat32Array()
	var ry := PackedFloat32Array()
	for k in 4:
		rx.append(minf(maxf(radii[k], 0.0), w * 0.5))
		ry.append(minf(maxf(radii[k], 0.0), h * 0.5))
	# Per corner: outer centre, the widths beside it (x, y), angle range.
	var corner_x := [x0 + rx[0], x1 - rx[1], x1 - rx[2], x0 + rx[3]]
	var corner_y := [y0 + ry[0], y0 + ry[1], y1 - ry[2], y1 - ry[3]]
	var bw_x := [bl, br, br, bl]
	var bw_y := [bt, bt, bb, bb]
	var sx := [-1.0, 1.0, 1.0, -1.0]
	var sy := [-1.0, -1.0, 1.0, 1.0]
	var a0s := [PI, PI * 1.5, 0.0, PI * 0.5]
	var samples: Array = []  # [outer, n_outer, inner, n_inner, side]
	for k in 4:
		var cx: float = corner_x[k]
		var cy: float = corner_y[k]
		var orx := rx[k]
		var ory := ry[k]
		var irx := maxf(0.0, orx - bw_x[k])
		var iry := maxf(0.0, ory - bw_y[k])
		# The inner centre: the inner box corner (the box corner less the
		# widths) moved in by the inner radii.
		var icx: float = cx + sx[k] * (orx - bw_x[k] - irx)
		var icy: float = cy + sy[k] * (ory - bw_y[k] - iry)
		# Where the two sides meet: the line from the box corner to the
		# point (max(width, radius)) in along each axis (measured: the
		# border-width diagonal at a square corner, 45 degrees at a round
		# corner with thinner borders), on the outer and the inner arc.
		var first: int = _CORNER_SIDES[k][0]
		var second: int = _CORNER_SIDES[k][1]
		var a0: float = a0s[k]
		var corner := Vector2(cx + sx[k] * orx, cy + sy[k] * ory)
		var dir := Vector2(sx[k] * -maxf(bw_x[k], orx), sy[k] * -maxf(bw_y[k], ory))
		var sharp := orx < _EPS or ory < _EPS
		var isharp := irx < _EPS or iry < _EPS
		# The split as a fraction of the quarter turn, for a square corner:
		# the direction of the line (corners 0 and 2 run from their x-side
		# to their y-side, corners 1 and 3 the other way).
		var f_line := 0.5
		if absf(dir.x) + absf(dir.y) > _EPS:
			var t := atan2(absf(dir.x), absf(dir.y)) / (PI * 0.5)  # 1: all x-side
			f_line = t if (k == 0 or k == 2) else 1.0 - t
		var f_o := f_line if sharp else _arc_split(corner, dir, Vector2(cx, cy), orx, ory, a0, f_line)
		var f_i := f_line if isharp else _arc_split(corner, dir, Vector2(icx, icy), irx, iry, a0, f_line)
		var n := 1
		if not (sharp and isharp):
			# Segments short enough that the chord is within 0.05px of the
			# arc.
			var r := maxf(maxf(orx, ory), 1.0)
			var step := 2.0 * acos(clampf(1.0 - 0.05 / r, -1.0, 1.0))
			n = clampi(int(ceil((PI * 0.5) / maxf(step, 0.01))), 2, 64)
		# The vertices sit slightly outside the arc, so the chords cross it
		# and the polygon's area matches the arc's (the coverage of the
		# edge pixels).
		_grow = 2.0 / (1.0 + cos(PI * 0.25 / float(n)))
		# Outer fraction u -> inner fraction: piecewise linear through the
		# split, so the segment between the two split points is the line.
		var placed := false
		for i in n + 1:
			var u := float(i) / float(n)
			if not placed and u >= f_o - _EPS:
				# A pixel centre on the line goes to the y-side at the left
				# corners and to the x-side at the right ones (measured): the
				# line moves a hundredth of a pixel off it.
				var sa := _sample(cx, cy, orx, ory, icx, icy, irx, iry, a0 + PI * 0.5 * f_o,
					a0 + PI * 0.5 * f_i, sharp, isharp, k, first)
				var nudge: Vector2 = _NUDGE[k]
				sa[0] += nudge
				sa[2] += nudge
				# The feather of the split samples runs along the line, so
				# the two sides still meet on it.
				if not sharp:
					sa[1] = -dir.normalized()
				if not isharp:
					sa[3] = -dir.normalized()
				var sb := sa.duplicate()
				sb[4] = second
				samples.append(sa)
				samples.append(sb)
				placed = true
				if absf(u - f_o) <= _EPS:
					continue
			var ui := 0.0
			if u <= f_o:
				ui = 0.0 if f_o < _EPS else u / f_o * f_i
			else:
				ui = f_i + (u - f_o) / maxf(1.0 - f_o, _EPS) * (1.0 - f_i)
			samples.append(_sample(cx, cy, orx, ory, icx, icy, irx, iry, a0 + PI * 0.5 * u,
				a0 + PI * 0.5 * ui, sharp, isharp, k, second if placed else first))
	var count := samples.size()
	# Background: a fan over the outline inset by half a pixel, and a
	# feather out to half a pixel outside.
	# The background fills the box. Under a side with an opaque border its
	# edge is half a pixel inside the outer edge; elsewhere (no border, or a
	# translucent one) on the outer edge (measured: the first pixel under
	# an opaque border is half background, a translucent border shows the
	# background out to its antialiased outer pixels). The edge is
	# antialiased over a pixel; a square corner has none on the grid.
	if fill_inner:
		# A mask: the coverage in the colour channels, alpha 1 (UxmlClip).
		var centre := Vector2(x0 + w * 0.5, y0 + h * 0.5)
		var transparent := Color(0.0, 0.0, 0.0, 1.0)
		for i in count:
			var s: Array = samples[i]
			var t: Array = samples[(i + 1) % count]
			var p0: Vector2 = s[2] - s[3] * 0.5
			var p1: Vector2 = t[2] - t[3] * 0.5
			if p0.distance_squared_to(p1) > 1e-8:
				_tri(centre, p0, p1, bg_color, bg_color, bg_color)
			if s[3] != Vector2.ZERO or t[3] != Vector2.ZERO:
				_quad(p0, p1, t[2] + t[3] * 0.5, s[2] + s[3] * 0.5,
					bg_color, bg_color, transparent, transparent)
		_bg_end = _idx.size()
		return
	if bg_color.a > 0.0:
		var centre := Vector2(x0 + w * 0.5, y0 + h * 0.5)
		var transparent := Color(bg_color, 0.0)
		for i in count:
			var s: Array = samples[i]
			var t: Array = samples[(i + 1) % count]
			var side: int = s[4]
			var under := widths[side] > 0.0 and colors[side].a >= 1.0
			var shift := 0.5 if under else 0.0
			var n0: Vector2 = s[1] if s[1] != Vector2.ZERO else (s[5] if under else Vector2.ZERO)
			var n1: Vector2 = t[1] if t[1] != Vector2.ZERO else (t[5] if under else Vector2.ZERO)
			var p0: Vector2 = s[0] - n0 * (0.5 + shift)
			var p1: Vector2 = t[0] - n1 * (0.5 + shift)
			if p0.distance_squared_to(p1) > 1e-8:
				_tri(centre, p0, p1, bg_color, bg_color, bg_color)
			if n0 != Vector2.ZERO or n1 != Vector2.ZERO:
				_quad(p0, p1, t[0] + n1 * (0.5 - shift), s[0] + n0 * (0.5 - shift),
					bg_color, bg_color, transparent, transparent)
	_bg_end = _idx.size()
	_img_points = PackedVector2Array()
	_img_cols = PackedColorArray()
	_img_uvs = PackedVector2Array()
	_img_idx = PackedInt32Array()
	var st := image as StyleBoxTexture
	if st != null and st.texture != null and (radii[0] > 0.0 or radii[1] > 0.0 or radii[2] > 0.0 or radii[3] > 0.0) 			and st.texture_margin_left == 0.0 and st.texture_margin_top == 0.0 			and st.texture_margin_right == 0.0 and st.texture_margin_bottom == 0.0:
		_build_image(samples, rect, st.modulate_color)
	# Border: per segment, in the colour of its side: the strip between the
	# outer and the inner outline, feathered on both edges.
	for i in count:
		var s: Array = samples[i]
		var t: Array = samples[(i + 1) % count]
		var side: int = s[4]
		var c: Color = colors[side]
		if c.a <= 0.0:
			continue
		var ends: Array = [_edges(s), _edges(t)]
		var e0: Array = ends[0]
		var e1: Array = ends[1]
		var c0 := Color(c, c.a * float(e0[4]))
		var c1 := Color(c, c.a * float(e1[4]))
		var z0 := Color(c, 0.0)
		# outer feather, body, inner feather
		_quad(e0[0], e1[0], e1[1], e0[1], z0, z0, c1, c0)
		_quad(e0[1], e1[1], e1[2], e0[2], c0, c1, c1, c0)
		_quad(e0[2], e1[2], e1[3], e0[3], c0, c1, z0, z0)


## The image of a rounded box: the outline's fan and its feather, with the
## texture stretched over the box.
func _build_image(samples: Array, rect: Rect2, tint: Color) -> void:
	var count := samples.size()
	var centre := rect.get_center()
	var clear := Color(tint, 0.0)
	var add := func(p: Vector2, c: Color) -> int:
		_img_points.append(p)
		_img_cols.append(c)
		_img_uvs.append(((p - rect.position) / rect.size).clamp(Vector2.ZERO, Vector2.ONE))
		return _img_points.size() - 1
	var ci: int = add.call(centre, tint)
	for i in count:
		var s: Array = samples[i]
		var t: Array = samples[(i + 1) % count]
		var a: int = add.call(s[0] - s[1] * 0.5, tint)
		var b: int = add.call(t[0] - t[1] * 0.5, tint)
		var c: int = add.call(t[0] + t[1] * 0.5, clear)
		var d: int = add.call(s[0] + s[1] * 0.5, clear)
		_img_idx.append_array([ci, a, b, a, b, c, a, c, d])


## The border's thickness at a sample.
static func _thick(s: Array) -> float:
	var n: Vector2 = s[1]
	var d: Vector2 = s[0] - s[2]
	return d.dot(n) if n != Vector2.ZERO else d.length()


## `inner` moved `by` px along `n`, at most to `outer`.
static func _toward(inner: Vector2, n: Vector2, outer: Vector2, by: float) -> Vector2:
	if n == Vector2.ZERO:
		# A square inner corner: each axis on its own, toward the outer one.
		var d := outer - inner
		return Vector2(inner.x + signf(d.x) * minf(by, absf(d.x)),
			inner.y + signf(d.y) * minf(by, absf(d.y)))
	var room := (outer - inner).dot(n)
	return inner + n * minf(by, maxf(room, 0.0))


## The four points of the border strip at a sample, from outside in, and
## the strip's coverage there: [outer + n/2, outer - n/2, inner + n/2,
## inner - n/2, coverage]. A strip thinner than a pixel collapses to its
## middle and draws with its thickness as coverage.
func _edges(s: Array) -> Array:
	var o: Vector2 = s[0]
	var no: Vector2 = s[1]
	var i: Vector2 = s[2]
	var ni: Vector2 = s[3]
	var d := (o - i).dot(no) if no != Vector2.ZERO else (o - i).length()
	if d < 1.0:
		var m := (o + i) * 0.5
		var cov := clampf(d, 0.0, 1.0)
		return [m + no * 0.5, m, m, m - ni * 0.5, cov]
	return [o + no * 0.5, o - no * 0.5, i + ni * 0.5, i - ni * 0.5, 1.0]


func _sample(cx: float, cy: float, orx: float, ory: float, icx: float, icy: float,
		irx: float, iry: float, a: float, ai: float, sharp: bool, isharp: bool, k: int, side: int) -> Array:
	var o := Vector2(cx + orx * _grow * cos(a), cy + ory * _grow * sin(a))
	# A square corner has no normal: its edges are not feathered (Unity
	# draws straight edges hard; the box is on the pixel grid).
	var no := Vector2.ZERO if sharp else Vector2(cos(a) / orx, sin(a) / ory).normalized()
	var inner := Vector2(icx + irx * _grow * cos(ai), icy + iry * _grow * sin(ai))
	var ni := Vector2.ZERO if isharp else Vector2(cos(ai) / irx, sin(ai) / iry).normalized()
	return [o, no, inner, ni, side, Vector2([-1.0, 1.0, 1.0, -1.0][k], [-1.0, -1.0, 1.0, 1.0][k])]


## Where the line from `corner` along `dir` meets the ellipse arc of the
## corner (centre c, radii rx ry, from angle a0 over a quarter turn), as a
## fraction of the quarter turn; `fallback` when it does not meet it.
static func _arc_split(corner: Vector2, dir: Vector2, c: Vector2, rx: float, ry: float,
		a0: float, fallback: float) -> float:
	# In the ellipse's unit-circle space: |q0 + u * qd| = 1.
	var q0 := Vector2((corner.x - c.x) / rx, (corner.y - c.y) / ry)
	var qd := Vector2(dir.x / rx, dir.y / ry)
	var A := qd.dot(qd)
	var B := 2.0 * q0.dot(qd)
	var C := q0.dot(q0) - 1.0
	var disc := B * B - 4.0 * A * C
	if A < 1e-12 or disc < 0.0:
		return fallback
	var u := (-B - sqrt(disc)) / (2.0 * A)
	if u < 0.0:
		u = (-B + sqrt(disc)) / (2.0 * A)
	var q := q0 + qd * u
	var ang := atan2(q.y, q.x)
	while ang < a0 - 0.01:
		ang += TAU
	while ang > a0 + PI * 0.5 + 0.01:
		ang -= TAU
	return clampf((ang - a0) / (PI * 0.5), 0.0, 1.0)


func _tri(a: Vector2, b: Vector2, c: Vector2, ca: Color, cb: Color, cc: Color) -> void:
	var base := _points.size()
	_points.append(a)
	_points.append(b)
	_points.append(c)
	_cols.append(ca)
	_cols.append(cb)
	_cols.append(cc)
	_idx.append(base)
	_idx.append(base + 1)
	_idx.append(base + 2)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	var base := _points.size()
	_points.append(a)
	_points.append(b)
	_points.append(c)
	_points.append(d)
	_cols.append(ca)
	_cols.append(cb)
	_cols.append(cc)
	_cols.append(cd)
	_idx.append(base)
	_idx.append(base + 1)
	_idx.append(base + 2)
	_idx.append(base)
	_idx.append(base + 2)
	_idx.append(base + 3)
