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
var _fc_customs: Array = []            # custom-property value map of _fc (shared read-only)
var _warn: Array = []                  # per element warnings
var _computed_once := false
## Previous computed Dictionary for each index update() returned (aligned).
var last_old: Array = []
var _opt_warnings: Array = []

## UxmlElement -> computed style (property -> {value, origin}), preorder.
var styles := {}

static var _inline_cache := {}         # style attribute text -> [records..., problems]
static var _exp_cache := {}            # property -> {raw -> expansion}
static var _inherited_cache := {}
static var _supported_cache := {}
static var _inline_origins: Array = []


func _init(p_doc: UxmlDocumentModel) -> void:
	doc = p_doc
	_index_tree()
	_compile_rules()


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
	_warn.resize(n)


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
# State bits (the resolver's _build_state_map, as bitmasks)
# ---------------------------------------------------------------------------

func _state_bits(options: Dictionary, attr_enabled: Array) -> PackedInt32Array:
	var n := els.size()
	var bits := PackedInt32Array()
	bits.resize(n)
	var global := 0
	for s in options.get("active_states", []):
		global |= int(STATE_BITS.get(s, 0))

	# States keys: matched with NO states active (a key never switches
	# itself on), root = document root — the original slow path, rare.
	var key_bits := PackedInt32Array()
	var states_opt: Dictionary = options.get("states", {})
	if not states_opt.is_empty():
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

	var own_dis := PackedByteArray()
	own_dis.resize(n)
	for i in n:
		own_dis[i] = 1 if attr_enabled[i] == "false" else 0
	for el in options.get("disabled_elements", {}):
		var i = index.get(el)
		if i != null:
			own_dis[i] = 1
	for el in options.get("enabled_elements", {}):
		var i = index.get(el)
		if i != null:
			own_dis[i] = 2 # override: never own-disabled
	var es: Dictionary = options.get("element_states", {})
	var dis := PackedByteArray()
	dis.resize(n)
	for i in n:
		var p := _parent[i]
		var d := (p >= 0 and dis[p] == 1) or own_dis[i] == 1
		dis[i] = 1 if d else 0
		bits[i] = global | (BIT_DISABLED if d else BIT_ENABLED)
	for el in es:
		var i = index.get(el)
		if i == null:
			continue
		var m := 0
		for s in es[el]:
			m |= int(STATE_BITS.get(s, 0))
		bits[i] |= m
	if not key_bits.is_empty():
		for i in n:
			bits[i] |= key_bits[i]
	return bits


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

