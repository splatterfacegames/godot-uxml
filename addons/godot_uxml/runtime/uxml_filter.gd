class_name UxmlFilter
extends RefCounted
## USS `filter` (Unity 6.3) on one element: the element and its subtree
## draw into a canvas group, and the group draws through one material.
##
## Godot draws a canvas group in two steps: the items of the group render
## into the back buffer (premultiplied alpha), then the group item draws a
## rectangle with its material, which reads the back buffer as
## `hint_screen_texture`. The group item here is an extra RenderingServer
## canvas item: it takes the place of the host's canvas item under the
## host's parent (same draw index), and the host's canvas item becomes its
## only child. The host's own background and border are therefore inside
## the group, as in Unity. Godot re-parents a canvas item when its node
## enters the tree, so the filter attaches again on `tree_entered`.
##
## Built-in functions use FILTER_SHADER: Unity's ColorEffect pass (a 4x4
## color matrix, a color offset and an invert amount on premultiplied
## color, clamped to 0..1 after each pass as Unity's 8-bit render targets
## do) and Unity's GaussianBlur pass pair (kernel radius ceil(3 sigma + 1),
## weights exp(-0.5 (x / sigma)^2)). A custom function draws with its own
## material (see UxmlFilterDefinition).
##
## Limits: Godot does not nest canvas groups, so the applier disables the
## filter of an element inside another filtered element (diagnosed). All the
## blurs of one chain combine into one blur with sigma = sqrt(sum sigma^2).

const MAX_OPS := 8
## Fetches per axis on each side of the center. A blur with a kernel
## radius up to EXACT_KERNEL pixels pairs neighbor pixels into one bilinear
## fetch (the weights are separable, so the result is the exact kernel);
## a wider blur samples every `kernel / MAX_TAPS` pixels from a back-buffer
## mipmap of about that size.
const MAX_TAPS := 8
const EXACT_KERNEL := 16.0

const FILTER_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform int pre_count = 0;
uniform int op_count = 0;
uniform vec4 op_m[32];
uniform vec4 op_v[8];
uniform float sigma = 0.0;
uniform float kernel = 0.0;
uniform float tap_step = 1.0;
uniform float lod = 0.0;

vec4 color_op(vec4 c, int i) {
	mat4 m = mat4(op_m[i * 4], op_m[i * 4 + 1], op_m[i * 4 + 2], op_m[i * 4 + 3]);
	c = m * c;
	c.rgb += vec3(op_v[i].x);
	c.rgb = mix(c.rgb, vec3(1.0) - c.rgb, op_v[i].y);
	return clamp(c, vec4(0.0), vec4(1.0));
}

// Pair j of one axis: j = 0 is the center pixel; j > 0 merges pixels
// 2j - 1 and 2j (j < 0 mirrors) into one bilinear fetch. Returns the fetch
// offset and the summed weight; a pixel beyond the kernel radius weighs 0.
vec2 pair(int j, float k2) {
	if (j == 0) {
		return vec2(0.0, 1.0);
	}
	float a = float(abs(j));
	float o1 = 2.0 * a - 1.0;
	float o2 = 2.0 * a;
	float w1 = exp(o1 * o1 * k2);
	float w2 = o2 <= kernel ? exp(o2 * o2 * k2) : 0.0;
	float w = w1 + w2;
	return vec2(sign(float(j)) * (o1 * w1 + o2 * w2) / w, w);
}

vec4 pre_ops(vec4 c) {
	for (int i = 0; i < 8; i++) {
		if (i >= pre_count) {
			break;
		}
		c = color_op(c, i);
	}
	return c;
}

