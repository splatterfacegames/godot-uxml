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
	"TemplateContainer": [],
	"Box": ["unity-box"],
	"TextElement": ["unity-text-element"],
	"Label": ["unity-text-element", "unity-label"],
	"Button": ["unity-text-element", "unity-button"],
	"RepeatButton": ["unity-text-element", "unity-repeat-button"],
	"Image": ["unity-image"],
	"ScrollView": ["unity-scroll-view"],
	"ListView": ["unity-list-view", "unity-collection-view"],
	"Toggle": ["unity-base-field", "unity-base-bool-field", "unity-toggle"],
	"RadioButton": ["unity-base-field", "unity-base-bool-field", "unity-radio-button"],
	"RadioButtonGroup": ["unity-base-field", "unity-radio-button-group"],
	"ToggleButtonGroup": ["unity-base-field", "unity-toggle-button-group"],
	"GroupBox": ["unity-group-box"],
	"HelpBox": ["unity-help-box"],
	"PopupWindow": ["unity-text-element", "unity-popup-window"],
	"Foldout": ["unity-foldout"],
	"ProgressBar": ["unity-progress-bar"],
	"DropdownField": ["unity-dropdown-field", "unity-base-popup-field", "unity-base-field"],
	"TextField": ["unity-text-field", "unity-base-text-field", "unity-base-field"],
	"IntegerField": ["unity-integer-field", "unity-base-text-field", "unity-base-field"],
	"FloatField": ["unity-float-field", "unity-base-text-field", "unity-base-field"],
	"Slider": ["unity-slider", "unity-base-slider", "unity-base-slider--horizontal", "unity-base-field"],
	"SliderInt": ["unity-slider-int", "unity-base-slider", "unity-base-slider--horizontal", "unity-base-field"],
}

## Tags that carry no pixels but are part of the document model, not
## unsupported controls: the root container and stylesheet references.
const NON_VISUAL_TAGS := ["UXML", "Style"]

## UXML machinery that parses fine but is out of scope for godot-uxml:
## templates/instances and slots are diagnosed rather than silently ignored.
const UNSUPPORTED_FEATURE_TAGS := {
	"Template": "UXML templates are not supported",
	"Instance": "UXML template instances are not supported",
	"AttributeOverride": "UXML template attribute overrides are not supported",
	"Slot": "UXML template slots are not supported",
}

## Controls Unity UXML offers that godot-uxml recognizes — they keep their
## implicit classes so author styles like `.unity-foldout` still match — but
## they have no runtime mapping yet, so they diagnose `unsupported-control`
## like any unmapped tag and fall back to a plain container. Remove a name
## from this list once a milestone actually maps it to a native control.
const RECOGNIZED_UNMAPPED := ["IntegerField", "FloatField"]

## UXML attributes the addon consumes or accepts as part of the document
## grammar. Namespace declarations (`xmlns:*`) and any namespaced attribute
## are always accepted and never reach this check. Anything not listed —
## including real Unity attributes for features godot-uxml does not
## implement, like `picking-mode` or `binding-path` — produces one
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
	# Controls built as Unity part trees (runtime/controls/)
	"delay": true, "interval": true, "title": true, "message-type": true,
	"is-multiple-selection": true, "allow-empty-selection": true,
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
	if NON_VISUAL_TAGS.has(local_name):
		return true
	return IMPLICIT_CLASSES.has(local_name) and not RECOGNIZED_UNMAPPED.has(local_name)
