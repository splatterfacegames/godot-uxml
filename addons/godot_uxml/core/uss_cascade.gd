class_name UssCascade
extends RefCounted
## Compiled, incremental USS cascade.
##
## Same semantics (and the same output Dictionaries, key order and
## diagnostics) as the original per-resolve UssStyleResolver walk — see that
## file for the precedence rules — but built for speed:
##
##   * every usable rule is compiled ONCE per document: selectors become
##     flat compound records with an integer specificity key, declarations
##     carry precomputed custom/var flags and their static shorthand
##     expansion, and selectors are bucketed by their rightmost compound's
##     most selective key (#name > .class > Type > universal) so an element
##     only ever tests rules that could possibly match it;
##   * elements live in preorder-indexed packed arrays (parent, subtree
##     end) so ancestor walks and scope checks are integer operations;
##   * the cascade is incremental across update() calls: an element is only
##     recomputed when its own inputs changed (class/name/style attribute,
##     pseudo-state bits), its parent handed it different inherited values,
##     or an ancestor changed a feature some rule tests in a NON-rightmost
##     compound (descendant/child selectors). Everything else keeps its
##     previous result object.
##
## Readability is deliberately traded for speed here; the reference
## semantics live in docs/design.md and the resolver's comments.

const STATE_BITS := {
	"hover": 1, "active": 2, "inactive": 4, "focus": 8,
	"checked": 16, "disabled": 32, "enabled": 64, "selected": 128,
}
const BIT_DISABLED := 32
const BIT_ENABLED := 64
## Inline declarations outrank every selector: above any packed rule key.
const INLINE_SPEC := 1 << 62

const F_CUSTOM := 1
const F_VAR := 2

var doc: UxmlDocumentModel

# --- compiled rules -------------------------------------------------------
var _rule_scope_idx: PackedInt32Array   # preorder index of the scope element, -1 none/unknown
var _rule_scope_lo: PackedInt32Array    # scope subtree [lo, hi) or (-1,-1) → nothing in tree; lo=-2 → no scope
var _rule_scope_hi: PackedInt32Array
var _rule_sheet: PackedInt32Array
var _rule_item: PackedInt32Array
var _rule_file: PackedStringArray
var _rule_dprop: Array = []            # per rule PackedStringArray
var _rule_dval: Array = []             # per rule PackedStringArray
var _rule_dflag: Array = []            # per rule PackedInt32Array
var _rule_dexp: Array = []             # per rule Array (static expansion or null)
var _sel_rule: PackedInt32Array
var _sel_spec: PackedInt64Array
var _sel_parts: Array = []             # per selector: Array of compound records (rightmost last)
var _sel_states: Array = []            # per selector: Array of state names (origin "states")
var _sel_origins: Array = []           # per selector: lazily built Array of origin dicts per decl
var _b_name := {}
var _b_class := {}
var _b_type := {}
var _b_any := PackedInt32Array()
# Features some rule tests in a non-rightmost compound: a change to one of
# these on an element can change its descendants' matches.
var _anc_classes := {}
var _anc_names := {}
var _anc_states := 0
var _rule_warnings: Array = []

# --- element index --------------------------------------------------------
var els: Array = []                    # preorder UxmlElement list
var index := {}                        # UxmlElement -> preorder index
var _parent: PackedInt32Array
var _end: PackedInt32Array             # subtree end (exclusive)
var _local: PackedStringArray
var _cls_set: Array = []               # per element Dictionary class -> true (explicit + implicit)
var _name: Array = []                  # per element name attribute (null when absent)

# --- per-element cached state --------------------------------------------
var _sig_cls: Array = []
var _sig_name: Array = []
var _sig_style: Array = []
var _sig_bits: PackedInt32Array
var _anc_key: Array = []
var _fc: Array = []                    # for_children Dictionary per element
var _fc_customs: Array = []            # [id, custom-property map of _fc] (shared, read-only)
var _bloom: PackedInt64Array           # per element: feature bits of all its ancestors
var _own_bloom: PackedInt64Array       # per element: its own class/name/type bits
var _sel_need: PackedInt64Array        # per selector: bits its non-rightmost compounds need
var _sel_entries: Array = []           # per selector: lazily shared computed entries
var _subst: Dictionary = {}            # customs id -> {value -> substituted (false = failed)}
var _next_cid := 1
const _EMPTY_CP := [0, {}]
static var _empty_fc := {}
var _warn: Array = []                  # per element warnings
var _arefs: Array = []                 # per element attribute refs (see _attr_refs)
var _sig_en: Array = []                # per element `enabled` attribute value (or null)
var _last_changed := PackedInt32Array()
var _own_none := PackedByteArray()
var _eff_dis := PackedByteArray()
var _eff_gone := PackedByteArray()
var _computed_once := false
## Previous computed Dictionary for each index update() returned (aligned).
var last_old: Array = []
var _opt_warnings: Array = []
# Computed overrides (USS transitions, runtime/uss_transitions.gd): per
# preorder index, {property: {value, origin}} entries written over the
# cascade result at the end of _compute, so inheritance, layout and the
# style applier all see the animated value. _tgt keeps the result before
# the overrides (the transition target); _ov_force lists the indices whose
# overrides changed since the last update (recomputed even when clean).
var _ov := {}
var _tgt := {}
var _ov_force := PackedInt32Array()

