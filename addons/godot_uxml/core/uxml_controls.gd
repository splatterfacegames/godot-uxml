class_name UxmlControls
extends RefCounted
## The elements godot-uxml supports and the UXML attributes each one reads:
## the catalog an editor palette and inspector show.
##
## The names, types and defaults follow Unity 6000.3 (the UxmlAttribute
## declarations of the controls); only attributes that godot-uxml reads are
## listed (UssControls.KNOWN_ATTRIBUTES), and tests keep the two in step.
## Control parts (TextInput, ObjectFieldDisplay, ...) are not authored and
## are not listed.

## Attribute spec: "name:type=default" or "name:enum(A|B|C)=default".
## Types: string, bool, int, long, float, double, color, enum.
const _VE := ["name:string=", "class:string=", "style:string=", "tooltip:string=",
	"enabled:bool=true", "focusable:bool=false", "tabindex:int=0",
	"picking-mode:enum(Position|Ignore)=Position", "view-data-key:string=",
	"usage-hints:enum(None|DynamicTransform|GroupTransform|MaskContainer|DynamicColor|DynamicPostProcessing)=None",
	"language-direction:enum(Inherit|LTR|RTL)=Inherit", "content-container:string=",
	"data-source:string=", "data-source-path:string=", "data-source-type:string="]
const _BINDABLE := ["binding-path:string="]
const _TEXT := ["text:string=", "enable-rich-text:bool=true", "parse-escape-sequences:bool=false",
	"display-tooltip-when-elided:bool=true"]
const _FIELD := ["focusable:bool=true", "label:string="]
const _TEXT_INPUT := ["max-length:int=-1", "password:bool=false", "mask-character:string=*",
	"placeholder-text:string=", "hide-placeholder-on-focus:bool=false", "readonly:bool=false",
	"is-delayed:bool=false", "select-all-on-focus:bool=true", "select-all-on-mouse-up:bool=true",
	"select-word-by-double-click:bool=true", "select-line-by-triple-click:bool=true",
	"vertical-scroller-visibility:enum(Hidden|Auto|AlwaysVisible)=Hidden",
	"auto-correction:bool=false", "hide-mobile-input:bool=false",
	"keyboard-type:enum(Default|ASCIICapable|NumbersAndPunctuation|URL|NumberPad|PhonePad|NamePhonePad|EmailAddress|NintendoNetworkAccount|Social|Search|DecimalPad|OneTimeCode)=Default",
	"emoji-fallback-support:bool=true"]
const _NUMERIC := _TEXT_INPUT + ["support-expressions:bool=true"]
const _COLLECTION := ["fixed-item-height:float=22",
	"virtualization-method:enum(FixedHeight|DynamicHeight)=FixedHeight",
	"show-border:bool=false", "selection-type:enum(None|Single|Multiple)=Single",
	"show-alternating-row-backgrounds:enum(None|ContentOnly|All)=None",
	"reorderable:bool=false", "horizontal-scrolling:bool=false"]
const _LIST := _COLLECTION + ["show-foldout-header:bool=false", "header-title:string=",
	"show-add-remove-footer:bool=false", "allow-add:bool=true", "allow-remove:bool=true",
	"reorder-mode:enum(Simple|Animated)=Simple", "show-bound-collection-size:bool=true",
	"binding-source-selection-mode:enum(Manual|AutoAssign)=Manual"]
const _SORTING := ["sorting-mode:enum(None|Default|Custom)=None"]
const _SLIDER := ["page-size:float=0", "show-input-field:bool=false",
	"direction:enum(Horizontal|Vertical)=Horizontal", "inverted:bool=false", "fill:bool=false"]
const _POPUP := ["choices:string=", "index:int=-1"]

