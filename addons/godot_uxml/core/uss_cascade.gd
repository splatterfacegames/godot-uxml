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
	# `:selected` is Unity's old name of `:checked` (one pseudo-state);
	# `:inactive` is set on every element that is not `:active`.
	"checked": 16, "disabled": 32, "enabled": 64, "selected": 16,
}
const BIT_ACTIVE := 2
const BIT_INACTIVE := 4
const BIT_DISABLED := 32
const BIT_ENABLED := 64
## Inline declarations outrank every selector: above any packed rule key.
const INLINE_SPEC := 1 << 62
## `all: initial` outranks every other declaration of the element, inline
## ones included (measured: uss-all, uss-all-2).
const ALL_SPEC := (1 << 62) | (1 << 61)
## Author rules outrank every theme rule (a sheet with "theme": true, see
## UxmlTheme), whatever the specificity — Unity sorts default-theme matches
## below author matches. Packed into the specificity key, so the native
## cascade (which reads `_sel_spec`) agrees by construction.
const AUTHOR_LAYER := 1 << 61

const F_CUSTOM := 1
const F_VAR := 2
const F_ALL := 4

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
# Non-rightmost compounds that test a pseudo-state: [types, names, classes,
# state mask]. A state of an element is an ancestor feature only when the
# element matches the rest of such a compound, so hovering an element that
# no `X:hover Y` rule can reach does not re-cascade its subtree.
var _anc_state_reqs: Array = []
var _anc_state_seen := {}
var _rule_warnings: Array = []

# --- element index --------------------------------------------------------
var els: Array = []                    # preorder UxmlElement list
var index := {}                        # UxmlElement -> preorder index
var _parent: PackedInt32Array
## Selector parent per element (UxmlParts.logical_parent): the parent that
## Unity's `>` and descendant combinators walk. An author child that a
## control keeps in its content container has the control as selector
## parent; style inheritance follows _parent.
var _sel_parent: PackedInt32Array
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
	_sel_parent = _parent.duplicate()
	for i in n:
		var lp := UxmlParts.logical_parent(els[i])
		if lp != null and index.has(lp):
			_sel_parent[i] = index[lp]
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
	var reported_root := [false]
	var visited := {}
	for root in doc.style_roots:
		var si: int = root["sheet"]
		if root["scope"] == null and _add_theme_block(si, visited, reported_root):
			continue
		var flat: Array = []
		UssStyleResolver._walk_sheet(doc, si, root["scope"], visited, flat)
		for f in flat:
			_compile_flat(f, reported_root)


## Checks one flattened rule (diagnostics) and adds it. `reported_root` is
## a one-element Array: the :root note is reported once per document.
func _compile_flat(f: Dictionary, reported_root: Array) -> void:
	var rule: Dictionary = f["rule"]
	var bad := UssSelector.unsupported_fragment(rule["selectors"])
	if bad != "":
		_rule_warnings.append(_unsupported_diag(bad, rule, f["sheet"]))
		return
	if not reported_root[0] and UssStyleResolver._has_root_pseudo(rule):
		reported_root[0] = true
		_rule_warnings.append(_root_diag(rule, f["sheet"]))
	_add_rule(f)


func _unsupported_diag(bad: String, rule: Dictionary, sheet: int) -> Dictionary:
	return UxmlDiagnostic.make(
		"unsupported-selector",
		'"%s" is not supported in USS; the whole rule is ignored' % bad,
		UssStyleResolver._sheet_source(doc, sheet),
		rule["selector_span"]["start"],
		UssStyleResolver._sheet_origin(doc, sheet)
	)


func _root_diag(rule: Dictionary, sheet: int) -> Dictionary:
	return UxmlDiagnostic.make(
		"version-dependent",
		":root in USS names the element the stylesheet was applied to, not the document root as in CSS",
		UssStyleResolver._sheet_source(doc, sheet),
		rule["selector_span"]["start"],
		UssStyleResolver._sheet_origin(doc, sheet)
	)


