class_name UssControls
extends RefCounted
## The element tags godot-uxml knows, and the USS classes Unity's constructors
## would add to them.
##
## Ported from the class table in vendor/uxml-preview/src/controls/registry.ts
## (Apache-2.0). Implicit classes matter to the cascade: an author writes
## `.unity-button` in USS and it has to match a plain `<ui:Button />`.
## Which native Godot control each tag instantiates is the runtime's concern
## (milestone 2); this table is only about matching.

## Implicit `unity-*` classes per element local name.
const IMPLICIT_CLASSES := {
	"VisualElement": [],
	"Label": ["unity-label"],
	"Button": ["unity-button"],
	"Image": ["unity-image"],
	"ScrollView": ["unity-scroll-view"],
	"ListView": ["unity-list-view", "unity-collection-view"],
	"Toggle": ["unity-toggle", "unity-base-field"],
	"DropdownField": ["unity-dropdown-field", "unity-base-popup-field", "unity-base-field"],
	"TextField": ["unity-text-field", "unity-base-text-field", "unity-base-field"],
	"IntegerField": ["unity-integer-field", "unity-base-text-field", "unity-base-field"],
	"FloatField": ["unity-float-field", "unity-base-text-field", "unity-base-field"],
	"Slider": ["unity-slider", "unity-base-slider", "unity-base-slider--horizontal", "unity-base-field"],
	"SliderInt": ["unity-slider-int", "unity-base-slider", "unity-base-slider--horizontal", "unity-base-field"],
	"Foldout": ["unity-foldout"],
	# What an expanded <ui:Instance> becomes: a plain box, no implicit class.
	"TemplateContainer": [],
}

## Tags that carry no pixels but are part of the document model, not
## unsupported controls: the root container and stylesheet references.
const NON_VISUAL_TAGS := ["UXML", "Style"]

## Template syntax. UxmlTemplates expands it at load time: <Instance>
## becomes a TemplateContainer, <Template> and <AttributeOverrides> leave the
## tree. The names count as known so the authored file does not warn.
const TEMPLATE_TAGS := ["Template", "Instance", "AttributeOverrides"]

## UXML machinery that parses fine but is out of scope for godot-uxml; such
## a tag is diagnosed `unsupported-feature` rather than silently ignored.
## Empty: every UXML structure tag Unity 6 defines is supported.
const UNSUPPORTED_FEATURE_TAGS := {}

## Controls Unity UXML offers that godot-uxml recognizes — they keep their
## implicit classes so author styles like `.unity-foldout` still match — but
## they have no runtime mapping yet, so they diagnose `unsupported-control`
## like any unmapped tag and fall back to a plain container. Remove a name
## from this list once a milestone actually maps it to a native control.
const RECOGNIZED_UNMAPPED := ["IntegerField", "FloatField", "Foldout"]

## UXML attributes the addon consumes or accepts as part of the document
## grammar. Namespace declarations (`xmlns:*`) and any namespaced attribute
## are always accepted and never reach this check. Anything not listed —
## including real Unity attributes of controls godot-uxml does not
## implement yet — produces one
## `unsupported-attribute` diagnostic per attribute name per document; the
## value stays in the model but has no effect.
const KNOWN_ATTRIBUTES := {
	"name": true, "class": true, "style": true,
	"src": true, "enabled": true, "focusable": true,
	"text": true, "label": true, "tooltip": true,
	"value": true, "low-value": true, "high-value": true,
	"choices": true, "index": true, "image": true,
	"multiline": true, "placeholder-text": true, "readonly": true,
	"max-length": true, "mask-char": true,
	"object-type": true, "type": true,
	# ListView (virtualized; rows instantiated from item-template)
	"fixed-item-height": true, "item-template": true,
	"show-alternating-row-backgrounds": true, "virtualization-method": true,
	"selection-type": true,
	# Templates (<Template>, <Instance>, <AttributeOverrides>, slots)
	"template": true, "path": true, "element-name": true,
	"content-container": true, "slot": true, "slot-name": true,
	# VisualElement / BindableElement base attributes (Unity 6000.3):
	# data binding (UxmlBinding) and the common attributes
	# (UxmlCommonAttributes). usage-hints is accepted as a no-op hint.
	"data-source": true, "data-source-path": true, "data-source-type": true,
	"binding-path": true, "tabindex": true, "picking-mode": true,
	"view-data-key": true, "usage-hints": true, "language-direction": true,
	# ListView AutoAssign: rows get the bound itemsSource as data source.
	"binding-source-selection-mode": true,
}


static func implicit_classes_of(local_name: String) -> Array:
	return IMPLICIT_CLASSES.get(local_name, [])


static func is_non_visual(local_name: String) -> bool:
	return NON_VISUAL_TAGS.has(local_name)


## Tags that are part of the supported control set — the controls the scope
## requires (VisualElement/Label/Button/Image/ScrollView/Toggle/
## DropdownField/TextField/Slider/SliderInt) plus non-visual tags.
## Recognized-but-unmapped controls (RECOGNIZED_UNMAPPED) do NOT count:
## until a milestone maps them they warn like any unknown control.
static func is_known_control(local_name: String) -> bool:
	if NON_VISUAL_TAGS.has(local_name) or TEMPLATE_TAGS.has(local_name):
		return true
	if UxmlBindings.is_binding_tag(local_name):
		return true
	return IMPLICIT_CLASSES.has(local_name) and not RECOGNIZED_UNMAPPED.has(local_name)
