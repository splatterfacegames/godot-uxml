class_name UxmlRichText
extends RefCounted
## Unity rich text tags -> Godot RichTextLabel content.
##
## Unity TextElements (Label, Button, ...) parse rich text tags by default
## (enable-rich-text="true"). parse() reads the tags once per text into a
## small op list; render() replays the ops into a RichTextLabel through its
## push_* API with the element's computed font, size and color. The push API
## (not BBCode) is used because superscript, subscript and voffset need a
## FontVariation with a baseline offset, which BBCode cannot name.
##
## Tag coverage (Unity TextCore names):
##   drawn:  b i u s color=<c> <#hex> alpha=<#aa> size=<n|n%|+n|-n|nem>
##           mark=<c> sup sub br noparse link=<id> a href=<url>
##           align=<left|center|right|justified|flush> allcaps uppercase
##           lowercase smallcaps cspace=<n|nem> font-weight=<n> nobr
##           voffset=<n|nem>
##   dropped (text drawn without the effect, diagnosed): font indent
##           line-height line-indent margin mspace pos rotate space sprite
##           style width gradient page action
## An unknown or malformed tag stays in the text as literal characters,
## as in Unity.

const DRAWN := {
	"b": true, "i": true, "u": true, "s": true, "color": true, "alpha": true,
	"size": true, "mark": true, "sup": true, "sub": true, "br": true,
	"noparse": true, "link": true, "a": true, "align": true, "allcaps": true,
	"uppercase": true, "lowercase": true, "smallcaps": true, "cspace": true,
	"font-weight": true, "nobr": true, "voffset": true,
}
const DROPPED := {
	"font": true, "indent": true, "line-height": true, "line-indent": true,
	"margin": true, "mspace": true, "pos": true, "rotate": true, "space": true,
	"sprite": true, "style": true, "width": true, "gradient": true,
	"page": true, "action": true,
}
## Tags that need a value to be valid.
const _VALUED := {
	"color": true, "alpha": true, "size": true, "mark": true, "link": true,
	"a": true, "align": true, "cspace": true, "font-weight": true, "voffset": true,
}
## TextCore's named rich text colors.
const _NAMED := {
	"black": Color(0, 0, 0), "blue": Color(0, 0, 1), "green": Color(0, 1, 0),
	"orange": Color(1, 0.502, 0), "purple": Color(0.627, 0.125, 0.941),
	"red": Color(1, 0, 0), "white": Color(1, 1, 1), "yellow": Color(1, 1, 0),
}
## Superscript / subscript: size ratio and baseline shift (fraction of the
## run's font height; negative is up). TextCore takes these from the font
## asset's face info; these are TextCore's defaults for generated assets.
const SCRIPT_SIZE := 0.5
const SUP_SHIFT := -0.45
const SUB_SHIFT := 0.15
const SMALLCAPS_SIZE := 0.8

static var _parse_cache := {}
static var _NOT_RICH := {"rich": false, "ops": [], "plain": "", "dropped": PackedStringArray()}


## {rich: bool, ops: Array, plain: String, dropped: PackedStringArray}.
## `rich` is true when the text holds at least one rich text tag; `plain`
## is the text with every tag removed. Memoized by text (read-only result).
static func parse(text: String) -> Dictionary:
	if text.find("<") < 0:
		return _NOT_RICH  # no tag possible: the common case, no parse
	var hit = _parse_cache.get(text)
	if hit != null:
		return hit
	if _parse_cache.size() > 2048:
		_parse_cache.clear()
	var out := _parse(text)
	_parse_cache[text] = out
	return out


static func _parse(text: String) -> Dictionary:
	var ops: Array = []
	var dropped := PackedStringArray()
	var plain := ""
	var buf := ""
	var rich := false
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c != "<":
			buf += c
			i += 1
			continue
		var close := text.find(">", i + 1)
		var next_open := text.find("<", i + 1)
		if close < 0 or (next_open >= 0 and next_open < close):
			buf += c
			i += 1
			continue
		var tag = _read_tag(text.substr(i + 1, close - i - 1))
		if tag == null:
			buf += c
			i += 1
			continue
		rich = true
		if not buf.is_empty():
			ops.append(["t", buf])
			plain += buf
			buf = ""
		var name: String = tag[1]
		i = close + 1
		if tag[0] == "+" and name == "noparse":
			var end := text.findn("</noparse>", i)
			var lit := text.substr(i) if end < 0 else text.substr(i, end - i)
			if not lit.is_empty():
				ops.append(["t", lit])
				plain += lit
			i = n if end < 0 else end + 10
			continue
		if name == "br":
			ops.append(["br"])
			plain += "\n"
			continue
		if DROPPED.has(name):
			if not dropped.has(name):
				dropped.append(name)
			continue
		ops.append(tag)
	if not buf.is_empty():
		ops.append(["t", buf])
		plain += buf
	return {"rich": rich, "ops": ops, "plain": plain, "dropped": dropped}