void fragment() {
	vec4 c;
	if (sigma <= 0.001) {
		c = pre_ops(textureLod(screen_texture, SCREEN_UV, 0.0));
	} else if (tap_step <= 1.0) {
		// Unity's kernel, exactly: pixels -kernel..kernel on both axes.
		int np = int(ceil(kernel * 0.5 - 0.0001));
		float k2 = -0.5 / (sigma * sigma);
		vec4 acc = vec4(0.0);
		float wsum = 0.0;
		for (int y = -8; y <= 8; y++) {
			if (y < -np || y > np) {
				continue;
			}
			vec2 py = pair(y, k2);
			for (int x = -8; x <= 8; x++) {
				if (x < -np || x > np) {
					continue;
				}
				vec2 px = pair(x, k2);
				float w = px.y * py.y;
				vec2 uv = SCREEN_UV + vec2(px.x, py.x) * SCREEN_PIXEL_SIZE;
				acc += pre_ops(textureLod(screen_texture, uv, 0.0)) * w;
				wsum += w;
			}
		}
		c = acc / wsum;
	} else {
		int n = int(ceil(kernel / tap_step - 0.0001));
		float k2 = -0.5 / (sigma * sigma);
		vec4 acc = vec4(0.0);
		float wsum = 0.0;
		for (int y = -8; y <= 8; y++) {
			if (y < -n || y > n) {
				continue;
			}
			float oy = float(y) * tap_step;
			float wy = exp(oy * oy * k2);
			for (int x = -8; x <= 8; x++) {
				if (x < -n || x > n) {
					continue;
				}
				float ox = float(x) * tap_step;
				float w = exp(ox * ox * k2) * wy;
				vec2 uv = SCREEN_UV + vec2(ox, oy) * SCREEN_PIXEL_SIZE;
				acc += pre_ops(textureLod(screen_texture, uv, lod)) * w;
				wsum += w;
			}
		}
		c = acc / wsum;
	}
	for (int i = 0; i < 8; i++) {
		if (i >= op_count) {
			break;
		}
		if (i >= pre_count) {
			c = color_op(c, i);
		}
	}
	// Unity composites the filter result as straight color: rgb / a,
	// clamped to 1, times a.
	c.rgb = min(c.rgb, vec3(c.a));
	COLOR = c;
}
"""

static var _shader: Shader = null

var host: Control
var item: RID
## False while an ancestor's filter owns the canvas group (nesting).
var enabled := true
var _material: Material = null
var _builtin: ShaderMaterial = null
var _margin := 0.0
var _mipmaps := false
var _attached := false


static func shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = FILTER_SHADER
	return _shader


func _init(p_host: Control) -> void:
	host = p_host
	item = RenderingServer.canvas_item_create()
	_update_group()
	host.tree_entered.connect(_attach)
	_attach()


## Built-in functions. `ops`: [[Projection, offset, invert], ...] in chain
## order; `pre`: how many of them run before the blur; `sigma` the combined
## blur sigma and `margin` the blur margin, both in render-target pixels.
func set_builtin(ops: Array, pre: int, sigma: float, margin: float) -> void:
	if _builtin == null:
		_builtin = ShaderMaterial.new()
		_builtin.shader = shader()
	var m := PackedVector4Array()
	m.resize(MAX_OPS * 4)
	var v := PackedVector4Array()
	v.resize(MAX_OPS)
	for i in mini(ops.size(), MAX_OPS):
		var p: Projection = ops[i][0]
		m[i * 4] = p.x
		m[i * 4 + 1] = p.y
		m[i * 4 + 2] = p.z
		m[i * 4 + 3] = p.w
		v[i] = Vector4(ops[i][1], ops[i][2], 0.0, 0.0)
	_builtin.set_shader_parameter("op_m", m)
	_builtin.set_shader_parameter("op_v", v)
	_builtin.set_shader_parameter("op_count", mini(ops.size(), MAX_OPS))
	_builtin.set_shader_parameter("pre_count", mini(pre, MAX_OPS))
	var kernel := ceilf(3.0 * sigma + 1.0) if sigma > 0.001 else 0.0
	var step := blur_step(kernel)
	_builtin.set_shader_parameter("sigma", sigma)
	_builtin.set_shader_parameter("kernel", kernel)
	_builtin.set_shader_parameter("tap_step", step)
	_builtin.set_shader_parameter("lod", log(step) / log(2.0) if step > 1.0 else 0.0)
	_use(_builtin, margin, step > 1.0)


## A custom function: `mat` draws the group (it reads the back buffer as
## `hint_screen_texture`); `margin` grows the group rect.
func set_custom(mat: Material, margin: float) -> void:
	_use(mat, margin, false)


func _use(mat: Material, margin: float, mipmaps: bool) -> void:
	if mat != _material:
		_material = mat
		RenderingServer.canvas_item_set_material(item, RID() if mat == null else mat.get_rid())
	if margin != _margin or mipmaps != _mipmaps:
		_margin = margin
		_mipmaps = mipmaps
		_update_group()


func _update_group() -> void:
	RenderingServer.canvas_item_set_canvas_group_mode(
		item, RenderingServer.CANVAS_GROUP_MODE_TRANSPARENT,
		_margin + 2.0, true, _margin, _mipmaps)


## The current material (for tests and tools).
func get_material() -> Material:
	return _material


## The canvas item the host's canvas item normally hangs from: the parent's
## UxmlClip item when the parent clips its children, else the parent's own.
func _parent_item() -> RID:
	var p := host.get_parent() as CanvasItem
	if p == null:
		return RID()
	if p.has_meta(&"uxml_clip"):
		var clip = p.get_meta(&"uxml_clip")
		if clip != null and clip.item.is_valid():
			return clip.item
	return p.get_canvas_item()


func _attach() -> void:
	if not enabled or not host.is_inside_tree() or host.top_level:
		return
	var pi := _parent_item()
	if not pi.is_valid():
		return
	RenderingServer.canvas_item_set_parent(item, pi)
	RenderingServer.canvas_item_set_draw_index(item, host.get_index())
	RenderingServer.canvas_item_set_parent(host.get_canvas_item(), item)
	_attached = true


func _release() -> void:
	if not _attached:
		return
	_attached = false
	if is_instance_valid(host) and host.is_inside_tree():
		var pi := _parent_item()
		if pi.is_valid():
			RenderingServer.canvas_item_set_parent(host.get_canvas_item(), pi)
	RenderingServer.canvas_item_set_parent(item, RID())


## The canvas item the host's canvas item hangs from while the filter
## draws (UxmlClip parents this one instead of the host's item).
func group_item() -> RID:
	return item if _attached else RID()


func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	if on:
		_attach()
	else:
		_release()


## Puts the host's canvas item back and frees the group item.
func detach() -> void:
	if not item.is_valid():
		return
	_release()
	if is_instance_valid(host) and host.tree_entered.is_connected(_attach):
		host.tree_entered.disconnect(_attach)
	RenderingServer.free_rid(item)
	item = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and item.is_valid():
		RenderingServer.free_rid(item)


# ---------------------------------------------------------------------------
# Unity's built-in filter math (FilterFunctionDefinitionUtils.ApplySettings)
# ---------------------------------------------------------------------------

## Unity Matrix4x4(c0, c1, c2, c3) takes columns; the shader computes
## M * color, as Unity's mul(_ColorMatrix, col).
static func _cols(c0: Vector4, c1: Vector4, c2: Vector4, c3: Vector4) -> Projection:
	return Projection(c0, c1, c2, c3)


## [Projection matrix, offset, invert] of a built-in color function, with
## Unity's parameter clamps. `p` is the function's first parameter (a float
## or a Color, see UssValues.filter_float / filter_color).
static func color_effect(name: String, p) -> Array:
	var ident := Projection.IDENTITY
	match name:
		"tint":
			var t := UssValues.filter_color(p)
			var a := clampf(t.a, 0.0, 1.0)
			return [_cols(Vector4(clampf(t.r * a, 0.0, 1.0), 0, 0, 0), Vector4(0, clampf(t.g * a, 0.0, 1.0), 0, 0),
				Vector4(0, 0, clampf(t.b * a, 0.0, 1.0), 0), Vector4(0, 0, 0, a)), 0.0, 0.0]
		"opacity":
			var o := clampf(UssValues.filter_float(p), 0.0, 1.0)
			return [_cols(Vector4(o, 0, 0, 0), Vector4(0, o, 0, 0), Vector4(0, 0, o, 0), Vector4(0, 0, 0, o)), 0.0, 0.0]
		"invert":
			return [ident, 0.0, clampf(UssValues.filter_float(p), 0.0, 1.0)]
		"grayscale":
			var g := 1.0 - clampf(UssValues.filter_float(p), 0.0, 1.0)
			return [_cols(
				Vector4(0.2126 + 0.7874 * g, 0.2126 - 0.2126 * g, 0.2126 - 0.2126 * g, 0),
				Vector4(0.7152 - 0.7152 * g, 0.7152 + 0.2848 * g, 0.7152 - 0.7152 * g, 0),
				Vector4(0.0722 - 0.0722 * g, 0.0722 - 0.0722 * g, 0.0722 + 0.9278 * g, 0),
				Vector4(0, 0, 0, 1)), 0.0, 0.0]
		"sepia":
			var s := 1.0 - clampf(UssValues.filter_float(p), 0.0, 1.0)
			return [_cols(
				Vector4(0.393 + 0.607 * s, 0.349 - 0.349 * s, 0.272 - 0.272 * s, 0),
				Vector4(0.769 - 0.769 * s, 0.686 + 0.314 * s, 0.534 - 0.534 * s, 0),
				Vector4(0.189 - 0.189 * s, 0.168 - 0.168 * s, 0.131 + 0.869 * s, 0),
				Vector4(0, 0, 0, 1)), 0.0, 0.0]
		"contrast":
			var c := maxf(0.0, UssValues.filter_float(p))
			return [_cols(Vector4(c, 0, 0, 0), Vector4(0, c, 0, 0), Vector4(0, 0, c, 0), Vector4(0, 0, 0, 1)),
				(1.0 - c) * 0.5, 0.0]
		"hue-rotate":
			var ang := UssValues.filter_float(p)
			var ca := cos(ang)
			var sa := sin(ang)
			var lr := 0.213
			var lg := 0.715
			var lb := 0.072
			return [_cols(
				Vector4(lr + ca * (1 - lr) + sa * (-lr), lr + ca * (-lr) + sa * 0.143, lr + ca * (-lr) + sa * (-(1 - lr)), 0),
				Vector4(lg + ca * (-lg) + sa * (-lg), lg + ca * (1 - lg) + sa * 0.140, lg + ca * (-lg) + sa * lg, 0),
				Vector4(lb + ca * (-lb) + sa * (1 - lb), lb + ca * (-lb) + sa * -0.283, lb + ca * (1 - lb) + sa * lb, 0),
				Vector4(0, 0, 0, 1)), 0.0, 0.0]
	return [ident, 0.0, 0.0]


## The CPU form of one color pass on a premultiplied color (tests and
## tools): M * c, + offset, invert, clamp.
static func apply_color_effect(effect: Array, c: Color) -> Color:
	var p: Projection = effect[0]
	var v := Vector4(c.r, c.g, c.b, c.a)
	var o := p * v
	var off: float = effect[1]
	var inv: float = effect[2]
	var rgb := Vector3(o.x + off, o.y + off, o.z + off)
	rgb = rgb.lerp(Vector3.ONE - rgb, inv)
	return Color(clampf(rgb.x, 0, 1), clampf(rgb.y, 0, 1), clampf(rgb.z, 0, 1), clampf(o.w, 0, 1))


## Sample spacing of a blur with kernel radius `kernel`: 1 (exact) up to
## EXACT_KERNEL, else kernel / MAX_TAPS (mipmap sampling).
static func blur_step(kernel: float) -> float:
	return 1.0 if kernel <= EXACT_KERNEL else kernel / float(MAX_TAPS)


## Unity's blur margin for one blur function (ComputeHorizontalBlurMargins):
## the kernel radius ceil(3 sigma + 1).
static func blur_margin(sigma: float) -> float:
	return ceilf(maxf(0.0, sigma) * 3.0 + 1.0) if sigma > 0.0 else 0.0
