class_name UssSelector
extends RefCounted
## Selector matching, specificity, and selector hygiene.
##
## Ported from vendor/uxml-preview/src/style/selector.ts and
## style/specificity.ts (Apache-2.0). Matching runs right to left and
## backtracks across descendant combinators, which is what makes
## `.a .b .c` correct when `.a` appears at several depths.
##
## Case-sensitive throughout: USS does not fold case, so `label` does not
## match a `Label`.
##
## One deliberate delta: a pseudo-class name outside SUPPORTED_PSEUDOS is
## reported by unsupported_fragment(), so the rule carrying it is dropped
## with a diagnostic instead of silently never matching.

## Pseudo-classes godot-uxml honors. `:root` names the element the stylesheet
## is attached to (a position, not a state); the rest are element states.
const SUPPORTED_PSEUDOS := [
	"hover", "active", "inactive", "focus", "checked", "disabled", "enabled", "selected", "root",
]


## `ctx` for matching is a Dictionary:
##   parents:  UxmlElement -> UxmlElement (built by the resolver)
##   states:   UxmlElement -> Dictionary of active pseudo-state -> true
##   root:     UxmlElement the `:root` pseudo refers to (stylesheet scope)
static func matches(selector: Dictionary, element: UxmlElement, ctx: Dictionary) -> bool:
	var parts: Array = selector["parts"]
	if parts.is_empty():
		return false
	return _match_from(parts, parts.size() - 1, element, ctx)


static func _match_simple(simple: Dictionary, element: UxmlElement, ctx: Dictionary) -> bool:
	match simple["kind"]:
		"universal":
			return true
		"type":
			# Type selectors name the C# class, so the namespace prefix is not
			# part of the comparison.
			return element.local == simple["name"]
		"class":
			var classes := element.class_list()
			if classes.has(simple["name"]):
				return true
			return UssControls.implicit_classes_of(element.local).has(simple["name"])
		"name":
			return element.get_attribute("name") == simple["name"]
		"pseudo":
			if simple["name"] == "root":
				return element == ctx["root"]
			var states: Dictionary = ctx["states"].get(element, {})
			# Unity: `:selected` is `:checked`; `:inactive` is not `:active`.
			match String(simple["name"]):
				"selected", "checked":
					return states.has("checked") or states.has("selected")
				"inactive":
					return not states.has("active")
			return states.has(simple["name"])
		_:
			# `unknown` selectors never reach here in practice — a rule holding
			# one is dropped before matching. False keeps that true either way.
			return false


static func _match_compound(part: Dictionary, element: UxmlElement, ctx: Dictionary) -> bool:
	for simple in part["simple"]:
		if not _match_simple(simple, element, ctx):
			return false
	return true


static func _match_from(parts: Array, index: int, element: UxmlElement, ctx: Dictionary) -> bool:
	if not _match_compound(parts[index], element, ctx):
		return false
	if index == 0:
		return true

	var parent: UxmlElement = ctx["parents"].get(element)
	if parts[index]["combinator"] == "child":
		return parent != null and _match_from(parts, index - 1, parent, ctx)

	# Descendant: any ancestor may satisfy the rest, so try each one. Without
	# backtracking `.a .b .a .b` would fail on a tree where it should match.
	var ancestor := parent
	while ancestor != null:
		if _match_from(parts, index - 1, ancestor, ctx):
			return true
		ancestor = ctx["parents"].get(ancestor)
	return false


## Specificity as [names, classes+pseudos, types]; compared left to right.
static func specificity_of(selector: Dictionary) -> Array:
	var names := 0
	var classes := 0
	var types := 0
	for part in selector["parts"]:
		for simple in part["simple"]:
			match simple["kind"]:
				"name":
					names += 1
				"class", "pseudo":
					classes += 1
				"type":
					types += 1
				_:
					# `*` adds nothing; `unknown` never reaches a match.
					pass
	return [names, classes, types]


## Negative when a loses to b, positive when it wins, 0 on a tie.
static func compare_specificity(a: Array, b: Array) -> int:
	if a[0] != b[0]:
		return a[0] - b[0]
	if a[1] != b[1]:
		return a[1] - b[1]
	return a[2] - b[2]


## State pseudo-classes a selector depends on, in source order (`:root`
## excluded — it names a position, not a state).
static func states_required_by(selector: Dictionary) -> Array:
	var out: Array = []
	for part in selector["parts"]:
		for simple in part["simple"]:
			if simple["kind"] == "pseudo" and simple["name"] != "root" and not out.has(simple["name"]):
				out.append(simple["name"])
	return out


## The first fragment in a selector group the cascade cannot honor, or "".
## `unknown` simple selectors cover `[attr]`, `::before`, `:nth-child()`,
## `+`/`~`, and malformed combinator sequences (leading/repeated/trailing
## `>` or a dangling `+`/`~`). An empty selector — `,.a` or `.a,` — counts
## too: an unparseable group member invalidates the whole rule rather than
## broadening it. An out-of-subset pseudo name reports as `:name`.
static func unsupported_fragment(selectors: Array) -> String:
	for selector in selectors:
		if selector["parts"].is_empty():
			return "(empty selector)"
		for part in selector["parts"]:
			for simple in part["simple"]:
				if simple["kind"] == "unknown":
					return simple["text"]
				if simple["kind"] == "pseudo" and not SUPPORTED_PSEUDOS.has(simple["name"]):
					return ":" + simple["name"]
	return ""


## Names/classes in a selector group aimed at Unity-internal parts, e.g.
## `#unity-text-input` — those elements are built by the control, not the file.
static func unity_fragments_in(selectors: Array) -> Array:
	var out: Array = []
	for selector in selectors:
		for part in selector["parts"]:
			for simple in part["simple"]:
				if simple["kind"] != "name" and simple["kind"] != "class":
					continue
				if not String(simple["name"]).begins_with("unity-"):
					continue
				var text: String = "#" + simple["name"] if simple["kind"] == "name" else "." + simple["name"]
				if not out.has(text):
					out.append(text)
	return out