## The inside of <...> -> ["+", name, value] / ["-", name], or null when it
## is not a rich text tag (the characters then stay literal).
static func _read_tag(inner: String) -> Variant:
	# A tag starts and ends without white space: "a < b > c" is text.
	if inner.is_empty() or inner.unicode_at(0) <= 32 or inner.unicode_at(inner.length() - 1) <= 32:
		return null
	var s := inner
	if s.begins_with("/"):
		var cname := s.substr(1).strip_edges().to_lower()
		if DRAWN.has(cname) or DROPPED.has(cname):
			return ["-", cname]
		return null
	if s.begins_with("#"):
		var hc = _color(s)
		return null if hc == null else ["+", "color", hc]
	if s.ends_with("/"):
		s = s.substr(0, s.length() - 1).strip_edges()
	var name := s
	var value := ""
	var eq := s.find("=")
	var sp := s.find(" ")
	if eq >= 0 and (sp < 0 or eq < sp):
		name = s.substr(0, eq).strip_edges()
		value = s.substr(eq + 1).strip_edges()
	elif sp >= 0:
		name = s.substr(0, sp)
		value = s.substr(sp + 1).strip_edges()
	name = name.to_lower()
	if not (DRAWN.has(name) or DROPPED.has(name)):
		return null
	if name == "a":
		# <a href="url">: the attribute form.
		var hv := value
		if hv.to_lower().begins_with("href"):
			var e2 := hv.find("=")
			hv = "" if e2 < 0 else hv.substr(e2 + 1).strip_edges()
		value = hv
	value = _unquote(value)
	if DROPPED.has(name):
		return ["+", name, value]
	if _VALUED.has(name) and value.is_empty():
		return null
	match name:
		"color", "mark":
			var col = _color(value)
			return null if col == null else ["+", name, col]
		"alpha":
			var a := _hex_byte(value)
			return null if a < 0 else ["+", name, a / 255.0]
		"size", "cspace", "voffset":
			var spec = _size_spec(value)
			return null if spec == null else ["+", name, spec]
		"font-weight":
			var w := UssValues.parse_number(value)
			return null if is_nan(w) else ["+", name, w]
		"align":
			var al := value.to_lower()
			if not ["left", "center", "right", "justified", "flush"].has(al):
				return null
			return ["+", name, al]
	return ["+", name, value]


static func _unquote(v: String) -> String:
	if v.length() >= 2 and (v[0] == '"' or v[0] == "'") and v[v.length() - 1] == v[0]:
		return v.substr(1, v.length() - 2)
	return v


static func _color(v: String) -> Variant:
	var t := _unquote(v.strip_edges()).to_lower()
	if _NAMED.has(t):
		return _NAMED[t]
	if t.begins_with("#") and [4, 5, 7, 9].has(t.length()) and t.substr(1).is_valid_hex_number():
		return Color.html(t)
	return null


static func _hex_byte(v: String) -> int:
	var t := v.strip_edges()
	if t.begins_with("#"):
		t = t.substr(1)
	if t.length() != 2 or not t.is_valid_hex_number():
		return -1
	return t.hex_to_int()


## "20" / "20px" / "150%" / "+5" / "-5" / "1.5em" -> [mode, value] with
## mode "px" | "pct" | "rel" | "em".
static func _size_spec(v: String) -> Variant:
	var t := v.strip_edges().to_lower()
	var mode := "px"
	if t.begins_with("+"):
		mode = "rel"
		t = t.substr(1)
	elif t.ends_with("%"):
		mode = "pct"
		t = t.substr(0, t.length() - 1)
	elif t.ends_with("em"):
		mode = "em"
		t = t.substr(0, t.length() - 2)
	elif t.ends_with("px"):
		t = t.substr(0, t.length() - 2)
	var num := UssValues.parse_number(t)
	if is_nan(num):
		return null
	if mode == "px" and num < 0.0 and v.strip_edges().begins_with("-"):
		mode = "rel"  # <size=-5>: five less than the base size
	return [mode, num]


