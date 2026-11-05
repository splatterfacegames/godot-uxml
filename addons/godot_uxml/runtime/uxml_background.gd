class_name UxmlBackgroundStyle
extends StyleBox
## A USS background image with Unity's placement rules: background-size,
## background-position-x/-y, background-repeat (repeat, space, round,
## no-repeat), 9-slicing with -unity-slice-type (sliced | tiled) and
## -unity-slice-scale, and the image tint.
##
## The applier uses this StyleBox only when one of those placement
## properties is present; a plain stretched or 9-sliced image keeps the
## StyleBoxTexture path. Being a StyleBox, it paints the same way on a
## UxmlBox (draw_style_box) and in a themed control's stylebox slots, and
## its content margins inset native text like any other stylebox.
##
## tiles() is a port of Unity 6 MeshGenerator.DoDrawRectangleRepeat
## (UIRMeshGenerator.cs) at one pixel per point.

var texture: Texture2D = null
var tint := Color.WHITE
## 9-slice margins in source pixels: left, top, right, bottom.
var slices := PackedInt32Array([0, 0, 0, 0])
var slice_scale := 1.0
var slice_tiled := false
## [keyword, unit, value]: keyword center|left|right (x) or
## center|top|bottom (y); unit "px" | "percent".
var pos_x: Array = ["center", "px", 0.0]
var pos_y: Array = ["center", "px", 0.0]
## "length" | "cover" | "contain"; axes are [unit, value] with unit
## "auto" | "px" | "percent".
var size_type := "length"
var size_x: Array = ["percent", 100.0]
var size_y: Array = ["percent", 100.0]
var repeat_x := "no-repeat"
var repeat_y := "no-repeat"

const _EPS := 0.001


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if texture == null:
		return
	var tex_size := texture.get_size()
	var sliced := slices[0] != 0 or slices[1] != 0 or slices[2] != 0 or slices[3] != 0
	for t in tiles(tex_size, rect.size):
		var dest: Rect2 = t[0]
		dest.position += rect.position
		if sliced:
			_draw_sliced(to_canvas_item, t[2], rect.position)
		else:
			RenderingServer.canvas_item_add_texture_rect_region(
				to_canvas_item, dest, texture.get_rid(), t[1], tint)


## One 9-sliced tile at its full (uncropped) rect. Slices scale by
## slice_scale through a draw transform; the tile's middle stretches
## (sliced) or repeats (tiled).
func _draw_sliced(ci: RID, tile: Rect2, origin: Vector2) -> void:
	var mode := (RenderingServer.NINE_PATCH_TILE if slice_tiled
		else RenderingServer.NINE_PATCH_STRETCH)
	var s := slice_scale if slice_scale > _EPS else 1.0
	var r := Rect2(tile.position + origin, tile.size)
	if not is_equal_approx(s, 1.0):
		RenderingServer.canvas_item_add_set_transform(
			ci, Transform2D(0.0, Vector2(s, s), 0.0, r.position))
		r = Rect2(Vector2.ZERO, r.size / s)
	RenderingServer.canvas_item_add_nine_patch(
		ci, r, Rect2(Vector2.ZERO, texture.get_size()), texture.get_rid(),
		Vector2(slices[0], slices[1]), Vector2(slices[2], slices[3]),
		mode, mode, true, tint)
	if not is_equal_approx(s, 1.0):
		RenderingServer.canvas_item_add_set_transform(ci, Transform2D.IDENTITY)