## UxmlElement -> computed style (property -> {value, origin}), preorder.
var styles := {}

static var _inline_cache := {}         # style attribute text -> [records..., problems]
static var _exp_cache := {}            # property -> {raw -> expansion}
static var _inherited_cache := {}
static var _supported_cache := {}
static var _inline_origins: Array = []


## Use the native backend (godot_uxml_native GDExtension) when it is
## loaded. The GDScript path below stays the reference implementation and
## the fallback on platforms without the binary; set false to force it.
static var use_native := true
var _native: Object = null


func _init(p_doc: UxmlDocumentModel) -> void:
	doc = p_doc
	_index_tree()
	_compile_rules()
	if use_native and ClassDB.class_exists("UxmlNativeCascade"):
		var nc: Object = ClassDB.instantiate("UxmlNativeCascade")
		if nc.call("setup", self, {
			"subst": func(v: String, customs: Dictionary, seed_prop: String):
				return UssStyleResolver._substitute_vars(
					v, customs, {} if seed_prop.is_empty() else {seed_prop: true}),
			"expand": func(prop: String, raw: String): return UssCascade._expand(prop, raw),
			"inline": func(text: String): return UssCascade._inline(text),
			"inherited": UssProperties.INHERITED,
			"supported": UssProperties.SUPPORTED,
			"implicit": UssControls.IMPLICIT_CLASSES,
		}):
			_native = nc


# ---------------------------------------------------------------------------
# Element index
# ---------------------------------------------------------------------------

func _index_tree() -> void:
	var stack: Array = [doc.root]
	var parents: Array = [-1]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		var p: int = parents.pop_back()
		var i := els.size()
		els.append(el)
		index[el] = i
		_parent.append(p)
		_local.append(el.local)
		var ch: Array = el.children
		var k := ch.size() - 1
		while k >= 0:
			stack.append(ch[k])
			parents.append(i)
			k -= 1
	var n := els.size()
	_end.resize(n)
	for i in n:
		_end[i] = i + 1
	var i2 := n - 1
	while i2 > 0:
		var p2 := _parent[i2]
		if _end[i2] > _end[p2]:
			_end[p2] = _end[i2]
		i2 -= 1
	_cls_set.resize(n)
	_name.resize(n)
	_sig_cls.resize(n)
	_sig_name.resize(n)
	_sig_style.resize(n)
	_sig_bits.resize(n)
	_anc_key.resize(n)
	_fc.resize(n)
	_fc_customs.resize(n)
	_bloom.resize(n)
	_own_bloom.resize(n)
	_warn.resize(n)
	_arefs.resize(n)
	_sig_en.resize(n)


# ---------------------------------------------------------------------------
# Rule compilation (once per document)
# ---------------------------------------------------------------------------

func _compile_rules() -> void:
	var reported_root := false
	var visited := {}
	var flat: Array = []
	for root in doc.style_roots:
		UssStyleResolver._walk_sheet(doc, root["sheet"], root["scope"], visited, flat)
	for f in flat:
		var rule: Dictionary = f["rule"]
		var bad := UssSelector.unsupported_fragment(rule["selectors"])
		if bad != "":
			_rule_warnings.append(UxmlDiagnostic.make(
				"unsupported-selector",
				'"%s" is not supported in USS; the whole rule is ignored' % bad,
				UssStyleResolver._sheet_source(doc, f["sheet"]),
				rule["selector_span"]["start"],
				UssStyleResolver._sheet_origin(doc, f["sheet"])
			))
			continue
		if not reported_root and UssStyleResolver._has_root_pseudo(rule):
			reported_root = true
			_rule_warnings.append(UxmlDiagnostic.make(
				"version-dependent",
				":root in USS names the element the stylesheet was applied to, not the document root as in CSS",
				UssStyleResolver._sheet_source(doc, f["sheet"]),
				rule["selector_span"]["start"],
				UssStyleResolver._sheet_origin(doc, f["sheet"])
			))
		_add_rule(f)