## Unity parse-escape-sequences: \n \t \r \\ \uXXXX \UXXXXXXXX.
static func unescape(text: String) -> String:
	var out := ""
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c != "\\" or i + 1 >= n:
			out += c
			i += 1
			continue
		var e := text[i + 1]
		match e:
			"n":
				out += "\n"
				i += 2
			"t":
				out += "\t"
				i += 2
			"r":
				out += "\r"
				i += 2
			"\\":
				out += "\\"
				i += 2
			"u", "U":
				var w := 4 if e == "u" else 8
				var hx := text.substr(i + 2, w)
				if hx.length() == w and hx.is_valid_hex_number():
					out += String.chr(hx.hex_to_int())
					i += 2 + w
				else:
					out += c
					i += 1
			_:
				out += c
				i += 1
	return out


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

## Fills `rtl` from parse()d `ops`. `font`/`size`/`color` are the element's
## computed base text style.
static func render(rtl: RichTextLabel, ops: Array, font: Font, size: int, color: Color) -> void:
	rtl.clear()
	var st := {
		"b": 0, "i": 0, "u": 0, "s": 0, "nobr": 0,
		"color": [], "alpha": [], "size": [], "mark": [], "script": [],
		"link": [], "case": [], "cspace": [], "weight": [], "voffset": [],
		"align": 0,
	}
	var cache := {}
	for op in ops:
		match op[0]:
			"t":
				_emit(rtl, String(op[1]), st, font, size, color, cache)
			"br":
				rtl.add_text("\n")
			"+":
				_open(rtl, op[1], op[2], st, size)
			"-":
				_close(rtl, op[1], st)
	while st["align"] > 0:
		rtl.pop()
		st["align"] -= 1


static func _open(rtl: RichTextLabel, name: String, value, st: Dictionary, base: int) -> void:
	match name:
		"b", "i", "u", "s", "nobr":
			st[name] += 1
		"color", "alpha", "mark", "link", "cspace", "voffset":
			(st[name] as Array).append(value)
		"a":
			(st["link"] as Array).append(value)
		"size":
			var spec: Array = value
			var px := float(base)
			match spec[0]:
				"px":
					px = spec[1]
				"pct":
					px = base * float(spec[1]) / 100.0
				"rel":
					px = base + float(spec[1])
				"em":
					px = base * float(spec[1])
			(st["size"] as Array).append(maxi(1, roundi(px)))
		"sup", "sub":
			(st["script"] as Array).append(name)
		"allcaps", "uppercase", "lowercase", "smallcaps":
			(st["case"] as Array).append("upper" if name == "allcaps" else name)
		"font-weight":
			(st["weight"] as Array).append(value)
		"align":
			var al: String = value
			var h := HORIZONTAL_ALIGNMENT_LEFT
			match al:
				"center":
					h = HORIZONTAL_ALIGNMENT_CENTER
				"right":
					h = HORIZONTAL_ALIGNMENT_RIGHT
				"justified", "flush":
					h = HORIZONTAL_ALIGNMENT_FILL
			rtl.push_paragraph(h)
			st["align"] += 1


static func _close(rtl: RichTextLabel, name: String, st: Dictionary) -> void:
	match name:
		"b", "i", "u", "s", "nobr":
			st[name] = maxi(0, st[name] - 1)
		"color", "alpha", "mark", "link", "cspace", "voffset", "size":
			_pop(st[name])
		"a":
			_pop(st["link"])
		"sup", "sub":
			_pop(st["script"])
		"allcaps", "uppercase", "lowercase", "smallcaps":
			_pop(st["case"])
		"font-weight":
			_pop(st["weight"])
		"align":
			if st["align"] > 0:
				rtl.pop()
				st["align"] -= 1


static func _pop(a: Array) -> void:
	if not a.is_empty():
		a.pop_back()