# --- theme blocks ---------------------------------------------------------
# A theme sheet (UxmlTheme: "theme": true, no scope) is parsed once and
# shared by every load, so what _compile_flat/_add_rule derive from it is
# the same on every load except the sheet index and the offsets of its
# rules and selectors in this cascade. Its compiled form is kept as a block
# (per sheet origin, valid while the parsed items are the same Array) and
# spliced in with array appends. The native cascade gets the block ids and
# ranges (`_blocks`) and keeps its own converted form of each block, so
# neither side converts the theme rules again on a later load.

## origin path -> [items Array, block]. Block: see _theme_block.
static var _theme_blocks := {}
static var _next_block_id := 1
## Per theme block spliced into this cascade: [block id, first rule,
## rule count, first selector, selector count, sheet index].
var _blocks: Array = []


## Splices the block of sheet `si` when it is a theme sheet without
## imports; false when the sheet takes the general path.
func _add_theme_block(si: int, visited: Dictionary, reported_root: Array) -> bool:
	if si < 0 or si >= doc.sheets.size():
		return false
	var sheet: Dictionary = doc.sheets[si]
	if not bool(sheet.get("theme", false)):
		return false
	var in_scope: Dictionary = visited.get(null, {})
	if in_scope.has(si):
		return true  # _walk_sheet would add nothing
	var b := _theme_block(sheet, si)
	if b.is_empty():
		return false
	in_scope[si] = true
	visited[null] = in_scope
	for ev in b["events"]:
		if ev[0] == 0:
			_rule_warnings.append(_unsupported_diag(ev[1], ev[2], si))
		elif not reported_root[0]:
			reported_root[0] = true
			_rule_warnings.append(_root_diag(ev[2], si))
	var r0 := _rule_sheet.size()
	var s0 := _sel_rule.size()
	var items: PackedInt32Array = b["items"]
	var nr := items.size()
	var file: String = UssStyleResolver._sheet_origin(doc, si)
	for k in nr:
		_rule_sheet.append(si)
		_rule_file.append(file)
	_rule_item.append_array(items)
	_rule_scope_idx.append_array(b["neg1"])
	_rule_scope_lo.append_array(b["neg2"])
	_rule_scope_hi.append_array(b["neg2"])
	_rule_dprop.append_array(b["dprop"])
	_rule_dval.append_array(b["dval"])
	_rule_dflag.append_array(b["dflag"])
	_rule_dexp.append_array(b["dexp"])
	var srule: PackedInt32Array = b["sel_rule"]
	var ns := srule.size()
	for k in ns:
		_sel_rule.append(r0 + srule[k])
	_sel_parts.append_array(b["sel_parts"])
	_sel_need.append_array(b["sel_need"])
	_sel_spec.append_array(b["sel_spec"])
	_sel_states.append_array(b["sel_states"])
	_sel_entries.resize(s0 + ns)
	_sel_origins.resize(s0 + ns)
	_merge_buckets(_b_name, b["b_name"], s0)
	_merge_buckets(_b_class, b["b_class"], s0)
	_merge_buckets(_b_type, b["b_type"], s0)
	for x in (b["b_any"] as PackedInt32Array):
		_b_any.append(s0 + x)
	for c in b["anc_classes"]:
		_anc_classes[c] = true
	for nm in b["anc_names"]:
		_anc_names[nm] = true
	_anc_states |= int(b["anc_states"])
	for rq in b["reqs"]:
		if not _anc_state_seen.has(rq[0]):
			_anc_state_seen[rq[0]] = true
			_anc_state_reqs.append(rq[1])
	_blocks.append([b["id"], r0, nr, s0, ns, si])
	return true


static func _merge_buckets(dst: Dictionary, src: Dictionary, s0: int) -> void:
	for key in src:
		var l: PackedInt32Array = dst.get(key, PackedInt32Array())
		for x in (src[key] as PackedInt32Array):
			l.append(s0 + x)
		dst[key] = l