func _add_rule(f: Dictionary) -> void:
	var r := _rule_sheet.size()
	var rule: Dictionary = f["rule"]
	var scope: UxmlElement = f["scope"]
	_rule_sheet.append(f["sheet"])
	_rule_item.append(f["item"])
	_rule_file.append(UssStyleResolver._sheet_origin(doc, f["sheet"]))
	if scope == null:
		_rule_scope_idx.append(-1)
		_rule_scope_lo.append(-2)
		_rule_scope_hi.append(-2)
	else:
		var si: int = index.get(scope, -1)
		_rule_scope_idx.append(si)
		_rule_scope_lo.append(si)
		_rule_scope_hi.append(_end[si] if si >= 0 else -1)

	var dp := PackedStringArray()
	var dv := PackedStringArray()
	var df := PackedInt32Array()
	var de: Array = []
	for decl in rule["declarations"]:
		var prop: String = decl["property"]
		var val: String = decl["value"]
		dp.append(prop)
		dv.append(val)
		var fl := 0
		if prop.begins_with("--"):
			fl |= F_CUSTOM
		if val.find("var(") >= 0:
			fl |= F_VAR
			de.append(null)
		else:
			de.append(_expand(prop, val))
		df.append(fl)
	_rule_dprop.append(dp)
	_rule_dval.append(dv)
	_rule_dflag.append(df)
	_rule_dexp.append(de)

	for sel in rule["selectors"]:
		var s := _sel_rule.size()
		_sel_rule.append(r)
		var parts: Array = []
		var names := 0
		var classes := 0
		var types := 0
		var sel_parts: Array = sel["parts"]
		for pi in sel_parts.size():
			var part: Dictionary = sel_parts[pi]
			var ptypes := PackedStringArray()
			var pnames := PackedStringArray()
			var pclasses := PackedStringArray()
			var mask := 0
			var root := false
			for simple in part["simple"]:
				match simple["kind"]:
					"type":
						ptypes.append(simple["name"])
						types += 1
					"name":
						pnames.append(simple["name"])
						names += 1
					"class":
						pclasses.append(simple["name"])
						classes += 1
					"pseudo":
						classes += 1
						if simple["name"] == "root":
							root = true
						else:
							mask |= int(STATE_BITS[simple["name"]])
			var is_child: bool = part["combinator"] == "child"
			parts.append([ptypes, pnames, pclasses, mask, root, is_child])
			if pi < sel_parts.size() - 1:
				for c in pclasses:
					_anc_classes[c] = true
				for nm in pnames:
					_anc_names[nm] = true
				_anc_states |= mask
		_sel_parts.append(parts)
		var need := 0
		for pi2 in parts.size() - 1:
			var cp2: Array = parts[pi2]
			for x in cp2[0]:
				need |= _fbits("<" + x)
			for x in cp2[1]:
				need |= _fbits("#" + x)
			for x in cp2[2]:
				need |= _fbits("." + x)
		_sel_need.append(need)
		_sel_entries.append(null)
		_sel_spec.append((names << 40) | (classes << 20) | types)
		_sel_states.append(UssSelector.states_required_by(sel))
		_sel_origins.append(null)
		var right: Array = parts[parts.size() - 1]
		if not (right[1] as PackedStringArray).is_empty():
			_bucket_add(_b_name, right[1][0], s)
		elif not (right[2] as PackedStringArray).is_empty():
			_bucket_add(_b_class, right[2][0], s)
		elif not (right[0] as PackedStringArray).is_empty():
			_bucket_add(_b_type, right[0][0], s)
		else:
			_b_any.append(s)


## Two bloom-filter bits for a feature key ("<Type", "#name", ".class").
static func _fbits(key: String) -> int:
	var h := key.hash()
	return (1 << (h & 63)) | (1 << ((h >> 6) & 63))


func _own_bits(i: int) -> int:
	var b := _fbits("<" + _local[i])
	var nm = _name[i]
	if nm != null:
		b |= _fbits("#" + String(nm))
	for c in _cls_set[i]:
		b |= _fbits("." + String(c))
	return b


static func _bucket_add(b: Dictionary, key: String, s: int) -> void:
	var l: PackedInt32Array = b.get(key, PackedInt32Array())
	l.append(s)
	b[key] = l


static func _expand(prop: String, raw: String) -> Array:
	var per: Dictionary = _exp_cache.get(prop, {})
	var hit = per.get(raw)
	if hit != null:
		return hit
	var out := UssProperties.expand_shorthand(prop, raw)
	per[raw] = out
	_exp_cache[prop] = per
	return out


static func _is_inherited(prop: String) -> bool:
	var v = _inherited_cache.get(prop)
	if v == null:
		v = UssProperties.is_inherited(prop)
		_inherited_cache[prop] = v
	return v


static func _is_supported(prop: String) -> bool:
	var v = _supported_cache.get(prop)
	if v == null:
		v = UssProperties.is_supported(prop)
		_supported_cache[prop] = v
	return v


## Origin dicts for selector `s` (one per declaration of its rule) — shared
## by every element the selector wins on.
func _origins_for(s: int) -> Array:
	var o = _sel_origins[s]
	if o != null:
		return o
	var r := _sel_rule[s]
	var states: Array = _sel_states[s]
	var out: Array = []
	var nd := (_rule_dprop[r] as PackedStringArray).size()
	for d in nd:
		var origin := {
			"kind": "rule",
			"sheet": _rule_sheet[r],
			"item": _rule_item[r],
			"decl_index": d,
			"file": _rule_file[r],
		}
		if not states.is_empty():
			origin["states"] = states.duplicate()
		out.append(origin)
	_sel_origins[s] = out
	return out