static func _emit(rtl: RichTextLabel, text: String, st: Dictionary, font: Font,
		base: int, base_color: Color, cache: Dictionary) -> void:
	var cs: Array = st["case"]
	var mode: String = "" if cs.is_empty() else cs.back()
	if st["nobr"] > 0:
		text = text.replace(" ", String.chr(0xA0))  # no-break space
	if mode == "smallcaps":
		# Lowercase letters become smaller capitals; the rest keep size.
		var run := ""
		var low := false
		for k in text.length():
			var ch := text[k]
			var is_low := ch != ch.to_upper()
			if k > 0 and is_low != low:
				_run(rtl, run.to_upper(), st, font, base, base_color, cache, low)
				run = ""
			low = is_low
			run += ch
		if not run.is_empty():
			_run(rtl, run.to_upper(), st, font, base, base_color, cache, low)
		return
	if mode == "upper":
		text = text.to_upper()
	elif mode == "lowercase":
		text = text.to_lower()
	_run(rtl, text, st, font, base, base_color, cache, false)


static func _run(rtl: RichTextLabel, text: String, st: Dictionary, font: Font,
		base: int, base_color: Color, cache: Dictionary, small: bool) -> void:
	var size := base
	var sizes: Array = st["size"]
	if not sizes.is_empty():
		size = sizes.back()
	var scripts: Array = st["script"]
	var shift := 0.0
	if not scripts.is_empty():
		size = maxi(1, roundi(size * SCRIPT_SIZE))
		shift = SUP_SHIFT if scripts.back() == "sup" else SUB_SHIFT
	if small:
		size = maxi(1, roundi(size * SMALLCAPS_SIZE))
	var weights: Array = st["weight"]
	var bold: bool = st["b"] > 0 or (not weights.is_empty() and float(weights.back()) >= 600.0)
	var italic: bool = st["i"] > 0
	var glyph := 0
	var cspaces: Array = st["cspace"]
	if not cspaces.is_empty():
		var cspec: Array = cspaces.back()
		glyph = roundi(float(cspec[1]) * size if cspec[0] == "em" else float(cspec[1]))
	var voffs: Array = st["voffset"]
	if not voffs.is_empty() and font != null:
		var vspec: Array = voffs.back()
		var vpx := float(vspec[1]) * size if vspec[0] == "em" else float(vspec[1])
		var fh := font.get_height(size)
		if fh > 0.0:
			shift -= vpx / fh
	var f := _variant(font, bold, italic, glyph, shift, cache)
	var col := base_color
	var colors: Array = st["color"]
	if not colors.is_empty():
		col = colors.back()
	var alphas: Array = st["alpha"]
	if not alphas.is_empty():
		col.a = alphas.back()
	var pushes := 2
	rtl.push_font(f, size)
	rtl.push_color(col)
	if st["u"] > 0:
		rtl.push_underline()
		pushes += 1
	if st["s"] > 0:
		rtl.push_strikethrough()
		pushes += 1
	var marks: Array = st["mark"]
	if not marks.is_empty():
		rtl.push_bgcolor(marks.back())
		pushes += 1
	var links: Array = st["link"]
	if not links.is_empty():
		rtl.push_meta(links.back())
		pushes += 1
	rtl.add_text(text)
	for _k in pushes:
		rtl.pop()


## The base font with bold/italic/spacing/baseline applied; the base font
## itself when nothing applies. Synthetic bold and italic match
## -unity-font-style (UxmlStyleApplier._font).
static func _variant(font: Font, bold: bool, italic: bool, glyph: int, shift: float, cache: Dictionary) -> Font:
	if not bold and not italic and glyph == 0 and is_zero_approx(shift):
		return font
	var key := "%d|%d|%d|%d|%s" % [font.get_instance_id() if font != null else 0, int(bold), int(italic), glyph, shift]
	var hit = cache.get(key)
	if hit != null:
		return hit
	var fv := FontVariation.new()
	fv.base_font = font
	if bold:
		fv.variation_embolden = UxmlStyleApplier.BOLD_EMBOLDEN
	if italic:
		fv.variation_transform = UxmlStyleApplier.ITALIC_TRANSFORM
	if glyph != 0:
		fv.spacing_glyph = glyph
	if not is_zero_approx(shift):
		fv.baseline_offset = shift
	cache[key] = fv
	return fv