## The cached block of theme `sheet` (index `si` in this document), built
## on first use; {} when the sheet has imports (general path).
func _theme_block(sheet: Dictionary, si: int) -> Dictionary:
	var origin: String = sheet.get("origin", "")
	var sheet_items: Array = sheet["items"]
	var hit = _theme_blocks.get(origin)
	if hit != null and is_same(hit[0], sheet_items):
		return hit[1]
	for item in sheet_items:
		if item["kind"] == "import":
			return {}
	# Built the way _compile_flat/_add_rule build these rules (layer 0, no
	# scope); events are the diagnostics in rule order: [0, fragment, rule]
	# for an unsupported selector, [1, null, rule] for the first :root.
	var b := {
		"id": _next_block_id, "events": [], "items": PackedInt32Array(),
		"neg1": PackedInt32Array(), "neg2": PackedInt32Array(),
		"dprop": [], "dval": [], "dflag": [], "dexp": [],
		"sel_rule": PackedInt32Array(), "sel_parts": [], "sel_need": PackedInt64Array(),
		"sel_spec": PackedInt64Array(), "sel_states": [],
		"b_name": {}, "b_class": {}, "b_type": {}, "b_any": PackedInt32Array(),
		"anc_classes": {}, "anc_names": {}, "anc_states": 0, "reqs": [],
	}
	_next_block_id += 1
	var root_seen := false
	var req_seen := {}
	var events: Array = b["events"]
	var b_items: PackedInt32Array = []
	var neg1: PackedInt32Array = []
	var neg2: PackedInt32Array = []
	var sel_rule: PackedInt32Array = []
	var sel_need: PackedInt64Array = []
	var sel_spec: PackedInt64Array = []
	var b_any: PackedInt32Array = []
	var anc_states := 0
	for i in sheet_items.size():
		var item: Dictionary = sheet_items[i]
		if item["kind"] != "rule":
			continue
		var rule: Dictionary = item["rule"]
		var bad := UssSelector.unsupported_fragment(rule["selectors"])
		if bad != "":
			events.append([0, bad, rule])
			continue
		if not root_seen and UssStyleResolver._has_root_pseudo(rule):
			root_seen = true
			events.append([1, null, rule])
		var r := b_items.size()
		b_items.append(i)
		neg1.append(-1)
		neg2.append(-2)
		var cc = rule.get(CC)
		if cc == null:
			cc = _compile_rule(rule, 0)
			rule[CC] = cc
		b["dprop"].append(cc[0])
		b["dval"].append(cc[1])
		b["dflag"].append(cc[2])
		b["dexp"].append(cc[3])
		for sc in cc[4]:
			var s := sel_rule.size()
			sel_rule.append(r)
			for c in sc[5]:
				b["anc_classes"][c] = true
			for nm in sc[6]:
				b["anc_names"][nm] = true
			anc_states |= int(sc[7])
			for req in sc[8]:
				var rk := "%s|%s|%s|%d" % [",".join(req[0]), ",".join(req[1]), ",".join(req[2]), req[3]]
				if not req_seen.has(rk):
					req_seen[rk] = true
					b["reqs"].append([rk, req])
			b["sel_parts"].append(sc[0])
			sel_need.append(sc[1])
			sel_spec.append(sc[2])
			b["sel_states"].append(sc[3])
			var bk: int = sc[4][0]
			if bk == 0:
				_bucket_add(b["b_name"], sc[4][1], s)
			elif bk == 1:
				_bucket_add(b["b_class"], sc[4][1], s)
			elif bk == 2:
				_bucket_add(b["b_type"], sc[4][1], s)
			else:
				b_any.append(s)
	b["items"] = b_items
	b["neg1"] = neg1
	b["neg2"] = neg2
	b["sel_rule"] = sel_rule
	b["sel_need"] = sel_need
	b["sel_spec"] = sel_spec
	b["b_any"] = b_any
	b["anc_states"] = anc_states
	_theme_blocks[origin] = [sheet_items, b]
	return b


