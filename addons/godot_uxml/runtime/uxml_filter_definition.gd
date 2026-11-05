@tool
class_name UxmlFilterDefinition
extends Resource
## The Godot counterpart of Unity's FilterFunctionDefinition asset: what a
## custom USS filter function, `filter(url("x.asset") <params>)`, draws.
##
## Unity -> Godot mapping:
##   FilterFunctionDefinition.filterName           -> filter_name
##   passes[0].material (a post-processing shader) -> material: a
##       ShaderMaterial with a canvas_item shader that reads the element's
##       rendered subtree as `uniform sampler2D t : hint_screen_texture`
##       at SCREEN_UV (premultiplied color, as Unity's _MainTex) and writes
##       COLOR (use `render_mode blend_premul_alpha;` to write
##       premultiplied color, as a Unity filter pass does)
##   passes[0].parameterBindings[i].name           -> parameter_names[i]:
##       the shader uniform that receives parameter i
##   parameters[i].interpolationDefaultValue       -> interpolation_defaults[i]
##       (a float or a Color): the value a transition pads with
##   passes[0].readMargins / writeMargins          -> margins (left, top,
##       right, bottom, in pixels): the extra space around the element
##
## Godot draws a canvas group with one material, so a definition has one
## pass. A Unity filter with several passes needs one Godot shader that does
## the work of all of them.
##
## The runtime finds the definition from the reference in the USS: the
## file itself when Godot can load it, else the same path with the
## extension .tres, .res or .gdshader. A ShaderMaterial or a Shader there
## is accepted too: its non-sampler uniforms then take the parameters in
## declaration order, and the margins are 0.

@export var filter_name := ""
@export var material: Material
@export var parameter_names := PackedStringArray()
@export var interpolation_defaults: Array = []
@export var margins := Vector4.ZERO


## A definition around a plain ShaderMaterial or Shader: parameters bind to
## the shader's non-sampler uniforms in declaration order.
static func from_material(mat: Material) -> UxmlFilterDefinition:
	var d := UxmlFilterDefinition.new()
	d.material = mat
	var sm := mat as ShaderMaterial
	if sm != null and sm.shader != null:
		d.filter_name = sm.shader.resource_path.get_file().get_basename()
		for u in sm.shader.get_shader_uniform_list():
			var t: int = u.get("type", TYPE_NIL)
			if t == TYPE_OBJECT:
				continue  # samplers (the screen texture, textures)
			d.parameter_names.append(String(u["name"]))
	return d
