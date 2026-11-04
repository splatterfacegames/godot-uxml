class_name UssStyleResolver
extends RefCounted
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
	# The cascade itself lives in UssCascade (compiled rules, bucketed
	# matching, incremental updates); a one-shot resolve is a fresh cascade
	# with every element computed.
	var c := UssCascade.new(doc)
	c.update(options, true)
	return {"styles": c.styles, "warnings": c.collect_warnings()}


# ---------------------------------------------------------------------------
# Rules in cascade order
# ---------------------------------------------------------------------------

## Flatten every reachable sheet's rules into cascade order, splicing an
## imported sheet's rules in where the `@import` appears. Each rule carries
## the UXML subtree its sheet is attached to.
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


# ---------------------------------------------------------------------------
# var() substitution (shared with UssCascade)
# ---------------------------------------------------------------------------

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