## Drop the cached theme blocks (UxmlTheme.clear_cache).
static func clear_theme_blocks() -> void:
	_theme_blocks.clear()


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
	# The compiled form of a rule depends only on the rule and its layer.
	# Theme sheets are parsed once and shared by every load (UxmlTheme), so
	# their compiled rules are kept on the shared rule (key CC) and reused.
	var theme := bool(doc.sheets[f["sheet"]].get("theme", false))
	var cc = rule.get(CC) if theme else null
	if cc == null:
		cc = _compile_rule(rule, 0 if theme else AUTHOR_LAYER)
		if theme:
			rule[CC] = cc
	_rule_dprop.append(cc[0])
	_rule_dval.append(cc[1])
	_rule_dflag.append(cc[2])
	_rule_dexp.append(cc[3])
	for sc in cc[4]:
		var s := _sel_rule.size()
		_sel_rule.append(r)
		for c in sc[5]:
			_anc_classes[c] = true
		for nm in sc[6]:
			_anc_names[nm] = true
		_anc_states |= int(sc[7])
		for req in sc[8]:
			var rk := "%s|%s|%s|%d" % [",".join(req[0]), ",".join(req[1]), ",".join(req[2]), req[3]]
			if not _anc_state_seen.has(rk):
				_anc_state_seen[rk] = true
				_anc_state_reqs.append(req)
		_sel_parts.append(sc[0])
		_sel_need.append(sc[1])
		_sel_entries.append(null)
		_sel_spec.append(sc[2])
		_sel_states.append(sc[3])
		_sel_origins.append(null)
		var bk: int = sc[4][0]
		if bk == 0:
			_bucket_add(_b_name, sc[4][1], s)
		elif bk == 1:
			_bucket_add(_b_class, sc[4][1], s)
		elif bk == 2:
			_bucket_add(_b_type, sc[4][1], s)
		else:
			_b_any.append(s)


## Key of a theme rule's compiled form (see _add_rule).
const CC := "_uxml_compiled"


## The compiled form of `rule`: [declaration properties, values, flags,
## expansions, selectors]. Each selector: [parts, ancestor bloom need,
## specificity key, required states, [bucket kind (0 name, 1 class,
## 2 type, 3 any), key], ancestor classes, ancestor names, ancestor state
## mask, ancestor state requirements]. Read-only once built.
static func _compile_rule(rule: Dictionary, layer: int) -> Array:
	var dc := _compile_decls(rule)
	var dp: PackedStringArray = dc[0]
	var dv: PackedStringArray = dc[1]
	var df: PackedInt32Array = dc[2]
	var de: Array = dc[3]
	var sels: Array = []
	for sel in rule["selectors"]:
		var parts: Array = []
		var names := 0
		var classes := 0
		var types := 0
		var anc_c: Array = []
		var anc_n: Array = []
		var anc_s := 0
		var anc_r: Array = []
		var sel_parts: Array = sel["parts"]
		var anc_root := false
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
			if root and pi < sel_parts.size() - 1:
				# Unity matches `:root` on the selector's subject only: as an
				# ancestor (`:root > .a`, `:root .a`) it matches nothing
				# (measured, sel-root).
				anc_root = true
			parts.append([ptypes, pnames, pclasses, mask, root, is_child])
			if pi < sel_parts.size() - 1:
				anc_c.append_array(pclasses)
				anc_n.append_array(pnames)
				anc_s |= mask
				if mask != 0:
					anc_r.append([ptypes, pnames, pclasses, mask])
		if anc_root:
			continue
		var need := 0
		for pi2 in parts.size() - 1:
			var cp2: Array = parts[pi2]
			for x in cp2[0]:
				need |= _fbits("<" + x)
			for x in cp2[1]:
				need |= _fbits("#" + x)
			for x in cp2[2]:
				need |= _fbits("." + x)
		var right: Array = parts[parts.size() - 1]
		var bucket: Array = [3, ""]
		if not (right[1] as PackedStringArray).is_empty():
			bucket = [0, right[1][0]]
		elif not (right[2] as PackedStringArray).is_empty():
			bucket = [1, right[2][0]]
		elif not (right[0] as PackedStringArray).is_empty():
			bucket = [2, right[0][0]]
		sels.append([parts, need, (names << 40) | (classes << 20) | types | layer,
			UssSelector.states_required_by(sel), bucket, anc_c, anc_n, anc_s, anc_r])
	return [dp, dv, df, de, sels]


