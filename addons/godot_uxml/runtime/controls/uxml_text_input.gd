class_name UxmlTextInput
extends RefCounted
## The Godot editor inside the text element part of a TextField or a
## numeric field: a LineEdit, or a TextEdit for `multiline="true"`. The
## editor keeps Godot's IME, selection, clipboard and caret; everything it
## paints comes from the cascade of its TextElement part: the box
## (transparent unless USS says otherwise), the text colour, the font and
## size, `--unity-selection-color` and `--unity-cursor-color`
## (UxmlStyleApplier). Without USS the editor falls back to an empty
## theme, never to Godot's default LineEdit look.

static var _theme: Theme = null


## The fallback theme: empty styleboxes and no minimum character width,
## so the editor measures as its text line (Unity's TextElement).
static func fallback_theme() -> Theme:
	if _theme != null:
		return _theme
	_theme = Theme.new()
	var empty := StyleBoxEmpty.new()
	for type in ["LineEdit", "TextEdit"]:
		for slot in ["normal", "focus", "read_only"]:
			_theme.set_stylebox(slot, type, empty)
	_theme.set_constant("minimum_character_width", "LineEdit", 0)
	_theme.set_color("selection_color", "LineEdit", Color(61 / 255.0, 128 / 255.0, 223 / 255.0, 0.65))
	_theme.set_color("selection_color", "TextEdit", Color(61 / 255.0, 128 / 255.0, 223 / 255.0, 0.65))
	_theme.set_color("caret_color", "LineEdit", Color.BLACK)
	_theme.set_color("caret_color", "TextEdit", Color.BLACK)
	return _theme


## Unity's TouchScreenKeyboardType names -> Godot's virtual keyboard types.
const KEYBOARD := {
	"Default": LineEdit.KEYBOARD_TYPE_DEFAULT,
	"ASCIICapable": LineEdit.KEYBOARD_TYPE_DEFAULT,
	"NumbersAndPunctuation": LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL,
	"URL": LineEdit.KEYBOARD_TYPE_URL,
	"NumberPad": LineEdit.KEYBOARD_TYPE_NUMBER,
	"PhonePad": LineEdit.KEYBOARD_TYPE_PHONE,
	"NamePhonePad": LineEdit.KEYBOARD_TYPE_PHONE,
	"EmailAddress": LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS,
	"Social": LineEdit.KEYBOARD_TYPE_DEFAULT,
	"Search": LineEdit.KEYBOARD_TYPE_DEFAULT,
	"DecimalPad": LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL,
	"OneTimeCode": LineEdit.KEYBOARD_TYPE_NUMBER,
}


## The editor for the text element part `el` (role "editor") of `field`.
static func create(el: UxmlElement) -> Control:
	var field := el.part_of
	var text := String(el.get_attribute("text")) if el.get_attribute("text") != null else ""
	var c: Control
	if el.has_meta(&"uxml_multiline"):
		var te := TextEdit.new()
		te.text = text
		te.scroll_fit_content_height = true
		te.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		te.context_menu_enabled = true
		c = te
	else:
		var le := LineEdit.new()
		le.text = text
		le.context_menu_enabled = true
		le.caret_blink = true
		c = le
	c.theme = fallback_theme()
	c.focus_mode = Control.FOCUS_ALL
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	if field != null:
		configure(c, field)
	return c


## Apply the field attributes the editor implements itself.
static func configure(c: Control, field: UxmlElement) -> void:
	var placeholder := UxmlParts._attr(field, "placeholder-text")
	var ro := UxmlParts._bool(field, "readonly", false)
	c.set("placeholder_text", placeholder)
	c.set("editable", not ro)
	c.set_meta("uxml_editable", not ro)
	if c is LineEdit:
		var le := c as LineEdit
		var ml := int(UxmlInputParts.num(field, "max-length", -1.0))
		if UxmlNumeric.KIND.has(field.local) and not field.has_attribute("max-length"):
			ml = 1000  # Unity's numeric fields default to 1000 characters
		le.max_length = maxi(0, ml)
		var password := UxmlParts._bool(field, "password", false)
		le.secret = password
		var mask := UxmlParts._attr(field, "mask-character", UxmlParts._attr(field, "mask-char", "*"))
		le.secret_character = "*" if mask.is_empty() else mask.substr(0, 1)
		le.select_all_on_focus = UxmlParts._bool(field, "select-all-on-focus", true)
		le.virtual_keyboard_enabled = not UxmlParts._bool(field, "hide-mobile-input", false)
		le.virtual_keyboard_type = KEYBOARD.get(UxmlParts._attr(field, "keyboard-type", "Default"), LineEdit.KEYBOARD_TYPE_DEFAULT)
	elif c is TextEdit:
		var vis := UxmlParts._attr(field, "vertical-scroller-visibility", "Hidden")
		(c as TextEdit).scroll_fit_content_height = vis == "Hidden"