## Shared computed entries for selector `s`: per declaration, an Array of
## {value, origin} per static shorthand expansion pair (null for var()
## declarations, which are substituted per element).
func _entries_for(s: int, origins: Array) -> Array:
	var e = _sel_entries[s]
	if e != null:
		return e
	var r := _sel_rule[s]
	var de: Array = _rule_dexp[r]
	var out: Array = []
	for d in de.size():
		var pairs = de[d]
		if pairs == null:
			out.append(null)
			continue
		var lst: Array = []
		for pair in pairs:
			lst.append({"value": pair[1], "origin": origins[d]})
		out.append(lst)
	_sel_entries[s] = out
	return out


static func _inline_origin(d: int) -> Dictionary:
	while _inline_origins.size() <= d:
		_inline_origins.append({"kind": "inline", "decl_index": _inline_origins.size()})
	return _inline_origins[d]


## Parsed inline style: [props, vals, flags, exps, problems]. Cached by text
## (parse_declarations is pure).
static func _inline(text: String) -> Array:
	var hit = _inline_cache.get(text)
	if hit != null:
		return hit
	var parsed := UssParser.parse_declarations(text)
	var dp := PackedStringArray()
	var dv := PackedStringArray()
	var df := PackedInt32Array()
	var de: Array = []
	for decl in parsed["declarations"]:
		var prop: String = decl["property"]
		var val: String = decl["value"]
		dp.append(prop)
		dv.append(val)
		var fl := 0
		if prop.begins_with("--"):
			fl |= F_CUSTOM
		if val.find("var(") >= 0:
			fl |= F_VAR
			de.append(null)
		else:
			de.append(_expand(prop, val))
		df.append(fl)
	var out := [dp, dv, df, de, parsed["problems"]]
	if _inline_cache.size() > 4096:
		_inline_cache.clear()
	_inline_cache[text] = out
	return out


# ---------------------------------------------------------------------------
# State keys (the resolver's `states` option — rare, kept on the slow path)
# ---------------------------------------------------------------------------

## Per-element bits contributed by `states` selector keys, matched with NO
## states active (a key never switches itself on) and root = document root.
## Empty when the option is absent.
func _key_bits(options: Dictionary) -> PackedInt32Array:
	var key_bits := PackedInt32Array()
	var states_opt: Dictionary = options.get("states", {})
	if states_opt.is_empty():
		return key_bits
	var n := els.size()
	key_bits.resize(n)
	var entries: Array = []
	for key in states_opt.keys():
		var parsed := UssParser.parse_selectors(String(key))
		var bad := UssSelector.unsupported_fragment(parsed["selectors"])
		if parsed["selectors"].is_empty() or bad != "":
			_opt_warnings.append(UxmlDiagnostic.make(
				"unsupported-selector",
				'states key "%s" is not a usable USS selector; it is ignored' % key,
				doc.source, 0, doc.path
			))
			continue
		var m := 0
		for s in states_opt[key]:
			m |= int(STATE_BITS.get(s, 0))
		entries.append([parsed["selectors"], m])
	if not entries.is_empty():
		var parents := {}
		for i in range(1, n):
			parents[els[i]] = els[_parent[i]]
		var base_ctx := {"parents": parents, "states": {}, "root": doc.root}
		for i in n:
			var node: UxmlElement = els[i]
			for entry in entries:
				for sel in entry[0]:
					if UssSelector.matches(sel, node, base_ctx):
						key_bits[i] |= entry[1]
						break
	return key_bits


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

## The attribute Dictionaries an element's cascade inputs live in:
## [attributes Array, size, class, name, style, enabled] (each the FIRST
## attribute of that name, like get_attribute, or null). Values are read
## through these on every update, so in-place value edits (set_class, or
## game code writing the model) are seen; the record is rebuilt whenever
## the attributes Array is replaced or changes size.
func _attr_refs(el: UxmlElement) -> Array:
	var c = null
	var nm = null
	var st = null
	var en = null
	for a in el.attributes:
		var an: String = a["name"]
		if an == "class":
			if c == null:
				c = a
		elif an == "name":
			if nm == null:
				nm = a
		elif an == "style":
			if st == null:
				st = a
		elif an == "enabled":
			if en == null:
				en = a
	return [el.attributes, el.attributes.size(), c, nm, st, en]