## The declarations of `rule`: [properties, values, flags, expansions].
static func _compile_decls(rule: Dictionary) -> Array:
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
		elif prop == "all":
			fl |= F_ALL
		if val.find("var(") >= 0:
			fl |= F_VAR
			de.append(null)
		else:
			de.append(_expand(prop, val))
		df.append(fl)
	return [dp, dv, df, de]


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
	var out: Array
	if prop.begins_with("--"):
		out = UssProperties.expand_shorthand(prop, raw)
	else:
		# Unity ignores `!important` and reads an unreadable longhand value
		# as its type's zero value (UssProperties.unity_value).
		var pairs := UssProperties.expand_shorthand(prop, UssProperties.strip_important(raw))
		out = pairs
		for k in pairs.size():
			var pair: Array = pairs[k]
			var uv := UssProperties.unity_value(pair[0], pair[1])
			if uv != pair[1]:
				if is_same(out, pairs):
					out = pairs.duplicate()  # expansions may be shared
				out[k] = [pair[0], uv]
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
		elif prop == "all":
			fl |= F_ALL
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
# Rule patches (UxmlDocument.reload_stylesheet): the declarations of a rule
# change, the selectors and the rule order stay. The buckets, ancestor
# features and bloom bits depend only on selectors, so they stay valid.
# ---------------------------------------------------------------------------

## More patched rules than this recompute every element: the match test of
## each selector against each element would cost more than the recompute.
const PATCH_MATCH_LIMIT := 32


## The edit from sheet items `old` to `new` when only declarations differ:
## {item index: new rule} (empty: nothing can change a computed style). null
## when the edit changes selectors, rules, imports or the item order: the
## compiled rule tables are then out of date.
static func sheet_patch(old: Array, new: Array):
	if old.size() != new.size():
		return null
	var out := {}
	for i in new.size():
		var a: Dictionary = old[i]
		var b: Dictionary = new[i]
		var kind: String = b["kind"]
		if a["kind"] != kind:
			return null
		if kind == "import":
			if a["url"] != b["url"] or a.get("resolved_sheet", -1) != b.get("resolved_sheet", -1):
				return null
		elif kind == "rule":
			var ra: Dictionary = a["rule"]
			var rb: Dictionary = b["rule"]
			var sa: Array = ra["selectors"]
			var sb: Array = rb["selectors"]
			if sa.size() != sb.size():
				return null
			for k in sb.size():
				if sa[k]["parts"] != sb[k]["parts"]:
					return null
			var da: Array = ra["declarations"]
			var db: Array = rb["declarations"]
			var same := da.size() == db.size()
			if same:
				for k in db.size():
					if da[k]["property"] != db[k]["property"] or da[k]["value"] != db[k]["value"]:
						same = false
						break
			if not same:
				out[i] = rb
	return out


## Give the compiled rules of sheet `si` the declarations in `patch` (see
## sheet_patch) and mark the elements the changed rules match now. The next
## update() recomputes those elements, and inheritance carries the change
## to their subtrees. An element that a changed rule does not match now
## reads the new declarations when its inputs change.
func patch_rules(si: int, patch: Dictionary) -> void:
	var rs := PackedInt32Array()
	for r in _rule_sheet.size():
		if _rule_sheet[r] != si:
			continue
		var rule = patch.get(_rule_item[r])
		if rule == null:
			continue
		var dc := _compile_decls(rule)
		_rule_dprop[r] = dc[0]
		_rule_dval[r] = dc[1]
		_rule_dflag[r] = dc[2]
		_rule_dexp[r] = dc[3]
		rs.append(r)
		if _native != null:
			_native.call("patch_rule", r, dc[0], dc[1], dc[2], dc[3])
	if rs.is_empty():
		return
	if _native != null:
		_native.call("force_rules", rs, PATCH_MATCH_LIMIT)
	var hit := {}
	for r in rs:
		hit[r] = true
	var sels := PackedInt32Array()
	for s in _sel_rule.size():
		if hit.has(_sel_rule[s]):
			# explain_style reads these on both backends.
			_sel_entries[s] = null
			_sel_origins[s] = null
			sels.append(s)
	if _native != null:
		return
	var n := els.size()
	if rs.size() > PATCH_MATCH_LIMIT:
		for i in n:
			_ov_force.append(i)
		return
	for i in n:
		for s in sels:
			var r := _sel_rule[s]
			var lo := _rule_scope_lo[r]
			if lo != -2 and (i < lo or i >= _rule_scope_hi[r]):
				continue
			var need := _sel_need[s]
			if need != 0 and (_bloom[i] & need) != need:
				continue
			var parts: Array = _sel_parts[s]
			if _match_from(parts, parts.size() - 1, i, _rule_scope_idx[r]):
				_ov_force.append(i)
				break