## Element table: [name, base, own attributes, flags]. Base: "ve" (VisualElement),
## "bind" (BindableElement), "text" (TextElement), "field" (BaseField).
## Flags: "c" takes authored children, "e" UnityEditor.UIElements (editor only),
## "o" a UxmlObject (data, not a visual element).
const _TABLE := [
	["VisualElement", "ve", [], "c"],
	["Box", "ve", [], "c"],
	["TemplateContainer", "bind", [], "c"],
	["Label", "text", [], ""],
	["TextElement", "text", [], ""],
	["Button", "text", [], ""],
	["RepeatButton", "text", ["delay:long=0", "interval:long=0"], ""],
	["Image", "ve", ["image:string="], ""],
	["ScrollView", "ve", ["mode:enum(Vertical|Horizontal|VerticalAndHorizontal)=Vertical",
		"horizontal-scroller-visibility:enum(Auto|AlwaysVisible|Hidden)=Auto",
		"vertical-scroller-visibility:enum(Auto|AlwaysVisible|Hidden)=Auto",
		"horizontal-page-size:float=-1", "vertical-page-size:float=-1",
		"mouse-wheel-scroll-size:float=18",
		"nested-interaction-kind:enum(Default|StopScrolling|ForwardScrolling)=Default",
		"touch-scroll-type:enum(Unrestricted|Elastic|Clamped)=Clamped",
		"elasticity:float=0.1", "scroll-deceleration-rate:float=0.135"], "c"],
	["Scroller", "ve", ["low-value:float=0", "high-value:float=0",
		"direction:enum(Horizontal|Vertical)=Vertical", "value:float=0"], ""],
	["ListView", "bind", _LIST + ["item-template:string="], ""],
	["TreeView", "bind", _COLLECTION + ["auto-expand:bool=false", "item-template:string="], ""],
	["MultiColumnListView", "bind", _LIST + _SORTING, ""],
	["MultiColumnTreeView", "bind", _COLLECTION + ["auto-expand:bool=false"] + _SORTING, ""],
	["Columns", "", ["reorderable:bool=true", "resizable:bool=true"], "o"],
	["Column", "", ["name:string=", "title:string=", "icon:string=", "visible:bool=true",
		"width:float=0", "min-width:float=35", "max-width:float=8388608", "sortable:bool=true",
		"stretchable:bool=false", "optional:bool=true", "resizable:bool=true",
		"header-template:string=", "cell-template:string="], "o"],
	["SortColumnDescriptions", "", [], "o"],
	["SortColumnDescription", "", ["column-name:string=", "column-index:int=-1",
		"direction:enum(Ascending|Descending)=Ascending"], "o"],
	["Toggle", "field", ["value:bool=false", "text:string="], ""],
	["RadioButton", "field", ["value:bool=false", "text:string="], ""],
	["RadioButtonGroup", "field", ["value:int=-1", "choices:string="], "c"],
	["ToggleButtonGroup", "field", ["value:string=", "is-multiple-selection:bool=false",
		"allow-empty-selection:bool=true"], "c"],
	["GroupBox", "bind", ["text:string="], "c"],
	["HelpBox", "ve", ["text:string=", "message-type:enum(None|Info|Warning|Error)=None"], ""],
	["PopupWindow", "text", [], "c"],
	["Foldout", "bind", ["text:string=", "value:bool=true"], "c"],
	["ProgressBar", "bind", ["low-value:float=0", "high-value:float=100", "value:float=0",
		"title:string="], ""],
	["DropdownField", "field", ["value:string="] + _POPUP, ""],
	["EnumField", "field", ["type:string=", "value:string=", "include-obsolete-values:bool=false"], ""],
	["TextField", "field", ["value:string=", "multiline:bool=false"] + _TEXT_INPUT, ""],
	["IntegerField", "field", ["value:int=0"] + _NUMERIC, ""],
	["LongField", "field", ["value:long=0"] + _NUMERIC, ""],
	["FloatField", "field", ["value:float=0"] + _NUMERIC, ""],
	["DoubleField", "field", ["value:double=0"] + _NUMERIC, ""],
	["UnsignedIntegerField", "field", ["value:int=0"] + _NUMERIC, ""],
	["UnsignedLongField", "field", ["value:long=0"] + _NUMERIC, ""],
	["Hash128Field", "field", ["value:string=00000000000000000000000000000000"] + _TEXT_INPUT, ""],
	["Slider", "field", ["value:float=0", "low-value:float=0", "high-value:float=10"] + _SLIDER, ""],
	["SliderInt", "field", ["value:int=0", "low-value:int=0", "high-value:int=10"] + _SLIDER, ""],
	["MinMaxSlider", "field", ["min-value:float=0", "max-value:float=10", "low-limit:float=-3.4028235E+38",
		"high-limit:float=3.4028235E+38"], ""],
	["Vector2Field", "field", ["x:float=0", "y:float=0"], ""],
	["Vector2IntField", "field", ["x:int=0", "y:int=0"], ""],
	["Vector3Field", "field", ["x:float=0", "y:float=0", "z:float=0"], ""],
	["Vector3IntField", "field", ["x:int=0", "y:int=0", "z:int=0"], ""],
	["Vector4Field", "field", ["x:float=0", "y:float=0", "z:float=0", "w:float=0"], ""],
	["RectField", "field", ["x:float=0", "y:float=0", "w:float=0", "h:float=0"], ""],
	["RectIntField", "field", ["x:int=0", "y:int=0", "w:int=0", "h:int=0"], ""],
	["BoundsField", "field", ["cx:float=0", "cy:float=0", "cz:float=0", "ex:float=0", "ey:float=0",
		"ez:float=0"], ""],
	["BoundsIntField", "field", ["px:int=0", "py:int=0", "pz:int=0", "sx:int=0", "sy:int=0",
		"sz:int=0"], ""],
	["Tab", "ve", ["label:string=", "icon-image:string=", "closeable:bool=false"], "c"],
	["TabView", "ve", ["reorderable:bool=false"], "c"],
	["TwoPaneSplitView", "ve", ["fixed-pane-index:int=0", "fixed-pane-initial-dimension:float=100",
		"orientation:enum(Horizontal|Vertical)=Horizontal"], "c"],
	["IMGUIContainer", "ve", [], ""],
	# UnityEditor.UIElements
	["ColorField", "field", ["value:color=#000000FF", "show-alpha:bool=true",
		"hdr:bool=false", "show-eye-dropper:bool=true"], "e"],
	["CurveField", "field", [], "e"],
	["GradientField", "field", ["hdr:bool=false", "color-space:enum(Gamma|Linear)=Gamma"], "e"],
	["ObjectField", "field", ["type:string=", "allow-scene-objects:bool=true"], "e"],
	["EnumFlagsField", "field", ["type:string=", "value:string=", "include-obsolete-values:bool=false"], "e"],
	["MaskField", "field", ["choices:string=", "choices-masks:string=", "value:int=0"], "e"],
	["LayerField", "field", ["value:int=0"], "e"],
	["LayerMaskField", "field", ["value:int=0"], "e"],
	["RenderingLayerMaskField", "field", ["value:int=0"], "e"],
	["TagField", "field", ["value:string="], "e"],
	["Toolbar", "ve", [], "ce"],
	["ToolbarButton", "text", [], "e"],
	["ToolbarToggle", "field", ["value:bool=false", "text:string="], "e"],
	["ToolbarMenu", "text", ["variant:enum(Default|Popup)=Default"], "e"],
	["ToolbarSpacer", "ve", ["flex:bool=false"], "e"],
	["ToolbarBreadcrumbs", "ve", [], "e"],
	["ToolbarSearchField", "ve", [], "e"],
	["ToolbarPopupSearchField", "ve", [], "e"],
	["PropertyField", "bind", ["label:string="], "e"],
	["InspectorElement", "bind", [], "e"],
]

