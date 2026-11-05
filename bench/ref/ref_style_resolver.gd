class_name RefStyleResolver
extends RefCounted
@warning_ignore_start("inference_on_variant", "unsafe_method_access", "untyped_declaration")
## The cascade: what style actually applies to each element.
##
## Ported from vendor/uxml-preview/src/style/resolve.ts (Apache-2.0), narrowed
## to document elements only — control parts and the Unity theme sheet are the
## renderer's business in the reference engine, while godot-uxml maps controls
## to native Godot nodes instead.
##
## Precedence, highest first:
##   1. the element's own `style` attribute
##   2. matching rules, by specificity, ties going to the later rule
##   3. inheritance from the parent, for the properties that inherit
##   4. the USS default — a property absent from the result is at its default
##
## resolve() output:
##   styles:   UxmlElement -> {property -> {value: String, origin: Dictionary}}
##   warnings: Array of diagnostic Dictionaries
##
## `options`:
##   active_states: Array of pseudo-states applied to every element
##   states:        {selector-text -> Array of states}; keys are matched
##                  against the tree with no states active, so a key cannot
##                  switch itself on
##   element_states:    {UxmlElement -> Array of states}; runtime-driven
##                  states (hover/focus/active/checked) applied to those
##                  elements directly — unlike `states` keys these can and
##                  do feed selectors on the element itself
##   disabled_elements: {UxmlElement -> true}; runtime SetEnabled(false) —
##                  activates :disabled on the element and its whole subtree,
##                  exactly like enabled="false" in the file

## Inline styles outrank every selector, so they get an unreachable score.
const INLINE_SPECIFICITY := [1073741824, 0, 0]

## Maximum var() recursion depth — bounded so pathological nesting cannot
## hang the resolver; exceeding it resolves the declaration as failed.
const MAX_VAR_DEPTH := 32


static func resolve(doc: UxmlDocumentModel, options: Dictionary = {}) -> Dictionary:
	var warnings: Array = []
	var parents := _build_parent_map(doc.root)
	var state_map := _build_state_map(doc, parents, options, warnings)
	var usable := _usable_rules(doc, warnings)

	var styles := {}
	_visit(doc, doc.root, {}, parents, state_map, usable, styles, warnings)
	return {"styles": styles, "warnings": warnings}


# ---------------------------------------------------------------------------
# Matching context
# ---------------------------------------------------------------------------

## Selector parents. An author child that a control keeps in its content
## container matches combinators against the control (Unity's
## VisualElement.parent; added with unity/controls-containers, the
## original resolver predates part trees).
static func _build_parent_map(root: UxmlElement) -> Dictionary:
	var map := {}
	var stack := [root]
	while not stack.is_empty():
		var node: UxmlElement = stack.pop_back()
		for child in node.children:
			var lp := UxmlParts.logical_parent(child)
			map[child] = node if lp == null else lp
			stack.append(child)
	return map