## Recompute every element whose result could have changed (all of them
## when `force` or on the first call). Returns the preorder indices whose
## computed style Dictionary differs from the previous one (previous
## Dictionaries in `last_old`, aligned); `styles` holds the new results.
##
## One preorder pass does everything: read the element's cascade inputs,
## derive its pseudo-state bits (disabled descends from the parent, which
## is already done), decide whether it is dirty, and recompute it.
## Matching only ever looks at the element and its ancestors, all of which
## are final by the time the element is reached.
##
## `dirty`: null re-reads every element's attributes (the safe default — sees
## any model edit); a PackedInt32Array of preorder indices re-reads only
## those, everything else keeps the values read last time (the runtime
## passes the elements whose UxmlElement.changed fired).
##
## `only_forced`: the caller guarantees that nothing but computed overrides
## changed since the last update (same options, no attribute edits) — only
## the subtrees of elements whose overrides changed are visited, so a
## transition frame does not scan the whole document.
func update(options: Dictionary = {}, force: bool = false, dirty = null, only_forced: bool = false) -> PackedInt32Array:
	if _native != null:
		_opt_warnings = []
		var kb := _key_bits(options)
		var dl := PackedInt32Array() if dirty == null else PackedInt32Array(dirty)
		var ch: PackedInt32Array = _native.call("update", options, force, kb, styles, dirty == null, dl, only_forced)
		last_old = _native.call("last_old")
		_computed_once = true
		return ch
	var n := els.size()
	_opt_warnings = []
	var global := 0
	for s in options.get("active_states", []):
		global |= int(STATE_BITS.get(s, 0))
	var key_bits := _key_bits(options)
	var has_keys := not key_bits.is_empty()
	# Own-disabled overrides by index: 1 = runtime disabled, 2 = runtime
	# SetEnabled(true) (cancels the attribute; written last so it wins).
	var dis_ov := {}
	for el in options.get("disabled_elements", {}):
		var i = index.get(el)
		if i != null:
			dis_ov[i] = 1
	for el in options.get("enabled_elements", {}):
		var i = index.get(el)
		if i != null:
			dis_ov[i] = 2
	var es_bits := {}
	var es: Dictionary = options.get("element_states", {})
	for el in es:
		var i = index.get(el)
		if i == null:
			continue
		var m := 0
		for s in es[el]:
			m |= int(STATE_BITS.get(s, 0))
		es_bits[i] = m

	var full := force or not _computed_once
	var scan_all: bool = full or dirty == null
	var reread := PackedByteArray()
	if not scan_all:
		reread.resize(n)
		for di in dirty:
			reread[di] = 1
	var has_ov := not dis_ov.is_empty()
	var has_es := not es_bits.is_empty()
	var forced := PackedByteArray()
	var has_forced := not _ov_force.is_empty()
	# Visited index ranges [lo, hi) when only overrides changed.
	var ranges := PackedInt32Array()
	var use_ranges: bool = only_forced and _computed_once and not force
	if has_forced:
		forced.resize(n)
		var fs := PackedInt32Array()
		for fi in _ov_force:
			if fi >= 0 and fi < n:
				forced[fi] = 1
				fs.append(fi)
		_ov_force = PackedInt32Array()
		if use_ranges:
			fs.sort()
			for fi in fs:
				if not ranges.is_empty() and fi < ranges[ranges.size() - 1]:
					continue  # inside the previous subtree
				ranges.append(fi)
				ranges.append(_end[fi])
	var nr := ranges.size() / 2
	var ri := 0
	var changed := PackedInt32Array()
	last_old = []
	var inh_dirty := PackedByteArray()
	inh_dirty.resize(n)
	var anc_until := -1
	var i := -1
	while true:
		i += 1
		if use_ranges:
			while ri < nr and i >= ranges[ri * 2 + 1]:
				ri += 1
			if ri >= nr:
				break
			if i < ranges[ri * 2]:
				i = ranges[ri * 2]
		elif i >= n:
			break
		var el: UxmlElement = els[i]
		var c
		var nm
		var st
		var en
		if scan_all or reread[i] == 1:
			var r = _arefs[i]
			var attrs: Array = el.attributes
			if r == null or not is_same(r[0], attrs) or r[1] != attrs.size():
				r = _attr_refs(el)
				_arefs[i] = r
			var a = r[2]
			c = null if a == null else a["value"]
			a = r[3]
			nm = null if a == null else a["value"]
			a = r[4]
			st = null if a == null else a["value"]
			a = r[5]
			en = null if a == null else a["value"]
			_sig_en[i] = en
		else:
			c = _sig_cls[i]
			nm = _sig_name[i]
			st = _sig_style[i]
			en = _sig_en[i]
		var own_d: int = 1 if en != null and en == "false" else 0
		if has_ov:
			var ov = dis_ov.get(i)
			if ov != null:
				own_d = ov
		var p := _parent[i]
		var b := global
		if own_d == 1 or (p >= 0 and (_sig_bits[p] & BIT_DISABLED) != 0):
			b |= BIT_DISABLED
		else:
			b |= BIT_ENABLED
		if has_es:
			var eb = es_bits.get(i)
			if eb != null:
				b |= eb
		if has_keys:
			b |= key_bits[i]
		var own: bool = (
			full or b != _sig_bits[i] or c != _sig_cls[i]
			or nm != _sig_name[i] or st != _sig_style[i]
		)
		if own:
			if full or c != _sig_cls[i] or _cls_set[i] == null:
				_cls_set[i] = _class_set(c, _local[i])
			_name[i] = nm
			_sig_cls[i] = c
			_sig_name[i] = nm
			_sig_style[i] = st
			_sig_bits[i] = b
			_own_bloom[i] = _own_bits(i)
			var ak := _anc_key_of(i)
			if not full and ak != _anc_key[i] and _end[i] > anc_until:
				anc_until = _end[i]
			_anc_key[i] = ak
		_bloom[i] = (_bloom[p] | _own_bloom[p]) if p >= 0 else 0
		if not own and inh_dirty[i] == 0 and i >= anc_until and (not has_forced or forced[i] == 0):
			continue
		var old = styles.get(el)
		var old_fc = _fc[i]
		var old_t = null if _tgt.is_empty() else _tgt.get(i)
		_compute(i)
		if full or old == null:
			changed.append(i)
			last_old.append(old)
		elif old != styles[el]:
			changed.append(i)
			last_old.append(old)
		elif old_t != null and old_t != _tgt.get(i):
			# Overridden (transitioning) element whose own cascade result
			# changed under an unchanged override: report it so the
			# transition retargets.
			changed.append(i)
			last_old.append(old)
		elif (old as Dictionary).keys() == (styles[el] as Dictionary).keys():
			# Equal result in the same key order (Dictionary == ignores
			# order): keep the previous object so identity-keyed caches
			# downstream (layout records) stay valid.
			styles[el] = old
		if old_fc == null or old_fc != _fc[i]:
			var ch := i + 1
			var e := _end[i]
			while ch < e:
				inh_dirty[ch] = 1
				ch = _end[ch]
	_computed_once = true
	# Accumulated until effective_flags() consumes it: one restyle may run
	# several updates (transition passes).
	_last_changed.append_array(changed)
	return changed