## Move the rule diagnostics of a patched sheet: `moved` maps the old selector
## offsets to the new ones, `source` is the new text of the sheet `file`.
func move_rule_warnings(file: String, source: String, moved: Dictionary) -> void:
	for k in _rule_warnings.size():
		var w: Dictionary = _rule_warnings[k]
		if String(w["file"]) != file:
			continue
		var no = moved.get(int(w["offset"]))
		if no != null:
			_rule_warnings[k] = UxmlDiagnostic.make(w["kind"], w["message"], source, no, file)


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
			parents[els[i]] = els[_sel_parent[i]]
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
		if (b & BIT_ACTIVE) == 0:
			b |= BIT_INACTIVE
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
	return [cl, nm if nm != null and _anc_names.has(nm) else null, _sig_bits[i] & _anc_state_mask(i)]


## The state bits of element i that some non-rightmost compound can test:
## those of compounds whose type/name/class parts the element matches.
func _anc_state_mask(i: int) -> int:
	var m := 0
	var set: Dictionary = _cls_set[i]
	for r in _anc_state_reqs:
		var rm: int = r[3]
		if (m & rm) == rm:
			continue
		var ok := true
		for x in (r[0] as PackedStringArray):
			if _local[i] != x:
				ok = false
				break
		if ok:
			for x in (r[1] as PackedStringArray):
				if _name[i] != x:
					ok = false
					break
		if ok:
			for x in (r[2] as PackedStringArray):
				if not set.has(x):
					ok = false
					break
		if ok:
			m |= rm
	return m


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


## A font-size percentage of the inherited font-size entry as px text, ""
## when the inherited size is not in px (the parent's size is the theme's).
static func _font_percent(value: String, parent_entry) -> String:
	if parent_entry == null:
		return ""
	var pl := UssValues.parse_length(String(parent_entry["value"]))
	var own := UssValues.parse_length(value)
	if pl["kind"] != "px" or own["kind"] != "percent":
		return ""
	return UssValues.fmt_number(float(pl["value"]) * float(own["value"]) / 100.0) + "px"


func _match_from(parts: Array, k: int, i: int, scope_idx: int) -> bool:
	var cp: Array = parts[k]
	if not _match_compound(cp, i, scope_idx):
		return false
	if k == 0:
		return true
	var p := _sel_parent[i]
	if cp[5]:
		return p >= 0 and _match_from(parts, k - 1, p, scope_idx)
	while p >= 0:
		if _match_from(parts, k - 1, p, scope_idx):
			return true
		p = _sel_parent[p]
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
				doc.source, node.open_tag_start, doc.path, node.open_tag_end
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
				doc.source, node.open_tag_start, doc.path, node.open_tag_end
			))
			continue
		var sp := ALL_SPEC if (c_flag[j] & F_ALL) else c_spec[j]
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
				doc.source, node.open_tag_start, doc.path, node.open_tag_end
			))
			continue
		var ent = b_ent[slot]
		if not _is_supported(prop):
			warns.append(UxmlDiagnostic.make(
				"unsupported-property",
				'"%s" is not a supported USS property; the value is kept but has no effect' % prop,
				doc.source, node.open_tag_start, doc.path, node.open_tag_end
			))
		# `initial` (also what `all: initial` expands to): the property takes
		# its initial value, which the runtime reads as "not declared" — so
		# the entry goes, inherited value included.
		if b_val[slot] == "initial":
			computed.erase(prop)
			continue
		# `unset`: an inherited property keeps the inherited value, any
		# other one takes its initial value.
		if b_val[slot] == "unset":
			if not _is_inherited(prop):
				computed.erase(prop)
			continue
		computed[prop] = ent if ent != null else {"value": b_val[slot], "origin": b_origin[slot]}

	# font-size: a percentage of the inherited size, computed here as Unity
	# computes it (children inherit the px value).
	var fse = computed.get("font-size")
	if fse != null and String(fse["value"]).ends_with("%"):
		var pxv := _font_percent(String(fse["value"]), inherited.get("font-size"))
		if not pxv.is_empty():
			computed["font-size"] = {"value": pxv, "origin": fse["origin"]}

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