## Which pseudo-classes are active on each element.
## `enabled="false"` in the file is a state the document declares about
## itself, and it descends — Unity's SetEnabled(false) disables the subtree.
static func _build_state_map(
	doc: UxmlDocumentModel,
	parents: Dictionary,
	options: Dictionary,
	warnings: Array
) -> Dictionary:
	var global: Array = options.get("active_states", [])

	var entries: Array = []
	for key in options.get("states", {}).keys():
		var parsed := UssParser.parse_selectors(String(key))
		var bad := UssSelector.unsupported_fragment(parsed["selectors"])
		if parsed["selectors"].is_empty() or bad != "":
			warnings.append(UxmlDiagnostic.make(
				"unsupported-selector",
				'states key "%s" is not a usable USS selector; it is ignored' % key,
				doc.source, 0, doc.path
			))
			continue
		entries.append({"selectors": parsed["selectors"], "states": options["states"][key]})

	# State keys are matched with NO states active — a key can never switch
	# itself on, and the result cannot depend on its own output.
	var base_ctx := {"parents": parents, "states": {}, "root": doc.root}

	# Runtime-provided state. element_states adds pseudo-classes to specific
	# elements (the runtime knows which node is hovered; a selector key could
	# not address unnamed elements). disabled_elements is the runtime form of
	# enabled="false" and descends the same way.
	var element_states: Dictionary = options.get("element_states", {})
	var disabled_elements: Dictionary = options.get("disabled_elements", {})
	# enabled_elements is the runtime SetEnabled(true) override: it cancels
	# an enabled="false" attribute for the element itself. A disabled
	# ancestor still wins — the parent frame's flag descends unchanged.
	var enabled_elements: Dictionary = options.get("enabled_elements", {})

	var map := {}
	var stack: Array = [[doc.root, false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var node: UxmlElement = frame[0]
		var disabled: bool = (
			frame[1]
			or (not enabled_elements.has(node)
				and (node.get_attribute("enabled") == "false"
					or disabled_elements.has(node)))
		)
		var set := {}
		for s in global:
			set[s] = true
		set["disabled" if disabled else "enabled"] = true
		for s in element_states.get(node, []):
			set[s] = true
		for entry in entries:
			for sel in entry["selectors"]:
				if UssSelector.matches(sel, node, base_ctx):
					for s in entry["states"]:
						set[s] = true
					break
		map[node] = set
		for child in node.children:
			stack.append([child, disabled])
	return map


# ---------------------------------------------------------------------------
# Rules in cascade order
# ---------------------------------------------------------------------------

## Flatten every reachable sheet's rules into cascade order, splicing an
## imported sheet's rules in where the `@import` appears. Each rule carries
## the UXML subtree its sheet is attached to.
static func _cascade_order(doc: UxmlDocumentModel) -> Array:
	var out: Array = []
	var visited := {} ## scope element -> {sheet index -> true}
	for root in doc.style_roots:
		_walk_sheet(doc, root["sheet"], root["scope"], visited, out)
	return out


static func _walk_sheet(
	doc: UxmlDocumentModel,
	sheet_index: int,
	scope: UxmlElement,
	visited: Dictionary,
	out: Array
) -> void:
	if sheet_index < 0 or sheet_index >= doc.sheets.size():
		return
	var in_scope: Dictionary = visited.get(scope, {})
	if in_scope.has(sheet_index):
		return
	in_scope[sheet_index] = true
	visited[scope] = in_scope

	var sheet: Dictionary = doc.sheets[sheet_index]
	for i in sheet["items"].size():
		var item: Dictionary = sheet["items"][i]
		if item["kind"] == "rule":
			out.append({"rule": item["rule"], "sheet": sheet_index, "item": i, "scope": scope})
		elif item["kind"] == "import" and item["resolved_sheet"] >= 0:
			_walk_sheet(doc, item["resolved_sheet"], scope, visited, out)


## Rules that can match: unsupported fragments drop the whole rule with one
## diagnostic per rule — never a silent universal match.
static func _usable_rules(doc: UxmlDocumentModel, warnings: Array) -> Array:
	var usable: Array = []
	var reported_root := false
	for flat in _cascade_order(doc):
		var bad := UssSelector.unsupported_fragment(flat["rule"]["selectors"])
		if bad != "":
			warnings.append(UxmlDiagnostic.make(
				"unsupported-selector",
				'"%s" is not supported in USS; the whole rule is ignored' % bad,
				_sheet_source(doc, flat["sheet"]),
				flat["rule"]["selector_span"]["start"],
				_sheet_origin(doc, flat["sheet"])
			))
			continue
		if not reported_root and _has_root_pseudo(flat["rule"]):
			reported_root = true
			warnings.append(UxmlDiagnostic.make(
				"version-dependent",
				":root in USS names the element the stylesheet was applied to, not the document root as in CSS",
				_sheet_source(doc, flat["sheet"]),
				flat["rule"]["selector_span"]["start"],
				_sheet_origin(doc, flat["sheet"])
			))
		usable.append(flat)
	return usable


static func _has_root_pseudo(rule: Dictionary) -> bool:
	for sel in rule["selectors"]:
		for part in sel["parts"]:
			for simple in part["simple"]:
				if simple["kind"] == "pseudo" and simple["name"] == "root":
					return true
	return false


static func _sheet_source(doc: UxmlDocumentModel, index: int) -> String:
	if index < 0 or index >= doc.sheets.size():
		return ""
	return doc.sheets[index]["source"]


static func _sheet_origin(doc: UxmlDocumentModel, index: int) -> String:
	if index < 0 or index >= doc.sheets.size():
		return ""
	return doc.sheets[index]["origin"]


static func _is_within_scope(element: UxmlElement, scope: UxmlElement, parents: Dictionary) -> bool:
	var current: UxmlElement = element
	while current != null:
		if current == scope:
			return true
		current = parents.get(current)
	return false


# ---------------------------------------------------------------------------
# Per-element computation
# ---------------------------------------------------------------------------

static func _visit(
	doc: UxmlDocumentModel,
	node: UxmlElement,
	inherited: Dictionary,
	parents: Dictionary,
	state_map: Dictionary,
	usable: Array,
	styles: Dictionary,
	warnings: Array
) -> void:
	var result := _compute_for(doc, node, inherited, parents, state_map, usable, warnings)
	styles[node] = result["computed"]
	for child in node.children:
		_visit(doc, child, result["for_children"], parents, state_map, usable, styles, warnings)


## Every declaration reaching one element, in cascade order. Declarations
## are NOT shorthand-expanded here: a var() reference must be substituted
## before expansion (`padding: var(--pad)` expands the resolved token list,
## not the literal text "var(--pad)"), and substitution needs the winning
## custom properties, which are only known once the declaration-level
## cascade has run.
static func _collect_candidates(
	doc: UxmlDocumentModel,
	node: UxmlElement,
	parents: Dictionary,
	state_map: Dictionary,
	usable: Array
) -> Array:
	var out: Array = []
	var order := 0
	var ctx := {"parents": parents, "states": state_map, "root": null}

	for flat in usable:
		var scope: UxmlElement = flat["scope"]
		if scope != null and not _is_within_scope(node, scope, parents):
			continue
		# USS :root names the element this particular stylesheet is attached to.
		ctx["root"] = scope
		# A rule contributes once however many selectors match, at the
		# specificity of the *most specific* one that matched.
		var specificity = null
		var states: Array = []
		for sel in flat["rule"]["selectors"]:
			if not UssSelector.matches(sel, node, ctx):
				continue
			var candidate := UssSelector.specificity_of(sel)
			if specificity == null or UssSelector.compare_specificity(candidate, specificity) > 0:
				specificity = candidate
				states = UssSelector.states_required_by(sel)
		if specificity == null:
			continue
		var rule: Dictionary = flat["rule"]
		for decl_index in rule["declarations"].size():
			var decl: Dictionary = rule["declarations"][decl_index]
			var origin := {
				"kind": "rule",
				"sheet": flat["sheet"],
				"item": flat["item"],
				"decl_index": decl_index,
				"file": _sheet_origin(doc, flat["sheet"]),
			}
			if not states.is_empty():
				origin["states"] = states.duplicate()
			out.append({
				"property": decl["property"],
				"value": decl["value"],
				"origin": origin,
				"specificity": specificity,
				"order": order,
			})
			order += 1

	# Inline style outranks every selector.
	var style_attr = node.get_attribute("style")
	if style_attr != null:
		var parsed := UssParser.parse_declarations(String(style_attr))
		for decl_index in parsed["declarations"].size():
			var decl: Dictionary = parsed["declarations"][decl_index]
			out.append({
				"property": decl["property"],
				"value": decl["value"],
				"origin": {"kind": "inline", "decl_index": decl_index},
				"specificity": INLINE_SPECIFICITY,
				"order": order,
			})
			order += 1
		for problem in parsed["problems"]:
			out.append({"problem": problem})
	return out


static func _wins(candidate: Dictionary, current: Dictionary) -> bool:
	var by_spec := UssSelector.compare_specificity(candidate["specificity"], current["specificity"])
	return by_spec > 0 or (by_spec == 0 and candidate["order"] > current["order"])


static func _compute_for(
	doc: UxmlDocumentModel,
	node: UxmlElement,
	inherited: Dictionary,
	parents: Dictionary,
	state_map: Dictionary,
	usable: Array,
	warnings: Array
) -> Dictionary:
	var candidates := _collect_candidates(doc, node, parents, state_map, usable)

	# Report malformed inline declarations (the `problem` markers above).
	var clean: Array = []
	for c in candidates:
		if c.has("problem"):
			var p: Dictionary = c["problem"]
			warnings.append(UxmlDiagnostic.make(
				"malformed",
				'style attribute of <%s>: %s' % [node.tag(), p["message"]],
				doc.source, node.open_tag_start, doc.path
			))
		else:
			clean.append(c)

	# Custom properties are decided by the same declaration-level cascade
	# (specificity, then source order). The winning --* values are kept raw
	# in `customs` — references between custom properties resolve lazily
	# during substitution, which is also what detects cycles.
	var customs := {}
	for property in inherited:
		if property.begins_with("--"):
			customs[property] = inherited[property]["value"]
	var custom_winners := {}
	for candidate in clean:
		var property: String = candidate["property"]
		if not property.begins_with("--"):
			continue
		var current = custom_winners.get(property)
		if current == null or _wins(candidate, current):
			custom_winners[property] = candidate
	for property in custom_winners:
		customs[property] = custom_winners[property]["value"]

	# Substitute var() on each declaration, THEN expand shorthands. A
	# declaration whose var() cannot resolve is marked failed: it still
	# competes (expanding to placeholder longhands), so a losing-but-valid
	# declaration cannot revive a property the cascade already gave away —
	# matching CSS "invalid at computed-value time" semantics.
	#
	# Custom-property declarations seed `seen` with their own name: a
	# reference back to the property being resolved is a dependency cycle,
	# and the property is guaranteed-invalid — a fallback inside its own
	# declaration cannot rescue it.
	var expanded: Array = []
	for candidate in clean:
		var property: String = candidate["property"]
		var seed := {}
		if property.begins_with("--"):
			seed[property] = true
		var substituted = _substitute_vars(candidate["value"], customs, seed)
		var failed: bool = substituted == null or _is_cycle(substituted)
		var raw: String = candidate["value"] if failed else String(substituted)
		var pairs: Array = UssProperties.expand_shorthand(property, raw)
		if pairs.is_empty():
			# Arity outside the shorthand grammar (e.g. `gap: 1px 2px 3px`):
			# the declaration is invalid at parse time and contributes no
			# longhands — an earlier valid declaration still wins.
			warnings.append(UxmlDiagnostic.make(
				"invalid-shorthand",
				"%s: %s -- wrong number of values; declaration dropped" % [property, raw],
				doc.source, node.open_tag_start, doc.path
			))
		for pair in pairs:
			var longhand: Dictionary = candidate.duplicate()
			longhand["property"] = pair[0]
			longhand["value"] = pair[1]
			longhand["failed"] = failed
			expanded.append(longhand)

	# Winning candidate per property: specificity, then source order.
	var best := {}
	for candidate in expanded:
		var property: String = candidate["property"]
		var current = best.get(property)
		if current == null or _wins(candidate, current):
			best[property] = candidate

	var computed := inherited.duplicate()
	var unsupported := {}
	for property in best:
		var candidate: Dictionary = best[property]
		if candidate["failed"]:
			warnings.append(UxmlDiagnostic.make(
				"unresolved-var",
				"%s: var() reference could not be resolved; declaration dropped" % property,
				doc.source, node.open_tag_start, doc.path
			))
			continue
		computed[property] = {"value": candidate["value"], "origin": candidate["origin"]}
		if not UssProperties.is_supported(property) and not unsupported.has(property):
			unsupported[property] = true
			warnings.append(UxmlDiagnostic.make(
				"unsupported-property",
				'"%s" is not a supported USS property; the value is kept but has no effect' % property,
				doc.source, node.open_tag_start, doc.path
			))

	# A direct declaration always beats an inherited one, so children are
	# handed these final values rather than a merge of anything else.
	var for_children := {}
	for property in computed:
		if not UssProperties.is_inherited(property):
			continue
		for_children[property] = {
			"value": computed[property]["value"],
			"origin": {"kind": "inherited", "from": node, "origin": computed[property]["origin"]},
		}
	return {"computed": computed, "for_children": for_children}


## Substitute `var(--x)` against the custom properties in scope.
##
## Semantics (CSS Variables level 1, css-variables-1):
## - A var() whose referenced custom property does not exist OR is invalid
##   at computed-value time substitutes its fallback, if any; otherwise the
##   declaration is invalid and returns null here.
## - A custom property in a dependency cycle is guaranteed-invalid. When a
##   reference closes the cycle back into the resolution chain, the marker
##   {"_cycle": name} propagates upward — every property on that chain is
##   in the cycle, so fallbacks inside THEIR declarations cannot rescue
##   them. At a use site outside the cycle the same reference just means
##   "referenced property is invalid", and the use-site fallback applies.
## - Unterminated `var(`, and a first argument that is not a
##   custom-property name, are malformed: the declaration returns null —
##   the text never survives as a "value".
##
## `var(` is located by a balanced-parenthesis scan (brackets and quoted
## strings are tracked), so fallbacks may themselves contain var(), commas
## inside functions like rgb(), or quoted text:
##   var(--missing, var(--base, 8px))   -> "8px" when both are absent
##   var(--missing, rgb(1, 2, 3))       -> "rgb(1, 2, 3)"
##
## Bounded: recursion is capped by MAX_VAR_DEPTH and the outer loop allows
## at most MAX_VAR_DEPTH substitutions per value; exceeding either fails
## the declaration (diagnosed upstream as unresolved-var).
##
## `seen` is the set of custom properties whose resolution is in progress
## on this chain. Callers resolving a custom property's own declaration
## seed it with that property's name so self-references close the cycle.
static func _substitute_vars(
	value: String,
	lookup: Dictionary,
	seen: Dictionary = {},
	depth: int = 0
) -> Variant:
	if depth > MAX_VAR_DEPTH:
		return null
	var out := value
	for _guard in MAX_VAR_DEPTH:
		var start := out.find("var(")
		if start < 0:
			return out
		var close := _matching_paren(out, start + 3)
		if close < 0:
			return null # unterminated var(

		var inner := out.substr(start + 4, close - start - 4)
		var comma := _top_level_comma(inner)
		var name := (inner if comma < 0 else inner.substr(0, comma)).strip_edges()
		var fallback := "" if comma < 0 else inner.substr(comma + 1).strip_edges()
		if name.length() <= 2 or not name.begins_with("--"):
			return null # var() needs a custom-property name

		if seen.has(name):
			return {"_cycle": name}
		var nested := seen.duplicate()
		nested[name] = true

		# A referenced property that fails to resolve for any reason —
		# missing, malformed, or guaranteed-invalid through a cycle — is
		# invalid, and the use-site fallback applies. The one exception:
		# the failure closed a cycle back into THIS chain, in which case
		# the property being resolved is itself cyclic and must fail.
		var replacement = null
		if lookup.has(name):
			replacement = _substitute_vars(String(lookup[name]), lookup, nested, depth + 1)
			if _is_cycle(replacement):
				if seen.has(replacement["_cycle"]):
					return replacement
				replacement = null
		if replacement == null and not fallback.is_empty():
			replacement = _substitute_vars(fallback, lookup, nested, depth + 1)
			if _is_cycle(replacement):
				if seen.has(replacement["_cycle"]):
					return replacement
				replacement = null
		if replacement == null:
			return null

		out = out.substr(0, start) + String(replacement) + out.substr(close + 1)
	return null


## True when a _substitute_vars result is the cycle marker rather than a
## value (String) or an invalid reference (null).
static func _is_cycle(result: Variant) -> bool:
	return result is Dictionary and result.has("_cycle")


## Index of the ')' matching the '(' at open_idx, tracking quotes and
## nested brackets. -1 when unbalanced.
static func _matching_paren(text: String, open_idx: int) -> int:
	var depth := 1
	var i := open_idx + 1
	while i < text.length():
		var c := text.unicode_at(i)
		if c == 34 or c == 39:
			var close := UssParser._find_quote_close(text, i)
			if close < 0:
				return -1
			i = close
			continue
		if c == 40: # '('
			depth += 1
		elif c == 41: # ')'
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


## Index of the first ',' at bracket depth 0 outside quotes, or -1.
static func _top_level_comma(text: String) -> int:
	var depth := 0
	var i := 0
	while i < text.length():
		var c := text.unicode_at(i)
		if c == 34 or c == 39:
			var close := UssParser._find_quote_close(text, i)
			if close < 0:
				return -1
			i = close
			continue
		if c == 40 or c == 91: # '(' or '['
			depth += 1
		elif c == 41 or c == 93: # ')' or ']'
			if depth > 0:
				depth -= 1
		elif c == 44 and depth == 0: # ','
			return i
		i += 1
	return -1