## Write computed overrides for preorder index `i` ({property: {value,
## origin}}; empty clears them). They apply at the end of the element's
## cascade on the next update(), which recomputes the element even when
## none of its inputs changed.
func set_override(i: int, entries: Dictionary) -> void:
	if _native != null:
		_native.call("set_override", i, entries)
		return
	if entries.is_empty():
		if not _ov.has(i):
			return
		_ov.erase(i)
	else:
		_ov[i] = entries
	_ov_force.append(i)


## The computed style of preorder index `i` without its overrides (the
## value the cascade itself resolved). Same object as `styles[el]` when the
## element has no overrides.
func target_style(i: int) -> Dictionary:
	if _native != null:
		var t = _native.call("target_style", i)
		if t != null:
			return t
	else:
		var t2 = _tgt.get(i)
		if t2 != null:
			return t2
	return styles.get(els[i], {})


## Effective disabled (attribute/runtime, descending) and display:none
## (self or an ancestor) per preorder index, and the indices whose flags
## flipped since the last call: [flipped PackedInt32Array, disabled
## PackedByteArray, gone PackedByteArray].
func effective_flags() -> Array:
	if _native != null:
		return _native.call("effective_flags")
	var n := els.size()
	if _own_none.size() != n:
		_own_none.resize(n)
		_eff_dis.resize(n)
		_eff_gone.resize(n)
	for ci in _last_changed:
		var disp = styles[els[ci]].get("display")
		_own_none[ci] = 1 if disp != null and String(disp["value"]) == "none" else 0
	_last_changed = PackedInt32Array()
	var flipped := PackedInt32Array()
	for i in n:
		var d := 1 if (_sig_bits[i] & BIT_DISABLED) != 0 else 0
		var p := _parent[i]
		var g := 1 if _own_none[i] == 1 or (p >= 0 and _eff_gone[p] == 1) else 0
		if d != _eff_dis[i] or g != _eff_gone[i]:
			_eff_dis[i] = d
			_eff_gone[i] = g
			flipped.append(i)
	return [flipped, _eff_dis, _eff_gone]


## True when the element is effectively disabled after the last update
## (enabled="false" / runtime set, descending from ancestors).
## Effective disabled flag per preorder index (1 = disabled).
func disabled_flags() -> PackedByteArray:
	if _native != null:
		return _native.call("disabled_flags")
	var out := PackedByteArray()
	out.resize(els.size())
	for i in els.size():
		out[i] = 1 if (_sig_bits[i] & BIT_DISABLED) != 0 else 0
	return out


func is_disabled(i: int) -> bool:
	return (_sig_bits[i] & BIT_DISABLED) != 0


func _class_set(raw, local: String) -> Dictionary:
	var out := {}
	if raw != null:
		var text := String(raw)
		# Same splitting as UxmlElement.class_list(): space/tab/LF/CR only.
		if text.find("\t") >= 0 or text.find("\n") >= 0 or text.find("\r") >= 0:
			text = text.replace("\t", " ").replace("\n", " ").replace("\r", " ")
		for part in text.split(" ", false):
			out[part] = true
	for c in UssControls.implicit_classes_of(local):
		out[c] = true
	return out


func _anc_key_of(i: int) -> Array:
	var cl := PackedStringArray()
	for c in _cls_set[i]:
		if _anc_classes.has(c):
			cl.append(c)
	cl.sort()
	var nm = _name[i]
	return [cl, nm if nm != null and _anc_names.has(nm) else null, _sig_bits[i] & _anc_states]


## Every diagnostic of the last update, in the original resolver's order:
## states-key problems, rule problems, then per element in preorder.
func collect_warnings() -> Array:
	if _native != null:
		return _opt_warnings + _rule_warnings + _native.call("element_warnings")
	var out: Array = _opt_warnings + _rule_warnings
	for w in _warn:
		if w != null and not (w as Array).is_empty():
			out.append_array(w)
	return out


# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