# ---------------------------------------------------------------------------
# Provenance (UxmlDocument.explain_style). A query path apart from update():
# it reads the compiled rules, the element tree and the last computed
# styles, and keeps nothing, so the cascade itself pays nothing for it.
# Both backends compile the rules here and agree on the computed styles,
# so the answer is the same on both.
# ---------------------------------------------------------------------------

## Every declaration that sets `property` on preorder index `i`, winner
## first (see UxmlDocument.explain_style for the entry shape).
## `bits_of.call(j) -> int` gives the pseudo-state bits (STATE_BITS,
## BIT_ENABLED, BIT_INACTIVE) of any preorder index; `parent_style` is the
## computed style of the inheritance parent ({} for the root).
func explain(i: int, property: String, bits_of: Callable, parent_style: Dictionary) -> Array:
	var ctx := {}  # preorder index -> [name, class set, bits]
	var cand := PackedInt32Array()
	var nm = _x_ctx(i, bits_of, ctx)[0]
	if nm != null:
		var l = _b_name.get(nm)
		if l != null:
			cand.append_array(l)
	for c in _x_ctx(i, bits_of, ctx)[1]:
		var l2 = _b_class.get(c)
		if l2 != null:
			cand.append_array(l2)
	var l3 = _b_type.get(_local[i])
	if l3 != null:
		cand.append_array(l3)
	cand.append_array(_b_any)
	cand.sort()
	# Matched declarations in cascade order: [prop, raw, flag, exp, origin,
	# spec, rank, rule specificity key].
	var decls: Array = []
	var k := 0
	var nc := cand.size()
	while k < nc:
		var s := cand[k]
		var r := _sel_rule[s]
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
			if not _x_match(parts, parts.size() - 1, i, scope_idx, bits_of, ctx):
				continue
			var sp := _sel_spec[ss]
			if best_sel < 0 or sp > best_spec:
				best_sel = ss
				best_spec = sp
		k = k_end
		if best_sel < 0:
			continue
		var origins := _origins_for(best_sel)
		var theme := bool(doc.sheets[_rule_sheet[r]].get("theme", false))
		var dp: PackedStringArray = _rule_dprop[r]
		for d in dp.size():
			decls.append([dp[d], _rule_dval[r][d], _rule_dflag[r][d], _rule_dexp[r][d],
				origins[d], best_spec, "theme" if theme else "author"])
	var st = els[i].get_attribute("style")
	if st != null:
		var inl := _inline(String(st))
		var ip: PackedStringArray = inl[0]
		for d in ip.size():
			decls.append([ip[d], inl[1][d], inl[2][d], inl[3][d], _inline_origin(d), INLINE_SPEC, "inline"])
	# Custom properties: the inherited ones, then the element's own winners
	# (raw values, as update() substitutes against them).
	var customs := {}
	for prop in parent_style:
		if String(prop).begins_with("--"):
			customs[prop] = parent_style[prop]["value"]
	var cw := {}
	for j in decls.size():
		if int(decls[j][2]) & F_CUSTOM:
			var cur = cw.get(decls[j][0])
			if cur == null or int(decls[j][5]) >= int(decls[cur][5]):
				cw[decls[j][0]] = j
	for prop in cw:
		customs[prop] = decls[cw[prop]][1]
	var out: Array = []
	for j in decls.size():
		var dc: Array = decls[j]
		var dprop: String = dc[0]
		var raw: String = dc[1]
		var flag: int = dc[2]
		var pairs = dc[3]
		var failed := false
		if flag & F_VAR:
			var sub = UssStyleResolver._substitute_vars(raw, customs,
				{dprop: true} if (flag & F_CUSTOM) else {})
			failed = sub == null or UssStyleResolver._is_cycle(sub)
			pairs = _expand(dprop, raw if failed else String(sub))
		if pairs == null:
			continue
		for pair in (pairs as Array):
			if pair[0] != property:
				continue
			var spec: int = dc[5]
			var key: int = ALL_SPEC if (flag & F_ALL) else spec
			var layerless := spec & ~(AUTHOR_LAYER | INLINE_SPEC)
			out.append({
				"value": String(pair[1]),
				"property": dprop,
				"declared": raw,
				"winner": false,
				"status": "overridden",
				"rank": dc[6],
				"specificity": Vector3i.ZERO if dc[6] == "inline" else Vector3i(
					(layerless >> 40) & 0xFFFFF, (layerless >> 20) & 0xFFFFF, layerless & 0xFFFFF),
				"order": j,
				"origin": (dc[4] as Dictionary).duplicate(true),
				"_key": key,
				"_failed": failed,
			})
	# Winner first: the highest key, later declarations winning ties.
	out.sort_custom(func(a, b):
		if a["_key"] != b["_key"]:
			return a["_key"] > b["_key"]
		return a["order"] > b["order"])
	var fallback := ""  # "inherited" or "default" when the winner gives no value
	if out.is_empty():
		fallback = "inherited" if _is_inherited(property) else "default"
	else:
		var w: Dictionary = out[0]
		if w["_failed"]:
			w["status"] = "dropped"
			fallback = "inherited" if _is_inherited(property) else "default"
		elif w["value"] == "initial":
			w["status"] = "keyword"
			fallback = "default"
		elif w["value"] == "unset":
			w["status"] = "keyword"
			fallback = "inherited" if _is_inherited(property) else "default"
		else:
			w["status"] = "winner"
			w["winner"] = true
			if property == "font-size" and w["value"].ends_with("%"):
				var pxv := _font_percent(w["value"], parent_style.get("font-size"))
				if not pxv.is_empty():
					w["value"] = pxv
	for e in out:
		if e["_failed"] and e["status"] == "overridden":
			e["status"] = "dropped"
		e.erase("_key")
		e.erase("_failed")
	if fallback == "inherited":
		var pe = parent_style.get(property)
		if pe != null:
			var p := _parent[i]
			out.append({"value": String(pe["value"]), "property": property, "declared": "",
				"winner": true, "status": "inherited", "rank": "inherited",
				"specificity": Vector3i.ZERO, "order": -1,
				"origin": {"kind": "inherited", "from": els[p], "origin": (pe["origin"] as Dictionary).duplicate(true)}})
		else:
			fallback = "default"
	if fallback == "default":
		out.append({"value": UssTransitions.INITIAL.get(property), "property": property, "declared": "",
			"winner": true, "status": "default", "rank": "default",
			"specificity": Vector3i.ZERO, "order": -1, "origin": {"kind": "default"}})
	return out