## Recompute every element whose result could have changed (all of them
## when `force` or on the first call). Returns the preorder indices whose
## computed style Dictionary differs from the previous one; `styles` holds
## the new results.
func update(options: Dictionary = {}, force: bool = false) -> PackedInt32Array:
	var n := els.size()
	_opt_warnings = []
	# One pass over attributes per element: class/name/style/enabled.
	var a_cls: Array = []
	var a_name: Array = []
	var a_style: Array = []
	var a_en: Array = []
	a_cls.resize(n)
	a_name.resize(n)
	a_style.resize(n)
	a_en.resize(n)
	for i in n:
		var el: UxmlElement = els[i]
		var c = null
		var nm = null
		var st = null
		var en = null
		for a in el.attributes:
			var an: String = a["name"]
			if an == "class":
				if c == null:
					c = a["value"]
			elif an == "name":
				if nm == null:
					nm = a["value"]
			elif an == "style":
				if st == null:
					st = a["value"]
			elif an == "enabled":
				if en == null:
					en = a["value"]
		a_cls[i] = c
		a_name[i] = nm
		a_style[i] = st
		a_en[i] = en
	var bits := _state_bits(options, a_en)

	var full := force or not _computed_once
	var changed := PackedInt32Array()
	last_old = []
	var inh_dirty := PackedByteArray()
	inh_dirty.resize(n)
	var anc_until := -1
	for i in n:
		var c = a_cls[i]
		var nm = a_name[i]
		var st = a_style[i]
		var b := bits[i]
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
			var ak := _anc_key_of(i)
			if not full and ak != _anc_key[i] and _end[i] > anc_until:
				anc_until = _end[i]
			_anc_key[i] = ak
		elif inh_dirty[i] == 0 and i >= anc_until:
			continue
		var el: UxmlElement = els[i]
		var old = styles.get(el)
		var old_fc = _fc[i]
		_compute(i)
		if full or old == null or old != styles[el]:
			changed.append(i)
			last_old.append(old)
		if old_fc == null or old_fc != _fc[i]:
			var ch := i + 1
			var e := _end[i]
			while ch < e:
				inh_dirty[ch] = 1
				ch = _end[ch]
	_computed_once = true
	return changed


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

	# Candidates in cascade order: parallel arrays.
	var c_prop := PackedStringArray()
	var c_val := PackedStringArray()
	var c_flag := PackedInt32Array()
	var c_exp: Array = []
	var c_origin: Array = []
	var c_spec := PackedInt64Array()

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
		for problem in inl[4]:
			warns.append(UxmlDiagnostic.make(
				"malformed",
				'style attribute of <%s>: %s' % [node.tag(), problem["message"]],
				doc.source, node.open_tag_start, doc.path
			))

	var ncand := c_prop.size()
	# Custom properties: inherited values, then the winning declarations.
	var customs: Dictionary = _fc_customs[p] if p >= 0 else {}
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

	# Substitute, expand, and pick the winner per longhand. Candidates are
	# in increasing source order, so "later wins ties" is `>=`.
	var best := {}                      # longhand -> slot in b_* arrays
	var b_val: Array = []
	var b_origin: Array = []
	var b_failed: Array = []
	var b_spec := PackedInt64Array()
	for j in ncand:
		var prop := c_prop[j]
		var pairs: Array
		var failed := false
		var raw: String
		if c_flag[j] & F_VAR:
			var seed := {}
			if c_flag[j] & F_CUSTOM:
				seed[prop] = true
			var sub = UssStyleResolver._substitute_vars(c_val[j], customs, seed)
			failed = sub == null or UssStyleResolver._is_cycle(sub)
			raw = c_val[j] if failed else String(sub)
			pairs = _expand(prop, raw)
		else:
			raw = c_val[j]
			pairs = c_exp[j]
		if pairs.is_empty():
			warns.append(UxmlDiagnostic.make(
				"invalid-shorthand",
				"%s: %s -- wrong number of values; declaration dropped" % [prop, raw],
				doc.source, node.open_tag_start, doc.path
			))
			continue
		var sp := c_spec[j]
		var org = c_origin[j]
		for pair in pairs:
			var lh: String = pair[0]
			var slot = best.get(lh)
			if slot == null:
				best[lh] = b_val.size()
				b_val.append(pair[1])
				b_origin.append(org)
				b_failed.append(failed)
				b_spec.append(sp)
			elif sp >= b_spec[slot]:
				b_val[slot] = pair[1]
				b_origin[slot] = org
				b_failed[slot] = failed
				b_spec[slot] = sp

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
		computed[prop] = {"value": b_val[slot], "origin": b_origin[slot]}
		if not _is_supported(prop):
			warns.append(UxmlDiagnostic.make(
				"unsupported-property",
				'"%s" is not a supported USS property; the value is kept but has no effect' % prop,
				doc.source, node.open_tag_start, doc.path
			))

	var fc := {}
	var fcc := {}
	for prop in computed:
		if not _is_inherited(prop):
			continue
		var e: Dictionary = computed[prop]
		var v = e["value"]
		fc[prop] = {
			"value": v,
			"origin": {"kind": "inherited", "from": node, "origin": e["origin"]},
		}
		if prop.begins_with("--"):
			fcc[prop] = v
	styles[node] = computed
	_fc[i] = fc
	_fc_customs[i] = fcc
	_warn[i] = warns