func _match_compound(cp: Array, i: int, scope_idx: int) -> bool:
	var t: PackedStringArray = cp[0]
	for x in t:
		if _local[i] != x:
			return false
	var nms: PackedStringArray = cp[1]
	for x in nms:
		if _name[i] != x:
			return false
	var cs: PackedStringArray = cp[2]
	if not cs.is_empty():
		var set: Dictionary = _cls_set[i]
		for x in cs:
			if not set.has(x):
				return false
	var m: int = cp[3]
	if m != 0 and (_sig_bits[i] & m) != m:
		return false
	if cp[4] and (scope_idx < 0 or i != scope_idx):
		return false
	return true


func _match_from(parts: Array, k: int, i: int, scope_idx: int) -> bool:
	var cp: Array = parts[k]
	if not _match_compound(cp, i, scope_idx):
		return false
	if k == 0:
		return true
	var p := _parent[i]
	if cp[5]:
		return p >= 0 and _match_from(parts, k - 1, p, scope_idx)
	while p >= 0:
		if _match_from(parts, k - 1, p, scope_idx):
			return true
		p = _parent[p]
	return false


# ---------------------------------------------------------------------------
# Per-element computation (mirrors UssStyleResolver's original
# _collect_candidates + _compute_for exactly, including key order)
# ---------------------------------------------------------------------------