## [name, class set, state bits] of preorder index `j`, read from the
## element (the values the last update() read).
func _x_ctx(j: int, bits_of: Callable, ctx: Dictionary) -> Array:
	var c = ctx.get(j)
	if c != null:
		return c
	var el: UxmlElement = els[j]
	c = [el.get_attribute("name"), _class_set(el.get_attribute("class"), _local[j]), int(bits_of.call(j))]
	ctx[j] = c
	return c


## _match_from over the explain context.
func _x_match(parts: Array, k: int, i: int, scope_idx: int, bits_of: Callable, ctx: Dictionary) -> bool:
	var cp: Array = parts[k]
	var x := _x_ctx(i, bits_of, ctx)
	for t in (cp[0] as PackedStringArray):
		if _local[i] != t:
			return false
	for n in (cp[1] as PackedStringArray):
		if x[0] != n:
			return false
	var set: Dictionary = x[1]
	for cl in (cp[2] as PackedStringArray):
		if not set.has(cl):
			return false
	var m: int = cp[3]
	if m != 0 and (int(x[2]) & m) != m:
		return false
	if cp[4] and (scope_idx < 0 or i != scope_idx):
		return false
	if k == 0:
		return true
	var p := _sel_parent[i]
	if cp[5]:
		return p >= 0 and _x_match(parts, k - 1, p, scope_idx, bits_of, ctx)
	while p >= 0:
		if _x_match(parts, k - 1, p, scope_idx, bits_of, ctx):
			return true
		p = _sel_parent[p]
	return false