static var _catalog: Array = []


## Every supported element: [{namespace: "UnityEngine.UIElements" or
## "UnityEditor.UIElements", name, container: bool, editor_only: bool,
## uxml_object: bool, attributes: [{name, type, default[, choices]}]}].
## `container` marks the elements that take authored children (a palette
## can nest elements into them); `uxml_object` marks data elements of a
## parent (the Columns of a multi-column view), not visual elements.
## `type` is one of string, bool, int, long, float, double, color, enum;
## `default` is the value as UXML text; an enum lists its `choices`. The
## caller gets a copy.
static func catalog() -> Array:
	if _catalog.is_empty():
		_catalog = _build()
	return _catalog.duplicate(true)


## The catalog entry of `element_name` (a local name, `Button`), or {}.
static func describe(element_name: String) -> Dictionary:
	if _catalog.is_empty():
		_catalog = _build()
	for e in _catalog:
		if e["name"] == element_name:
			return (e as Dictionary).duplicate(true)
	return {}


static func _build() -> Array:
	var out: Array = []
	for row in _TABLE:
		var flags: String = row[3]
		var specs: Array = []
		match String(row[1]):
			"ve":
				specs = _VE.duplicate()
			"bind":
				specs = _VE + _BINDABLE
			"text":
				specs = _VE + _BINDABLE + _TEXT
			"field":
				specs = _VE + _BINDABLE + _FIELD
		specs.append_array(row[2])
		var attrs: Array = []
		var at := {}  # name -> index: a later spec replaces an earlier default
		for s in specs:
			var a := _attr(String(s))
			if at.has(a["name"]):
				attrs[at[a["name"]]] = a
			else:
				at[a["name"]] = attrs.size()
				attrs.append(a)
		out.append({
			"namespace": "UnityEditor.UIElements" if flags.contains("e") else "UnityEngine.UIElements",
			"name": row[0],
			"container": flags.contains("c"),
			"editor_only": flags.contains("e"),
			"uxml_object": flags.contains("o"),
			"attributes": attrs,
		})
	return out


static func _attr(spec: String) -> Dictionary:
	var colon := spec.find(":")
	var eq := spec.find("=", colon)
	var type := spec.substr(colon + 1, eq - colon - 1)
	var a := {"name": spec.substr(0, colon), "type": type, "default": spec.substr(eq + 1)}
	if type.begins_with("enum("):
		a["type"] = "enum"
		a["choices"] = PackedStringArray(type.substr(5, type.length() - 6).split("|"))
	return a