func _compute(i: int) -> void:
	var node: UxmlElement = els[i]
	var p := _parent[i]
	var inherited: Dictionary = _fc[p] if p >= 0 else {}
	var warns: Array = []

	# Candidate selectors from the buckets this element can hit.
	var cand := PackedInt32Array()
	var nm = _name[i]
	if nm != null:
		var l = _b_name.get(nm)
		if l != null:
			cand.append_array(l)
	for c in _cls_set[i]:
		var l2 = _b_class.get(c)
		if l2 != null:
			cand.append_array(l2)
	var l3 = _b_type.get(_local[i])
	if l3 != null:
		cand.append_array(l3)
	cand.append_array(_b_any)
	cand.sort()

	var bloom := _bloom[i]
	# Candidates in cascade order: parallel arrays.
	var c_prop := PackedStringArray()
	var c_val := PackedStringArray()
	var c_flag := PackedInt32Array()
	var c_exp: Array = []
	var c_origin: Array = []
	var c_spec := PackedInt64Array()
	var c_ent: Array = []               # shared entry lists (static rule decls) or null

	var k := 0
	var nc := cand.size()
	while k < nc:
		var s := cand[k]
		var r := _sel_rule[s]
		# group: all candidate selectors of rule r (contiguous after sort)
		var k_end := k + 1
		while k_end < nc and _sel_rule[cand[k_end]] == r:
			k_end += 1
		var lo := _rule_scope_lo[r]
		if lo != -2 and (i < lo or i >= _rule_scope_hi[r]):
			k = k_end
			continue
		var scope_idx := _rule_scope_idx[r]
		var best_sel := -1
		var best_spec := -1
		for kk in range(k, k_end):
			var ss := cand[kk]
			# Ancestor bloom: a descendant/child selector whose ancestor
			# features are not all present above this element cannot match.
			var need := _sel_need[ss]
			if need != 0 and (bloom & need) != need:
				continue
			var parts: Array = _sel_parts[ss]
			if not _match_from(parts, parts.size() - 1, i, scope_idx):
				continue
			var sp := _sel_spec[ss]
			if best_sel < 0 or sp > best_spec:
				best_sel = ss
				best_spec = sp
		k = k_end
		if best_sel < 0:
			continue
		var origins := _origins_for(best_sel)
		var ents := _entries_for(best_sel, origins)
		var dp: PackedStringArray = _rule_dprop[r]
		var dv: PackedStringArray = _rule_dval[r]
		var df: PackedInt32Array = _rule_dflag[r]
		var de: Array = _rule_dexp[r]
		for d in dp.size():
			c_prop.append(dp[d])
			c_val.append(dv[d])
			c_flag.append(df[d])
			c_exp.append(de[d])
			c_origin.append(origins[d])
			c_spec.append(best_spec)
			c_ent.append(ents[d])

	var st = _sig_style[i]
	if st != null:
		var inl := _inline(String(st))
		var dp: PackedStringArray = inl[0]
		var dv: PackedStringArray = inl[1]
		var df: PackedInt32Array = inl[2]
		var de: Array = inl[3]
		for d in dp.size():
			c_prop.append(dp[d])
			c_val.append(dv[d])
			c_flag.append(df[d])
			c_exp.append(de[d])
			c_origin.append(_inline_origin(d))
			c_spec.append(INLINE_SPEC)
			c_ent.append(null)
		for problem in inl[4]:
			warns.append(UxmlDiagnostic.make(
				"malformed",
				'style attribute of <%s>: %s' % [node.tag(), problem["message"]],
				doc.source, node.open_tag_start, doc.path
			))

	var ncand := c_prop.size()
	# Custom properties: inherited values, then the winning declarations.
	var cpair: Array = _fc_customs[p] if p >= 0 else _EMPTY_CP
	var customs: Dictionary = cpair[1]
	var cid: int = cpair[0]
	var any_custom := false
	for j in ncand:
		if c_flag[j] & F_CUSTOM:
			any_custom = true
			break
	if any_custom:
		var cw := {}
		for j in ncand:
			if not (c_flag[j] & F_CUSTOM):
				continue
			var cur = cw.get(c_prop[j])
			if cur == null or c_spec[j] >= c_spec[cur]:
				cw[c_prop[j]] = j
		customs = customs.duplicate()
		for prop in cw:
			customs[prop] = c_val[cw[prop]]
		cid = -1  # private map: not worth memoizing substitutions against

	# Substitute, expand, and pick the winner per longhand. Candidates are
	# in increasing source order, so "later wins ties" is `>=`.
	var best := {}                      # longhand -> slot in b_* arrays
	var b_val: Array = []
	var b_origin: Array = []
	var b_failed: Array = []
	var b_spec := PackedInt64Array()
	var b_ent: Array = []
	var memo = null
	if cid > 0:
		memo = _subst.get(cid)
		if memo == null:
			memo = {}
			if _subst.size() > 4096:
				_subst.clear()
			_subst[cid] = memo
	for j in ncand:
		var prop := c_prop[j]
		var pairs: Array
		var failed := false
		var raw: String
		var ents = null
		if c_flag[j] & F_VAR:
			var sub
			if c_flag[j] & F_CUSTOM:
				# A custom property's own declaration seeds the cycle set
				# with its name — never memoized.
				sub = UssStyleResolver._substitute_vars(c_val[j], customs, {prop: true})
			elif memo != null:
				# Substitution is a pure function of (value, customs map);
				# shared maps are immutable and identified by cid.
				sub = memo.get(c_val[j])
				if sub == null:
					sub = UssStyleResolver._substitute_vars(c_val[j], customs, {})
					memo[c_val[j]] = false if sub == null else sub
				elif sub is bool:
					sub = null
			else:
				sub = UssStyleResolver._substitute_vars(c_val[j], customs, {})
			failed = sub == null or UssStyleResolver._is_cycle(sub)
			raw = c_val[j] if failed else String(sub)
			pairs = _expand(prop, raw)
		else:
			raw = c_val[j]
			pairs = c_exp[j]
			ents = c_ent[j]
		if pairs.is_empty():
			warns.append(UxmlDiagnostic.make(
				"invalid-shorthand",
				"%s: %s -- wrong number of values; declaration dropped" % [prop, raw],
				doc.source, node.open_tag_start, doc.path
			))
			continue
		var sp := c_spec[j]
		var org = c_origin[j]
		for pk in pairs.size():
			var pair: Array = pairs[pk]
			var lh: String = pair[0]
			var slot = best.get(lh)
			var ent = null if ents == null else ents[pk]
			if slot == null:
				best[lh] = b_val.size()
				b_val.append(pair[1])
				b_origin.append(org)
				b_failed.append(failed)
				b_spec.append(sp)
				b_ent.append(ent)
			elif sp >= b_spec[slot]:
				b_val[slot] = pair[1]
				b_origin[slot] = org
				b_failed[slot] = failed
				b_spec[slot] = sp
				b_ent[slot] = ent

	var computed := inherited.duplicate()
	for prop in best:
		var slot: int = best[prop]
		if b_failed[slot]:
			warns.append(UxmlDiagnostic.make(
				"unresolved-var",
				"%s: var() reference could not be resolved; declaration dropped" % prop,
				doc.source, node.open_tag_start, doc.path
			))
			continue
		var ent = b_ent[slot]
		computed[prop] = ent if ent != null else {"value": b_val[slot], "origin": b_origin[slot]}
		if not _is_supported(prop):
			warns.append(UxmlDiagnostic.make(
				"unsupported-property",
				'"%s" is not a supported USS property; the value is kept but has no effect' % prop,
				doc.source, node.open_tag_start, doc.path
			))

	if not _ov.is_empty():
		var ov = _ov.get(i)
		if ov != null:
			_tgt[i] = computed
			computed = computed.duplicate()
			for prop in ov:
				computed[prop] = ov[prop]
		elif not _tgt.is_empty():
			_tgt.erase(i)
	elif not _tgt.is_empty():
		_tgt.erase(i)
	styles[node] = computed
	_warn[i] = warns
	if node.children.is_empty():
		# Nothing inherits from a leaf.
		_fc[i] = _empty_fc
		_fc_customs[i] = cpair
		return
	var fc := {}
	for prop in computed:
		if not _is_inherited(prop):
			continue
		var e: Dictionary = computed[prop]
		fc[prop] = {
			"value": e["value"],
			"origin": {"kind": "inherited", "from": node, "origin": e["origin"]},
		}
	_fc[i] = fc
	if not any_custom:
		# No own custom declarations: the custom properties handed down are
		# exactly the inherited ones — share the parent's map (and its id).
		_fc_customs[i] = cpair
	else:
		var fcc := {}
		for prop in fc:
			if prop.begins_with("--"):
				fcc[prop] = fc[prop]["value"]
		_fc_customs[i] = [_next_cid, fcc]
		_next_cid += 1