## The tiles that cover a `total`-sized box: [dest Rect2 cropped to the
## box, source region in texture pixels, full uncropped tile Rect2].
func tiles(tex_size: Vector2, total: Vector2) -> Array:
	var out: Array = []
	if tex_size.x <= _EPS or tex_size.y <= _EPS:
		return out
	if total.x <= _EPS or total.y <= _EPS:
		return out
	# One repetition's size before position and clipping.
	var target := tex_size
	if size_type == "contain" or size_type == "cover":
		var rx := total.x / target.x
		var ry := total.y / target.y
		var fit_width := rx < ry if size_type == "contain" else rx > ry
		if fit_width:
			target = Vector2(total.x, target.y * total.x / target.x)
		else:
			target = Vector2(target.x * total.y / target.y, total.y)
	else:
		var ux: String = size_x[0]
		var uy: String = size_y[0]
		if ux != "auto" and uy == "auto":
			var w := _axis_len(size_x, total.x)
			target = Vector2(w, w * target.y / target.x)
		elif not (ux == "auto" and uy == "auto"):
			var t := target
			if ux != "auto":
				t.x = _axis_len(size_x, total.x)
			if uy != "auto":
				t.y = _axis_len(size_y, total.y)
				if ux == "auto":
					t.x = t.y * target.x / target.y
			target = t
	if target.x <= _EPS or target.y <= _EPS:
		return out
	# round on one axis with auto size on the other keeps the aspect.
	if size_x[0] == "auto" and repeat_y == "round":
		var count := maxi(1, int(total.y / target.y + 0.5))
		var h := total.y / count
		target = Vector2(h * target.x / target.y, h)
	elif size_y[0] == "auto" and repeat_x == "round":
		var count2 := maxi(1, int(total.x / target.x + 0.5))
		var w2 := total.x / count2
		target = Vector2(w2, w2 * target.y / target.x)

	var axes: Array = [[], []]  # per axis: [start, size] spans
	for axis in 2:
		var repeat := repeat_x if axis == 0 else repeat_y
		var pos: Array = pos_x if axis == 0 else pos_y
		var tot: float = total[axis]
		var sz: float = target[axis]
		var spans: Array = []
		var linear := 0.0
		match repeat:
			"repeat":
				var count := int((tot + 1.0) / sz)
				if pos[0] == "center":
					count += 2 if (count & 1) == 1 else 1
				else:
					count += 2
				for i in count:
					spans.append([i * sz, sz])
					linear += sz
			"space":
				var count := int(tot / sz)
				if count >= 0:
					spans.append([0.0, sz])
					linear = sz
				if count >= 2:
					spans.append([tot - sz, sz])
					linear = tot
				if count > 2:
					var gap := (tot - sz * count) / (count - 1)
					for i in count - 2:
						spans.append([(sz + gap) * (1 + i), sz])
			"round":
				var count := maxi(1, int((tot + sz * 0.5) / sz))
				var new_size := tot / count
				if pos[0] == "center":
					count += 2 if (count & 1) == 1 else 1
				else:
					count += 1
				sz = new_size
				for i in count:
					spans.append([new_size * i, new_size])
					linear += new_size
			_:
				spans.append([0.0, sz])
				linear = sz
		# Position offset.
		var offset := 0.0
		if pos[0] == "center":
			offset = (tot - linear) * 0.5
			offset = _align(offset, sz)
		elif repeat != "space":
			if pos[1] == "percent":
				offset = (tot - sz) * float(pos[2]) / 100.0
				offset = _align(offset, sz)
			else:
				offset = float(pos[2])
			if pos[0] == "right" or pos[0] == "bottom":
				offset = (tot - linear) - offset
		if repeat == "repeat" or repeat == "round":
			if sz > _EPS:
				if offset < -sz:
					offset += int(-offset / sz) * sz
				if offset > 0.0:
					offset -= (1 + int(offset / sz)) * sz
		for sp in spans:
			sp[0] += offset
		axes[axis] = spans

	for ys in axes[1]:
		for xs in axes[0]:
			var full := Rect2(xs[0], ys[0], xs[1], ys[1])
			var crop := full.intersection(Rect2(Vector2.ZERO, total))
			if crop.size.x < _EPS or crop.size.y < _EPS:
				continue
			var src := Rect2(
				(crop.position - full.position) / full.size * tex_size,
				crop.size / full.size * tex_size)
			out.append([crop, src, full])
	return out


static func _axis_len(spec: Array, total: float) -> float:
	return total * float(spec[1]) / 100.0 if spec[0] == "percent" else float(spec[1])


## Unity rounds a centered or percentage offset up to the pixel grid
## (AlignmentUtils.CeilToPixelGrid) when
## the tile size is a whole number of pixels (UUM-36753).
static func _align(offset: float, size: float) -> float:
	if absf(roundf(size) - size) < 0.001:
		return ceilf(offset - 0.02)
	return offset
